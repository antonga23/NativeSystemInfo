#!/bin/bash
set -u
LABEL=com.alatha.nativesysteminfo
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/System Information.app"
pkill -f MacOS/NativeSystemInfo 2>/dev/null
echo "removed. The signing identity is left in the login keychain (delete 'NativeSystemInfo Local Signing' in Keychain Access if unwanted)."
