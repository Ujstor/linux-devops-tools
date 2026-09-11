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
# It is for FILES ONLY. On a hardened host $TMPDIR is /tmp and /tmp is mounted
# noexec, so nothing here can be RUN — that is what devenv_execdir below is for.
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
#   NOT executable: use devenv_execdir when something in it has to be run.
devenv_tmpdir() { mktemp -d "$DEVENV_RUNDIR/d.XXXXXXXX"; }

# devenv_tmpfile
#   Prints a fresh empty file under $DEVENV_RUNDIR. Same lifetime as devenv_tmpdir.
#   NOT executable: use devenv_execdir when it has to be run.
devenv_tmpfile() { mktemp "$DEVENV_RUNDIR/f.XXXXXXXX"; }

# ---------------------------------------------------------------------------
# Exec-capable scratch  ($DEVENV_EXECROOT / devenv_execdir)
# ---------------------------------------------------------------------------
#
# $DEVENV_RUNDIR above is for FILES. It is not a place to RUN one.
#
# A hardened host mounts /tmp `noexec` — the estate's own vm-hardening role makes
# exactly that change — and then nothing downloaded into $DEVENV_RUNDIR can be
# executed. Two real failures on one install, same single cause:
#
#     .../krew-linux_amd64: Permission denied
#         -> "krew self-install failed", and the whole kubectl plugin roster skipped
#     error: Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
#         (likely because of mounting /tmp as noexec)
#         -> "rustup could not be installed"
#
# So there is a SECOND scratch area whose one distinguishing property is that a
# file in it can actually be exec()'d, and every download-then-execute path uses
# it instead. $DEVENV_RUNDIR deliberately stays where it is: it must not pollute
# $HOME, because the acceptance test fingerprints $HOME and /etc around a dry run.
#
# The answer is PROBED, never assumed. `mount` output and /proc/mounts both lie
# here — a bind mount re-flags a subtree, an overlay's upper layer is not the
# mount you can see, a user namespace shows you the host's table — and the only
# question that matters is "does execve() work on a file I just wrote here", so
# that is the question this asks.
#
# Candidates, in order; the first one that passes the probe wins:
#
#     $TMPDIR  ->  /tmp  ->  $XDG_RUNTIME_DIR  ->  $DEVENV_CACHE/exec
#              ->  $HOME/.cache/devops-env/exec
#
# The last two are under $HOME on purpose: they are the fallback for the host
# where every shared temp filesystem is noexec, and the EXIT trap removes them
# again (including the parent it had to create), so the fingerprint stays clean.

# _devenv_exec_probe DIR   (private)
#   Returns 0 when a file created in DIR can be made executable AND executed.
#   Writes one throwaway script, runs it, removes it. Prints nothing, never dies.
#   The probe script exits 41, and ONLY 41 is accepted: 126 is "found but not
#   executable" (which is what noexec looks like) and 127 is "no interpreter" —
#   neither proves the kernel ran anything.
#   PRECONDITION: DIR must be one you just created yourself, mode 0700 (mktemp -d).
#   The probe's file name is predictable, and writing a predictable name into a
#   world-writable directory such as /tmp is a symlink-clobber waiting to happen.
#   _devenv_execroot honours this: it probes the mktemp'd directory, never /tmp.
_devenv_exec_probe() {
  local dir=${1-} probe rc=0
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  probe="$dir/.devenv-execprobe.$$"
  { printf '#!/bin/sh\nexit 41\n' >"$probe"; } 2>/dev/null || {
    rm -f -- "$probe" 2>/dev/null
    return 1
  }
  chmod 0700 -- "$probe" 2>/dev/null || {
    rm -f -- "$probe" 2>/dev/null
    return 1
  }
  "$probe" >/dev/null 2>&1 || rc=$?
  rm -f -- "$probe" 2>/dev/null
  [ "$rc" -eq 41 ]
}

# _devenv_execroot   (private)
#   Prints the per-run exec-capable scratch ROOT, creating it on first use.
#
#   The choice is recorded in $DEVENV_RUNDIR/execroot, a FILE, and not only in an
#   exported variable. It has to be: `work=$(devenv_execdir)` runs this inside a
#   command substitution, and a subshell's `export` dies with the subshell — so a
#   variable memo alone would re-probe on every call, leave a fresh root behind
#   each time with nothing able to remove them, and print the fallback notice over
#   and over. $DEVENV_RUNDIR is the one thing every subshell AND every child
#   module already shares, so the answer lives there and the run directory's owner
#   is what cleans the exec root up. The variable stays as a same-process
#   shortcut. (Modules run one at a time, so two writers cannot race here.)
#
#   Returns 1, with an actionable error, when no candidate passes the probe.
#   Removing $DEVENV_RUNDIR/execroot and unsetting DEVENV_EXECROOT forces a
#   re-probe; the unit tests do exactly that.
_devenv_execroot() {
  local stamp="${DEVENV_RUNDIR:-}/execroot"
  if [ -n "${DEVENV_EXECROOT:-}" ] && [ -d "${DEVENV_EXECROOT:-}" ]; then
    printf '%s\n' "$DEVENV_EXECROOT"
    return 0
  fi
  if [ -n "${DEVENV_RUNDIR:-}" ] && [ -s "$stamp" ]; then
    local recorded
    recorded=$(cat -- "$stamp" 2>/dev/null) || recorded=''
    if [ -n "$recorded" ] && [ -d "$recorded" ]; then
      DEVENV_EXECROOT=$recorded
      export DEVENV_EXECROOT
      printf '%s\n' "$recorded"
      return 0
    fi
  fi
  # An array, not a " $tried " string: `case " $tried " in *" $c "*)` reads a path
  # containing a space as two candidates, and would then skip a perfectly good
  # directory because an unrelated one shared a word with it.
  local cand root='' s dup
  local -a tried=()
  for cand in "${TMPDIR:-}" /tmp "${XDG_RUNTIME_DIR:-}" \
    "${DEVENV_CACHE:-$HOME/.cache/devops-env}/exec" "$HOME/.cache/devops-env/exec"; do
    [ -n "$cand" ] || continue
    cand=${cand%/}
    [ -n "$cand" ] || continue
    dup=0
    if [ ${#tried[@]} -gt 0 ]; then
      for s in "${tried[@]}"; do
        [ "$s" = "$cand" ] && dup=1
      done
    fi
    [ "$dup" = 0 ] || continue
    tried+=("$cand")
    # Only the two $HOME fallbacks are ours to create; a missing $TMPDIR or
    # $XDG_RUNTIME_DIR means "not available here", not "make one".
    case $cand in
      */exec) mkdir -p -- "$cand" 2>/dev/null || continue ;;
    esac
    root=$(mktemp -d "$cand/devenv-exec.XXXXXXXX" 2>/dev/null) || {
      root=''
      continue
    }
    # Probe the directory we will actually hand out, not its parent — that is
    # also what keeps the probe's predictable file name out of world-writable
    # /tmp, where it would be a symlink target.
    _devenv_exec_probe "$root" && break
    rm -rf -- "$root"
    root=''
  done
  if [ -z "$root" ]; then
    log_error "no exec-capable scratch directory is available on this host."
    log_error "  tried: ${tried[*]:-(nothing)}"
    log_error "  each one is missing, not writable, or on a filesystem mounted noexec."
    log_error "  Point TMPDIR at a directory that permits execution and re-run."
    return 1
  fi
  DEVENV_EXECROOT=$root
  export DEVENV_EXECROOT
  if [ -n "${DEVENV_RUNDIR:-}" ] && [ -d "${DEVENV_RUNDIR:-}" ]; then
    printf '%s\n' "$root" >"$stamp" 2>/dev/null || :
  fi
  case ${root%/*} in
    "${TMPDIR:-/tmp}" | /tmp)
      log_debug "exec scratch: $root"
      ;;
    *)
      # Said out loud, once, on purpose. A SILENT fallback is exactly how "/tmp
      # is noexec on every hardened host in the fleet" stayed invisible for a
      # year: the installs simply failed and nothing named the reason.
      log_info "/tmp here does not permit execution (mounted noexec?) — downloaded"
      log_info "  installers and binaries will be run from $root instead"
      ;;
  esac
  printf '%s\n' "$root"
  return 0
}

# devenv_execdir
#   Args: none.
#   Prints a fresh empty directory that is writable AND on a filesystem that
#   permits execution: the place for a downloaded artefact that has to RUN
#   (krew's self-installer, rustup-init, a vendor `install.sh`, a ./configure).
#   Use devenv_tmpdir for everything that is only written, read or unpacked —
#   `install`, `tar`, `cp` and `awk -f` all work fine on a noexec filesystem.
#   Safe to call any number of times, from a subshell and from a child module:
#   each call returns its own fresh directory, all of them under ONE per-run root
#   that is probed for once and removed by the EXIT trap of whichever process owns
#   $DEVENV_RUNDIR. Returns 1 (having said why) when no filesystem on this host
#   will execute anything.
#   NOT for use under --dry-run. Allocating the root can create directories (the
#   $HOME fallback makes its own $DEVENV_CACHE/exec), and a dry run has to leave
#   $HOME fingerprint-identical. Every caller returns on is_dry_run before it —
#   krew_bootstrap, sh_installer_run and install_tmux_from_source all do. Keep it
#   that way.
devenv_execdir() {
  local root
  root=$(_devenv_execroot) || return 1
  mktemp -d "$root/x.XXXXXXXX"
}

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

# _devenv_on_exit   (private) — the EXIT trap body. Only the process that created
# $DEVENV_RUNDIR removes it, so a child module cannot delete its parent's scratch;
# the exec root belongs to the same run and goes with it. Both paths are matched
# against the shape mktemp gave them before anything is removed.
_devenv_on_exit() {
  local rc=$?
  if [ "${DEVENV_RUNDIR_OWNER:-0}" = "$$" ] && [ -n "${DEVENV_RUNDIR:-}" ]; then
    # The exec root FIRST: the path is recorded inside the run directory, so
    # removing that one first would throw away the note saying what to clean.
    local execroot=''
    if [ -s "$DEVENV_RUNDIR/execroot" ]; then
      execroot=$(cat -- "$DEVENV_RUNDIR/execroot" 2>/dev/null) || execroot=''
    fi
    case ${execroot:-none} in
      /*/devenv-exec.*)
        rm -rf -- "$execroot"
        # The two $HOME fallbacks had to create their own parent. Take it back
        # when it is empty, so a run that fell off /tmp still leaves $HOME
        # fingerprint-identical. rmdir refuses a non-empty directory, which is
        # exactly the guard wanted here.
        case $execroot in
          */exec/devenv-exec.*) rmdir -- "${execroot%/*}" 2>/dev/null || : ;;
        esac
        ;;
    esac
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
