# shellcheck shell=bash
# ~/.bashrc.d/20-lang.sh — devops-env-config :: Go, Rust, Python and Node.
#
# The pre-repo ~/.bashrc sourced ~/.cargo/env TWICE (once as `.`, once as
# `source`) and loaded nvm eagerly, which measured 0.20 s of every interactive
# shell. Here each runtime is sourced at most once and Node is LAZY.

# --- Go (K7/D8: the tarball stays; GOTOOLCHAIN=auto does version switching) --
[ -d /usr/local/go ] && export GOROOT=/usr/local/go
export GOPATH="${GOPATH:-$HOME/go}"
export GOCACHE="${GOCACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/go-build}"

# --- Rust ------------------------------------------------------------------
# ONE source, guarded. rustup writes this file; it prepends ~/.cargo/bin itself,
# which 10-path.sh has already done idempotently.
if [ -s "$HOME/.cargo/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.cargo/env"
fi

# --- Python / uv -----------------------------------------------------------
# The uv installer writes ~/.local/bin/env. The pre-repo ~/.bashrc sourced it
# through the installer's odd ~/.local/share/../bin/env spelling.
if [ -s "$HOME/.local/bin/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.local/bin/env"
fi

# --- Node ------------------------------------------------------------------
# DEVENV_NODE_MANAGER=nvm|mise|none|auto (default auto). `auto` picks whichever
# manager is actually installed, so the fragment matches what the module did.
# Set it in ~/.bashrc.d/90-local.sh to force one.
export NVM_DIR="${NVM_DIR:-$HOME/.config/nvm}"
_devenv_node_manager=${DEVENV_NODE_MANAGER:-auto}
if [ "$_devenv_node_manager" = auto ]; then
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    _devenv_node_manager=nvm
  elif [ -x "$HOME/.local/bin/mise" ]; then
    _devenv_node_manager=mise
  else
    _devenv_node_manager=none
  fi
fi

case $_devenv_node_manager in
  nvm)
    # D8: lazy. nvm.sh is ~1200 lines of bash; loading it eagerly is the single
    # largest startup cost on this box. The shims load it on first use and then
    # remove themselves, so the second call is the real nvm/node/npm/npx.
    _devenv_nvm_load() {
      unset -f nvm node npm npx corepack _devenv_nvm_load 2>/dev/null
      [ -s "$NVM_DIR/nvm.sh" ] || return 1
      # shellcheck source=/dev/null
      . "$NVM_DIR/nvm.sh"
      if [ -s "$NVM_DIR/bash_completion" ]; then
        # shellcheck source=/dev/null
        . "$NVM_DIR/bash_completion"
      fi
    }
    nvm() { _devenv_nvm_load && nvm "$@"; }
    # Only shim the runtimes that are NOT already on PATH: a system or mise node
    # must keep working untouched.
    if ! command -v node >/dev/null 2>&1; then
      node() { _devenv_nvm_load && node "$@"; }
    fi
    if ! command -v npm >/dev/null 2>&1; then
      npm() { _devenv_nvm_load && npm "$@"; }
    fi
    if ! command -v npx >/dev/null 2>&1; then
      npx() { _devenv_nvm_load && npx "$@"; }
    fi
    if ! command -v corepack >/dev/null 2>&1; then
      corepack() { _devenv_nvm_load && corepack "$@"; }
    fi
    ;;
  mise)
    if [ -x "$HOME/.local/bin/mise" ]; then
      eval "$("$HOME/.local/bin/mise" activate bash)"
    fi
    ;;
esac
unset _devenv_node_manager
