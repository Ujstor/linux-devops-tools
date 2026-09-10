# shellcheck shell=bash
# lib/log.sh — logging primitives.
#
# linux-devops-tools :: shared library.
# Sourced by lib/common.sh only. Never executed, never `set -e` here.
#
# CONTRACT: every log function writes to STDERR. stdout belongs to machine-readable
# output (`devenv list`, `need_sudo`, `gh_latest_tag`, …). No function in this file
# calls `exit` except `die` and `skip`.

[ -n "${_DEVENV_LOG:-}" ] && return 0
_DEVENV_LOG=1

# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------

# log_init_colour
#   Args: none.
#   Recomputes the colour palette. Colour is enabled only when stderr is a tty
#   AND neither NO_COLOR (https://no-color.org) nor DEVENV_NO_COLOR is set.
#   Call again after bin/devenv parses --no-color.
#   Exit codes: always 0. Dry-run: not a mutation.
log_init_colour() {
  if [ -t 2 ] && [ -z "${NO_COLOR:-}" ] && [ "${DEVENV_NO_COLOR:-0}" != 1 ]; then
    _C_RESET=$'\033[0m'
    _C_DIM=$'\033[2m'
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_BLUE=$'\033[34m'
    _C_CYAN=$'\033[36m'
    _C_BOLD=$'\033[1m'
  else
    _C_RESET='' _C_DIM='' _C_RED='' _C_GREEN='' _C_YELLOW='' _C_BLUE='' _C_CYAN='' _C_BOLD=''
  fi
}
log_init_colour

# _log EMIT_TAG COLOUR MSG…   (private)
_log() {
  local tag=$1 colour=$2
  shift 2
  [ "${DEVENV_QUIET:-0}" = 1 ] && case $tag in ' .. ' | ' ok ' | ' -- ') return 0 ;; esac
  printf '%s[%s]%s %s%s\n' "$colour" "$tag" "$_C_RESET" "${DEVENV_LOG_PREFIX:-}" "$*" >&2
}

# log_info MSG…      informational progress.                      -> stderr, always 0
log_info() { _log ' .. ' "$_C_BLUE" "$@"; }
# log_warn MSG…      something is off but the run continues.       -> stderr, always 0
log_warn() { _log ' !! ' "$_C_YELLOW" "$@"; }
# log_error MSG…     a failure. Does NOT exit — the caller decides. -> stderr, always 0
log_error() { _log ' xx ' "$_C_RED" "$@"; }
# log_success MSG…   a completed action.                           -> stderr, always 0
log_success() { _log ' ok ' "$_C_GREEN" "$@"; }
# log_debug MSG…     only printed when DEVENV_VERBOSE=1.           -> stderr, always 0
log_debug() {
  [ "${DEVENV_VERBOSE:-0}" = 1 ] || return 0
  _log ' -> ' "$_C_DIM" "$@"
}
# log_skip MSG…      "not applicable here". RETURNS 0 — it does NOT exit.
#                    Use `skip` when a whole module must abort with 78.
log_skip() { _log ' -- ' "$_C_DIM" "$@"; }
# log_plan MSG…      one line of the resolved plan (--dry-run / list).
log_plan() { _log 'plan' "$_C_CYAN" "$@"; }
# log_dryrun MSG…    one "would do this" line. Emitted by the run gate and by
#                    every fs.sh writer. Never call it from a module directly.
log_dryrun() { _log 'dry ' "$_C_CYAN" "$@"; }

# log_step TITLE
#   Section header. Under GitHub Actions it opens a collapsible ::group::.
#   Always pair with log_step_end. Exit codes: always 0.
log_step() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::group::%s\n' "$*" >&2
  else
    printf '\n%s==>%s %s%s%s\n' "$_C_BLUE" "$_C_RESET" "$_C_BOLD" "$*" "$_C_RESET" >&2
  fi
}

# log_step_end
#   Closes the section opened by log_step. Exit codes: always 0.
log_step_end() {
  [ -n "${GITHUB_ACTIONS:-}" ] && printf '::endgroup::\n' >&2
  return 0
}

# ---------------------------------------------------------------------------
# Terminating helpers — the ONLY two functions in lib/ that call `exit`
# ---------------------------------------------------------------------------

# die [CODE] MSG…
#   Args: an optional leading all-digit exit code (default 1), then the message.
#   Prints the message with log_error and exits. Never returns.
die() {
  local code=1
  case ${1:-} in
    '' | *[!0-9]*) ;;
    *)
      code=$1
      shift
      ;;
  esac
  log_error "$@"
  exit "$code"
}

# skip REASON…
#   Module-level "precondition missing". Prints a warning and exits 78, which
#   lib/registry.sh records as a SKIP and never as a failure.
#   Never returns. Do not use inside lib/ helpers that a module may recover from —
#   use `log_skip` + `return 0` there.
skip() {
  _log ' -- ' "$_C_YELLOW" "skip: $*"
  exit 78
}
