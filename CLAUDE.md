# Context Limit Fix Toolkit

Diagnostic and fix toolkit for the "Context limit reached" error in Claude Code.

## Repository Structure

```
CLAUDE.md                       ← this file (loaded automatically by Claude Code)
README.md                       ← project overview for GitHub
CONTEXT-FIX.md                  ← full technical analysis (Hebrew)
.gitignore                      ← excludes .bak files created by the scripts
.claude/settings.json           ← SOURCE OF TRUTH for all settings values
scripts/setup.sh                ← single entry point — runs the full chain
scripts/fix-context-limit.sh    ← 16-check diagnostic, writes user settings + shell profile
scripts/apply-globally.sh       ← copies project settings to ~/.claude/settings.json
```

## Settings Chain

All settings originate from one file: `.claude/settings.json`.
Both scripts read their target values from it — nothing is hardcoded separately.

```
.claude/settings.json           ← single source of truth
        │
        ├─ auto-loaded by Claude Code (project scope, automatic)
        │
        ├─ scripts/fix-context-limit.sh reads values from here, then:
        │       ├─ writes to ~/.claude/settings.json (user scope)
        │       └─ writes to shell profile exports (belt & braces)
        │
        └─ scripts/apply-globally.sh merges values into:
                └─ ~/.claude/settings.json (user scope)
```

Run `bash scripts/setup.sh` to execute the full chain in one command.

## How to Run

```bash
bash scripts/setup.sh                    # full chain: diagnose + fix + propagate
bash scripts/setup.sh --check            # dry run, read-only

bash scripts/fix-context-limit.sh        # step 1 only: diagnose + fix
bash scripts/fix-context-limit.sh --check
bash scripts/fix-context-limit.sh --no-profile

bash scripts/apply-globally.sh           # step 2 only: project → global
```

All scripts are idempotent (safe for repeated runs).

## Settings Values (defined in .claude/settings.json)

| Key | Value | Why |
|---|---|---|
| `ENABLE_TOOL_SEARCH` | `true` | Lazy MCP tool schema loading — prevents startup bloat |
| `autoCompactWindow` | `120000` | Start compaction at ~87K tokens instead of 167K |
| `autoCompactEnabled` | `true` | Ensure auto-compaction is on |
| `CLAUDE_CODE_AUTO_COMPACT_WINDOW` | `120000` | Same value as env var for sub-agents |
| `MAX_MCP_OUTPUT_TOKENS` | `10000` | Cap single MCP result to 10K tokens |

The blocking line is at 177,000 tokens (200K window - 23K). Default compaction starts at 167K,
leaving only 10K margin. These settings widen the margin to ~90K.

## Settings Precedence (Claude Code's own chain)

```
Enterprise managed-settings.json    ← wins over everything (admin only)
Shell profile exports               ← win over settings files
~/.claude/settings.json              ← user-level settings
.claude/settings.json                ← project-level settings (this repo)
```

A shell `export` beats a settings file. That's why `fix-context-limit.sh` writes to
both the settings file AND the shell profile — so nothing in between can break the chain.

## Safety Contract — All Scripts Follow These Rules

1. **Never delete anything** — only add keys to settings files
2. **Always back up first** — every file written gets a `.bak` copy
3. **Never loosen a stricter value** — if the user set `MAX_MCP_OUTPUT_TOKENS=4000`, keep it
4. **Report, don't auto-fix removals** — items that need removal are detected and reported only
5. **Never set `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE`** — it trades a clean local message for hard API errors

## Development Rules

- All scripts must be idempotent (safe for repeated runs)
- Target values come from `.claude/settings.json` — do not hardcode values elsewhere
- Stricter-value logic must be consistent across all scripts
- Python3 is required for JSON manipulation — scripts must detect its absence gracefully
- Shell scripts target `bash` (not `sh`) and must work on macOS, Linux, WSL, and Git Bash on Windows
- `fix-context-limit.sh` deliberately omits `set -e` so all 16 checks run even if one fails
- `apply-globally.sh` and `setup.sh` use `set -e` because they perform atomic operations
- CONTEXT-FIX.md is the detailed technical reference — keep it in sync with any script changes

## The 16 Checks (fix-context-limit.sh)

1. Continued conversation already above blocking line
2. MCP schemas loaded eagerly (ToolSearch off)
3. `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` blocks ToolSearch
4. HIPAA mode active
5. `ANTHROPIC_BASE_URL` points to a proxy
6. Auto-compaction disabled
7. Compaction window too late
8. MCP output tokens too large
9. `CLAUDE_CODE_MAX_CONTEXT_TOKENS` shrinks window
10. `MAX_THINKING_TOKENS` too large
11. Enterprise managed-settings.json overrides
12. Shell profile exports override settings
13. Large CLAUDE.md files
14. Too many MCP servers
15. Oversized saved conversation (.jsonl)
16. `CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE` detected (reported, not set)

## When to Run Each Script

| Scenario | Command |
|---|---|
| First-time setup on a machine | `bash scripts/setup.sh` |
| Dry run — see what would change | `bash scripts/setup.sh --check` |
| After editing `.claude/settings.json` | `bash scripts/setup.sh` (re-propagates) |
| Diagnose without propagating | `bash scripts/fix-context-limit.sh --check` |
| Fix user settings only (no propagation) | `bash scripts/fix-context-limit.sh` |
| Fix without touching shell profile | `bash scripts/fix-context-limit.sh --no-profile` |
| Propagate only (skip diagnostics) | `bash scripts/apply-globally.sh` |
| On a new machine / fresh install | `bash scripts/setup.sh` |
| After "Context limit reached" returns | `bash scripts/fix-context-limit.sh --check` (diagnose first) |

## Execution Flow — What Runs When

### `setup.sh` (full chain)

```
setup.sh "$@"
  │
  ├─ Step 1: bash scripts/fix-context-limit.sh "$@"
  │    │
  │    ├─ Detect platform (macOS/Linux/WSL/Windows)
  │    ├─ Find python3 (required for JSON merging)
  │    ├─ Read target values from .claude/settings.json
  │    │    (falls back to hardcoded defaults if file missing or python3 absent)
  │    ├─ Run 16 diagnostic checks (checks 1–16)
  │    │    Each check: ok / warn / block
  │    │    Blockers are collected and shown at the end
  │    ├─ Write fix to ~/.claude/settings.json
  │    │    (backup to .bak, merge only relevant keys, preserve stricter values)
  │    ├─ Optionally write shell exports to profile
  │    │    (backup to .bak, appended once, marked with comment block)
  │    └─ Print verdict: 0 blockers = ready, N blockers = needs manual action
  │
  └─ Step 2: bash scripts/apply-globally.sh    (skipped in --check mode)
       │
       ├─ Read .claude/settings.json (source)
       ├─ Backup ~/.claude/settings.json to .bak
       ├─ Merge: autoCompactWindow, autoCompactEnabled, env vars
       │    (stricter user values preserved)
       └─ Validate result is valid JSON
```

### Error Paths

| Error | What happens |
|---|---|
| python3 not found | `fix-context-limit.sh`: skips settings write, reports error. `apply-globally.sh`: exits with error. |
| `.claude/settings.json` missing | Falls back to hardcoded defaults (120000, 10000, true). |
| `~/.claude/settings.json` invalid JSON | Backed up to `.bak`, rewritten from scratch. |
| `~/.claude/settings.json` doesn't exist | Created from `.claude/settings.json` directly. |
| Enterprise managed-settings.json exists | Reported as blocker — script cannot override admin settings. |
| Shell export contradicts settings file | Reported as blocker — user must remove the export manually. |
| Permission denied on settings file | Python write fails, script reports error, original file untouched. |

## Testing (Manual)

1. `bash scripts/setup.sh --check` — verify full chain runs without writing
2. `bash scripts/fix-context-limit.sh --check` — verify 16-check output
3. Edit `.claude/settings.json`, run scripts, verify they pick up the new values
4. Create a test `~/.claude/settings.json` with a stricter value, run scripts, verify it's preserved
5. Run on a fresh config — verify `.bak` is created and settings are correct
6. Verify JSON validity: `python3 -c "import json; json.load(open('path'))"`
7. Test on macOS and Linux at minimum
