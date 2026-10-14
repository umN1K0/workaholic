// Workaholic: a menu-bar switch that keeps the Mac awake with the lid closed.
//
// It toggles `pmset -a disablesleep` (the only setting that overrides lid-close sleep)
// through a sudoers rule scoped to exactly those two commands, and turns it back off
// on its own at the battery floor, when the timer ends, on critical heat, and on quit.

import AppKit
import Combine
import IOKit.ps
import ServiceManagement
import SwiftUI

enum Pmset {
    /// Reads the live kernel flag; `pmset -g` only lists `SleepDisabled` when it is set.
    static func sleepDisabled() -> Bool {
        run("/usr/bin/pmset", ["-g"]).output.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.first == "SleepDisabled" && fields.last == "1"
        }
    }

    /// Fails (returns false) when the sudoers grant from install.sh is missing.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]).status == 0
    }

    private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct Battery {
    let percent: Int
    let onBattery: Bool

    static func read() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Battery(
                percent: current * 100 / max,
                onBattery: desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            )
        }
        return nil
    }
}

/// Owns the sleep switch and its safety nets; the panel and the menu-bar icon render from it.
@MainActor
final class Controller: ObservableObject {
    @Published private(set) var awake = false
    @Published private(set) var deadline: Date?
    @Published private(set) var lastOffReason: String?
    @Published private(set) var battery = Battery.read()
    @Published private(set) var grantMissing = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published var timerHours: Int {
        didSet {
            UserDefaults.standard.set(timerHours, forKey: "timerHours")
            if awake { restartDeadline() }
        }
    }

    @Published var batteryFloor: Int {
        didSet {
            UserDefaults.standard.set(batteryFloor, forKey: "batteryFloor")
            enforceLimits()
        }
    }

    private var ticker: Timer?
    // Keeps App Nap from throttling the safety checks while the Mac runs lid-closed.
    private var activity: NSObjectProtocol?

    init() {
        timerHours = UserDefaults.standard.object(forKey: "timerHours") as? Int ?? 0
        batteryFloor = UserDefaults.standard.object(forKey: "batteryFloor") as? Int ?? 20
        // Always start idle, so a crash or force-quit never leaves sleep disabled past the next launch.
        if Pmset.sleepDisabled() { Pmset.setSleepDisabled(false) }
        awake = Pmset.sleepDisabled()
    }

    func setAwake(_ on: Bool) {
        on ? turnOn() : turnOff(reason: nil)
    }

    func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        try? on ? service.register() : service.unregister()
        launchAtLogin = service.status == .enabled
    }

    /// Re-reads the real flag and the battery; runs when the panel opens and on every tick.
    func refresh() {
        battery = Battery.read()
        if awake && !Pmset.sleepDisabled() { return turnOff(reason: "Turned off outside Workaholic") }
        enforceLimits()
    }

    func restoreSleep() {
        if awake { Pmset.setSleepDisabled(false) }
    }

    private func turnOn() {
        grantMissing = !Pmset.setSleepDisabled(true)
        guard !grantMissing else { return }
        awake = Pmset.sleepDisabled()
        lastOffReason = nil
        restartDeadline()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching battery, timer and heat while lid-close sleep is off"
        )
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        refresh()
    }

    private func turnOff(reason: String?) {
        Pmset.setSleepDisabled(false)
        awake = Pmset.sleepDisabled()
        lastOffReason = reason
        deadline = nil
        ticker?.invalidate()
        ticker = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func enforceLimits() {
        guard awake else { return }
        if let deadline, Date() >= deadline {
            turnOff(reason: "Timer ended")
        } else if let battery, battery.onBattery, battery.percent <= batteryFloor {
            turnOff(reason: "Battery reached \(battery.percent)%")
        } else if ProcessInfo.processInfo.thermalState == .critical {
            turnOff(reason: "Mac got too hot")
        }
    }

    private func restartDeadline() {
        deadline = timerHours > 0 ? Date().addingTimeInterval(Double(timerHours) * 3600) : nil
    }
}

// MARK: - Panel

private let warmGradient = LinearGradient(
    colors: [Color(red: 1.0, green: 0.66, blue: 0.25), Color(red: 0.97, green: 0.38, blue: 0.24)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

struct Panel: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if controller.grantMissing {
                Label("Run ./install.sh once to give Workaholic its permission.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let battery = controller.battery {
                BatteryRow(battery: battery, floor: controller.batteryFloor)
            }
            settings
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 290)
        .animation(.easeInOut(duration: 0.2), value: controller.awake)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(controller.awake ? AnyShapeStyle(warmGradient) : AnyShapeStyle(.quaternary))
                Image(systemName: controller.awake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(controller.awake ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.awake ? "Awake" : "Off")
                    .font(.system(.headline, design: .rounded))
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Toggle("Keep awake", isOn: Binding(get: { controller.awake }, set: { controller.setAwake($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.orange)
        }
    }

    private var subtitle: Text {
        if controller.awake, let deadline = controller.deadline {
            return Text("Lid can close · off in ") + Text(deadline, style: .timer).monospacedDigit()
        }
        if controller.awake { return Text("Lid can close · no timer") }
        if let reason = controller.lastOffReason { return Text("Auto-off: \(reason)") }
        return Text("Sleeps when the lid closes")
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Auto-off timer").font(.caption).foregroundStyle(.secondary)
                Picker("Auto-off timer", selection: $controller.timerHours) {
                    ForEach([0, 1, 2, 4, 8], id: \.self) { hours in
                        Text(hours == 0 ? "Never" : "\(hours)h").tag(hours)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Battery floor")
                    Spacer()
                    Text("\(controller.batteryFloor)%").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Slider(
                    // Snaps to 5% in the setter rather than via `step:`, which would draw tick marks.
                    value: Binding(
                        get: { Double(controller.batteryFloor) },
                        set: { controller.batteryFloor = Int(($0 / 5).rounded()) * 5 }
                    ),
                    in: 5...50
                )
                .controlSize(.small)
                .tint(.orange)
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle(
                "Launch at login",
                isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) })
            )
            .toggleStyle(.checkbox)
            .font(.caption)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Quit Workaholic and restore normal sleep")
        }
    }
}

struct BatteryRow: View {
    let battery: Battery
    let floor: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(
                    battery.onBattery ? "On battery" : "On power adapter",
                    systemImage: battery.onBattery ? "battery.\((battery.percent + 12) / 25 * 25)percent" : "bolt.fill"
                )
                Spacer()
                Text("\(battery.percent)%").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(battery.percent <= floor ? Color.red : Color.green.opacity(0.85))
                        .frame(width: geo.size.width * CGFloat(battery.percent) / 100)
                    Capsule()
                        .fill(.primary.opacity(0.55))
                        .frame(width: 2, height: 10)
                        .offset(x: geo.size.width * CGFloat(floor) / 100 - 1)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - App

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let controller = Controller()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var iconSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingController(rootView: Panel(controller: controller))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        iconSubscription = controller.$awake.sink { [weak self] in self?.setIcon(awake: $0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreSleep()
    }

    private func setIcon(awake: Bool) {
        let image = NSImage(
            systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: awake ? "Workaholic: awake" : "Workaholic: off"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            controller.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
