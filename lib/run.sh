# shellcheck shell=bash
# lib/run.sh — THE mutation gate, privilege acquisition and confirmation.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# MUST-FIX S6: every mutation in this repository — apt, dpkg, installs, and every
# filesystem writer in lib/fs.sh and lib/shell.sh — routes through `run`/`run_sudo`
# or consults `is_dry_run`. There is exactly one place where --dry-run is decided,
# and it is this file. `tests/policy/rules.sh` enforces it by grep.
#
# MUST-FIX S14 / P1 / idempotency F21: sudo is acquired LAZILY, at the moment a
# module actually needs root — never up front. Running as root works. A box with no
# sudo, or a user who is not a sudoer (stock Debian), gets one actionable message
# and a skip, not an obscure failure.

[ -n "${_DEVENV_RUN:-}" ] && return 0
_DEVENV_RUN=1

# _cmd_str ARG…   (private) — printable, minimally-quoted command line.
_cmd_str() {
  local out='' a
  for a in "$@"; do
    case $a in
      '' | *[!A-Za-z0-9._/=:@%+,-]*) out="$out '${a//\'/\'\\\'\'}'" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

# is_dry_run
#   Returns 0 when DEVENV_DRY_RUN=1. The only predicate a writer may branch on.
#   Safe inside `if`; never dies.
is_dry_run() { [ "${DEVENV_DRY_RUN:-0}" = 1 ]; }

# have_tty
#   Returns 0 when this process can actually OPEN its controlling terminal.
#   `[ -c /dev/tty ]` is not enough: the device node exists even for a process with
#   no controlling terminal (a systemd unit, a cron job, a CI runner), and opening it
#   then fails with ENXIO. Every prompt in this library goes through here.
have_tty() { { : >/dev/tty; } 2>/dev/null; }

# is_root
#   Returns 0 when the current process is uid 0.
is_root() { [ "${EUID:-$(id -u)}" -eq 0 ]; }

# run CMD [ARGS…]
#   THE mutation gate. Under --dry-run it prints "[dry ] <cmd>" and returns 0
#   WITHOUT executing. Otherwise it executes CMD and returns its exit status.
#   Args are passed through verbatim — no shell, no globbing, no redirection.
#   A pipeline or a redirection cannot go through `run`: build the payload in
#   "$(devenv_tmpdir)" first and install it with an argv-only command.
run() {
  if is_dry_run; then
    log_dryrun "$(_cmd_str "$@")"
    return 0
  fi
  log_debug "+ $(_cmd_str "$@")"
  "$@"
}

# run_quiet CMD [ARGS…]
#   As `run`, but stdout+stderr are captured and shown ONLY if the command fails.
#   Returns the command's exit status. Honours --dry-run identically.
run_quiet() {
  if is_dry_run; then
    log_dryrun "$(_cmd_str "$@")"
    return 0
  fi
  log_debug "+ $(_cmd_str "$@")"
  local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    log_error "command failed (exit $rc): $(_cmd_str "$@")"
    [ -n "$out" ] && printf '%s\n' "$out" >&2
  fi
  return "$rc"
}

# need_sudo
#   Args: none.
#   Prints the privilege prefix to use on stdout: "sudo", or the empty string when
#   already root. Returns 0 when root privileges are available, 1 when they are not
#   — and NEVER exits (idempotency F21: `devenv --only k9s-config` and `devenv doctor`
#   must not prompt for a password, and a box without sudo must still run every
#   module that needs no root).
#   Under --dry-run it never runs `sudo -v`, so a dry run never prompts (F6).
#   Caches its answer for the lifetime of the process; sudo's own timestamp keeps
#   sibling modules from prompting again.
need_sudo() {
  if [ -n "${_DEVENV_SUDO_STATE:-}" ]; then
    printf '%s\n' "${_DEVENV_SUDO_PREFIX:-}"
    [ "$_DEVENV_SUDO_STATE" = ok ]
    return
  fi
  if is_root; then
    _DEVENV_SUDO_STATE=ok _DEVENV_SUDO_PREFIX=''
    printf '\n'
    return 0
  fi
  if ! have sudo; then
    _DEVENV_SUDO_STATE=fail _DEVENV_SUDO_PREFIX=''
    log_error "root privileges are required, but 'sudo' is not installed (stock Debian ships without it)."
    log_error "Either re-run this as root:      su -   then  DEVENV_ALLOW_ROOT=1 $DEVENV_HOME/bin/devenv ..."
    log_error "or install sudo once, as root:   apt-get install -y sudo && adduser ${USER:-$(id -un)} sudo"
    log_error "then log out and back in so the new group membership takes effect."
    printf '\n'
    return 1
  fi
  if is_dry_run; then
    # Do not validate: a dry run must never prompt and must never mutate the
    # sudo timestamp. Report the prefix optimistically and let the plan say so.
    _DEVENV_SUDO_STATE=ok _DEVENV_SUDO_PREFIX=sudo
    printf 'sudo\n'
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    _DEVENV_SUDO_STATE=ok _DEVENV_SUDO_PREFIX=sudo
    printf 'sudo\n'
    return 0
  fi
  if have_tty; then
    log_info "root privileges are needed for the next step; sudo will ask for your password."
    # shellcheck disable=SC2024  # deliberate: the redirect is applied as the CURRENT user,
    # which is exactly what gives sudo a terminal to read the password from.
    if sudo -v </dev/tty 2>/dev/null; then
      _DEVENV_SUDO_STATE=ok _DEVENV_SUDO_PREFIX=sudo
      printf 'sudo\n'
      return 0
    fi
  fi
  _DEVENV_SUDO_STATE=fail _DEVENV_SUDO_PREFIX=''
  log_error "could not obtain root privileges: ${USER:-$(id -un)} is not permitted to run sudo here,"
  log_error "or no terminal is available to ask for a password."
  log_error "Fix one of these, then re-run:"
  log_error "  * add the user to a sudo group, as root:  adduser ${USER:-$(id -un)} sudo   (log out and back in)"
  log_error "  * or run the whole install as root:       su -   then  DEVENV_ALLOW_ROOT=1 $DEVENV_HOME/bin/devenv ..."
  log_error "  * or run only the modules that need no root, e.g.  devenv --only shell,k9s-config"
  printf '\n'
  return 1
}

# have_root
#   Returns 0 when root privileges are available (root already, or a usable sudo).
#   Quiet on success; need_sudo's message is printed once on the first failure.
#   Use this to decide whether to `skip` a root-only module.
have_root() {
  need_sudo >/dev/null
}

# run_sudo CMD [ARGS…]
#   `run`, executed with root privileges. Returns 1 without executing anything when
#   privileges cannot be obtained (need_sudo has already explained why).
#   Honours --dry-run exactly like `run` and never prompts under it.
run_sudo() {
  local prefix
  prefix=$(need_sudo) || {
    log_error "not run: $(_cmd_str "$@")"
    return 1
  }
  if [ -n "$prefix" ]; then
    run "$prefix" "$@"
  else
    run "$@"
  fi
}

# as_root CMD [ARGS…]
#   Privileged READ. Runs CMD as root WITHOUT the dry-run gate, for queries whose
#   result the caller needs even during a dry run (e.g. `as_root test -r <file>`).
#   Using it for a mutation defeats --dry-run and is rejected by tests/policy/rules.sh.
#   Returns the command's status, or 1 when privileges are unavailable.
as_root() {
  local prefix
  prefix=$(need_sudo) || return 1
  if [ -n "$prefix" ]; then
    "$prefix" "$@"
  else
    "$@"
  fi
}

# confirm QUESTION
#   Asks a yes/no question. Returns 0 for yes, 1 for no.
#   Reads /dev/tty, NEVER stdin — install.sh may be curl-piped, so stdin is the script.
#   Returns 0 immediately when DEVENV_ASSUME_YES=1 (`--yes`).
#   Returns 1 (no) when there is no terminal to ask.
confirm() {
  local q=${1:?confirm: QUESTION required} ans=''
  if [ "${DEVENV_ASSUME_YES:-0}" = 1 ]; then
    log_debug "confirm (auto-yes): $q"
    return 0
  fi
  if ! have_tty; then
    log_warn "no terminal to ask: $q -> assuming no"
    return 1
  fi
  printf '%s[ ?? ]%s %s [y/N] ' "$_C_YELLOW" "$_C_RESET" "$q" >&2
  read -r ans </dev/tty || ans=''
  case $ans in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# confirm_dangerous QUESTION OPTIN_VAR
#   MUST-FIX S5 / idempotency F5: a confirmation that always says yes when nobody is
#   watching is not a confirmation. This variant is for privileged, system-wide,
#   hard-to-undo changes (docker group membership, /etc/wsl.conf, package removal).
#   Args: the question, and the NAME of the explicit opt-in environment variable.
#   Returns 0 only when:
#       ${!OPTIN_VAR} = 1                                   (explicit opt-in), or
#       a human answers yes on /dev/tty and DEVENV_ASSUME_YES is not set.
#   Under --yes / no-tty it returns 1 and prints the exact opt-in the user can set.
confirm_dangerous() {
  local q=${1:?confirm_dangerous: QUESTION required}
  local var=${2:?confirm_dangerous: OPTIN_VAR required}
  if [ "${!var:-0}" = 1 ]; then
    log_info "$var=1 — proceeding: $q"
    return 0
  fi
  if [ "${DEVENV_ASSUME_YES:-0}" = 1 ] || ! have_tty; then
    log_warn "not doing this unattended: $q"
    log_warn "re-run with $var=1 (or answer the prompt interactively) to allow it."
    return 1
  fi
  confirm "$q"
}

# changed WHAT…
#   Records one change for `99-summary` and for the run-twice idempotency test.
#   Child modules append to the same file, because DEVENV_RUNDIR is exported.
#   Under --dry-run the entry is recorded as "would: …". Always returns 0.
changed() {
  local what=$*
  [ -n "$what" ] || return 0
  if is_dry_run; then
    what="would: $what"
  fi
  DEVENV_CHANGED_LAST=1
  export DEVENV_CHANGED_LAST
  if [ -n "${DEVENV_RUNDIR:-}" ] && [ -d "$DEVENV_RUNDIR" ]; then
    printf '%s\t%s\n' "${DEVENV_MODULE:-devenv}" "$what" >>"$DEVENV_RUNDIR/changed"
  fi
  log_debug "changed: $what"
  return 0
}

# changed_list
#   Prints every recorded change, one "<module>\t<what>" per line, in order.
#   Always returns 0 (prints nothing when there were none).
changed_list() {
  [ -n "${DEVENV_RUNDIR:-}" ] || return 0
  [ -s "$DEVENV_RUNDIR/changed" ] || return 0
  cat "$DEVENV_RUNDIR/changed"
}
