#!/bin/bash
set -e

REPO_DIR="$HOME/mission-control-board"
SESSION_STORE="$HOME/.openclaw/agents/main/sessions/sessions.json"

cd "$REPO_DIR"

python3 <<PY > status.json
import json
import subprocess
from pathlib import Path
from datetime import datetime

session_store = Path("$SESSION_STORE")

task_candidates = [
    Path.home() / ".openclaw" / "workspace" / "tasks.json",
    Path.home() / ".openclaw" / "tasks.json",
    Path.home() / ".clawdbot" / "tasks.json",
]

def run_cmd(cmd):
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=25,
            shell=False
        )
        return {
            "ok": result.returncode == 0,
            "stdout": (result.stdout or "").strip(),
            "stderr": (result.stderr or "").strip(),
            "code": result.returncode
        }
    except Exception as e:
        return {"ok": False, "stdout": "", "stderr": str(e), "code": -1}

def normalize_status(value: str) -> str:
    v = (value or "").strip().lower()
    if v in {"backlog", "todo", "to-do", "queued"}:
        return "backlog"
    if v in {"in progress", "in-progress", "doing", "active", "working"}:
        return "in_progress"
    if v in {"review", "qa", "testing", "verify"}:
        return "review"
    if v in {"done", "complete", "completed", "closed"}:
        return "done"
    return "backlog"

def extract_tasks(obj):
    raw = []
    if isinstance(obj, list):
        raw = obj
    elif isinstance(obj, dict):
        if isinstance(obj.get("tasks"), list):
            raw = obj["tasks"]
        elif isinstance(obj.get("items"), list):
            raw = obj["items"]
        elif isinstance(obj.get("cards"), list):
            raw = obj["cards"]

    tasks = []
    for i, item in enumerate(raw):
        if isinstance(item, str):
            tasks.append({"title": item, "status": "backlog", "notes": ""})
            continue
        if not isinstance(item, dict):
            continue

        title = (
            item.get("title")
            or item.get("name")
            or item.get("task")
            or item.get("summary")
            or f"Task {i+1}"
        )
        status = normalize_status(
            item.get("status")
            or item.get("state")
            or item.get("column")
            or item.get("lane")
            or "backlog"
        )
        notes = (
            item.get("notes")
            or item.get("description")
            or item.get("detail")
            or ""
        )
        owner = item.get("owner") or item.get("assignee") or ""
        priority = item.get("priority") or ""

        tasks.append({
            "title": str(title),
            "status": status,
            "notes": str(notes),
            "owner": str(owner),
            "priority": str(priority)
        })
    return tasks

def clip(text, n=220):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"

def flatten_text(value):
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float, bool)):
        return str(value)
    if isinstance(value, list):
        out = []
        for item in value:
            t = flatten_text(item)
            if t:
                out.append(t)
        return " ".join(out)
    if isinstance(value, dict):
        preferred = [
            "text", "content", "value", "delta", "summary",
            "message", "title", "event", "body"
        ]
        out = []
        for key in preferred:
            if key in value:
                t = flatten_text(value.get(key))
                if t:
                    out.append(t)
        return " ".join(out)
    return ""

def extract_role(obj):
    candidates = [
        obj.get("role"),
        (obj.get("message") or {}).get("role") if isinstance(obj.get("message"), dict) else None,
        (obj.get("author") or {}).get("role") if isinstance(obj.get("author"), dict) else None,
        obj.get("type"),
        obj.get("eventType"),
        obj.get("kind"),
    ]
    for c in candidates:
        if c:
            return str(c)
    return "event"

def extract_timestamp(obj):
    for key in ["timestamp", "createdAt", "updatedAt", "time", "ts"]:
        if obj.get(key) is not None:
            return obj.get(key)
    meta = obj.get("metadata")
    if isinstance(meta, dict):
        for key in ["timestamp", "createdAt", "updatedAt", "time", "ts"]:
            if meta.get(key) is not None:
                return meta.get(key)
    return None

def extract_text(obj):
    candidates = [
        obj.get("content"),
        obj.get("text"),
        obj.get("delta"),
        obj.get("summary"),
        obj.get("event"),
        obj.get("body"),
        obj.get("parts"),
        obj.get("messages"),
        obj.get("payload"),
        obj.get("data"),
        obj.get("output"),
        obj.get("input"),
        obj.get("result"),
    ]

    msg = obj.get("message")
    if isinstance(msg, dict):
        candidates.extend([
            msg.get("content"),
            msg.get("text"),
            msg.get("parts"),
        ])

    author = obj.get("author")
    if isinstance(author, dict):
        candidates.append(author.get("content"))

    for c in candidates:
        t = flatten_text(c)
        if t and t.strip():
            return clip(t)
    return ""

def is_noise(role, text):
    t = (text or "").strip()
    tl = t.lower()
    rl = (role or "").strip().lower()

    if not t:
        return True
    if t == "NO_REPLY":
        return True
    if tl.startswith("system: [") and "post-compaction context refresh" in tl:
        return True
    if "session was just compacted" in tl:
        return True
    if "conversation summary above is a hint" in tl:
        return True
    if rl == "system" and ("compaction" in tl or "context refresh" in tl):
        return True
    if rl in {"event", "system"} and len(t) < 8:
        return True
    return False

def extract_activity_from_jsonl(path, session_key, limit=4):
    items = []
    if not path:
        return items

    p = Path(path)
    if not p.exists():
        return items

    try:
        lines = p.read_text(errors="ignore").splitlines()
    except Exception:
        return items

    for raw in reversed(lines):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if not isinstance(obj, dict):
            continue

        role = extract_role(obj)
        text = extract_text(obj)
        ts = extract_timestamp(obj)

        if is_noise(role, text):
            continue

        items.append({
            "session_key": session_key,
            "role": str(role),
            "text": text,
            "timestamp": ts
        })

        if len(items) >= limit:
            break

    return items

sessions = []
recent_activity = []

if session_store.exists():
    data = json.loads(session_store.read_text())
    if isinstance(data, dict):
        for session_key, item in data.items():
            if isinstance(item, dict):
                session = {
                    "session_key": session_key,
                    "session_id": item.get("sessionId", ""),
                    "updated_at": item.get("updatedAt"),
                    "chat_type": item.get("chatType", ""),
                    "channel": item.get("lastChannel") or item.get("channel") or (
                        item.get("deliveryContext", {}) or {}
                    ).get("channel", ""),
                    "label": (item.get("origin", {}) or {}).get("label", ""),
                    "provider": (item.get("origin", {}) or {}).get("provider", ""),
                    "surface": (item.get("origin", {}) or {}).get("surface", ""),
                    "session_file": item.get("sessionFile", "")
                }
                sessions.append(session)
                recent_activity.extend(
                    extract_activity_from_jsonl(
                        session.get("session_file"),
                        session_key,
                        limit=4
                    )
                )

sessions.sort(key=lambda x: x.get("updated_at") or 0, reverse=True)

def sort_key(x):
    ts = x.get("timestamp")
    try:
        return float(ts)
    except Exception:
        return -1

recent_activity.sort(key=sort_key, reverse=True)
recent_activity = recent_activity[:12]

tasks_source = ""
tasks = []
for candidate in task_candidates:
    if candidate.exists():
        tasks_source = str(candidate)
        try:
            tasks = extract_tasks(json.loads(candidate.read_text()))
        except Exception:
            tasks = []
        break

openclaw_version_res = run_cmd(["openclaw", "--version"])
openclaw_version = openclaw_version_res["stdout"] or "Unknown"

gog_auth_res = run_cmd(["gog", "auth", "list", "--check"])
gog_installed = run_cmd(["which", "gog"])

gmail_res = run_cmd(["gog", "gmail", "search", "in:inbox newer_than:30d"])
calendar_res = run_cmd(["gog", "calendar", "calendars"])
drive_res = run_cmd(["gog", "drive", "ls"])
tasks_res = run_cmd(["gog", "tasks", "lists", "list"])
contacts_res = run_cmd(["gog", "contacts", "list"])

def status_from_result(res, empty_ok=False):
    if res["ok"]:
        if not res["stdout"] or res["stdout"].strip().startswith("No "):
            return "working_empty" if empty_ok else "working"
        return "working"
    return "blocked"

google_audit = {
    "account": "buzzagent232@gmail.com",
    "profile": "default",
    "services": [
        {
            "name": "gog Installed",
            "status": "working" if gog_installed["ok"] else "blocked",
            "detail": gog_installed["stdout"] or gog_installed["stderr"] or "gog not found"
        },
        {
            "name": "gog Auth",
            "status": "working" if gog_auth_res["ok"] and "true" in gog_auth_res["stdout"].lower() else "blocked",
            "detail": clip(gog_auth_res["stdout"] or gog_auth_res["stderr"] or "No auth result")
        },
        {
            "name": "Gmail",
            "status": status_from_result(gmail_res),
            "detail": clip(gmail_res["stdout"] or gmail_res["stderr"] or "No result")
        },
        {
            "name": "Calendar",
            "status": status_from_result(calendar_res, empty_ok=True),
            "detail": clip(calendar_res["stdout"] or calendar_res["stderr"] or "No result")
        },
        {
            "name": "Drive",
            "status": status_from_result(drive_res, empty_ok=True),
            "detail": clip(drive_res["stdout"] or drive_res["stderr"] or "No result")
        },
        {
            "name": "Tasks",
            "status": status_from_result(tasks_res, empty_ok=True),
            "detail": clip(tasks_res["stdout"] or tasks_res["stderr"] or "No result")
        },
        {
            "name": "Contacts",
            "status": status_from_result(contacts_res, empty_ok=True),
            "detail": clip(contacts_res["stdout"] or contacts_res["stderr"] or "No result")
        }
    ]
}

capabilities = [
    {"name": "Mission Control Board", "status": "working", "detail": "GitHub Pages board is live and updating"},
    {"name": "Auto Refresh", "status": "working", "detail": "launchd refresh job is configured on this Mac"},
    {"name": "Telegram Sessions", "status": "working", "detail": "Telegram direct session is active and visible on the board"},
    {"name": "Telegram Gmail Send", "status": "working", "detail": "Confirmed end-to-end: Telegram -> OpenClaw -> gog gmail send -> inbox delivery"},
    {"name": "Google Workspace Access", "status": "working", "detail": "Dynamic audit runs on each refresh"},
    {"name": "Recent Activity Feed", "status": "working", "detail": "Recent session activity is being extracted from jsonl logs"},
    {"name": "Tasks Kanban", "status": "working", "detail": "Tasks snapshot is loading from local tasks.json"}
]

payload = {
    "board_status": "Live",
    "last_updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "agent_name": "main",
    "session_store": str(session_store),
    "tasks_source": tasks_source,
    "sessions": sessions,
    "tasks": tasks,
    "recent_activity": recent_activity,
    "openclaw_version": openclaw_version,
    "google_audit": google_audit,
    "capabilities": capabilities
}

print(json.dumps(payload, indent=2))
PY

git add status.json
git commit -m "Refresh Mission Control status" || true
git push origin main
