#!/usr/bin/env bash
# Applies the context-limit fix to the *user* settings (~/.claude/settings.json)
# so it takes effect in every project, not only in this repository.
#
#   bash .claude/apply-globally.sh
#
# Safe to run more than once. An existing file is backed up to <file>.bak and
# only the relevant keys are merged in - nothing else is touched or removed.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/settings.json"
DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/settings.json"

[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }
mkdir -p "$DEST_DIR"

if [ ! -f "$DEST" ]; then
  cp "$SRC" "$DEST"
  echo "created $DEST"
else
  cp "$DEST" "$DEST.bak"
  python3 - "$SRC" "$DEST" <<'PY'
import json, sys

src_path, dest_path = sys.argv[1], sys.argv[2]
with open(src_path) as f:
    src = json.load(f)
with open(dest_path) as f:
    dest = json.load(f)

dest["autoCompactWindow"] = src["autoCompactWindow"]
env = dest.get("env")
if not isinstance(env, dict):
    env = {}
env.update(src["env"])
dest["env"] = env

with open(dest_path, "w") as f:
    json.dump(dest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "merged into $DEST (backup: $DEST.bak)"
fi

python3 -c "import json,sys; json.load(open(sys.argv[1])); print('valid JSON')" "$DEST"
