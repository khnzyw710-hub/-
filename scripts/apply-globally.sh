#!/usr/bin/env bash
# =============================================================================
#  Propagate project settings to user-level settings
# =============================================================================
#  Merges .claude/settings.json (project, this repo) into
#  ~/.claude/settings.json (user-level, all projects).
#
#  Usage:
#    bash scripts/apply-globally.sh
#
#  What it does:
#    1. Reads target values from .claude/settings.json (single source of truth)
#    2. Backs up ~/.claude/settings.json to ~/.claude/settings.json.bak
#    3. Merges only the relevant keys — everything else is untouched
#    4. Validates the result is valid JSON
#
#  Safety:
#    - Never deletes any key from the destination file
#    - Stricter user values are preserved (e.g. your MAX_MCP_OUTPUT_TOKENS=4000 stays)
#    - Backs up before writing
#    - Safe to run repeatedly (idempotent)
#
#  Requires: python3
# =============================================================================

set -euo pipefail

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'HELP'
Propagate project settings to user-level settings.

Usage:
  bash scripts/apply-globally.sh

Merges .claude/settings.json (this repo) into ~/.claude/settings.json
so the context-limit fix applies to all projects, not just this one.

Stricter values you already set are preserved. Backs up before writing.
Requires python3.
HELP
      exit 0 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/.claude/settings.json"
DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
DEST="$DEST_DIR/settings.json"

echo ""
echo "  Propagating project settings → user-level settings"
echo "  Source: $SRC"
echo "  Target: $DEST"
echo ""

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

echo ""
echo "  Done. Settings from this project now apply to all projects."
echo "  Open a new terminal for changes to take effect."
