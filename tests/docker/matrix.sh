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
#     IMAGES="docker.io/library/debian:12" bash tests/docker/matrix.sh
#     PROFILE=devops bash tests/docker/matrix.sh      # the default set, what CI runs
#     bash tests/docker/matrix.sh --print-images      # the resolved lists, no Docker
#
# Environment:
#     IMAGES        required images, space separated. Default: the image column of
#                   config/os-support.list, every row — the one declaration of the
#                   supported releases (spec 002 FR-002). There is no list here.
#     SOFT_IMAGES   images that may fail without failing the run. Default: none.
#                   Every supported release is a gate (SC-007); this exists for a
#                   candidate release someone wants to try, by hand, before it
#                   enters the list.
#     PROFILE       profile installed for real     (default minimal)
#     DRY_PROFILE   profile used for the dry run   (default ci)
#     DOCKER        the container CLI              (default docker)
#     PULL          1 = docker pull each image first
#     REQUIRE_DOCKER 1 = a missing or unusable Docker is a FAILURE, not a skip.
#                   Set it anywhere the result is being trusted as a gate.
#     JOBS          1 = sequential (default). Anything else is not supported yet:
#                   the images fight over the network and the logs interleave.
#
# It needs Docker and network access. Both are absent often enough that a missing
# one is a clear SKIP, never a confusing failure.

set -euo pipefail

# "Unset", not "empty", decides whether a default applies — `${VAR-default}` and
# `${VAR+set}`, never the colon forms. With the colon an explicitly EMPTY IMAGES
# falls back to the full matrix, so `IMAGES= make test-docker` — a typo, or a
# caller that built an empty list — silently runs something other than what was
# asked for, and the empty-list tripwire below could never fire.
#
# IMAGES is not defaulted on this line: its default is read from
# config/os-support.list by resolve_images, which can fail, and a failure there
# must say why.
SOFT_IMAGES=${SOFT_IMAGES-}
PROFILE=${PROFILE:-minimal}
DRY_PROFILE=${DRY_PROFILE:-ci}
DOCKER=${DOCKER:-docker}
PULL=${PULL:-0}
REQUIRE_DOCKER=${REQUIRE_DOCKER:-0}

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
LOGDIR=${LOGDIR:-$ROOT/.cache/docker-matrix}
LIST=$ROOT/config/os-support.list
IMAGES_FROM='the IMAGES variable'

RESULTS=''
HARD_FAILURES=0
RAN=0

# resolve_images — set IMAGES from config/os-support.list unless the caller set
# it (set, not non-empty: see the note above). A missing list,
# a row that is not five columns and a list with no row at all are failures:
# each of them would otherwise test a different set from the one declared, and
# tests/policy/os-support.sh — which compares this script's default with the CI
# matrices — would be comparing against nothing.
resolve_images() {
  [ -z "${IMAGES+set}" ] || return 0
  if [ ! -r "$LIST" ]; then
    printf 'IMAGES is unset and %s is not readable — there is no default to test\n' "$LIST" >&2
    return 1
  fi
  local bad
  bad=$(awk '!/^[[:space:]]*(#|$)/ && NF != 5 { printf "  line %d: %s\n", NR, $0 }' "$LIST")
  if [ -n "$bad" ]; then
    printf '%s: a row is not "family distro release image lab":\n%s\n' "$LIST" "$bad" >&2
    return 1
  fi
  IMAGES=$(awk '!/^[[:space:]]*(#|$)/ { printf "%s%s", sep, $4; sep = " " }' "$LIST")
  if [ -z "$IMAGES" ]; then
    printf '%s has no release row — there is nothing to test\n' "$LIST" >&2
    return 1
  fi
  IMAGES_FROM=${LIST#"$ROOT"/}
  return 0
}

run_image() {
  local image=$1 soft=$2 log rc=0 name
  name=$(printf '%s' "$image" | tr -c 'A-Za-z0-9._-' '-')
  log="$LOGDIR/$name.log"

  printf '\n########## %s ##########\n' "$image"
  RAN=$((RAN + 1))
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
    RESULTS="$RESULTS$(printf '  %-36s PASS\n' "$image")"$'\n'
    return 0
  fi
  if [ "$soft" = 1 ]; then
    RESULTS="$RESULTS$(printf '  %-36s FAIL (allowed: not a supported target yet)\n' "$image")"$'\n'
    return 0
  fi
  RESULTS="$RESULTS$(printf '  %-36s FAIL  -> %s\n' "$image" "$log")"$'\n'
  HARD_FAILURES=$((HARD_FAILURES + 1))
  return 0
}

# no_docker WHY — a missing Docker is a skip on a developer's laptop and a
# failure anywhere the result is being read as a gate. It is never both silently:
# REQUIRE_DOCKER=1 says which one this run is.
no_docker() {
  if [ "$REQUIRE_DOCKER" = 1 ]; then
    printf '%s\n' "$1" >&2
    printf 'REQUIRE_DOCKER=1: a matrix that ran no container has not proved anything.\n' >&2
    return 1
  fi
  printf 'skip: %s\n' "$1"
  printf 'Nothing was tested. Set REQUIRE_DOCKER=1 to make this a failure instead.\n'
  return 0
}

main() {
  case ${1:-} in
    '') ;;
    --print-images)
      # What a run WOULD test, without Docker: one `image X` or `soft X` line
      # each. tests/policy/os-support.sh reads this to hold the default to the
      # list, so it resolves exactly as a real run does.
      resolve_images || return 1
      local i
      for i in $IMAGES; do printf 'image %s\n' "$i"; done
      for i in $SOFT_IMAGES; do printf 'soft %s\n' "$i"; done
      return 0
      ;;
    *)
      printf 'usage: %s [--print-images]\n' "${0##*/}" >&2
      return 64
      ;;
  esac
  resolve_images || return 1

  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    no_docker "$DOCKER is not installed — the container matrix needs it"
    return
  fi
  if ! "$DOCKER" info >/dev/null 2>&1; then
    no_docker "$DOCKER is installed but not usable here (daemon down, or no permission)"
    return
  fi

  # An empty image list runs no container and, without this, prints "every
  # supported image passed". IMAGES="" is a typo, not a clean result.
  if [ -z "${IMAGES// /}" ]; then
    printf 'IMAGES is empty: there is nothing to test, so there is nothing to pass\n' >&2
    return 1
  fi

  mkdir -p "$LOGDIR"
  printf 'checkout : %s\n' "$ROOT"
  printf 'profiles : dry-run=%s install=%s\n' "$DRY_PROFILE" "$PROFILE"
  printf 'images   : %s  (from %s)\n' "$IMAGES" "$IMAGES_FROM"
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
  if [ "$RAN" -eq 0 ]; then
    printf 'no container was started at all — refusing to report a pass\n' >&2
    return 1
  fi
  printf 'every supported image passed (%d container run(s))\n' "$RAN"
  return 0
}

main "$@"
