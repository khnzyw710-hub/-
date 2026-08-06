# Context Limit Fix for Claude Code

Fixes the recurring **"Context limit reached · /compact or /clear to continue"** message
in Claude Code by tuning auto-compaction timing and enabling lazy MCP tool loading.

## The Problem

Claude Code blocks at 177,000 tokens (200K − 23K). Default auto-compaction starts at 167K —
only 10K margin. A single large MCP tool result (up to 25K tokens) can jump over that gap,
skipping compaction entirely and hitting the wall.

With ToolSearch disabled (which happens silently behind proxies), **all** MCP tool schemas
load at startup. With many connectors this alone can exceed 177K before you type a word.

## Quick Fix — One Command

No clone needed. Run in a regular terminal (not inside Claude Code):

```bash
python3 - <<'PY'
import json, os, shutil, pathlib
d = pathlib.Path(os.environ.get("CLAUDE_CONFIG_DIR") or (pathlib.Path.home() / ".claude"))
d.mkdir(parents=True, exist_ok=True)
f = d / "settings.json"
s = {}
if f.exists():
    shutil.copy(f, str(f) + ".bak")
    try: s = json.loads(f.read_text() or "{}")
    except Exception: s = {}
if not isinstance(s, dict): s = {}
s["autoCompactWindow"] = 120000
e = s.get("env")
if not isinstance(e, dict): e = {}
e.update({"CLAUDE_CODE_AUTO_COMPACT_WINDOW": "120000",
          "MAX_MCP_OUTPUT_TOKENS": "10000", "ENABLE_TOOL_SEARCH": "true"})
s["env"] = e
f.write_text(json.dumps(s, indent=2, ensure_ascii=False) + "\n")
print("OK ->", f)
PY
```

Then close and reopen Claude Code.

## Full Diagnostic (16 Checks)

Clone this repo and run:

```bash
bash scripts/fix-context-limit.sh            # diagnose + fix
bash scripts/fix-context-limit.sh --check    # dry run only
```

See [CONTEXT-FIX.md](CONTEXT-FIX.md) for the full technical analysis (in Hebrew).

## What It Sets

| Setting | Value | Effect |
|---|---|---|
| `ENABLE_TOOL_SEARCH` | `true` | Lazy tool schema loading |
| `autoCompactWindow` | `120000` | Compaction at ~87K instead of 167K |
| `autoCompactEnabled` | `true` | Ensure compaction is on |
| `MAX_MCP_OUTPUT_TOKENS` | `10000` | Cap single MCP result |

## Safety

- Scripts **never delete** anything — only add keys
- Every file is backed up to `.bak` before writing
- Stricter user values are preserved
- Safe to run repeatedly
