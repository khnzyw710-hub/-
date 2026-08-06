# Context Limit Fix for Claude Code

Fixes the recurring **"Context limit reached / /compact or /clear to continue"** message
in Claude Code by tuning auto-compaction timing and enabling lazy MCP tool loading.

## The Problem

Claude Code blocks at 177,000 tokens (200K - 23K). Default auto-compaction starts at 167K —
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

## Full Setup (Clone This Repo)

For the full diagnostic (16 checks) and organized settings chain:

```bash
git clone <this-repo>
cd -
bash scripts/setup.sh               # full chain: diagnose + fix + propagate
bash scripts/setup.sh --check       # dry run only
```

### What `setup.sh` Does

```
.claude/settings.json           ← single source of truth for all values
        │
        ├─ Step 1 (fix-context-limit.sh):
        │       ├─ runs 16 diagnostic checks
        │       ├─ writes values to ~/.claude/settings.json
        │       └─ writes shell profile exports
        │
        └─ Step 2 (apply-globally.sh):
                └─ merges project settings into ~/.claude/settings.json
```

Individual steps can also run separately:

```bash
bash scripts/fix-context-limit.sh            # diagnose + fix
bash scripts/fix-context-limit.sh --check    # dry run only
bash scripts/apply-globally.sh               # propagate project → global
```

## What It Sets

All values are defined in `.claude/settings.json` — one source of truth.

| Setting | Value | Effect |
|---|---|---|
| `ENABLE_TOOL_SEARCH` | `true` | Lazy tool schema loading |
| `autoCompactWindow` | `120000` | Compaction at ~87K instead of 167K |
| `autoCompactEnabled` | `true` | Ensure compaction is on |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `120000` | Same value as env var for sub-agents |
| `MAX_MCP_OUTPUT_TOKENS` | `10000` | Cap single MCP result |

## How It Works — Step by Step

### Settings Precedence (Claude Code's own chain)

```
Enterprise managed-settings.json    ← wins over everything (admin only)
Shell profile exports               ← win over settings files
~/.claude/settings.json              ← user-level settings
.claude/settings.json                ← project-level settings (this repo)
```

A shell `export` beats a settings file. That's why `fix-context-limit.sh` writes to
both the settings file AND the shell profile — so nothing in between can break the chain.

### The 16 Diagnostic Checks

| # | What it checks | Script action |
|---|---|---|
| 1 | Continued conversation already above blocking line | Reports, guides to `/clear` |
| 2 | MCP schemas loaded eagerly (ToolSearch off) | **Fixes** — sets `ENABLE_TOOL_SEARCH=true` |
| 3 | `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` blocks ToolSearch | Reports as blocker |
| 4 | HIPAA mode active | Reports as blocker |
| 5 | `ANTHROPIC_BASE_URL` points to a proxy | Reports — proxy must pass `tool_reference` |
| 6 | Auto-compaction disabled | **Fixes** — enables `autoCompactEnabled` |
| 7 | Compaction window too late (167K default) | **Fixes** — sets `autoCompactWindow=120000` |
| 8 | MCP output tokens too large (25K default) | **Fixes** — caps to `10000` |
| 9 | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` shrinks window | Reports — user must unset |
| 10 | `MAX_THINKING_TOKENS` too large | Reports |
| 11 | Enterprise managed-settings.json overrides | Reports — admin only |
| 12 | Shell profile exports override settings | Reports — user must review |
| 13 | Large CLAUDE.md files | Reports size |
| 14 | Too many MCP servers | Reports count |
| 15 | Oversized saved conversation (.jsonl) | Reports — suggests `/clear` |
| 16 | `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE` detected | Reports — deliberately NOT set |

### When to Run

| Scenario | Command |
|---|---|
| First-time setup | `bash scripts/setup.sh` |
| See what would change (dry run) | `bash scripts/setup.sh --check` |
| After editing `.claude/settings.json` | `bash scripts/setup.sh` |
| Diagnose "Context limit reached" | `bash scripts/fix-context-limit.sh --check` |
| Fix without shell profile changes | `bash scripts/fix-context-limit.sh --no-profile` |

All scripts support `-h` / `--help` for usage details.

## Safety

- Scripts **never delete** anything — only add keys
- Every file is backed up to `.bak` before writing
- Stricter user values are preserved (e.g. your `MAX_MCP_OUTPUT_TOKENS=4000` stays)
- Safe to run repeatedly (idempotent)

## Troubleshooting

**"Context limit reached" returns after fix:**
1. Run `bash scripts/fix-context-limit.sh --check` to see which of the 16 causes is active
2. Check if a shell export overrides the settings: `env | grep ENABLE_TOOL_SEARCH`
3. In Claude Code, type `/context` — if MCP tools show tens of thousands of tokens, ToolSearch is still off

**Settings don't take effect:**
- Shell exports override settings files — check `~/.zshrc` / `~/.bashrc`
- Enterprise `managed-settings.json` overrides everything — needs admin
- Open a **new** terminal after running the fix

See [CONTEXT-FIX.md](CONTEXT-FIX.md) for the full technical analysis (in Hebrew).
