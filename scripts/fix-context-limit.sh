#!/usr/bin/env bash
# =============================================================================
#  Claude Code - "Context limit reached" full diagnose & fix
# =============================================================================
#  Run it:      bash scripts/fix-context-limit.sh
#  Dry run:     bash scripts/fix-context-limit.sh --check
#
#  SAFETY CONTRACT - this script never removes anything.
#    * It only ADDS keys to your settings file, keeping every existing key.
#    * Every file it writes is backed up first to <file>.bak.
#    * Anything that would need to be REMOVED is only DETECTED and REPORTED,
#      so you decide. The script will not delete it.
#    * It deliberately does NOT set CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE - see
#      the note at the end of the report for why that one adds risk instead of
#      removing it.
#
#  Safe to run as many times as you like.
# =============================================================================

set -uo pipefail

CHECK_ONLY=0
WRITE_PROFILE=1
for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_ONLY=1 ;;
    --no-profile)      WRITE_PROFILE=0 ;;
    -h|--help)
      sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
  esac
done

# --- helpers ------------------------------------------------------------------
hr() { printf '%s\n' "-------------------------------------------------------------"; }
h1() { printf '\n\033[1m%s\033[0m\n' "$1"; hr; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mBLOCK\033[0m %s\n' "$1"; }
inf()  { printf '        %s\n' "$1"; }

PY=""
for c in python3 python; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

# --- target values: read from .claude/settings.json (single source of truth) --
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ_SETTINGS="$REPO_ROOT/.claude/settings.json"

WANT_AUTOCOMPACT_WINDOW=120000
WANT_MCP_OUTPUT_TOKENS=10000
WANT_TOOL_SEARCH=true

if [ -f "$PROJ_SETTINGS" ] && [ -n "$PY" ]; then
  eval "$("$PY" - "$PROJ_SETTINGS" <<'PY' 2>/dev/null || true
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    w = s.get("autoCompactWindow")
    if isinstance(w, int) and w >= 100000:
        print("WANT_AUTOCOMPACT_WINDOW=%d" % w)
    e = s.get("env", {})
    m = e.get("MAX_MCP_OUTPUT_TOKENS")
    if m is not None:
        try:
            int(str(m))
            print("WANT_MCP_OUTPUT_TOKENS=%s" % m)
        except ValueError:
            pass
    t = e.get("ENABLE_TOOL_SEARCH")
    if t in ("true", "false", True, False):
        print("WANT_TOOL_SEARCH=%s" % str(t).lower())
except Exception:
    pass
PY
)"
fi

FINDINGS=()
BLOCKERS=()
note()    { FINDINGS+=("$1"); }
blocker() { BLOCKERS+=("$1"); }

printf '\n\033[1m Claude Code - context limit: full check\033[0m\n'

# =============================================================================
# 0. Platform
# =============================================================================
h1 "0. Platform"

UNAME="$(uname -s 2>/dev/null || echo unknown)"
IS_WSL=0
case "$UNAME" in
  Darwin)  PLATFORM=macos ;;
  Linux)   PLATFORM=linux
           if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
             PLATFORM=wsl; IS_WSL=1
           fi ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows ;;
  *)       PLATFORM=other ;;
esac
inf "platform : $PLATFORM ($UNAME)"

if command -v claude >/dev/null 2>&1; then
  inf "claude   : $(command -v claude)  $(claude --version 2>/dev/null | head -1)"
else
  inf "claude   : not on PATH from this shell"
fi
[ -n "$PY" ] && inf "python   : $(command -v $PY)" || warn "no python3 found - the merge step needs it (on Windows use WSL or Git Bash with python3)"

# =============================================================================
# 1. Where settings live
# =============================================================================
h1 "1. Settings files"

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
USER_SETTINGS="$CONFIG_DIR/settings.json"
USER_LOCAL="$CONFIG_DIR/settings.local.json"
LEGACY_CONFIG="$HOME/.claude.json"

[ -n "${CLAUDE_CONFIG_DIR:-}" ] && inf "CLAUDE_CONFIG_DIR is set -> $CLAUDE_CONFIG_DIR"

show_file() {  # path label
  if [ -f "$1" ]; then inf "$2: $1 ($(wc -c <"$1" | tr -d ' ') bytes)"
  else                 inf "$2: $1 (does not exist)"; fi
}
show_file "$USER_SETTINGS" "user     "
show_file "$USER_LOCAL"    "user-local"
show_file "$LEGACY_CONFIG" "legacy   "

PROJ_DIR="$(pwd)"
show_file "$PROJ_DIR/.claude/settings.json"       "project  "
show_file "$PROJ_DIR/.claude/settings.local.json" "proj-local"

# ---- enterprise / managed settings: these OVERRIDE everything above ----------
case "$PLATFORM" in
  macos)          MANAGED_DIRS=("/Library/Application Support/ClaudeCode") ;;
  windows)        MANAGED_DIRS=("/c/Program Files/ClaudeCode" "C:/Program Files/ClaudeCode") ;;
  wsl)            MANAGED_DIRS=("/etc/claude-code" "/mnt/c/Program Files/ClaudeCode") ;;
  *)              MANAGED_DIRS=("/etc/claude-code") ;;
esac

MANAGED_FOUND=0
for d in "${MANAGED_DIRS[@]}"; do
  f="$d/managed-settings.json"
  if [ -f "$f" ]; then
    MANAGED_FOUND=1
    bad "managed settings present: $f"
    blocker "Enterprise/admin managed settings exist at '$f'. Managed settings override your personal settings, so the fix below can be silently cancelled by them. Open the file and check whether it sets ENABLE_TOOL_SEARCH, autoCompactWindow, autoCompactEnabled, CLAUDE_CODE_MAX_CONTEXT_TOKENS, DISABLE_COMPACT or DISABLE_AUTO_COMPACT. If it does, only an admin can change it. NOT touched by this script."
    if [ -r "$f" ] && [ -n "$PY" ]; then
      "$PY" - "$f" <<'PY' || true
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception as e: print("        (unreadable: %s)"%e); raise SystemExit
keys=["env","autoCompactWindow","autoCompactEnabled"]
for k in keys:
    if k in s: print("        managed sets %s = %r"%(k,s[k]))
PY
    fi
  fi
  if [ -d "$d/managed-settings.d" ]; then
    MANAGED_FOUND=1
    bad "managed settings drop-in dir present: $d/managed-settings.d"
    blocker "Admin drop-in directory '$d/managed-settings.d' exists and also overrides your settings. NOT touched by this script."
  fi
done
[ "$MANAGED_FOUND" -eq 0 ] && ok "no enterprise/admin managed settings - your own settings are the final word"

# =============================================================================
# 2. Environment variables that can defeat the fix
# =============================================================================
h1 "2. Environment variables in this shell"

is_falsy() { case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in 0|false|no|off) return 0 ;; *) return 1 ;; esac; }
is_truthy(){ case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# 2a. the beta kill-switch - silently turns lazy tool loading OFF
if [ -n "${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-}" ] && ! is_falsy "${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS:-}"; then
  bad "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=${CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS}"
  blocker "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS is set. It forces every MCP tool schema to load eagerly at startup and it wins over ENABLE_TOOL_SEARCH, so the main fix cannot take effect while it is set. Remove that export from your shell profile yourself (this script will not delete it)."
else
  ok "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS not set"
fi

# 2b. ENABLE_TOOL_SEARCH itself
ETS="${ENABLE_TOOL_SEARCH:-}"
if [ -z "$ETS" ]; then
  inf "ENABLE_TOOL_SEARCH not set in this shell (the fix below sets it)"
elif is_falsy "$ETS"; then
  bad "ENABLE_TOOL_SEARCH=$ETS  (explicitly off)"
  blocker "ENABLE_TOOL_SEARCH is exported as '$ETS' in your shell. A shell export beats the settings file, so it cancels the fix. Change or remove that export yourself."
elif [ "$ETS" = "auto:100" ] || [ "$ETS" = "100" ]; then
  warn "ENABLE_TOOL_SEARCH=$ETS  (100 means: never defer -> same as off)"
  blocker "ENABLE_TOOL_SEARCH=$ETS means the threshold is 100%, i.e. tools are never deferred. Set it to 'true'."
else
  ok "ENABLE_TOOL_SEARCH=$ETS"
fi

# 2c. custom API endpoint - lazy tool loading is auto-disabled behind proxies
BU="${ANTHROPIC_BASE_URL:-}"
if [ -n "$BU" ]; then
  case "$BU" in
    *api.anthropic.com*|*anthropic.com*) ok "ANTHROPIC_BASE_URL=$BU (Anthropic host)" ;;
    *)
      warn "ANTHROPIC_BASE_URL=$BU (not an Anthropic host)"
      note "You go through a proxy/gateway ($BU). Claude Code disables lazy tool loading by default behind a non-Anthropic host, unless ENABLE_TOOL_SEARCH is set explicitly - which the fix below does. If your gateway does not forward 'tool_reference' blocks, tools will fail; in that case set ENABLE_TOOL_SEARCH=false again and instead reduce the number of connected MCP servers." ;;
  esac
else
  ok "ANTHROPIC_BASE_URL not set (talking to Anthropic directly)"
fi
for v in ANTHROPIC_AUTH_TOKEN_HELPER CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX; do
  [ -n "${!v:-}" ] && note "$v=${!v} - you are on a non-default backend; the window size can differ from 200K there."
done

# 2d. a shrunken context window - the single most brutal cause
MCT="${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}"
if [ -n "$MCT" ]; then
  bad "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$MCT"
  blocker "CLAUDE_CODE_MAX_CONTEXT_TOKENS=$MCT shrinks the whole context window. The block message fires at (window - 23000) tokens, so with $MCT the message can appear the moment you open a terminal. Unset it unless you set it on purpose."
else
  ok "CLAUDE_CODE_MAX_CONTEXT_TOKENS not set"
fi

# 2e. compaction switched off entirely
for v in DISABLE_COMPACT DISABLE_AUTO_COMPACT; do
  if [ -n "${!v:-}" ] && ! is_falsy "${!v:-}"; then
    bad "$v=${!v}"
    blocker "$v is set, which turns auto-compaction off. Without auto-compaction the conversation just grows until it hits the wall and you get the message. Remove that export yourself."
  else
    ok "$v not set"
  fi
done

# 2f. tuning knobs worth reporting
[ -n "${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE:-}" ] && note "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=$CLAUDE_AUTOCOMPACT_PCT_OVERRIDE - compaction starts at that percentage of the window."
[ -n "${MAX_THINKING_TOKENS:-}" ]             && note "MAX_THINKING_TOKENS=$MAX_THINKING_TOKENS - large values make every turn heavier."
[ -n "${MAX_MCP_OUTPUT_TOKENS:-}" ]           && inf "MAX_MCP_OUTPUT_TOKENS=$MAX_MCP_OUTPUT_TOKENS"
if [ -n "${CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE:-}" ]; then
  bad "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE=$CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE"
  blocker "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE is set. It moves the local safety line. If it is above the real server limit you trade a clean local message for hard API errors mid-work. Unset it."
fi

# =============================================================================
# 3. Shell profiles - a profile export beats the settings file
# =============================================================================
h1 "3. Shell profiles"

PROFILES=("$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile")
WATCH='ENABLE_TOOL_SEARCH|CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS|CLAUDE_CODE_MAX_CONTEXT_TOKENS|DISABLE_AUTO_COMPACT|DISABLE_COMPACT|CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE|ANTHROPIC_BASE_URL|MAX_THINKING_TOKENS|CLAUDE_CODE_AUTO_COMPACT_WINDOW|MAX_MCP_OUTPUT_TOKENS'
PROFILE_HITS=0
for p in "${PROFILES[@]}"; do
  [ -f "$p" ] || continue
  if grep -nE "$WATCH" "$p" >/dev/null 2>&1; then
    PROFILE_HITS=1
    warn "$p mentions Claude Code variables:"
    grep -nE "$WATCH" "$p" | sed 's/^/          /'
  fi
done
if [ "$PROFILE_HITS" -eq 0 ]; then
  ok "no Claude Code variables exported from your shell profiles"
else
  note "Lines above are exported by your shell and beat the settings file. Review them; this script does not edit or delete existing lines."
fi

# =============================================================================
# 4. The /config auto-compact toggle
# =============================================================================
h1 "4. Auto-compact toggle"

if [ -f "$LEGACY_CONFIG" ] && [ -n "$PY" ]; then
  AC=$("$PY" - "$LEGACY_CONFIG" <<'PY' 2>/dev/null
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception: print("?"); raise SystemExit
print(s.get("autoCompactEnabled","unset"))
PY
)
  case "$AC" in
    False|false)
      bad "autoCompactEnabled = false in $LEGACY_CONFIG"
      blocker "Auto-compact is switched OFF (the 'Auto-compact' toggle in /config). With it off the conversation never shrinks and the message is guaranteed sooner or later. The fix below re-enables it in settings.json, which takes priority - you can also turn it back on in /config." ;;
    True|true) ok "autoCompactEnabled = true" ;;
    *)         ok "autoCompactEnabled not overridden (defaults to on)" ;;
  esac
else
  inf "$LEGACY_CONFIG not readable - skipped"
fi

# =============================================================================
# 5. What is filling the window at startup
# =============================================================================
h1 "5. Startup weight"

if [ -f "$LEGACY_CONFIG" ] && [ -n "$PY" ]; then
  "$PY" - "$LEGACY_CONFIG" <<'PY' || true
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
n=len(s.get("mcpServers") or {})
print("        MCP servers in ~/.claude.json : %d"%n)
p=s.get("projects") or {}
tot=0
for v in p.values():
    if isinstance(v,dict): tot+=len(v.get("mcpServers") or {})
if tot: print("        MCP servers in project entries: %d"%tot)
PY
fi
for f in "$PROJ_DIR/.mcp.json" "$HOME/.mcp.json"; do
  [ -f "$f" ] && [ -n "$PY" ] && "$PY" -c "
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception: raise SystemExit
print('        MCP servers in %s: %d'%(sys.argv[1], len(s.get('mcpServers') or {})))
" "$f"
done
note "Every connected MCP server / connector publishes its tools. With lazy loading ON they are fetched only when needed; with it OFF all of them sit in the window from the first second."

for f in "$HOME/.claude/CLAUDE.md" "$PROJ_DIR/CLAUDE.md" "$PROJ_DIR/.claude/CLAUDE.md"; do
  if [ -f "$f" ]; then
    b=$(wc -c <"$f" | tr -d ' ')
    if [ "$b" -gt 20000 ]; then
      warn "$f is $b bytes (~$((b/4)) tokens) - loaded into every session"
      note "$f is large ($b bytes). It is loaded at the start of every session. Shortening it helps, but this script does not touch it."
    else
      ok "$(basename "$f") $b bytes - fine ($f)"
    fi
  fi
done

if [ -d "$CONFIG_DIR/projects" ]; then
  BIG=$(find "$CONFIG_DIR/projects" -name '*.jsonl' -size +5M 2>/dev/null | head -5)
  if [ -n "$BIG" ]; then
    warn "very large saved conversations found:"
    printf '%s\n' "$BIG" | sed 's/^/          /'
    note "Those are old conversations. If a terminal resumes one of them (--continue / --resume, or the IDE restoring the last session) it starts already full and the message appears immediately. Opening a new conversation with /clear avoids it. This script deletes nothing."
  else
    ok "no oversized saved conversations"
  fi
fi

# =============================================================================
# 6. Apply the fix
# =============================================================================
h1 "6. Fix"

if [ "$CHECK_ONLY" -eq 1 ]; then
  inf "--check given: nothing was written."
elif [ -z "$PY" ]; then
  bad "python3 not available - cannot write settings automatically"
else
  "$PY" - "$USER_SETTINGS" "$WANT_AUTOCOMPACT_WINDOW" "$WANT_MCP_OUTPUT_TOKENS" "$WANT_TOOL_SEARCH" <<'PY'
import json, os, shutil, sys, pathlib
path = pathlib.Path(sys.argv[1]); window = int(sys.argv[2])
mcp_out = sys.argv[3]; tool_search = sys.argv[4]
path.parent.mkdir(parents=True, exist_ok=True)
data = {}
if path.exists():
    shutil.copy(str(path), str(path) + ".bak")
    try:
        data = json.loads(path.read_text() or "{}")
    except Exception as e:
        print("        existing file is not valid JSON (%s) - it was backed up to %s.bak and rewritten" % (e, path))
        data = {}
if not isinstance(data, dict):
    data = {}
before = json.dumps(data, sort_keys=True)
changes = []

def as_int(v):
    try:
        return int(str(v).strip())
    except Exception:
        return None

data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")

# autoCompactWindow: a value you already chose that compacts EARLIER than ours is
# stricter, so we keep yours. Below 100000 Claude Code rejects the key, so those
# are replaced. Never loosened.
cur = as_int(data.get("autoCompactWindow"))
if cur is not None and 100000 <= cur < window:
    window = cur
    changes.append("autoCompactWindow = %d (kept your stricter value)" % window)
elif data.get("autoCompactWindow") != window:
    changes.append("autoCompactWindow = %d%s" % (window, "" if data.get("autoCompactWindow") is None
                                                 else " (was %r)" % data.get("autoCompactWindow")))
data["autoCompactWindow"] = window

if data.get("autoCompactEnabled") is not True:
    changes.append("autoCompactEnabled = true%s" % ("" if "autoCompactEnabled" not in data
                                                    else " (was %r)" % data.get("autoCompactEnabled")))
data["autoCompactEnabled"] = True

env = data.get("env")
if not isinstance(env, dict):
    env = {}

def set_env(key, value, keep_if_stricter=False):
    old = env.get(key)
    if old is not None and str(old) == str(value):
        return
    if keep_if_stricter:
        o, n = as_int(old), as_int(value)
        if o is not None and n is not None and o <= n:
            changes.append("env.%s = %s (kept your stricter value)" % (key, old))
            return
    env[key] = str(value)
    changes.append("env.%s = %s%s" % (key, value, "" if old is None else " (was %r)" % old))

set_env("CLAUDE_CODE_AUTO_COMPACT_WINDOW", window)
set_env("MAX_MCP_OUTPUT_TOKENS", mcp_out, keep_if_stricter=True)
set_env("ENABLE_TOOL_SEARCH", tool_search)   # this one is the actual fix - always forced on
data["env"] = env

if before == json.dumps(data, sort_keys=True):
    print("        %s was already correct - nothing changed" % path)
else:
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print("        wrote %s" % path)
for c in changes:
    print("          %s" % c)
print("        final: autoCompactWindow=%s autoCompactEnabled=%s ENABLE_TOOL_SEARCH=%s "
      "CLAUDE_CODE_AUTO_COMPACT_WINDOW=%s MAX_MCP_OUTPUT_TOKENS=%s"
      % (data["autoCompactWindow"], data["autoCompactEnabled"], env["ENABLE_TOOL_SEARCH"],
         env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"], env["MAX_MCP_OUTPUT_TOKENS"]))
PY
  if [ $? -eq 0 ]; then
    ok "settings written (backup at $USER_SETTINGS.bak)"
  else
    bad "could not write $USER_SETTINGS - nothing was changed, your file is untouched"
  fi

  # read back what actually ended up in the file, so the shell exports below cannot
  # loosen a stricter value the settings file kept
  EFF=$("$PY" - "$USER_SETTINGS" <<'PY' 2>/dev/null || true
import json, sys, pathlib
try:
    d = json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}")
    e = d.get("env") or {}
    print("%s %s" % (e.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW", ""), e.get("MAX_MCP_OUTPUT_TOKENS", "")))
except Exception:
    pass
PY
)
  EFF_WINDOW=$(printf '%s\n' "$EFF" | awk '{print $1}')
  EFF_MCP=$(printf '%s\n' "$EFF" | awk '{print $2}')
  [ -n "$EFF_WINDOW" ] && WANT_AUTOCOMPACT_WINDOW="$EFF_WINDOW"
  [ -n "$EFF_MCP" ] && WANT_MCP_OUTPUT_TOKENS="$EFF_MCP"

  # local settings file shadows the shared one - keep it consistent if it exists
  if [ -f "$USER_LOCAL" ]; then
    "$PY" - "$USER_LOCAL" "$WANT_TOOL_SEARCH" <<'PY' || true
import json, shutil, sys, pathlib
path = pathlib.Path(sys.argv[1]); ts = sys.argv[2]
try: data = json.loads(path.read_text() or "{}")
except Exception: raise SystemExit
if not isinstance(data, dict): raise SystemExit
env = data.get("env")
if isinstance(env, dict) and "ENABLE_TOOL_SEARCH" in env and env["ENABLE_TOOL_SEARCH"] != ts:
    shutil.copy(str(path), str(path) + ".bak")
    env["ENABLE_TOOL_SEARCH"] = ts
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print("        %s also set ENABLE_TOOL_SEARCH - aligned to %r (backup .bak)" % (path, ts))
PY
  fi

  # belt and braces: a shell export wins over the settings file, so set it there too
  if [ "$WRITE_PROFILE" -eq 1 ]; then
    TARGET=""
    case "${SHELL:-}" in
      */zsh)  TARGET="$HOME/.zshrc" ;;
      */bash) [ "$PLATFORM" = macos ] && TARGET="$HOME/.bash_profile" || TARGET="$HOME/.bashrc" ;;
      *)      for p in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do [ -f "$p" ] && { TARGET="$p"; break; }; done ;;
    esac
    if [ -z "$TARGET" ]; then
      inf "no shell profile identified - skipped (settings.json alone is enough)"
    elif grep -q 'claude-code context fix' "$TARGET" 2>/dev/null; then
      ok "shell profile already carries the fix ($TARGET)"
    else
      [ -f "$TARGET" ] && cp "$TARGET" "$TARGET.bak"
      {
        echo ""
        echo "# --- claude-code context fix (added by fix-context-limit.sh) ---"
        echo "export ENABLE_TOOL_SEARCH=true"
        echo "export CLAUDE_CODE_AUTO_COMPACT_WINDOW=$WANT_AUTOCOMPACT_WINDOW"
        echo "export MAX_MCP_OUTPUT_TOKENS=$WANT_MCP_OUTPUT_TOKENS"
        echo "# --- end claude-code context fix ---"
      } >> "$TARGET"
      ok "appended the same three variables to $TARGET (backup at $TARGET.bak)"
      inf "open a new terminal, or run: source $TARGET"
    fi
  fi
fi

# =============================================================================
# 7. Verdict
# =============================================================================
h1 "7. Result"

if [ ${#BLOCKERS[@]} -eq 0 ]; then
  ok "nothing on this machine is cancelling the fix"
  inf ""
  inf "Open a NEW terminal and run:  claude"
  inf "Then type /context - the number at the top is your starting size."
  inf "Under ~50K means lazy tool loading is working."
else
  bad "${#BLOCKERS[@]} thing(s) can still cancel the fix - none of them were touched:"
  i=1
  for b in "${BLOCKERS[@]}"; do
    printf '\n  %d) %s\n' "$i" "$b"
    i=$((i+1))
  done
fi

if [ ${#FINDINGS[@]} -gt 0 ]; then
  h1 "Notes"
  for n in "${FINDINGS[@]}"; do printf '  - %s\n' "$n"; done
fi

h1 "Deliberately NOT done"
inf "CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE was not set. It moves the local safety"
inf "line upward, so instead of a clean local message you would hit real server"
inf "errors in the middle of work, and lose the turn. That adds risk, so it stays off."
inf ""
inf "Nothing was deleted. No connector, MCP server, skill or file was removed."
printf '\n'
