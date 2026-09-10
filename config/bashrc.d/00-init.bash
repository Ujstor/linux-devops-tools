# shellcheck shell=bash
# ~/.bashrc.d/00-init.bash — devops-env-config :: the loader. DO NOT EDIT.
#
# Reached from ONE marker-fenced block in ~/.bashrc, and it is the only file
# that block knows about. Everything else this repo contributes to your shell is
# a whole-file drop-in beside this one, so nothing is ever appended to a dotfile
# and re-running the installer cannot duplicate a line.
#
# The extension is .bash, not .sh, on purpose: the loop below globs
# [0-9][0-9]-*.sh, so the loader can never source itself.
#
# Knobs (export them in ~/.bashrc.d/90-local.sh or ~/.config/devops-env/shell.env):
#   DEVENV_SKIP_FRAGMENTS="60-aliases.sh 70-tools.sh"   skip fragments by file name
#   DEVENV_DEBUG=1                            print each fragment's load time

case $- in *i*) ;; *) return 0 ;; esac # interactive shells only
[ -n "${DEVENV_SH_LOADED:-}" ] && return 0
DEVENV_SH_LOADED=1

DEVENV_DIR="${DEVENV_DIR:-$HOME/.bashrc.d}"
DEVENV_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/devops-env"
export DEVENV_DIR DEVENV_CONF

# ---------------------------------------------------------------------------
# Distro and platform facts, computed ONCE and exported. Fragments read these;
# they must not re-derive them, and nothing below forks a single process.
#
# MUST-FIX C8: /etc/os-release is PARSED, never sourced. `. /etc/os-release`
# leaks NAME, VERSION, PRETTY_NAME, LOGO, HOME_URL, SUPPORT_URL, BUG_REPORT_URL
# and friends into every interactive shell, where they collide with ordinary
# variable names. Only this repo's own DEVENV_* variables are exported.
# ---------------------------------------------------------------------------
: "${DEVENV_OS_ID:=}" "${DEVENV_OS_LIKE:=}" "${DEVENV_OS_CODENAME:=}"
if [ -z "$DEVENV_OS_ID" ] && [ -r /etc/os-release ]; then
  while IFS='=' read -r _devenv_k _devenv_v; do
    case $_devenv_v in
      '"'*'"')
        _devenv_v=${_devenv_v#\"}
        _devenv_v=${_devenv_v%\"}
        ;;
      "'"*"'")
        _devenv_v=${_devenv_v#\'}
        _devenv_v=${_devenv_v%\'}
        ;;
    esac
    case $_devenv_k in
      ID) DEVENV_OS_ID=$_devenv_v ;;
      ID_LIKE) DEVENV_OS_LIKE=$_devenv_v ;;
      VERSION_CODENAME) DEVENV_OS_CODENAME=$_devenv_v ;;
    esac
  done </etc/os-release
  unset _devenv_k _devenv_v
fi

# K25: WSL is detected from the filesystem, NEVER from $WSL_DISTRO_NAME — that
# variable is only exported by the wsl.exe launcher and is verified unset under
# systemd units, cron and `sudo` without -E.
DEVENV_IS_WSL=0
if [ -d /run/WSL ] || [ -d /usr/lib/wsl ]; then
  DEVENV_IS_WSL=1
elif [ -r /proc/sys/kernel/osrelease ]; then
  read -r _devenv_osrel </proc/sys/kernel/osrelease
  case $_devenv_osrel in *[Mm]icrosoft* | *WSL*) DEVENV_IS_WSL=1 ;; esac
  unset _devenv_osrel
fi

export DEVENV_OS_ID DEVENV_OS_LIKE DEVENV_OS_CODENAME DEVENV_IS_WSL

# ---------------------------------------------------------------------------
# The loader. Numeric filename order, and a fragment that is unreadable or
# listed in DEVENV_SKIP_FRAGMENTS is passed over rather than failing the shell.
# (NOT DEVENV_SKIP — bin/devenv exports that one as a list of MODULE names.)
# ---------------------------------------------------------------------------
for _devenv_f in "$DEVENV_DIR"/[0-9][0-9]-*.sh; do
  [ -r "$_devenv_f" ] || continue
  case " ${DEVENV_SKIP_FRAGMENTS:-} " in *" ${_devenv_f##*/} "*) continue ;; esac
  if [ -n "${DEVENV_DEBUG:-}" ] && [ -n "${EPOCHREALTIME:-}" ]; then
    _devenv_t0=${EPOCHREALTIME/./}
    # shellcheck source=/dev/null
    . "$_devenv_f"
    _devenv_t1=${EPOCHREALTIME/./}
    printf 'devenv: %-22s %6d us\n' "${_devenv_f##*/}" "$((_devenv_t1 - _devenv_t0))" >&2
  else
    # shellcheck source=/dev/null
    . "$_devenv_f"
  fi
done
unset _devenv_f _devenv_t0 _devenv_t1
