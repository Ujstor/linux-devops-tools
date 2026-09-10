# shellcheck shell=bash
# ~/.bashrc.d/70-tools.sh — devops-env-config :: per-tool PATH and hooks.
# Loads last, so anything here sits on top of mybash's own prompt work.

# 10-path.sh owns these helpers. Define no-op-safe fallbacks in case the user
# skipped that fragment with DEVENV_SKIP_FRAGMENTS.
if ! declare -F devenv_path_prepend >/dev/null 2>&1; then
  devenv_path_prepend() {
    [ -d "$1" ] || return 0
    case ":$PATH:" in *":$1:"*) return 0 ;; esac
    PATH="$1:$PATH"
  }
  devenv_path_append() {
    [ -d "$1" ] || return 0
    case ":$PATH:" in *":$1:"*) return 0 ;; esac
    PATH="$PATH:$1"
  }
fi

# --- per-tool bin directories ----------------------------------------------
# Each is [ -d ]-guarded, so a machine without the tool gets no phantom entry.
devenv_path_prepend "$HOME/.iximiuz/labctl/bin"
devenv_path_prepend "$HOME/.sst/bin"
devenv_path_prepend "$HOME/.pulumi/bin"
devenv_path_prepend "$HOME/.opencode/bin"
export PATH

# --- Homebrew --------------------------------------------------------------
# K9: brew goes AFTER the system paths. `brew shellenv` PREPENDS its prefix,
# which is what put brew's python3 (3.14) ahead of the system pip3 (3.12) on
# this box. The four exports below are exactly what shellenv sets, minus that
# prepend — and they cost no fork at all.
_devenv_brew_prefix=''
for _devenv_d in /home/linuxbrew/.linuxbrew /opt/homebrew; do
  if [ -x "$_devenv_d/bin/brew" ]; then
    _devenv_brew_prefix=$_devenv_d
    break
  fi
done
if [ -n "$_devenv_brew_prefix" ]; then
  export HOMEBREW_PREFIX="$_devenv_brew_prefix"
  export HOMEBREW_CELLAR="$_devenv_brew_prefix/Cellar"
  export HOMEBREW_REPOSITORY="$_devenv_brew_prefix/Homebrew"
  devenv_path_append "$_devenv_brew_prefix/bin"
  devenv_path_append "$_devenv_brew_prefix/sbin"
  export PATH
  export MANPATH="${MANPATH:-}:$_devenv_brew_prefix/share/man"
  export INFOPATH="${INFOPATH:-}:$_devenv_brew_prefix/share/info"
fi
unset _devenv_brew_prefix _devenv_d

# --- direnv ----------------------------------------------------------------
# Must come after the prompt-manipulating extensions, which it does: 40-shellui
# has already run. `direnv allow` is opt-in per directory, which is the right
# posture for a tree full of other people's manifests.
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook bash)"
fi

# --- nala ------------------------------------------------------------------
# K20: an ALIAS only, opt-in, and `sudo` is never redefined. The old
# ~/.use-nala redefined sudo() as a shell function, which put every interactive
# sudo through a wrapper for a cosmetic front-end.
if [ "${ENABLE_NALA_ALIAS:-0}" = 1 ] && command -v nala >/dev/null 2>&1; then
  alias apt='nala'
  alias apt-get='nala'
fi
