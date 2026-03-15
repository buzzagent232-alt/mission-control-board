#!/bin/bash
set -e

cd "$HOME/mission-control-board"
./scripts/update_status.sh >> "$HOME/mission-control-board/refresh.log" 2>&1
