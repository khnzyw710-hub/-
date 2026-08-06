#!/usr/bin/env bash
# Applies the context-limit fix to the *user* settings (~/.claude/settings.json)
# so it takes effect in every project, not only in this repository.
#
#   bash scripts/apply-globally.sh
#
# Safe to run more than once. An existing file is backed up to <file>.bak and
# only the relevant keys are merged in - nothing else is touched or removed.
# Stricter values already set by the user are preserved (never loosened).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/.claude/settings.json"
DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/settings.json"

[ -f "$SRC" ] || { echo "not found: $SRC" >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required but not found on PATH" >&2
  exit 1
fi

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

def as_int(v):
    try: return int(str(v).strip())
    except (ValueError, TypeError): return None

src_window = src["autoCompactWindow"]
cur_window = as_int(dest.get("autoCompactWindow"))
if cur_window is not None and 100000 <= cur_window < src_window:
    print("  autoCompactWindow = %d (kept your stricter value)" % cur_window)
else:
    dest["autoCompactWindow"] = src_window

dest.setdefault("autoCompactEnabled", True)

env = dest.get("env")
if not isinstance(env, dict):
    env = {}

for key, value in src.get("env", {}).items():
    old = env.get(key)
    if old is not None and key == "MAX_MCP_OUTPUT_TOKENS":
        o, n = as_int(old), as_int(value)
        if o is not None and n is not None and o <= n:
            print("  %s = %s (kept your stricter value)" % (key, old))
            continue
    env[key] = value

dest["env"] = env

with open(dest_path, "w") as f:
    json.dump(dest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
  echo "merged into $DEST (backup: $DEST.bak)"
fi

python3 -c "import json,sys; json.load(open(sys.argv[1])); print('valid JSON')" "$DEST"
