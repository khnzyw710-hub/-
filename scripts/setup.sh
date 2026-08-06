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
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  Claude Code Context Fix — full setup                    ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Source of truth: .claude/settings.json                  ║"
echo "║  Step 1: diagnose + fix user settings & shell profile    ║"
echo "║  Step 2: propagate project settings → ~/.claude/         ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

echo "━━━ Step 1: Diagnose & fix ━━━"
bash "$REPO_ROOT/scripts/fix-context-limit.sh" "$@"

# In --check mode, skip step 2 (apply-globally also only reads)
for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_ONLY=1 ;;
  esac
done

echo ""
echo "━━━ Step 2: Propagate project → global ━━━"
if [ "${CHECK_ONLY:-0}" -eq 1 ]; then
  echo "  --check given: skipped (would copy .claude/settings.json → ~/.claude/settings.json)"
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
echo "  Open a new terminal and run:  claude"
echo "  Then type /context to verify starting token count is under ~50K."
