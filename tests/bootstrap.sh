#!/usr/bin/env bash
#
# tests/bootstrap.sh — `curl … | bash` still survives.
#
# This is the shape a real user runs, and it is the shape that breaks first:
#
#   * under `bash -s` the BASH_SOURCE array is EMPTY, so an unguarded
#     ${BASH_SOURCE[0]} under `set -u` is fatal before the script prints a
#     single line (MUST-FIX S1)
#   * from cloud-init, a Dockerfile or a provisioning pipeline there is no
#     controlling terminal at all, and no stdin to read from
#
# CI has always run these two commands inline, which made this the one job a
# developer could not reproduce before pushing. It is `make test-bootstrap` now.
#
# EVERY CHECK ASSERTS ON THE OUTPUT, not only on the exit status. `bash -s --
# --help` printing nothing and exiting 0 is exactly the failure this is for, and
# a status-only assertion would call it a pass.
#
# Usage:
#     bash tests/bootstrap.sh
#     make test-bootstrap

set -euo pipefail

PROG=${0##*/}
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
INSTALLER=$ROOT/install.sh

# A line only the bootstrapper's own --help prints. If this ever stops matching,
# the check fails loudly rather than quietly measuring nothing.
MARKER='Bootstrap options (consumed here):'

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$*"
}

no() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$*" >&2
}

# check WHAT — runs the pipeline on stdin of this function and judges it.
# Reads the captured output from $1 (a file) and the status from $2.
judge() {
  local what=$1 log=$2 rc=$3 bytes
  bytes=$(wc -c <"$log" | tr -d ' ')
  if [ "$rc" -ne 0 ]; then
    no "$what: exited $rc"
    sed 's/^/        /' "$log" >&2
    return 0
  fi
  if [ "$bytes" -lt 200 ]; then
    no "$what: exited 0 but printed only $bytes byte(s) — a silent no-op is not a pass"
    sed 's/^/        /' "$log" >&2
    return 0
  fi
  if ! grep -qF -- "$MARKER" "$log"; then
    no "$what: exited 0 and printed $bytes byte(s), but not the help text"
    sed 's/^/        /' "$log" >&2
    return 0
  fi
  ok "$what ($bytes bytes of help)"
  return 0
}

main() {
  [ -f "$INSTALLER" ] || {
    printf '%s: no installer at %s\n' "$PROG" "$INSTALLER" >&2
    return 1
  }

  local tmp log rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/devenv-bootstrap.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: a fresh mktemp path
  trap "rm -rf -- '$tmp'" EXIT
  log=$tmp/out

  printf '%s: %s\n' "$PROG" "$INSTALLER"

  # 1. The canonical `curl … | bash -s -- --help`. BASH_SOURCE is empty here.
  rc=0
  # shellcheck disable=SC2002  # the useless `cat` IS the test: it is what makes
  # the installer arrive on stdin with an empty BASH_SOURCE, exactly as `curl |
  # bash` does. `bash -s < install.sh` is not the same code path.
  cat "$INSTALLER" | bash -s -- --help >"$log" 2>&1 || rc=$?
  judge 'cat install.sh | bash -s -- --help' "$log" "$rc"

  # 2. The same with no controlling terminal and no stdin, which is how it runs
  #    unattended. setsid is util-linux and present on every target of this
  #    repository; if it is missing here that is reported, never skipped.
  rc=0
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "cat '$INSTALLER' | bash -s -- --help" >"$log" 2>&1 </dev/null || rc=$?
    judge 'the same with no tty (setsid)' "$log" "$rc"
  else
    no 'setsid is not installed, so the no-tty case could not be exercised'
  fi

  # 3. Piped into a pipe, so stdout is not a terminal either. A script that only
  #    works when it can talk to a tty passes 1 and 2 and fails here.
  rc=0
  # shellcheck disable=SC2002  # as above: stdin must be a pipe, not a file
  { cat "$INSTALLER" | bash -s -- --help 2>&1 | cat >"$log"; } || rc=$?
  judge 'stdout is a pipe, not a terminal' "$log" "$rc"

  # 4. Running the file directly must agree with the piped form. A divergence
  #    means the BASH_SOURCE guard changed behaviour instead of only surviving.
  rc=0
  bash "$INSTALLER" --help >"$log" 2>&1 || rc=$?
  judge 'bash install.sh --help' "$log" "$rc"

  printf '\n%s: %d passed, %d failed\n' "$PROG" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || return 1
  # The count is the tripwire: if the checks above are ever commented out, this
  # target must not keep reporting success.
  [ "$PASS" -ge 4 ] || {
    printf '%s: only %d check(s) ran — expected at least 4\n' "$PROG" "$PASS" >&2
    return 1
  }
  return 0
}

main "$@"
