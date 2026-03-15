#!/bin/bash
set -e

REPO_DIR="$HOME/mission-control-board"
SESSION_STORE="$HOME/.openclaw/agents/main/sessions/sessions.json"

cd "$REPO_DIR"

if [ -f "$SESSION_STORE" ]; then
  python3 <<PY > status.json
import json
from pathlib import Path
from datetime import datetime

session_store = Path("$SESSION_STORE")
data = json.loads(session_store.read_text())

sessions = []
if isinstance(data, dict):
    for session_key, item in data.items():
        if isinstance(item, dict):
            sessions.append({
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
            })

sessions.sort(
    key=lambda x: x.get("updated_at") or 0,
    reverse=True
)

payload = {
    "board_status": "Live",
    "last_updated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "agent_name": "main",
    "session_store": str(session_store),
    "sessions": sessions
}

print(json.dumps(payload, indent=2))
PY
else
  cat > status.json <<JSON
{
  "board_status": "Live",
  "last_updated": "$(date +"%Y-%m-%d %H:%M:%S")",
  "agent_name": "main",
  "session_store": "$SESSION_STORE",
  "sessions": []
}
JSON
fi

git add status.json
git commit -m "Refresh Mission Control status" || true
git push origin main
