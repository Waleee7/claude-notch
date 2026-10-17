#!/bin/bash
# Plays the scripted demo in the real notch so you can screen-record it, then puts the live
# notch back. One loop is about 17s. Record with ⌘⇧5 → "Record Selected Portion".
set -euo pipefail
LABEL="com.joshdare.claudenotch"
APP="$HOME/Applications/ClaudeNotch.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

stop_notch() {
  pkill -x ClaudeNotch 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -x ClaudeNotch >/dev/null || break; sleep 0.1; done
}

restore() {
  stop_notch
  launchctl bootstrap "$DOMAIN" "$AGENT" 2>/dev/null || launchctl kickstart -k "$DOMAIN/$LABEL"
  echo "Live notch is back."
}

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
stop_notch
trap restore EXIT
trap 'exit 130' INT TERM
# CLAUDE_NOTCH_DEBUG=1 logs every scripted step to ~/.claude/mascot/demo.log.
open -a "$APP" ${CLAUDE_NOTCH_DEBUG:+--env CLAUDE_NOTCH_DEBUG=1 --stderr "$HOME/.claude/mascot/demo.log"} --args --demo
echo "Demo is playing in the notch (loops every ~17s)."
echo "Record: ⌘⇧5 → Record Selected Portion → box the notch → Record. ⌘⌃Esc stops recording."
read -r -p "Press Return to stop the demo and bring the live notch back. " _
