#!/usr/bin/env bash
#
# tests/docker/matrix.sh — run tests/docker/entry.sh on every supported image.
#
# Each image gets a throwaway container with this checkout mounted read-only at
# /src. The container installs, installs again, and asserts that the second run
# changed nothing; see tests/docker/entry.sh for what is actually checked.
#
# Usage:
#     make test-docker
#     bash tests/docker/matrix.sh
#     IMAGES="debian:12 ubuntu:24.04" bash tests/docker/matrix.sh
#     PROFILE=ci bash tests/docker/matrix.sh          # a deeper, slower run
#
# Environment:
#     IMAGES        required images, space separated
#     SOFT_IMAGES   images that may fail without failing the run (a future release)
#     PROFILE       profile installed for real     (default minimal)
#     DRY_PROFILE   profile used for the dry run   (default ci)
#     DOCKER        the container CLI              (default docker)
#     PULL          1 = docker pull each image first
#     JOBS          1 = sequential (default). Anything else is not supported yet:
#                   the images fight over the network and the logs interleave.
#
# It needs Docker and network access. Both are absent often enough that a missing
# one is a clear SKIP, never a confusing failure.

set -euo pipefail

IMAGES=${IMAGES:-"debian:12 debian:13 ubuntu:22.04 ubuntu:24.04"}
SOFT_IMAGES=${SOFT_IMAGES:-"ubuntu:26.04"}
PROFILE=${PROFILE:-minimal}
DRY_PROFILE=${DRY_PROFILE:-ci}
DOCKER=${DOCKER:-docker}
PULL=${PULL:-0}

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
LOGDIR=${LOGDIR:-$ROOT/.cache/docker-matrix}

RESULTS=''
HARD_FAILURES=0

run_image() {
  local image=$1 soft=$2 log rc=0 name
  name=$(printf '%s' "$image" | tr -c 'A-Za-z0-9._-' '-')
  log="$LOGDIR/$name.log"

  printf '\n########## %s ##########\n' "$image"
  if [ "$PULL" = 1 ]; then
    "$DOCKER" pull -q "$image" >/dev/null 2>&1 || true
  fi

  # --rm: the container is garbage the moment it exits. No -v other than the
  # read-only source mount, so nothing on this machine can be touched.
  "$DOCKER" run --rm \
    -v "$ROOT:/src:ro" \
    -e "PROFILE=$PROFILE" \
    -e "DRY_PROFILE=$DRY_PROFILE" \
    -e "SRC=/src" \
    "$image" bash /src/tests/docker/entry.sh 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}

  if [ "$rc" -eq 0 ]; then
    RESULTS="$RESULTS$(printf '  %-16s PASS\n' "$image")"$'\n'
    return 0
  fi
  if [ "$soft" = 1 ]; then
    RESULTS="$RESULTS$(printf '  %-16s FAIL (allowed: not a supported target yet)\n' "$image")"$'\n'
    return 0
  fi
  RESULTS="$RESULTS$(printf '  %-16s FAIL  -> %s\n' "$image" "$log")"$'\n'
  HARD_FAILURES=$((HARD_FAILURES + 1))
  return 0
}

main() {
  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    printf 'skip: %s is not installed — the container matrix needs it\n' "$DOCKER"
    return 0
  fi
  if ! "$DOCKER" info >/dev/null 2>&1; then
    printf 'skip: %s is installed but not usable here (daemon down, or no permission)\n' "$DOCKER"
    return 0
  fi

  mkdir -p "$LOGDIR"
  printf 'checkout : %s\n' "$ROOT"
  printf 'profiles : dry-run=%s install=%s\n' "$DRY_PROFILE" "$PROFILE"
  printf 'images   : %s\n' "$IMAGES"
  [ -n "$SOFT_IMAGES" ] && printf 'soft     : %s\n' "$SOFT_IMAGES"
  printf 'logs     : %s\n' "$LOGDIR"

  local image
  for image in $IMAGES; do
    run_image "$image" 0
  done
  for image in $SOFT_IMAGES; do
    run_image "$image" 1
  done

  printf '\n========== matrix ==========\n%s' "$RESULTS"
  if [ "$HARD_FAILURES" -gt 0 ]; then
    printf '%d supported image(s) failed\n' "$HARD_FAILURES" >&2
    return 1
  fi
  printf 'every supported image passed\n'
  return 0
}

main "$@"
