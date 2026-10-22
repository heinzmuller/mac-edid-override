#!/bin/bash
set -euo pipefail
INSTALL_DIR="$HOME/.config/edid-override"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.edid-override.plist"
if [ "$EUID" -eq 0 ]; then echo 'Run as your normal user, without sudo.' >&2; exit 1; fi
if [ -L "$INSTALL_DIR" ]; then echo 'Refusing a symlinked installation directory.' >&2; exit 1; fi
service="gui/$(id -u)/com.edid-override"
# Stop persistence even if the binary/profile is missing or invalid.
if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service"
fi
if [ -x "$INSTALL_DIR/edid_override" ]; then
    if ! "$INSTALL_DIR/edid_override" --reset; then
        echo 'Factory reset could not be verified. Reconnect the display or restart after uninstall.' >&2
    fi
else
    echo 'No reset binary found. Reconnect the display or restart to clear any runtime override.' >&2
fi
rm -f "$LAUNCH_AGENT"
rm -rf "$INSTALL_DIR"
echo 'Startup service and installed files removed.'
