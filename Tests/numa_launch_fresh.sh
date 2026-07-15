#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-build/GlideBoard.app}"
executable="$PWD/$app/Contents/MacOS/GlideBoard"
pkill -f "^${executable:q}$" 2>/dev/null || true
open -n "$app"

pid=""
for _ in {1..100}; do
  pid=$(pgrep -f "^${executable:q}$" | head -1 || true)
  [[ -n "$pid" ]] && break
  sleep 0.05
done
[[ -n "$pid" ]]
actual=$(ps -p "$pid" -o comm=)
[[ "$actual" == "$executable" ]]
echo "$pid"
