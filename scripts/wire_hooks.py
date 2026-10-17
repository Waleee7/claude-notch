#!/usr/bin/env python3
"""Wire session_state.py into ~/.claude/settings.json, or take it back out. Idempotent.

Dry run by default; pass --apply to write (a timestamped backup is made first).
  python3 scripts/wire_hooks.py [--apply]            add the hooks
  python3 scripts/wire_hooks.py --remove [--apply]   remove them
"""
import json
import shutil
import sys
import time
from pathlib import Path

SETTINGS = Path.home() / ".claude" / "settings.json"
COMMAND = "python3 ~/.claude/mascot/session_state.py"
# Tool hooks run async so they never add latency to a tool call.
EVENTS = {
    "SessionStart": {},
    "UserPromptSubmit": {},
    "PreToolUse": {"matcher": "*", "async": True},
    "PostToolUse": {"matcher": "*", "async": True},
    "Notification": {},
    "Stop": {},
    "SessionEnd": {},
}


def add(hooks, changes):
    for event, options in EVENTS.items():
        groups = hooks.setdefault(event, [])
        if any(h.get("command") == COMMAND for g in groups for h in g.get("hooks", [])):
            continue
        hook = {"type": "command", "command": COMMAND, "timeout": 5}
        if options.get("async"):
            hook["async"] = True
        groups.append({"matcher": options["matcher"], "hooks": [hook]} if "matcher" in options else {"hooks": [hook]})
        changes.append(f"+ {event}: {COMMAND}{' (async)' if options.get('async') else ''}")


def remove(hooks, changes):
    for event in list(hooks):
        removed = False
        for group in hooks[event]:
            kept = [h for h in group.get("hooks", []) if h.get("command") != COMMAND]
            removed |= len(kept) != len(group.get("hooks", []))
            group["hooks"] = kept
        if removed:
            changes.append(f"- {event}: {COMMAND}")
            hooks[event] = [g for g in hooks[event] if g.get("hooks")]
            if not hooks[event]:
                del hooks[event]


def main():
    apply = "--apply" in sys.argv
    settings = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    hooks = settings.setdefault("hooks", {})
    changes = []
    (remove if "--remove" in sys.argv else add)(hooks, changes)
    if not changes:
        print("Nothing to do.")
        return
    print("\n".join(changes))
    if not apply:
        print("\nDry run. Re-run with --apply to write ~/.claude/settings.json.")
        return
    if SETTINGS.exists():
        backup = SETTINGS.with_name(f"settings.json.bak-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(SETTINGS, backup)
        print(f"\nBackup: {backup.name}")
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {SETTINGS}. New Claude sessions pick it up.")


if __name__ == "__main__":
    main()
