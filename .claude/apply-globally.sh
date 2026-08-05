#!/usr/bin/env bash
# מחיל את הגדרות ההקשר של Claude Code על כל הפרויקטים במחשב (לא רק על הריפו הזה).
# שימוש:  bash .claude/apply-globally.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/settings.json"
DEST="$HOME/.claude/settings.json"

mkdir -p "$HOME/.claude"

if [ ! -f "$DEST" ]; then
  cp "$SRC" "$DEST"
  echo "נוצר $DEST"
  exit 0
fi

# כבר קיים קובץ הגדרות — ממזגים בלי לדרוס כלום.
cp "$DEST" "$DEST.bak"
python3 - "$SRC" "$DEST" <<'PY'
import json, sys

src_path, dest_path = sys.argv[1], sys.argv[2]

with open(src_path, encoding="utf-8") as f:
    src = json.load(f)
with open(dest_path, encoding="utf-8") as f:
    dest = json.load(f)

dest["autoCompactWindow"] = src["autoCompactWindow"]
dest.setdefault("env", {})["MAX_MCP_OUTPUT_TOKENS"] = src["env"]["MAX_MCP_OUTPUT_TOKENS"]

with open(dest_path, "w", encoding="utf-8") as f:
    json.dump(dest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "מוזג לתוך $DEST (גיבוי: $DEST.bak)"
