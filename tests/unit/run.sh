#!/usr/bin/env bash
#
# tests/unit/run.sh — every unit test, in order, in its own process.
#
# A unit test here never touches the network, never needs root, and never writes
# outside the throwaway $HOME that tests/unit/assert.bash creates for it. That is
# what makes `make test-unit` safe to run on the machine you are working on.
#
# Usage:
#     make test-unit
#     bash tests/unit/run.sh                 # everything
#     bash tests/unit/run.sh fs net          # only test_fs.sh and test_net.sh

set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
UNIT="$ROOT/tests/unit"

PASSED=0
FAILED=0
FAILED_FILES=''

run_one() {
  local f=$1 name rc=0
  name=$(basename -- "$f")
  printf '\n== %s\n' "$name"
  bash "$f" || rc=$?
  if [ "$rc" -eq 0 ]; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES="$FAILED_FILES $name"
  fi
  return 0
}

main() {
  local -a files=()
  if [ $# -gt 0 ]; then
    local want
    for want in "$@"; do
      if [ -f "$UNIT/test_$want.sh" ]; then
        files+=("$UNIT/test_$want.sh")
      elif [ -f "$UNIT/$want" ]; then
        files+=("$UNIT/$want")
      else
        printf 'no such unit test: %s\n' "$want" >&2
        return 64
      fi
    done
  else
    local f
    for f in "$UNIT"/test_*.sh; do
      [ -f "$f" ] || continue
      files+=("$f")
    done
  fi

  # A run that found no test file has not proved anything, so it must not
  # report success. `make test-unit` and CI both read this exit status, and
  # "no unit tests found" followed by 0 is indistinguishable from a green suite
  # — the same shape as a policy rule that greps a tree it cannot see.
  if [ ${#files[@]} -eq 0 ]; then
    printf 'no unit test was found in %s\n' "$UNIT" >&2
    printf 'That is a broken checkout, not a passing suite. Refusing to report success.\n' >&2
    return 1
  fi

  local f
  for f in "${files[@]}"; do
    run_one "$f"
  done

  printf '\n===============================================\n'
  printf 'unit tests: %d file(s) passed, %d failed\n' "$PASSED" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then
    printf 'failed:%s\n' "$FAILED_FILES" >&2
    return 1
  fi
  return 0
}

main "$@"
