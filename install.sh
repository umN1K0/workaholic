#!/usr/bin/env bash
# Builds Workaholic into /Applications and installs the one sudoers rule it needs.
set -euo pipefail
cd "$(dirname "$0")"

GRANT_FILE=/etc/sudoers.d/workaholic
GRANT="$(id -un) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"

osascript -e 'quit app "Workaholic"' 2>/dev/null || true
./build.sh /Applications

echo
echo "Installing this rule at $GRANT_FILE (root:wheel, 0440):"
echo "    $GRANT"
echo "It allows only turning lid-close sleep off and on. macOS will ask for your password once."

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$GRANT" > "$TMP"
visudo -cf "$TMP" >/dev/null
# The system password dialog works with or without a terminal, unlike sudo's prompt.
osascript -e "do shell script \"/usr/bin/install -m 0440 -o root -g wheel '$TMP' $GRANT_FILE && /usr/sbin/visudo -c\" with administrator privileges" >/dev/null

# Drop the cached sudo password so this check proves the rule itself works.
sudo -k
sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null || { echo "error: the rule is not active" >&2; exit 1; }

open /Applications/Workaholic.app
echo "Done. Click the cup in the menu bar."
