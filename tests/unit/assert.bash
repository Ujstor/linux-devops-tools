# shellcheck shell=bash
#
# tests/unit/assert.bash — the unit-test harness. Sourced by every tests/unit/test_*.sh.
#
# It loads lib/common.sh exactly the way a module does, with three differences that
# make a test file safe to run anywhere:
#
#   DEVENV_NO_TRAPS=1   no ERR/EXIT traps, so a deliberate failure is not "an error"
#   DEVENV_QUIET=1      library chatter stays out of the test output
#   HOME=<sandbox>      a throwaway directory, so a test can never touch a real
#                       dotfile even if an assertion is wrong
#
# No test here may touch the network, need root, or write outside $HOME.

[ -n "${_DEVENV_ASSERT:-}" ] && return 0
_DEVENV_ASSERT=1

T_PASS=0
T_FAIL=0
T_NAME=${T_NAME:-${0##*/}}

DEVENV_HOME=${DEVENV_HOME:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}
export DEVENV_HOME

T_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/devenv-unit.XXXXXXXX")
export T_SANDBOX
HOME=$T_SANDBOX
export HOME
export XDG_CONFIG_HOME="$T_SANDBOX/.config"
export XDG_CACHE_HOME="$T_SANDBOX/.cache"
export XDG_STATE_HOME="$T_SANDBOX/.local/state"

export DEVENV_NO_TRAPS=1
export DEVENV_QUIET=1
export DEVENV_NO_COLOR=1

t_cleanup() {
  case ${T_SANDBOX:-} in
    "${TMPDIR:-/tmp}"/devenv-unit.* | /tmp/devenv-unit.*) rm -rf -- "$T_SANDBOX" ;;
  esac
}
trap t_cleanup EXIT

# shellcheck source=lib/common.sh
. "$DEVENV_HOME/lib/common.sh"

# ---------------------------------------------------------------------------
# Assertions. Every one of them returns 0, so `set -e` never turns a failed
# assertion into an aborted test file — the count is what decides the outcome.
# ---------------------------------------------------------------------------

t_ok() {
  T_PASS=$((T_PASS + 1))
  printf '    ok   %s\n' "$*"
  return 0
}

t_not_ok() {
  T_FAIL=$((T_FAIL + 1))
  printf '    FAIL %s\n' "$*" >&2
  return 0
}

assert_eq() {
  local want=$1 got=$2 what=${3:-values are equal}
  if [ "$want" = "$got" ]; then
    t_ok "$what"
  else
    t_not_ok "$what
           expected: [$want]
           actual:   [$got]"
  fi
  return 0
}

assert_ne() {
  local a=$1 b=$2 what=${3:-values differ}
  if [ "$a" != "$b" ]; then t_ok "$what"; else t_not_ok "$what (both [$a])"; fi
  return 0
}

assert_contains() {
  local haystack=$1 needle=$2 what=${3:-output contains the expected text}
  case $haystack in
    *"$needle"*) t_ok "$what" ;;
    *) t_not_ok "$what
           looking for: [$needle]
           in:          [$haystack]" ;;
  esac
  return 0
}

# assert_ok WHAT CMD… / assert_fail WHAT CMD…
assert_ok() {
  local what=$1
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then t_ok "$what"; else t_not_ok "$what (exit $rc)"; fi
  return 0
}

assert_fail() {
  local what=$1
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then t_ok "$what"; else t_not_ok "$what (unexpectedly exit 0)"; fi
  return 0
}

# assert_status CODE WHAT CMD… — an exact exit status, which is how the module
# protocol distinguishes 78 (skip) from a failure.
assert_status() {
  local want=$1 what=$2
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$want" "$rc" "$what"
  return 0
}

assert_file() {
  # Two `local`s on purpose: in a single `local f=$1 what=${2:-$f …}` the default
  # expands BEFORE f is assigned, so it would read the caller's f — or die with
  # "unbound variable" under `set -u` when there is none (SC2318).
  local f=$1
  local what=${2:-$f exists}
  if [ -f "$f" ]; then t_ok "$what"; else t_not_ok "$what ($f is missing)"; fi
  return 0
}

assert_no_file() {
  local f=$1
  local what=${2:-$f does not exist}
  if [ ! -e "$f" ]; then t_ok "$what"; else t_not_ok "$what ($f exists)"; fi
  return 0
}

assert_symlink() {
  local f=$1
  local what=${2:-$f is still a symlink}
  if [ -L "$f" ]; then t_ok "$what"; else t_not_ok "$what ($f is not a symlink)"; fi
  return 0
}

# t_section TITLE — a heading in the output, purely cosmetic.
t_section() { printf '  -- %s\n' "$*"; }

# t_summary — the last line of every test file. Exit status decides the result.
t_summary() {
  printf '  %s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
