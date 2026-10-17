#!/bin/bash
# Build, install to ~/Applications, install the hook, and start Claude Notch at login.
# Hook wiring into ~/.claude/settings.json is a separate, explicit step:
#   python3 scripts/wire_hooks.py --apply
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.joshdare.claudenotch"
DEST="$HOME/Applications/ClaudeNotch.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/scripts/build.sh"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeNotch 2>/dev/null || true
# Let the old copy finish exiting, or the new one may see it and bow out.
for _ in $(seq 1 30); do pgrep -x ClaudeNotch >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents" "$HOME/.claude/mascot"
rm -rf "$DEST"
ditto "$ROOT/build/ClaudeNotch.app" "$DEST"
install -m 755 "$ROOT/hooks/session_state.py" "$HOME/.claude/mascot/session_state.py"

# Launch through LaunchServices (open), never the bare binary: when launchd execs an app
# directly, macOS never finishes its launch handshake and the window stays frozen at the
# start of the app-open zoom (90% size, below the menu bar). open -W keeps launchd attached,
# and KeepAlive brings the notch back however it exits. The app's Quit unloads this agent first.
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-W</string><string>-a</string><string>$DEST</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Claude Notch is running and will start at login."
