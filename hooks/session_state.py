#!/usr/bin/env python3
"""Claude Code hook: per-session state for Claude Notch.

Wire it to SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification,
Stop and SessionEnd. It reads the hook payload on stdin and writes
~/.claude/mascot/sessions/<session_id>.json, which the notch app watches. It also
keeps the legacy single-file ~/.claude/mascot/state.json current for the statusline.

It must never slow Claude down or break a turn: every path exits 0, fast.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path.home() / ".claude" / "mascot"
SESSIONS = ROOT / "sessions"
LEGACY_STATE = ROOT / "state.json"

TOOL_VERBS = {
    "Read": "Reading", "Edit": "Editing", "MultiEdit": "Editing", "Write": "Writing",
    "NotebookEdit": "Editing", "Grep": "Searching the code", "Glob": "Finding files",
    "WebFetch": "Reading the web", "WebSearch": "Searching the web",
    "Task": "Running a subagent", "Agent": "Running a subagent", "TodoWrite": "Planning",
}


def one_line(text, limit):
    """Flatten markdown-ish text into one line that fits the notch."""
    text = re.sub(r"```.*?```", " ", text or "", flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"^\s*(#+|>|[-*+]|\d+\.)\s+", "", text, flags=re.M)
    text = " ".join(text.replace("**", "").replace("`", "").split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def describe_tool(name, args):
    args = args if isinstance(args, dict) else {}
    if name == "Bash":
        return one_line(args.get("description"), 70) or "Running a command"
    verb = TOOL_VERBS.get(name)
    target = args.get("file_path") or args.get("notebook_path")
    if verb and target:
        return f"{verb} {os.path.basename(str(target))}"
    if verb:
        return verb
    if name.startswith("mcp__"):
        parts = name.split("__")
        server = parts[1] if len(parts) > 2 else "a tool"
        if server.startswith("claude_ai_"):  # mcp__claude_ai_Gmail__... → Gmail
            server = server[len("claude_ai_"):]
        elif server.startswith("plugin_"):  # mcp__plugin_playwright_playwright__... → playwright
            server = server.split("_")[-1]
        return f"Using {server.replace('_', ' ').replace('-', ' ')}"
    return f"Using {name}" if name else "Working"


def last_assistant_text(transcript):
    """The turn's final assistant message, read from the transcript's tail."""
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            fh.seek(max(0, fh.tell() - 512 * 1024))
            lines = fh.read().decode("utf-8", "ignore").splitlines()
    except (OSError, TypeError):
        return None
    for raw in reversed(lines):
        if '"assistant"' not in raw:
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if entry.get("type") != "assistant":
            continue
        content = (entry.get("message") or {}).get("content")
        if isinstance(content, list):
            text = " ".join(c.get("text", "") for c in content
                            if isinstance(c, dict) and c.get("type") == "text")
        elif isinstance(content, str):
            text = content
        else:
            continue
        if text.strip():
            return text
    return None


def find_host():
    """Walk up to the long-lived `claude` process. Its PID lets the notch drop
    sessions that died without SessionEnd; its TTY lets a click focus the tab."""
    try:
        out = subprocess.run(["ps", "-Ao", "pid=,ppid=,tty=,comm="],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return None, None
    procs = {}
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4 and parts[0].isdigit() and parts[1].isdigit():
            procs[int(parts[0])] = (int(parts[1]), parts[2], parts[3])
    pid = os.getppid()
    for _ in range(8):
        if pid not in procs:
            break
        ppid, tty, comm = procs[pid]
        if os.path.basename(comm) == "claude":
            return pid, (None if tty in ("??", "-") else f"/dev/{tty}")
        pid = ppid
    return None, None


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def legacy(state):
    known = ("idle", "working", "done", "needs-input")
    return {"state": state if state in known else "done", "updated": time.strftime("%H:%M:%S")}


def main():
    started = time.time()
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    raw_id = str(payload.get("session_id") or "")
    file_id = re.sub(r"[^A-Za-z0-9_-]", "", raw_id)[:80]
    event = payload.get("hook_event_name") or ""
    if not file_id or not event:
        return
    path = SESSIONS / f"{file_id}.json"

    if event == "SessionEnd":
        path.unlink(missing_ok=True)
        write_json(LEGACY_STATE, legacy("idle"))
        return

    try:
        rec = json.loads(path.read_text())
    except (OSError, ValueError):
        rec = {}
    if rec.get("updated_at", 0) > started:
        return  # a later event already landed; async hooks can finish out of order

    state = rec.get("state", "idle")
    if event == "SessionStart":
        if payload.get("source") != "compact":  # auto-compact fires mid-turn
            state, rec["message"] = "idle", None
    elif event == "UserPromptSubmit":
        state = "working"
        rec.update(prompt=one_line(payload.get("prompt"), 90) or None, message="Thinking…",
                   turn_started_at=started, turn_ended_at=None)
    elif event == "PreToolUse":
        state = "working"
        rec["message"] = describe_tool(payload.get("tool_name") or "", payload.get("tool_input"))
    elif event == "PostToolUse":
        if state in ("needs-input", "waiting"):  # permission granted; Claude carries on
            state = "working"
            rec["message"] = describe_tool(payload.get("tool_name") or "", payload.get("tool_input"))
    elif event == "Notification":
        kind = payload.get("notification_type") or ""
        message = one_line(payload.get("message"), 110)
        if kind == "idle_prompt" or "waiting for your input" in message.lower():
            if state in ("done", "idle", "waiting"):
                state = "waiting"
        elif kind != "auth_success":
            state = "needs-input"
            rec["message"] = message or "Claude needs your input"
    elif event == "Stop":
        state = "done"
        summary = last_assistant_text(payload.get("transcript_path"))
        rec.update(message=one_line(summary, 120) if summary else "Finished", turn_ended_at=started)
    else:
        return  # SubagentStop, PreCompact, ...: nothing to show

    cwd = payload.get("cwd") or rec.get("cwd") or os.getcwd()
    rec.update(session_id=raw_id, state=state, cwd=cwd, event=event, updated_at=started,
               project=os.path.basename(cwd.rstrip("/")) or "~", seq=int(rec.get("seq", 0)) + 1)
    rec.setdefault("app", os.environ.get("__CFBundleIdentifier"))
    rec.setdefault("term", os.environ.get("TERM_PROGRAM"))
    if not rec.get("host_checked"):
        pid, tty = find_host()
        rec.update(pid=pid, tty=tty, host_checked=True)
    write_json(path, rec)
    if event not in ("Notification", "Stop"):  # notify.py owns those two
        write_json(LEGACY_STATE, legacy(state))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # the notch must never break a Claude turn
    sys.exit(0)
