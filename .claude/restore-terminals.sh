#!/usr/bin/env bash
# =============================================================================
#  Claude Code - restore terminals to how they always worked
# =============================================================================
#  Rolls back EVERYTHING the earlier context-limit fix put on this machine and
#  repairs the common causes of "I type a prompt and Claude Code drops me back
#  to a plain terminal".
#
#  Run it on the computer where the terminals misbehave, in a REGULAR terminal
#  (not inside Claude Code):
#
#      bash .claude/restore-terminals.sh              # roll back + repair
#      bash .claude/restore-terminals.sh --check      # report only, touch nothing
#      bash .claude/restore-terminals.sh --keep-compact
#                    # remove only the tool-search parts (the crash suspect),
#                    # keep the harmless compaction tuning
#
#  SAFETY CONTRACT
#    * Every file it edits is backed up first to <file>.restore-bak.
#    * It removes ONLY the exact things the fix added:
#        - the marked "claude-code context fix" block in shell profiles
#        - the keys autoCompactWindow / autoCompactEnabled and
#          env.ENABLE_TOOL_SEARCH / env.CLAUDE_CODE_AUTO_COMPACT_WINDOW /
#          env.MAX_MCP_OUTPUT_TOKENS in ~/.claude/settings.json (+ .local)
#      Everything else (model, permissions, your own keys) is untouched.
#    * A state file (~/.claude.json or settings.json) that is INVALID JSON is
#      unusable anyway; it is moved aside to <file>.corrupt-bak so Claude Code
#      can start cleanly. Valid files are never replaced.
#    * Safe to run repeatedly.
# =============================================================================

set -uo pipefail

CHECK_ONLY=0
KEEP_COMPACT=0
for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_ONLY=1 ;;
    --keep-compact)    KEEP_COMPACT=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

hr()   { printf '%s\n' "-------------------------------------------------------------"; }
h1()   { printf '\n\033[1m%s\033[0m\n' "$1"; hr; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFIX\033[0m   %s\n' "$1"; }
inf()  { printf '        %s\n' "$1"; }

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -z "$PY" ] && { echo "python3 is required (macOS: xcode-select --install)"; exit 1; }

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CHANGED=0

printf '\n\033[1m Claude Code - restore terminals\033[0m\n'
[ "$CHECK_ONLY" -eq 1 ] && inf "(--check: reporting only, no file is written)"

# =============================================================================
# 0. The claude binary itself
# =============================================================================
h1 "0. Claude Code installation"
if command -v claude >/dev/null 2>&1; then
  VER="$(claude --version 2>/dev/null | head -1 || true)"
  inf "claude : $(command -v claude)  ${VER:-<--version failed>}"
  if [ -z "$VER" ]; then
    warn "'claude --version' produced no output - the installation itself may be broken."
    inf "Run:  claude doctor        (checks and repairs the installation)"
  fi
else
  warn "claude is not on PATH from this shell - if it used to be, the installation broke."
  inf "Reinstall:  npm install -g @anthropic-ai/claude-code   (or: claude doctor from another shell)"
fi

# =============================================================================
# 1. Shell profiles - remove the exported block the fix added
# =============================================================================
h1 "1. Shell profiles"

PROFILES=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
MARK_START='# --- claude-code context fix (added by fix-context-limit.sh) ---'
MARK_END='# --- end claude-code context fix ---'
FOUND_BLOCK=0

for p in "${PROFILES[@]}"; do
  [ -f "$p" ] || continue
  if grep -qF 'claude-code context fix' "$p" 2>/dev/null; then
    FOUND_BLOCK=1
    if [ "$CHECK_ONLY" -eq 1 ]; then
      warn "$p carries the exported fix block (would be removed)"
    else
      cp "$p" "$p.restore-bak"
      awk -v s="$MARK_START" -v e="$MARK_END" '
        $0 == s {skip=1; next}
        $0 == e {skip=0; next}
        !skip'  "$p.restore-bak" > "$p"
      bad "removed the export block from $p (backup: $p.restore-bak)"
      CHANGED=1
    fi
  fi
done
[ "$FOUND_BLOCK" -eq 0 ] && ok "no fix block in any shell profile"

# leftovers we only report, never edit - user-authored lines OUTSIDE the marked block
WATCH='ENABLE_TOOL_SEARCH|CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS|CLAUDE_CODE_MAX_CONTEXT_TOKENS|DISABLE_AUTO_COMPACT|DISABLE_COMPACT|CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE|ANTHROPIC_BASE_URL|CLAUDE_CODE_AUTO_COMPACT_WINDOW|MAX_MCP_OUTPUT_TOKENS'
for p in "${PROFILES[@]}"; do
  [ -f "$p" ] || continue
  LEFTOVER="$(awk -v s="$MARK_START" -v e="$MARK_END" '
      $0 == s {skip=1; next}
      $0 == e {skip=0; next}
      !skip' "$p" | grep -nE "^[^#]*(export[[:space:]]+)?($WATCH)=" || true)"
  if [ -n "$LEFTOVER" ]; then
    warn "$p still sets Claude Code variables on its own lines (NOT added by the fix - not touched):"
    printf '%s\n' "$LEFTOVER" | sed 's/^/          /'
  fi
done

# =============================================================================
# 2. Settings files - remove exactly the keys the fix added
# =============================================================================
h1 "2. Settings files"

for f in "$CONFIG_DIR/settings.json" "$CONFIG_DIR/settings.local.json"; do
  if [ ! -f "$f" ]; then inf "$f: does not exist"; continue; fi
  OUT="$("$PY" - "$f" "$CHECK_ONLY" "$KEEP_COMPACT" <<'PY'
import json, shutil, sys, pathlib
path = pathlib.Path(sys.argv[1]); check = sys.argv[2] == "1"; keep_compact = sys.argv[3] == "1"
try:
    data = json.loads(path.read_text() or "{}")
    assert isinstance(data, dict)
except Exception as e:
    print("INVALID %s" % e); raise SystemExit(0)

removed = []
def drop(container, key, label):
    if isinstance(container, dict) and key in container:
        removed.append("%s (was %r)" % (label, container.get(key)))
        if not check:
            del container[key]

env = data.get("env") if isinstance(data.get("env"), dict) else {}
drop(env, "ENABLE_TOOL_SEARCH", "env.ENABLE_TOOL_SEARCH")
if not keep_compact:
    drop(data, "autoCompactWindow", "autoCompactWindow")
    drop(data, "autoCompactEnabled", "autoCompactEnabled")
    drop(env, "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "env.CLAUDE_CODE_AUTO_COMPACT_WINDOW")
    drop(env, "MAX_MCP_OUTPUT_TOKENS", "env.MAX_MCP_OUTPUT_TOKENS")
if not check and isinstance(data.get("env"), dict) and not data["env"]:
    del data["env"]

if not removed:
    print("CLEAN")
elif check:
    print("WOULD-REMOVE " + "; ".join(removed))
else:
    shutil.copy(str(path), str(path) + ".restore-bak")
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    json.loads(path.read_text())
    print("REMOVED " + "; ".join(removed))
PY
)"
  case "$OUT" in
    CLEAN)          ok "$f: no fix keys present" ;;
    INVALID*)       bad "$f is NOT valid JSON (${OUT#INVALID }) - this alone breaks Claude Code"
                    if [ "$CHECK_ONLY" -eq 0 ]; then
                      mv "$f" "$f.corrupt-bak"
                      bad "moved it aside to $f.corrupt-bak - Claude Code will start with defaults"
                      CHANGED=1
                    else
                      inf "(would be moved aside to $f.corrupt-bak)"
                    fi ;;
    WOULD-REMOVE*)  warn "$f: ${OUT#WOULD-REMOVE }" ;;
    REMOVED*)       bad "$f: removed ${OUT#REMOVED } (backup: $f.restore-bak)"; CHANGED=1 ;;
    *)              warn "$f: unexpected result: $OUT" ;;
  esac
done

# =============================================================================
# 3. State file ~/.claude.json - corruption here is a classic silent crash
# =============================================================================
h1 "3. State file"

STATE="$HOME/.claude.json"
if [ -f "$STATE" ]; then
  if "$PY" -c "import json,sys; json.load(open(sys.argv[1]))" "$STATE" 2>/dev/null; then
    ok "$STATE is valid JSON ($(wc -c <"$STATE" | tr -d ' ') bytes)"
  else
    bad "$STATE is CORRUPT - this makes Claude Code exit right after startup"
    if [ "$CHECK_ONLY" -eq 0 ]; then
      mv "$STATE" "$STATE.corrupt-bak"
      bad "moved it aside to $STATE.corrupt-bak - Claude Code rebuilds it on next start"
      inf "(you may need to log in again with /login, and re-add MCP servers you added by hand)"
      CHANGED=1
    else
      inf "(would be moved aside to $STATE.corrupt-bak)"
    fi
  fi
else
  inf "$STATE does not exist (Claude Code will create it)"
fi

# =============================================================================
# 4. This terminal still carries the old exports
# =============================================================================
h1 "4. Current shell"

LEFT=0
for v in ENABLE_TOOL_SEARCH CLAUDE_CODE_AUTO_COMPACT_WINDOW MAX_MCP_OUTPUT_TOKENS; do
  if [ -n "${!v:-}" ]; then
    LEFT=1
    warn "$v=${!v} is still exported in THIS terminal (loaded before the rollback)"
  fi
done
if [ "$LEFT" -eq 1 ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    inf "After running the rollback, CLOSE every open terminal window and open a new one."
  else
    inf "Profile files are now clean - just CLOSE every open terminal window and open a new one."
  fi
else
  ok "no fix variables exported in this shell"
fi
for v in CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS CLAUDE_CODE_MAX_CONTEXT_TOKENS ANTHROPIC_BASE_URL CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE; do
  [ -n "${!v:-}" ] && warn "$v=${!v} is set (not from the fix - review it if problems continue)"
done

# =============================================================================
# 5. What the last local session actually said before dying
# =============================================================================
h1 "5. Last session errors"

if [ -d "$CONFIG_DIR/projects" ]; then
  LAST="$(ls -t "$CONFIG_DIR"/projects/*/*.jsonl 2>/dev/null | head -1 || true)"
  if [ -n "$LAST" ]; then
    inf "newest session log: $LAST"
    ERRS="$(grep -oE '"(API Error[^"]{0,160}|Error[^"]{0,160})"' "$LAST" 2>/dev/null | tail -3 || true)"
    if [ -n "$ERRS" ]; then
      warn "last recorded errors in it:"
      printf '%s\n' "$ERRS" | sed 's/^/          /'
    else
      ok "no error strings recorded in it"
    fi
  else
    inf "no local session logs found"
  fi
else
  inf "$CONFIG_DIR/projects does not exist"
fi

# =============================================================================
# 6. Verdict
# =============================================================================
h1 "6. Result"

if [ "$CHECK_ONLY" -eq 1 ]; then
  inf "--check given: nothing was written. Run without --check to apply."
elif [ "$CHANGED" -eq 1 ]; then
  ok "rollback applied. Now do exactly this:"
  inf "  1. Close ALL open terminal windows (old ones still carry the removed exports)."
  inf "  2. Open a NEW terminal and run:  claude"
  inf "  3. Type any message. If it answers and stays open - done."
  inf ""
  inf "If it STILL exits after a prompt, the fix was not the cause. Then run:"
  inf "  claude doctor          # checks/repairs the installation itself"
  inf "  claude --debug         # reproduce once; the last lines name the real error"
  inf "and send me that output."
else
  ok "nothing from the fix is present on this machine - it was not the cause."
  inf "Run these to find the real one, and send me the output:"
  inf "  claude doctor"
  inf "  claude --debug         # then type one message and copy the final lines"
fi
printf '\n'
