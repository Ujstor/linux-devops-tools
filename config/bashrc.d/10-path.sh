# shellcheck shell=bash
# ~/.bashrc.d/10-path.sh — linux-devops-tools :: PATH, computed exactly once.
#
# The pre-repo ~/.bashrc prepended $HOME/.local/bin three times, $HOME/.cargo/bin
# twice and $GOPATH/bin twice. Every duplicate lengthens every PATH lookup and
# makes "which one wins" unanswerable. These two helpers are [ -d ]-guarded and
# de-duplicating, so re-sourcing a fragment cannot grow PATH.
#
# 50-platform.sh and 70-tools.sh reuse them; they stay shell-local (never
# exported) so nothing a script runs inherits them by surprise.

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

# Highest priority LAST — prepend order is reversed on purpose.
devenv_path_append "/usr/local/go/bin"
devenv_path_prepend "${KREW_ROOT:-$HOME/.krew}/bin"
devenv_path_prepend "${GOPATH:-$HOME/go}/bin"
devenv_path_prepend "$HOME/.cargo/bin"
devenv_path_prepend "$HOME/.local/bin"
devenv_path_prepend "$HOME/bin"
export PATH
