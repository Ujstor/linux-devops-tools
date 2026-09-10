# shellcheck shell=bash
# ~/.bashrc.d/50-platform.sh — devops-env-config :: browser and clipboard wiring.
#
# The pre-repo ~/.bashrc defined `alias pbcopy='clip.exe'`,
# `alias pbpaste='powershell.exe … Get-Clipboard'`, `alias winclip='clip.exe'`
# and a `winpaste()` function. All four are DEAD on this box today: the Windows
# PATH is not inherited by this shell, so neither `clip.exe` nor
# `powershell.exe` resolves by name — even though interop itself is enabled.
# And none of them can work on a plain Debian/Ubuntu VM at all.
#
# The replacement is a pair of EXECUTABLES in ~/.local/bin (clip, clip-paste,
# with pbcopy/pbpaste symlinks) that resolve a backend at run time: Windows
# clip.exe by ABSOLUTE path, wl-copy, xclip, or OSC 52 to the laptop's own
# terminal emulator. Executables, not functions, because tmux copy-pipe, k9s
# plugins, a kubeconfig exec stanza, cron and systemd units all need a real
# command on PATH. They are installed by the auth-sso module.

# --- URL opening -----------------------------------------------------------
# ONE definition of $BROWSER on this box. The CLIs that ignore $BROWSER
# entirely (kubectl oidc-login, argocd, bao — they exec xdg-open /
# x-www-browser / www-browser by name) are covered by the ~/.local/bin symlinks
# instead, which is why $BROWSER alone is not enough.
if [ -x "$HOME/.local/bin/open-url" ]; then
  # NO trailing '&': python's webbrowser would read that as a BackgroundBrowser
  # and send the child's stdout AND stderr to /dev/null, swallowing the URL.
  export BROWSER="$HOME/.local/bin/open-url"
  export GH_BROWSER="$BROWSER" # gh precedence: GH_BROWSER, then BROWSER
  : "${DEVENV_BROWSER_MODE:=auto}"
  export DEVENV_BROWSER_MODE # auto | wsl | gui | print | command
fi

# --- clipboard -------------------------------------------------------------
# Override the backend with DEVENV_CLIP_BACKEND=wslclip|wayland|x11|osc52,
# either in the environment or in ~/.config/devops-env/sso.env.
# The mode is resolved when a command RUNS, never at shell start: that is what
# keeps startup free and keeps one ~/.bashrc correct in both a WSL pane and an
# SSH pane of the same tmux session.
if [ -x "$HOME/.local/bin/clip" ]; then
  alias winclip='clip'
fi

# --- WSL -------------------------------------------------------------------
# Opt-in: /mnt/<drive>/… entries cost a 9p round trip on every PATH miss, which
# is most `command -v` calls. Safe to enable here because nothing in this repo
# invokes a Windows executable by bare name — open-url and clip both resolve an
# absolute path under the automount root, honouring [automount] root.
if [ "${DEVENV_IS_WSL:-0}" = 1 ] && [ "${DEVENV_WSL_STRIP_WINPATH:-0}" = 1 ]; then
  # Split on ':' with parameter expansion only: no fork, and no `set --`,
  # which would clobber the sourcing shell's positional parameters.
  _devenv_newpath=''
  _devenv_rest=$PATH
  while [ -n "$_devenv_rest" ]; do
    _devenv_d=${_devenv_rest%%:*}
    case $_devenv_rest in
      *:*) _devenv_rest=${_devenv_rest#*:} ;;
      *) _devenv_rest='' ;;
    esac
    [ -n "$_devenv_d" ] || continue
    case $_devenv_d in /mnt/*) continue ;; esac
    _devenv_newpath="${_devenv_newpath:+$_devenv_newpath:}$_devenv_d"
  done
  [ -n "$_devenv_newpath" ] && PATH=$_devenv_newpath
  export PATH
  unset _devenv_newpath _devenv_rest _devenv_d
fi
