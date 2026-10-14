#!/usr/bin/env bash
# Removes Wakeful, its sudoers rule, and its settings, and restores normal sleep.
set -euo pipefail

osascript -e 'quit app "Wakeful"' 2>/dev/null || true
sudo /usr/bin/pmset -a disablesleep 0
sudo rm -f /etc/sudoers.d/wakeful
rm -rf /Applications/Wakeful.app
defaults delete com.umn1k0.wakeful 2>/dev/null || true

sudo -k
if sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  echo "warning: a pmset grant is still active somewhere else in sudoers" >&2
else
  echo "Removed. Normal sleep is back and the grant is gone."
fi
