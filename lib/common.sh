# shellcheck shell=bash
# lib/common.sh — the ONE entry point of the shared library.
#
# linux-devops-tools :: shared library.
#
#   source "${DEVENV_HOME:?}/lib/common.sh"
#
# is the only line a module, bin/devenv or a test ever needs. It sets the global
# contract, installs the traps and sources every other lib/*.sh in dependency order.
# Never source an individual lib file: the include guards make that harmless, but
# the ordering guarantees below only hold when you come through here.
#
# Load order (each file only needs the ones above it AT SOURCE TIME; function
# references resolve at call time, so cycles between them are fine):
#     log.sh       -> os.sh    -> run.sh -> fs.sh
#     -> net.sh    -> pkg.sh   -> repo.sh
#     -> shell.sh  -> lang.sh  -> wsl.sh -> registry.sh
#
# SPEC 5.3 names two of those files differently: `run.sh` holds the run/run_sudo/
# confirm/need_sudo group that SPEC 5.3.2/5.3.3 listed under log.sh and os.sh, and
# `net.sh` is SPEC 5.3.6's `github.sh`. EVERY FUNCTION NAME IS UNCHANGED — only the
# file split differs, and nothing outside lib/ sources a lib file by name.

[ -n "${_DEVENV_COMMON:-}" ] && return 0
_DEVENV_COMMON=1

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

# DEVENV_HOME must point at the repository checkout. When it is unset we derive it
# from this file's own location, so `DEVENV_HOME=$PWD ./modules/37-k9s-config.sh`
# and a plain `source lib/common.sh` both work.
if [ -z "${DEVENV_HOME:-}" ]; then
  DEVENV_HOME=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fi
export DEVENV_HOME

DEVENV_CONFIG=${DEVENV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/devops-env}
DEVENV_CACHE=${DEVENV_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/devops-env}
DEVENV_STATE=${DEVENV_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/devops-env}
export DEVENV_CONFIG DEVENV_CACHE DEVENV_STATE

# Flags. bin/devenv sets these from its options; each has an env twin so child
# modules inherit the state without re-parsing anything.
DEVENV_DRY_RUN=${DEVENV_DRY_RUN:-0}
DEVENV_ASSUME_YES=${DEVENV_ASSUME_YES:-0}
DEVENV_VERBOSE=${DEVENV_VERBOSE:-0}
DEVENV_QUIET=${DEVENV_QUIET:-0}
DEVENV_NO_COLOR=${DEVENV_NO_COLOR:-0}
DEVENV_PROFILE=${DEVENV_PROFILE:-devops}
export DEVENV_DRY_RUN DEVENV_ASSUME_YES DEVENV_VERBOSE DEVENV_QUIET DEVENV_NO_COLOR DEVENV_PROFILE

# Per-run scratch directory. It lives under $TMPDIR (NOT under $HOME) on purpose:
# the acceptance test fingerprints $HOME and /etc around a --dry-run, and our own
# scratch space must not show up in it.
# The process that CREATES it owns it; child modules inherit the path and must not
# remove it (that is what DEVENV_RUNDIR_OWNER records).
if [ -z "${DEVENV_RUNDIR:-}" ] || [ ! -d "${DEVENV_RUNDIR:-}" ]; then
  DEVENV_RUNDIR=$(mktemp -d "${TMPDIR:-/tmp}/devenv.XXXXXXXX") || {
    printf '[ xx ] cannot create a temporary directory\n' >&2
    # shellcheck disable=SC2317  # reachable: `return` fails when this file was executed, not sourced
    return 1 2>/dev/null || exit 1
  }
  DEVENV_RUNDIR_OWNER=$$
fi
DEVENV_RUNDIR_OWNER=${DEVENV_RUNDIR_OWNER:-0}
export DEVENV_RUNDIR DEVENV_RUNDIR_OWNER

# devenv_tmpdir
#   Prints a fresh empty directory under $DEVENV_RUNDIR. Removed by the EXIT trap of
#   whichever process created the run directory. Returns 1 when it cannot be made.
devenv_tmpdir() { mktemp -d "$DEVENV_RUNDIR/d.XXXXXXXX"; }

# devenv_tmpfile
#   Prints a fresh empty file under $DEVENV_RUNDIR. Same lifetime as devenv_tmpdir.
devenv_tmpfile() { mktemp "$DEVENV_RUNDIR/f.XXXXXXXX"; }

# devenv_version_env [FILE]
#   Loads versions.env (default $DEVENV_HOME/versions.env) with `set -a`, so every
#   pin is exported into this process and into every child module.
#   NOTE for anyone adding a key (idempotency F23): the file is exported wholesale,
#   so a key name must not collide with a variable a tool itself reads. Stick to the
#   documented suffixes in versions.env's own header.
#   Returns 1 when the file is missing.
devenv_version_env() {
  local f=${1:-$DEVENV_HOME/versions.env}
  [ -r "$f" ] || {
    printf '[ xx ] versions.env not found at %s\n' "$f" >&2
    return 1
  }
  set -a
  # shellcheck disable=SC1090  # runtime path, validated above
  . "$f"
  set +a
}

# ---------------------------------------------------------------------------
# Library
# ---------------------------------------------------------------------------
# shellcheck source=lib/log.sh
. "$DEVENV_HOME/lib/log.sh"
# shellcheck source=lib/os.sh
. "$DEVENV_HOME/lib/os.sh"
# shellcheck source=lib/run.sh
. "$DEVENV_HOME/lib/run.sh"
# shellcheck source=lib/fs.sh
. "$DEVENV_HOME/lib/fs.sh"
# shellcheck source=lib/net.sh
. "$DEVENV_HOME/lib/net.sh"
# shellcheck source=lib/pkg.sh
. "$DEVENV_HOME/lib/pkg.sh"
# shellcheck source=lib/repo.sh
. "$DEVENV_HOME/lib/repo.sh"
# shellcheck source=lib/shell.sh
. "$DEVENV_HOME/lib/shell.sh"
# shellcheck source=lib/lang.sh
. "$DEVENV_HOME/lib/lang.sh"
# shellcheck source=lib/wsl.sh
. "$DEVENV_HOME/lib/wsl.sh"
# shellcheck source=lib/registry.sh
. "$DEVENV_HOME/lib/registry.sh"

# Load the pins unless the caller has already done it (bin/devenv does it first so
# that `devenv version` can digest the file).
if [ "${DEVENV_VERSIONS_LOADED:-0}" != 1 ] && [ -r "$DEVENV_HOME/versions.env" ]; then
  devenv_version_env
  DEVENV_VERSIONS_LOADED=1
  export DEVENV_VERSIONS_LOADED
fi

# ---------------------------------------------------------------------------
# Traps
# ---------------------------------------------------------------------------

# _devenv_on_err LINE COMMAND   (private) — the ERR trap body.
_devenv_on_err() {
  local line=$1 cmd=$2 rc=$3
  log_error "failed (exit $rc) at ${DEVENV_MODULE:-${BASH_SOURCE[1]##*/}}:${line}"
  log_error "  command: $cmd"
}

# _devenv_on_exit   (private) — the EXIT trap body. Only the creating process
# removes $DEVENV_RUNDIR, so a child module cannot delete its parent's scratch.
_devenv_on_exit() {
  local rc=$?
  if [ "${DEVENV_RUNDIR_OWNER:-0}" = "$$" ] && [ -n "${DEVENV_RUNDIR:-}" ]; then
    case $DEVENV_RUNDIR in
      "${TMPDIR:-/tmp}"/devenv.*) rm -rf -- "$DEVENV_RUNDIR" ;;
      /tmp/devenv.*) rm -rf -- "$DEVENV_RUNDIR" ;;
    esac
  fi
  return "$rc"
}

# Install the traps unless the caller opted out (DEVENV_NO_TRAPS=1, used by the unit
# tests, which source the library repeatedly inside one shell).
if [ "${DEVENV_NO_TRAPS:-0}" != 1 ]; then
  set -o errtrace
  trap '_devenv_on_err "$LINENO" "$BASH_COMMAND" "$?"' ERR
  trap '_devenv_on_exit' EXIT
fi
