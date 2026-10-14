// Wakeful: a menu-bar switch that keeps the Mac awake with the lid closed.
//
// It toggles `pmset -a disablesleep` (the only setting that overrides lid-close sleep)
// through a sudoers rule scoped to exactly those two commands, and turns it back off
// on its own at the battery floor, when the timer ends, on critical heat, and on quit.

import AppKit
import IOKit.ps
import ServiceManagement

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

@main
@MainActor
final class Wakeful: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = Wakeful()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var awake = false
    private var deadline: Date?
    private var lastOffReason: String?
    private var ticker: Timer?
    // Keeps App Nap from throttling the safety checks while the Mac runs lid-closed.
    private var activity: NSObjectProtocol?

    private let timerChoices = [0, 1, 2, 4, 8]
    private let floorChoices = [10, 20, 30, 50]

    private var timerHours: Int {
        get { UserDefaults.standard.object(forKey: "timerHours") as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: "timerHours") }
    }

    private var batteryFloor: Int {
        get { UserDefaults.standard.object(forKey: "batteryFloor") as? Int ?? 20 }
        set { UserDefaults.standard.set(newValue, forKey: "batteryFloor") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        // Always start idle, so a crash or force-quit never leaves sleep disabled past the next launch.
        if Pmset.sleepDisabled() { Pmset.setSleepDisabled(false) }
        awake = Pmset.sleepDisabled()
        refreshIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if awake { Pmset.setSleepDisabled(false) }
    }

    // MARK: - Switching

    private func turnOn() {
        guard Pmset.setSleepDisabled(true) else { return showGrantMissing() }
        awake = Pmset.sleepDisabled()
        lastOffReason = nil
        restartDeadline()
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching battery, timer and heat while lid-close sleep is off"
        )
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        check()
        refreshIcon()
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
        refreshIcon()
    }

    private func check() {
        guard awake else { return }
        if !Pmset.sleepDisabled() {
            turnOff(reason: "Turned off outside Wakeful")
        } else if let deadline, Date() >= deadline {
            turnOff(reason: "Timer ended")
        } else if let battery = Battery.read(), battery.onBattery, battery.percent <= batteryFloor {
            turnOff(reason: "Battery reached \(battery.percent)%")
        } else if ProcessInfo.processInfo.thermalState == .critical {
            turnOff(reason: "Mac got too hot")
        }
    }

    private func restartDeadline() {
        deadline = timerHours > 0 ? Date().addingTimeInterval(Double(timerHours) * 3600) : nil
    }

    private func showGrantMissing() {
        let alert = NSAlert()
        alert.messageText = "Wakeful needs its one-time permission"
        alert.informativeText = """
            Run ./install.sh from the Wakeful folder. It adds a sudoers rule that allows \
            exactly "pmset -a disablesleep 0" and "pmset -a disablesleep 1", nothing else.
            """
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Menu

    private func refreshIcon() {
        let image = NSImage(
            systemSymbolName: awake ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: awake ? "Wakeful: awake" : "Wakeful: off"
        )
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        check()
        menu.removeAllItems()

        menu.addItem(label(awake ? "Awake: lid-close sleep is off" : "Off: Mac sleeps when the lid closes"))
        if awake {
            if let deadline {
                let remaining = DateComponentsFormatter.localizedString(
                    from: DateComponents(second: Int(deadline.timeIntervalSinceNow)), unitsStyle: .abbreviated
                ) ?? ""
                menu.addItem(label("Auto-off in \(remaining)"))
            }
            if let battery = Battery.read() {
                let source = battery.onBattery ? "on battery" : "charging"
                menu.addItem(label("Battery \(battery.percent)% \(source), floor \(batteryFloor)%"))
            }
            menu.addItem(label("Keep an eye on heat with the lid closed"))
        } else if let lastOffReason {
            menu.addItem(label("Last auto-off: \(lastOffReason)"))
        }

        menu.addItem(.separator())
        menu.addItem(item(awake ? "Turn Off" : "Keep Awake", #selector(toggle), key: "k"))

        let timerMenu = NSMenu()
        for hours in timerChoices {
            let entry = item(hours == 0 ? "Never" : "After \(hours) h", #selector(pickTimer(_:)))
            entry.representedObject = hours
            entry.state = hours == timerHours ? .on : .off
            timerMenu.addItem(entry)
        }
        let timerItem = NSMenuItem(title: "Auto-off Timer", action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let floorMenu = NSMenu()
        for percent in floorChoices {
            let entry = item("At \(percent)%", #selector(pickFloor(_:)))
            entry.representedObject = percent
            entry.state = percent == batteryFloor ? .on : .off
            floorMenu.addItem(entry)
        }
        let floorItem = NSMenuItem(title: "Battery Floor", action: nil, keyEquivalent: "")
        floorItem.submenu = floorMenu
        menu.addItem(floorItem)

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Wakeful", #selector(quit), key: "q"))
    }

    private func label(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    @objc private func toggle() {
        awake ? turnOff(reason: nil) : turnOn()
    }

    @objc private func pickTimer(_ sender: NSMenuItem) {
        timerHours = sender.representedObject as? Int ?? 0
        if awake { restartDeadline() }
    }

    @objc private func pickFloor(_ sender: NSMenuItem) {
        batteryFloor = sender.representedObject as? Int ?? 20
        check()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        try? service.status == .enabled ? service.unregister() : service.register()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
