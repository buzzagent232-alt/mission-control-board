#!/bin/bash
set -e

REPO_DIR="$HOME/mission-control-board"
SESSION_STORE="$HOME/.openclaw/agents/main/sessions/sessions.json"

cd "$REPO_DIR"

python3 <<PY > status.json
import json
from pathlib import Path
from datetime import datetime

session_store = Path("$SESSION_STORE")

task_candidates = [
    Path.home() / ".openclaw" / "workspace" / "tasks.json",
    Path.home() / ".openclaw" / "tasks.json",
    Path.home() / ".clawdbot" / "tasks.json",
]

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
            tasks.append({
                "title": item,
                "status": "backlog",
                "notes": ""
            })
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

def clip(text, n=180):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"

def extract_activity_from_jsonl(path, session_key, limit=2):
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

        role = (
            obj.get("role")
            or obj.get("message", {}).get("role")
            or obj.get("author", {}).get("role")
            or obj.get("type")
            or "event"
        )

        text = (
            obj.get("content")
            or obj.get("text")
            or obj.get("message", {}).get("content")
            or obj.get("delta")
            or obj.get("summary")
            or obj.get("event")
            or obj.get("type")
            or ""
        )

        if isinstance(text, list):
            text = " ".join(str(x) for x in text)

        ts = (
            obj.get("timestamp")
            or obj.get("createdAt")
            or obj.get("updatedAt")
            or obj.get("time")
            or None
        )

        if text:
            items.append({
                "session_key": session_key,
                "role": str(role),
                "text": clip(text),
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
                        limit=2
                    )
                )

sessions.sort(key=lambda x: x.get("updated_at") or 0, reverse=True)
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

payload = {
    "board_status": "Live",
    "last_updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "agent_name": "main",
    "session_store": str(session_store),
    "tasks_source": tasks_source,
    "sessions": sessions,
    "tasks": tasks,
    "recent_activity": recent_activity
}

print(json.dumps(payload, indent=2))
PY

git add status.json
git commit -m "Refresh Mission Control status" || true
git push origin main
