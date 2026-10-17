#!/bin/bash
# Stop Claude Notch and remove everything it installed: the app, its login agent, its hook
# entries in ~/.claude/settings.json (backed up first) and its state files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.joshdare.claudenotch"
MASCOT="$HOME/.claude/mascot"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x ClaudeNotch 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/ClaudeNotch.app"
python3 "$ROOT/scripts/wire_hooks.py" --remove --apply
rm -rf "$MASCOT/sessions"
rm -f "$MASCOT/session_state.py" "$MASCOT/notch.alive" "$MASCOT/open-claude.command"
echo "Claude Notch removed."
