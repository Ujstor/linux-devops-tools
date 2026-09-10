# shellcheck shell=bash
# devops-env-config :: runtime detection for open-url / clip / clip-paste.
# Installed at ~/.local/lib/devops-env/detect.sh. Sourced, never executed.
# NOT lib/os.sh — that one is module-side, runs inside a `devenv` run and exports
# OS_*/IS_*. This one runs in the user's shell and in processes spawned by
# kubectl, argocd and bao. Keep them separate; do not source one from the other.

[ -n "${_DEVENV_DETECT:-}" ] && return 0
_DEVENV_DETECT=1

# User-facing text goes to the controlling tty, else stderr. NEVER stdout:
#  - kubectl parses an exec credential plugin's stdout as ExecCredential JSON
#  - python webbrowser's BackgroundBrowser sends a child's stdout to /dev/null
dv_tty() { if { : >/dev/tty; } 2>/dev/null; then cat >/dev/tty; else cat >&2; fi; }

dv_is_wsl() {
  [ -d /run/WSL ] && return 0
  [ -d /usr/lib/wsl ] && return 0
  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null
}

# `[interop] enabled` controls LAUNCHING Windows processes; `appendWindowsPath`
# only controls PATH. Interop can therefore work while `powershell.exe`,
# `clip.exe` and friends are unresolvable BY NAME — which is the state of this
# box today (the Windows PATH is simply not on this shell's PATH). Every Windows
# call below uses an absolute path for exactly that reason.
dv_interop_ok() {
  grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null \
    || grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop-late 2>/dev/null
}

# Mount prefix of the Windows system drive. Honours [automount] root so this
# keeps working if wsl.conf ever says `root = /` (C: at /c instead of /mnt/c).
# NEVER hardcode /mnt/c anywhere in this repo.
dv_win_root() {
  local root=/mnt/ p d
  if [ -r /etc/wsl.conf ]; then
    p=$(awk -F= '/^[[:space:]]*root[[:space:]]*=/{v=$2;gsub(/^[ \t]+|[ \t\r]+$/,"",v);print v}' \
      /etc/wsl.conf 2>/dev/null | tail -n1)
    [ -n "${p:-}" ] && root=$p
  fi
  case "$root" in */) ;; *) root="$root/" ;; esac
  for d in "${root}c" "${root}C" /mnt/c /c; do
    [ -d "$d/Windows/System32" ] && {
      printf '%s' "$d"
      return 0
    }
  done
  return 1
}

dv_win_powershell() {
  local w p
  w=$(dv_win_root) || return 1
  p="$w/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  [ -x "$p" ] || return 1
  printf '%s' "$p"
}

# A *real* graphical session. Deliberately does NOT trust $DISPLAY alone:
# Ujstor/tmux-config sets `set-environment -g DISPLAY :1` unconditionally, so
# inside tmux a headless box otherwise looks graphical.
dv_has_gui() {
  local n
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "$WAYLAND_DISPLAY" in
      /*) [ -S "$WAYLAND_DISPLAY" ] && return 0 ;;
      *) [ -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WAYLAND_DISPLAY" ] && return 0 ;;
    esac
  fi
  case "${DISPLAY:-}" in
    '') return 1 ;;
    :* | unix:*)
      n=${DISPLAY#unix}
      n=${n#:}
      n=${n%%.*}
      [ -S "/tmp/.X11-unix/X$n" ]
      ;;
    *)
      command -v xset >/dev/null 2>&1 || return 1 # ssh -X style host:N
      timeout 2 xset q >/dev/null 2>&1
      ;;
  esac
}

# A GRAPHICAL browser. lynx/w3m/links are deliberately absent: xdg-open's
# generic chain ends at www-browser -> /usr/bin/lynx, which seizes the TTY
# mid-kubectl and looks like a hang. lynx is installed on this box, so this is
# not hypothetical.
dv_gui_browser() {
  local b
  # Deliberate word splitting: $DEVENV_GUI_BROWSER is one extra candidate name.
  # shellcheck disable=SC2086
  for b in ${DEVENV_GUI_BROWSER:-} google-chrome google-chrome-stable chromium \
    chromium-browser firefox firefox-esr brave-browser brave-browser-stable; do
    command -v "$b" >/dev/null 2>&1 && {
      command -v "$b"
      return 0
    }
  done
  return 1
}

# wsl | gui | print | command
dv_browser_mode() {
  case "${DEVENV_BROWSER_MODE:-auto}" in
    wsl | gui | print | command)
      printf '%s' "$DEVENV_BROWSER_MODE"
      return 0
      ;;
  esac
  if dv_is_wsl && dv_interop_ok && dv_win_root >/dev/null 2>&1; then
    printf wsl
    return 0
  fi
  if dv_has_gui && dv_gui_browser >/dev/null 2>&1; then
    printf gui
    return 0
  fi
  printf print
}

# wslclip | wayland | x11 | osc52
dv_clip_backend() {
  case "${DEVENV_CLIP_BACKEND:-auto}" in
    wslclip | wayland | x11 | osc52)
      printf '%s' "$DEVENV_CLIP_BACKEND"
      return 0
      ;;
  esac
  if dv_is_wsl && dv_interop_ok && dv_win_root >/dev/null 2>&1; then
    printf wslclip
    return 0
  fi
  if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    printf wayland
    return 0
  fi
  if dv_has_gui && command -v xclip >/dev/null 2>&1; then
    printf x11
    return 0
  fi
  printf osc52
}
