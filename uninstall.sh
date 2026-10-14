#!/usr/bin/env bash
# Removes Workaholic, its sudoers rule, and its settings, and restores normal sleep.
set -euo pipefail

osascript -e 'quit app "Workaholic"' 2>/dev/null || true
osascript -e 'do shell script "/usr/bin/pmset -a disablesleep 0 && /bin/rm -f /etc/sudoers.d/workaholic" with administrator privileges' >/dev/null
rm -rf /Applications/Workaholic.app
defaults delete com.umn1k0.workaholic 2>/dev/null || true

sudo -k
if sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  echo "warning: a pmset grant is still active somewhere else in sudoers" >&2
else
  echo "Removed. Normal sleep is back and the grant is gone."
fi
