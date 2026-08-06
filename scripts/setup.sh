#!/usr/bin/env bash
# =============================================================================
#  Single entry point — runs the full settings chain end-to-end.
#
#  Step 1: Diagnose all 16 causes and fix ~/.claude/settings.json + shell profile
#  Step 2: Propagate project settings (.claude/settings.json) to user level
#
#  Both steps read their target values from .claude/settings.json so there is
#  one source of truth. Safe to run repeatedly.
#
#  Usage:
#    bash scripts/setup.sh               # full run
#    bash scripts/setup.sh --check       # dry run (both steps read-only)
#    bash scripts/setup.sh -h            # show help
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<'HELP'
Claude Code Context Fix — full setup

Usage:
  bash scripts/setup.sh [OPTIONS]

Options:
  --check, --dry-run   Dry run — both steps read only, nothing is written.
  --no-profile         Passed to fix-context-limit.sh: skip shell profile exports.
  -h, --help           Show this help and exit.

What it does:
  Step 1 (fix-context-limit.sh):
    - Runs 16 diagnostic checks for "Context limit reached" causes
    - Writes fix to ~/.claude/settings.json (backup to .bak)
    - Appends shell exports to ~/.zshrc or ~/.bashrc (backup to .bak)

  Step 2 (apply-globally.sh):
    - Merges .claude/settings.json into ~/.claude/settings.json
    - Ensures the fix applies to all projects, not just this repo

Settings chain:
  .claude/settings.json           ← single source of truth (this repo)
  → ~/.claude/settings.json       ← user-level (all projects)
  → shell profile exports         ← belt & braces (wins over settings files)

All values originate from .claude/settings.json.
Both scripts are idempotent — safe to run repeatedly.
HELP
      exit 0 ;;
  esac
done

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_ONLY=1 ;;
  esac
done

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Claude Code Context Fix — full setup                    ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Source of truth: .claude/settings.json                  ║"
echo "║  Step 1: diagnose + fix user settings & shell profile    ║"
echo "║  Step 2: propagate project settings → ~/.claude/         ║"
if [ "$CHECK_ONLY" -eq 1 ]; then
echo "║  Mode: DRY RUN (--check) — no files will be written     ║"
fi
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

echo "━━━ Step 1: Diagnose & fix ━━━"
bash "$REPO_ROOT/scripts/fix-context-limit.sh" "$@"

echo ""
echo "━━━ Step 2: Propagate project → global ━━━"
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "  --check given: skipped (would merge .claude/settings.json → ~/.claude/settings.json)"
else
  bash "$REPO_ROOT/scripts/apply-globally.sh"
fi

echo ""
echo "━━━ Done ━━━"
echo "  Settings chain:"
echo "    .claude/settings.json  (source of truth, auto-loaded per project)"
echo "    → ~/.claude/settings.json  (user-level, all projects)"
echo "    → shell profile exports  (belt & braces)"
echo ""
if [ "$CHECK_ONLY" -eq 1 ]; then
  echo "  This was a dry run. No files were modified."
else
  echo "  Open a new terminal and run:  claude"
  echo "  Then type /context to verify starting token count is under ~50K."
fi
