#!/usr/bin/env bash
# minimax-statusline.sh — MiniMax statusline (refactored, public release)
#
# Layout:  <dir> │ <branch> │ <effort> │ ctx: NN% | 5h: ⚡ ████ 98% | @reset
#
# Inputs:  JSON from MiniMax on stdin (see docs/configuration.md)
# Config:  ~/.config/statusline/config.toml  (see config.example.toml)
# Theme:   bundled in themes/  (default, minimal, vivid, solarized)
# Cache:   ~/.cache/statusline/api.json  (auto-created; 60s TTL)
#
# Flags:   --version | --help | --doctor | --dump-config | --self-test
#          | --init-config
#
# Env:     STATUSLINE_CONFIG (path to config.toml)
#          STATUSLINE_THEME  (override display.theme)
#          STATUSLINE_CACHE_DIR (override ~/.cache/statusline)
#          DEBUG_STATUSLINE=1 → log stdin JSON to debug.log
#          NO_COLOR=1 → strip all ANSI colors
#
# Compatibility: bash 3.2+ (macOS default), POSIX awk, python3.
# Never uses `set -u` (would crash the TUI on missing vars).
# Never uses NUL bytes (bash can't store them); uses 0x1e record-sep instead.

set +e
set +u
set +o pipefail
IFS=$(printf ' \t\n')

VERSION="0.2.0"
SCRIPT_NAME="minimax-statusline"
SCRIPT_DIR_LIB="$(cd "$(dirname "$0")" && pwd)/lib"

# ─── Defaults (overridden by config.toml) ────────────────────────────────
PROVIDER_NAME="minimax"
PROVIDER_TOKEN_ENV="ANTHROPIC_AUTH_TOKEN"
PROVIDER_CACHE_TTL=60
PROVIDER_TIMEOUT=5
LAYOUT=("dir" "branch" "effort" "ctx" "five_hour")
THEME="default"
FIVE_HOUR_BAR=1
CTX_SHOW_TOKENS=1
GREEN_BELOW=50
YELLOW_BELOW=20
HIGH_ICON_PCT=90
LOW_ICON_PCT=10
MODEL_TABLE=()

# ─── ANSI palette (overridden by theme) ─────────────────────────────────
esc=$'\033'
C_RESET="${esc}[0m"
C_BOLD="${esc}[1m"
C_GRAY="${esc}[2;90m"

# Bash 3.2 (macOS default) has no associative arrays, so we use a case
# statement in `color()`. Empty / unknown names return C_RESET.
color() {
  local name="${1:-}"
  if [ -z "$name" ] || [ "${NO_COLOR:-}" = "1" ]; then
    printf '%s' "$C_RESET"
    return
  fi
  case "$name" in
    black)            printf '%s' "${esc}[30m" ;;
    red)              printf '%s' "${esc}[31m" ;;
    green)            printf '%s' "${esc}[32m" ;;
    yellow)           printf '%s' "${esc}[33m" ;;
    blue)             printf '%s' "${esc}[34m" ;;
    magenta)          printf '%s' "${esc}[35m" ;;
    cyan)             printf '%s' "${esc}[36m" ;;
    white)            printf '%s' "${esc}[37m" ;;
    bold_black)       printf '%s' "${esc}[1;30m" ;;
    bold_red)         printf '%s' "${esc}[1;31m" ;;
    bold_green)       printf '%s' "${esc}[1;32m" ;;
    bold_yellow)      printf '%s' "${esc}[1;33m" ;;
    bold_blue)        printf '%s' "${esc}[1;34m" ;;
    bold_magenta)     printf '%s' "${esc}[1;35m" ;;
    bold_cyan)        printf '%s' "${esc}[1;36m" ;;
    bold_white)       printf '%s' "${esc}[1;37m" ;;
    faint)            printf '%s' "${esc}[2;37m" ;;
    dim)              printf '%s' "${esc}[2;90m" ;;
    *)                printf '%s' "$C_RESET" ;;
  esac
}

# ─── Config + theme discovery ───────────────────────────────────────────
config_path() {
  if [ -n "${STATUSLINE_CONFIG:-}" ] && [ -f "${STATUSLINE_CONFIG}" ]; then
    printf '%s' "${STATUSLINE_CONFIG}"
    return
  fi
  local p
  for p in "${XDG_CONFIG_HOME:-$HOME/.config}/statusline/config.toml" \
           "$HOME/.statusline.toml" \
           "$HOME/.claude/statusline.toml"; do
    if [ -f "$p" ]; then
      printf '%s' "$p"
      return
    fi
  done
  return 1
}

theme_path() {
  local t="${STATUSLINE_THEME:-$THEME}"
  case "$t" in
    default|minimal|vivid|solarized)
      printf '%s' "$(script_dir)/themes/${t}.toml"
      ;;
    *)
      [ -f "$t" ] && printf '%s' "$t"
      ;;
  esac
}

script_dir() {
  cd "$(dirname "$0")" && pwd
}

load_toml() {
  # Reads a TOML file and emits its JSON form on stdout. Uses stdlib tomllib
  # (3.11+) if available, else falls back to the bundled tiny_toml.
  # Must be called with the script's own lib dir on PYTHONPATH.
  local file="$1"
  [ -f "$file" ] || { printf '{}'; return; }
  PYTHONPATH="$SCRIPT_DIR_LIB:${PYTHONPATH:-}" python3 - "$file" <<'PY' 2>/dev/null
import json, sys
try:
    import tomllib
except ImportError:
    import tiny_toml as tomllib  # type: ignore
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = tomllib.loads(f.read())
except Exception:
    d = {}
print(json.dumps(d))
PY
}

apply_config() {
  local cfg_json="${1:-}"
  [ -z "$cfg_json" ] && { cfg_json="{}"; return 0; }
  # Parse with python, then expose as KEY=VALUE.
  eval "$(printf '%s' "$cfg_json" | python3 -c '
import json, sys, shlex
d = json.loads(sys.stdin.read())
prov = d.get("provider", {}) or {}
mdl  = d.get("model", {}).get("context", {}) or {}
disp = d.get("display", {}) or {}
thr  = d.get("thresholds", {}) or {}
lay  = d.get("layout") or ["dir","branch","effort","ctx","five_hour"]
def emit(k, v):
    if isinstance(v, bool): print(f"CONFIG_{k}=" + ("1" if v else "0")); return
    if isinstance(v, list):  print(f"CONFIG_{k}=(" + " ".join(shlex.quote(str(x)) for x in v) + ")"); return
    if isinstance(v, (int, float)): print(f"CONFIG_{k}={v}"); return
    print(f"CONFIG_{k}={shlex.quote(str(v))}")
emit("PROVIDER_NAME", prov.get("name", "minimax"))
emit("PROVIDER_TOKEN_ENV", prov.get("token_env", "ANTHROPIC_AUTH_TOKEN"))
emit("PROVIDER_CACHE_TTL", prov.get("cache_ttl_seconds", 60))
emit("PROVIDER_TIMEOUT", prov.get("timeout_seconds", 5))
emit("LAYOUT", lay)
emit("THEME", disp.get("theme", "default"))
emit("FIVE_HOUR_BAR", bool(disp.get("five_hour_bar", True)))
emit("CTX_SHOW_TOKENS", bool(disp.get("ctx_show_tokens", True)))
emit("GREEN_BELOW", thr.get("green_below", 50))
emit("YELLOW_BELOW", thr.get("yellow_below", 20))
emit("HIGH_ICON_PCT", thr.get("high_icon_pct", 90))
emit("LOW_ICON_PCT", thr.get("low_icon_pct", 10))
# Model table (map of substring -> int). Emit as space-separated needle|val pairs.
mt = []
for k, v in mdl.items():
    mt.append(f"{k}|{v}")
print("CONFIG_MODEL_TABLE=(" + " ".join(shlex.quote(x) for x in mt) + ")")
')" 2>/dev/null
  : "${CONFIG_PROVIDER_NAME:=minimax}"
  PROVIDER_NAME="$CONFIG_PROVIDER_NAME"
  PROVIDER_TOKEN_ENV="$CONFIG_PROVIDER_TOKEN_ENV"
  PROVIDER_CACHE_TTL="$CONFIG_PROVIDER_CACHE_TTL"
  PROVIDER_TIMEOUT="$CONFIG_PROVIDER_TIMEOUT"
  THEME="$CONFIG_THEME"
  FIVE_HOUR_BAR="$CONFIG_FIVE_HOUR_BAR"
  CTX_SHOW_TOKENS="$CONFIG_CTX_SHOW_TOKENS"
  GREEN_BELOW="$CONFIG_GREEN_BELOW"
  YELLOW_BELOW="$CONFIG_YELLOW_BELOW"
  HIGH_ICON_PCT="$CONFIG_HIGH_ICON_PCT"
  LOW_ICON_PCT="$CONFIG_LOW_ICON_PCT"
  if [ "${#CONFIG_LAYOUT[@]}" -gt 0 ]; then
    LAYOUT=("${CONFIG_LAYOUT[@]}")
  fi
  MODEL_TABLE=("${CONFIG_MODEL_TABLE[@]:-}")
}

apply_theme() {
  local theme_json="${1:-}"
  [ -z "$theme_json" ] && { theme_json="{}"; }
  # Populate a small set of THEME_* shell variables.
  eval "$(printf '%s' "$theme_json" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
def s(k, v): print(f"THEME_{k}={v!r}".replace("\"", "\\\""))
for k in ("dir_color", "branch_color", "sep_color",
          "branch_glyph", "sep_glyph",
          "bar_filled", "bar_empty",
          "icon_high", "icon_mid", "icon_low"):
    v = d.get(k, "")
    if isinstance(v, str): print(f"THEME_{k}={v!r}")
eff = d.get("effort", {}) or {}
for k, v in eff.items(): print(f"THEME_EFF_{k}={v!r}")
bar = d.get("bar", {}) or {}
for k, v in bar.items(): print(f"THEME_BAR_{k}={v!r}")
ctx = d.get("ctx", {}) or {}
for k, v in ctx.items(): print(f"THEME_CTX_{k}={v!r}")
err = d.get("error", {}) or {}
for k, v in err.items(): print(f"THEME_ERR_{k}={v!r}")
')" 2>/dev/null
  : "${THEME_dir_color:=bold_cyan}"
  : "${THEME_branch_color:=bold_yellow}"
  : "${THEME_sep_color:=dim}"
  : "${THEME_branch_glyph:=🌿}"
  : "${THEME_sep_glyph:=│}"
  : "${THEME_bar_filled:=█}"
  : "${THEME_bar_empty:=░}"
  : "${THEME_icon_high:=⚡}"
  : "${THEME_icon_mid:=🔋}"
  : "${THEME_icon_low:=🪫}"
  : "${THEME_EFF_default:=faint}"
  : "${THEME_EFF_low:=bold_blue}"
  : "${THEME_EFF_medium:=bold_cyan}"
  : "${THEME_EFF_high:=bold_magenta}"
  : "${THEME_EFF_max:=bold_magenta}"
  : "${THEME_BAR_high:=bold_green}"
  : "${THEME_BAR_mid:=bold_yellow}"
  : "${THEME_BAR_low:=bold_red}"
  : "${THEME_CTX_high:=bold_green}"
  : "${THEME_CTX_mid:=bold_yellow}"
  : "${THEME_CTX_low:=bold_red}"
  : "${THEME_ERR_no_token:=}"
  : "${THEME_ERR_net:=bold_red}"
  : "${THEME_ERR_auth:=bold_red}"
  : "${THEME_ERR_http:=bold_yellow}"
  : "${THEME_ERR_generic:=bold_red}"
}

# ─── Mode flags ─────────────────────────────────────────────────────────
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
  printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"
  exit 0
fi
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  cat <<'EOF'
minimax-statusline — MiniMax statusline (customizable, themeable)

USAGE
  minimax-statusline.sh                 read JSON from stdin, print the statusline
  minimax-statusline.sh --version       print version and exit
  minimax-statusline.sh --help          print this help
  minimax-statusline.sh --doctor        check deps, network, and config
  minimax-statusline.sh --dump-config   show resolved config + theme
  minimax-statusline.sh --self-test     run with a fixture and print the result
  minimax-statusline.sh --init-config   write ~/.config/statusline/config.toml
                                from the bundled example

ENV
  STATUSLINE_CONFIG             path to config.toml (overrides search)
  STATUSLINE_THEME              override the display.theme setting
  STATUSLINE_CACHE_DIR          override ~/.cache/statusline
  DEBUG_STATUSLINE=1            append stdin JSON to debug.log
  NO_COLOR=1                    strip all ANSI colors

DOCS
  See docs/ in the repo: installation.md, configuration.md,
  providers.md, themes.md.

VERSION 0.1.0
EOF
  exit 0
fi
if [ "${1:-}" = "--init-config" ]; then
  cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/statusline"
  mkdir -p "$cfg_dir"
  src="$(script_dir)/config.example.toml"
  if [ ! -f "$src" ]; then
    printf 'cannot find config.example.toml next to the script\n' >&2
    exit 1
  fi
  dest="$cfg_dir/config.toml"
  if [ -e "$dest" ]; then
    printf 'refusing to overwrite %s\n' "$dest" >&2
    exit 1
  fi
  cp "$src" "$dest"
  printf 'wrote %s\n' "$dest"
  exit 0
fi

# ─── Load config + theme ───────────────────────────────────────────────
SCRIPT_DIR_REAL="$(script_dir)"
SCRIPT_DIR_LIB="$SCRIPT_DIR_REAL/lib"
# Add the lib dir to PYTHONPATH for the parse/fetch helpers.
export PYTHONPATH="$SCRIPT_DIR_LIB:${PYTHONPATH:-}"

CFG_FILE=""
cfg_json=""
if CFG_FILE="$(config_path 2>/dev/null)"; then
  cfg_json="$(load_toml "$CFG_FILE")"
  apply_config "$cfg_json"
fi
THEME_FILE="$(theme_path 2>/dev/null)"
if [ -n "${THEME_FILE:-}" ] && [ -f "$THEME_FILE" ]; then
  theme_json="$(load_toml "$THEME_FILE")"
  apply_theme "$theme_json"
fi

# ─── Mode: --dump-config ───────────────────────────────────────────────
if [ "${1:-}" = "--dump-config" ]; then
  {
    printf '# minimax-statusline %s — resolved config\n\n' "$VERSION"
    printf 'config_file:   %s\n' "${CFG_FILE:-(none found)}"
    printf 'theme_file:    %s\n' "${THEME_FILE:-(none)}"
    printf 'theme:         %s\n' "$THEME"
    printf 'provider:      %s (token_env=%s, ttl=%ss, timeout=%ss)\n' \
      "$PROVIDER_NAME" "$PROVIDER_TOKEN_ENV" "$PROVIDER_CACHE_TTL" "$PROVIDER_TIMEOUT"
    printf 'layout:        %s\n' "${LAYOUT[*]}"
    printf 'thresholds:    green<%s yellow<%s high_icon>=%s low_icon<%s\n' \
      "$GREEN_BELOW" "$YELLOW_BELOW" "$HIGH_ICON_PCT" "$LOW_ICON_PCT"
    printf 'model_table:   %s entries\n' "${#MODEL_TABLE[@]}"
    for entry in "${MODEL_TABLE[@]}"; do
      printf '  - %s\n' "$entry"
    done
  }
  exit 0
fi

# ─── Mode: --doctor ────────────────────────────────────────────────────
if [ "${1:-}" = "--doctor" ]; then
  printf '== minimax-statusline doctor ==\n'
  printf 'version:       %s\n' "$VERSION"
  printf 'bash:          %s (%s)\n' "$BASH_VERSION" "$(command -v bash)"
  printf 'python3:       %s\n' "$(command -v python3 || echo MISSING)"
  printf 'python3 ok:    %s\n' "$(python3 -c 'print("yes")' 2>/dev/null || echo NO)"
  printf 'git:           %s\n' "$(command -v git || echo MISSING)"
  printf 'jq:            %s\n' "$(command -v jq || echo MISSING)"
  printf 'NO_COLOR:      %s\n' "${NO_COLOR:-(unset)}"
  printf 'config:        %s\n' "${CFG_FILE:-(no config file found)}"
  printf 'theme:         %s -> %s\n' "$THEME" "${THEME_FILE:-(no theme file)}"
  printf 'token_env:     %s (set=%s)\n' "$PROVIDER_TOKEN_ENV" \
    "$([ -n "${!PROVIDER_TOKEN_ENV:-}" ] && echo yes || echo no)"
  exit 0
fi

# ─── Mode: --self-test ────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  fixture="${SCRIPT_DIR_REAL}/tests/fixtures/basic.json"
  if [ ! -f "$fixture" ]; then
    printf 'fixture not found: %s\n' "$fixture" >&2
    exit 1
  fi
  # Re-invoke with absolute path so subprocess finds lib/ etc.
  bash "$SCRIPT_DIR_REAL/minimax-statusline.sh" < "$fixture"
  exit $?
fi

# ─── Normal mode: read stdin, render ───────────────────────────────────
# Always fully buffer stdin first (the old bug was cat-then-read-empty).
input="$(cat)"
if [ "${DEBUG_STATUSLINE:-0}" = "1" ]; then
  debug_dir="${STATUSLINE_CACHE_DIR:-$HOME/.cache/statusline}"
  mkdir -p "$debug_dir" 2>/dev/null
  {
    # Use python for a portable timestamp.
    ts="$(python3 -c 'import datetime; print(datetime.datetime.now().isoformat(timespec="milliseconds"))' 2>/dev/null || date)"
    printf '==== %s ====\n%s\n\n' "$ts" "$input"
  } >> "$debug_dir/debug.log" 2>/dev/null
fi

parse_out="$(printf '%s' "$input" | python3 "$(script_dir)/lib/parse_input.py" 2>/dev/null)"
[ -z "$parse_out" ] && parse_out="$(printf '\x1e\x1e\x1e\x1e\x1e\x1e')"
IFS=$(printf '\x1e') read -r cwd_raw _model_raw effort_raw ctx_pct_raw ctx_toks_raw branch_raw <<< "$parse_out"

cwd="${cwd_raw:-}"
effort="${effort_raw:-default}"
ctx_pct="${ctx_pct_raw:-}"
ctx_toks="${ctx_toks_raw:-}"
branch="${branch_raw:-}"

# Fallback dir if stdin was empty
if [ -z "$cwd" ]; then
  cwd="$(pwd 2>/dev/null)"
fi
dir_base="${cwd##*/}"
[ -z "$dir_base" ] && dir_base="(no-cwd)"

# Branch already extracted by parse_input.py (it runs git). Fall back for
# empty-cwd case.
if [ -z "$branch" ]; then
  branch="-"
fi

# Provider (5h) call. JSON in, JSON out.
provider_json="$(printf '%s' "$PROVIDER_NAME" | python3 -c '
import json, sys
d = {"name": sys.stdin.read().strip(),
     "token_env": "'"$PROVIDER_TOKEN_ENV"'",
     "cache_ttl_seconds": '"$PROVIDER_CACHE_TTL"',
     "timeout_seconds": '"$PROVIDER_TIMEOUT"'}
print(json.dumps(d))
' | python3 "$(script_dir)/lib/fetch_plan.py" 2>/dev/null)"

# ─── Segment renderers ────────────────────────────────────────────────
SEP_FMT="$(color "$THEME_sep_color")${THEME_sep_glyph}${C_RESET}"
SEP=" ${SEP_FMT} "

render_dir() {
  printf '%s%s%s' "$(color "$THEME_dir_color")" "$dir_base" "$C_RESET"
}

render_branch() {
  printf '%s%s %s%s' "$(color "$THEME_branch_color")" "$THEME_branch_glyph" "$branch" "$C_RESET"
}

render_effort() {
  local eff_lower
  eff_lower="$(printf '%s' "$effort" | tr '[:upper:]' '[:lower:]')"
  local c=""
  local label="$eff_lower"
  case "$eff_lower" in
    ""|default|none)    c="$THEME_EFF_default"; label="default" ;;
    high|max|xhigh|extreme) c="$THEME_EFF_high";   label="$effort" ;;
    medium|med)         c="$THEME_EFF_medium"; label="medium" ;;
    low|min|minimal)    c="$THEME_EFF_low";    label="low" ;;
    *)                  c="$THEME_EFF_default"; label="$effort" ;;
  esac
  printf 'effort=%s%s%s' "$(color "$c")" "$label" "$C_RESET"
}

render_ctx() {
  if [ -z "$ctx_pct" ]; then
    printf '%sctx:%s %sn/a%s' "$C_BOLD" "$C_RESET" "$(color faint)" "$C_RESET"
    return
  fi
  local c
  if   [ "$ctx_pct" -ge "$GREEN_BELOW" ]; then c="$THEME_CTX_high"
  elif [ "$ctx_pct" -ge "$YELLOW_BELOW" ]; then c="$THEME_CTX_mid"
  else                                            c="$THEME_CTX_low"
  fi
  if [ "$CTX_SHOW_TOKENS" = "1" ] && [ -n "$ctx_toks" ]; then
    printf '%sctx:%s %s%s%%%s %s(%s)%s' \
      "$C_BOLD" "$C_RESET" \
      "$(color "$c")" "$ctx_pct" "$C_RESET" \
      "$C_GRAY" "$ctx_toks" "$C_RESET"
  else
    printf '%sctx:%s %s%s%%%s' "$C_BOLD" "$C_RESET" "$(color "$c")" "$ctx_pct" "$C_RESET"
  fi
}

bar() {
  local r="$1"
  if ! [[ "$r" =~ ^[0-9]+$ ]]; then
    printf '%sn/a%s' "$C_GRAY" "$C_RESET"
    return
  fi
  [ "$r" -lt 0 ] && r=0
  [ "$r" -gt 100 ] && r=100
  local c icon
  if   [ "$r" -ge "$HIGH_ICON_PCT" ]; then icon="$THEME_icon_high"
  elif [ "$r" -lt "$LOW_ICON_PCT" ];  then icon="$THEME_icon_low"
  else                                     icon="$THEME_icon_mid"
  fi
  if   [ "$r" -gt "$GREEN_BELOW" ];  then c="$THEME_BAR_high"
  elif [ "$r" -ge "$YELLOW_BELOW" ]; then c="$THEME_BAR_mid"
  else                                     c="$THEME_BAR_low"
  fi
  local filled=$(( (r + 5) / 10 ))
  local empty=$(( 10 - filled ))
  local bar_str=""
  local i=0
  while [ "$i" -lt "$filled" ]; do bar_str="${bar_str}${THEME_bar_filled}"; i=$((i+1)); done
  i=0
  while [ "$i" -lt "$empty" ];  do bar_str="${bar_str}${THEME_bar_empty}"; i=$((i+1)); done
  printf '%s %s%s%s %s%3d%%%s' \
    "$icon" "$(color "$c")" "$bar_str" "$C_RESET" "$C_BOLD" "$r" "$C_RESET"
}

render_five_hour() {
  printf '%s5h:%s' "$C_BOLD" "$C_RESET"
  # Parse provider JSON
  local pct rst err stale hidden
  pct="$(printf '%s' "$provider_json" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
print(d.get("percent", "") if d.get("percent") is not None else "")
' 2>/dev/null)"
  rst="$(printf '%s' "$provider_json" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
v = d.get("reset")
print(v if v else "")
' 2>/dev/null)"
  err="$(printf '%s' "$provider_json" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
print(d.get("error", "") if d.get("error") else "")
' 2>/dev/null)"
  stale="$(printf '%s' "$provider_json" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
print("1" if d.get("stale") else "")
' 2>/dev/null)"
  hidden="$(printf '%s' "$provider_json" | python3 -c '
import json, sys
try: d = json.loads(sys.stdin.read())
except Exception: d = {}
print("1" if d.get("hidden") else "")
' 2>/dev/null)"
  if [ "$hidden" = "1" ]; then
    return
  fi
  printf ' '
  if [ -n "$err" ]; then
    case "$err" in
      no-token) c="$THEME_ERR_no_token" ;;
      net)      c="$THEME_ERR_net" ;;
      auth)     c="$THEME_ERR_auth" ;;
      http-*)   c="$THEME_ERR_http" ;;
      *)        c="$THEME_ERR_generic" ;;
    esac
    if [ -n "$c" ]; then
      printf '%s⚠ %s%s' "$(color "$c")" "$err" "$C_RESET"
    fi
  elif [ -n "$pct" ]; then
    if [ "$FIVE_HOUR_BAR" = "1" ]; then
      bar "$pct"
    else
      local c
      if   [ "$pct" -gt "$GREEN_BELOW" ];  then c="$THEME_BAR_high"
      elif [ "$pct" -ge "$YELLOW_BELOW" ]; then c="$THEME_BAR_mid"
      else                                       c="$THEME_BAR_low"
      fi
      printf '%s%s%%%s' "$(color "$c")" "$pct" "$C_RESET"
    fi
    if [ -n "$rst" ]; then
      local suffix=""
      [ "$stale" = "1" ] && suffix=" ·cached"
      printf ' %s|%s @%s%s%s' "$C_GRAY" "$C_RESET" "$rst" "$suffix" "$C_RESET"
    fi
  fi
}

# ─── Compose ──────────────────────────────────────────────────────────
out=""
for seg in "${LAYOUT[@]}"; do
  case "$seg" in
    dir)       piece="$(render_dir)" ;;
    branch)    piece="$(render_branch)" ;;
    effort)    piece="$(render_effort)" ;;
    ctx)       piece="$(render_ctx)" ;;
    five_hour) piece="$(render_five_hour)" ;;
    *)         piece="" ;;
  esac
  if [ -z "$piece" ]; then continue; fi
  if [ -z "$out" ]; then
    out="$piece"
  else
    out="${out}${SEP}${piece}"
  fi
done
printf '%s\n' "$out"
