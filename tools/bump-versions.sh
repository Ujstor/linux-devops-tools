#!/usr/bin/env bash
#
# tools/bump-versions.sh — report (or apply) newer upstream tags for versions.env.
#
# versions.env is the only place this repository pins anything. This script reads
# it, asks each upstream what its current release is, and prints the drift. It is
# REPORT-ONLY unless you pass --write.
#
# It deliberately uses the `releases/latest` redirect rather than the GitHub API:
# the API is rate-limited to 60 requests/hour unauthenticated, and this repository
# pins ~50 things. The redirect is unauthenticated, unlimited, and returns the same
# answer. `curl -fsSIL` follows it; the final URL ends in /releases/tag/<tag>.
#
# Usage:
#     bash tools/bump-versions.sh                 # report drift
#     bash tools/bump-versions.sh --write         # rewrite versions.env in place
#     bash tools/bump-versions.sh --only K9S,HELM # limit to some pins
#     ONLY_STALE=1 bash tools/bump-versions.sh    # hide up-to-date rows
#
# Exit status:
#     0  every pin is current (or --write applied cleanly)
#     1  a lookup failed
#     2  drift found (report mode) — so CI can gate on it if you ever want that
#
# What it does NOT do: it never touches a pin whose value is `apt` (the distro
# owns it), `latest` (deliberately unpinned, resolved at install time), or one
# with no `# renovate:` annotation naming a GitHub repository. Those are choices,
# not drift.

set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)
VERSIONS=$ROOT/versions.env

WRITE=0
ONLY=''
ONLY_STALE=${ONLY_STALE:-0}

while [ $# -gt 0 ]; do
  case $1 in
    --write) WRITE=1 ;;
    --only)
      ONLY=${2:-}
      shift
      ;;
    --only=*) ONLY=${1#--only=} ;;
    -h | --help)
      sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      exit 1
      ;;
  esac
  shift
done

[ -r "$VERSIONS" ] || {
  printf 'not readable: %s\n' "$VERSIONS" >&2
  exit 1
}

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m' C_DIM=$'\033[2m' C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_RED=$'\033[31m'
else
  C_RESET='' C_DIM='' C_YEL='' C_GRN='' C_RED=''
fi

# gh_latest_tag OWNER/REPO — print the current release tag, or nothing.
# Follows redirects and asserts the resolved URL really is a release tag, so a
# renamed repository (several of ours have been) resolves instead of silently
# reporting "no release".
gh_latest_tag() {
  local repo=$1 final
  final=$(curl -fsSIL \
    --proto '=https' --tlsv1.2 --retry 2 --max-time 20 \
    -o /dev/null -w '%{url_effective}' \
    "https://github.com/$repo/releases/latest" 2>/dev/null) || return 1
  case $final in
    */releases/tag/*) printf '%s\n' "${final##*/releases/tag/}" ;;
    *) return 1 ;;
  esac
}

want() {
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$1,"*) return 0 ;; esac
  # also match a bare prefix, so --only K9S matches K9S_VERSION
  local k=${1%_VERSION}
  case ",$ONLY," in *",$k,"*) return 0 ;; esac
  return 1
}

stale=0 failed=0 checked=0 current=0 held=0
updates=()
pending_repo='' pending_manual=0 pending_filter=''

# A pin's annotations sit in the comment block directly above it. Three matter:
#
#   # renovate: datasource=github-releases depName=OWNER/REPO
#   # pin-policy: manual        this pin is NOT to be moved automatically
#   # tag-filter: <glob>        only tags matching this are candidates
#
# `pin-policy: manual` is load-bearing, not decoration. HELM_VERSION is pinned to
# the 3.x line on purpose while upstream's latest is already 4.x — without this
# check, `--write` would silently jump a major version in a bootstrap script.
# Same shape for KOR, whose releases/latest is a Helm CHART tag (kor-0.x), not the
# CLI's (vX.Y.Z): a bump there would rewrite the pin to an unrelated versioning
# scheme, which is why it carries a tag-filter.
while IFS= read -r line; do
  case $line in
    '# renovate:'*)
      case $line in
        *datasource=github-releases*)
          pending_repo=${line##*depName=}
          pending_repo=${pending_repo%% *}
          ;;
        *) pending_repo='' ;;
      esac
      continue
      ;;
    '# pin-policy: manual'*)
      pending_manual=1
      continue
      ;;
    '# tag-filter:'*)
      pending_filter=${line#'# tag-filter:'}
      pending_filter=${pending_filter## }
      pending_filter=${pending_filter%% *}
      continue
      ;;
    '#'*)
      # Any other comment inside the block is prose. It must NOT clear the
      # annotations — they are frequently separated from their pin by a note.
      continue
      ;;
    [A-Z]*_VERSION=*) ;;
    *)
      pending_repo='' pending_manual=0 pending_filter=''
      continue
      ;;
  esac

  key=${line%%=*}
  cur=${line#*=}
  repo=$pending_repo
  manual=$pending_manual
  filter=$pending_filter
  pending_repo='' pending_manual=0 pending_filter=''

  [ -n "$repo" ] || continue
  want "$key" || continue

  case $cur in
    apt | latest | '')
      continue
      ;;
  esac

  if [ "$manual" = 1 ]; then
    held=$((held + 1))
    [ "$ONLY_STALE" = 1 ] || printf '%s  %-26s %-14s held (pin-policy: manual)%s\n' \
      "$C_DIM" "$key" "$cur" "$C_RESET"
    continue
  fi

  checked=$((checked + 1))
  if ! new=$(gh_latest_tag "$repo"); then
    printf '%s  %-26s %-14s lookup failed (%s)%s\n' \
      "$C_RED" "$key" "$cur" "$repo" "$C_RESET" >&2
    failed=$((failed + 1))
    continue
  fi

  # A prefixed-tag monorepo (kustomize/vX.Y.Z) resolves to a tag the pin does not
  # use. Compare on the bare version so it does not report drift forever, and only
  # ever write back the form the pin already has.
  case $new in
    */v*)
      case $cur in
        */*) ;;
        *) new=${new##*/} ;;
      esac
      ;;
  esac

  # A tag-filter means "tags that do not match are not this tool's releases".
  if [ -n "$filter" ]; then
    # shellcheck disable=SC2254  # the glob is the whole point of the directive
    case $new in
      $filter) ;;
      *)
        printf '%s  %-26s %-14s upstream latest %s does not match tag-filter %s — skipped%s\n' \
          "$C_YEL" "$key" "$cur" "$new" "$filter" "$C_RESET" >&2
        continue
        ;;
    esac
  fi

  if [ "$new" = "$cur" ]; then
    current=$((current + 1))
    [ "$ONLY_STALE" = 1 ] || printf '%s  %-26s %-14s current%s\n' \
      "$C_DIM$C_GRN" "$key" "$cur" "$C_RESET"
    continue
  fi

  stale=$((stale + 1))
  printf '%s  %-26s %-14s -> %-14s %s%s\n' \
    "$C_YEL" "$key" "$cur" "$new" "$repo" "$C_RESET"

  # Collected, never applied here: rewriting the file inside the loop that is
  # reading it means every later iteration reads a file that has moved under it
  # (shellcheck SC2094). The whole batch is applied once, after the loop closes.
  # An explicit `if`, not `[ … ] && …`: that form makes the loop body's last
  # command return 1 whenever WRITE=0, which is exactly the shape `set -e` acts on.
  if [ "$WRITE" = 1 ]; then
    updates+=("$key=$new")
  fi
done <"$VERSIONS"

if [ "$WRITE" = 1 ] && [ ${#updates[@]} -gt 0 ]; then
  # One pass, one temp file, one rename: an interrupted run leaves the original
  # untouched rather than a half-rewritten pin file.
  tmp=$(mktemp "$VERSIONS.XXXXXX")
  printf '%s\n' "${updates[@]}" >"$tmp.map"
  awk -F= '
    NR == FNR { want[$1] = substr($0, index($0, "=") + 1); next }
    /^[A-Z][A-Z0-9_]*_VERSION=/ {
      k = substr($0, 1, index($0, "=") - 1)
      if (k in want) { print k "=" want[k]; next }
    }
    { print }
  ' "$tmp.map" "$VERSIONS" >"$tmp"
  chmod --reference="$VERSIONS" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
  mv -f "$tmp" "$VERSIONS"
  rm -f "$tmp.map"
fi

printf '\n'
if [ "$WRITE" = 1 ] && [ "$stale" -gt 0 ]; then
  printf 'wrote %s: %d pin(s) updated, %d current, %d lookup failure(s)\n' \
    "$VERSIONS" "$stale" "$current" "$failed"
  printf 'review with: git diff -- %s\n' "${VERSIONS#"$ROOT"/}"
else
  printf '%d pin(s) checked: %d current, %d stale, %d lookup failure(s), %d held\n' \
    "$checked" "$current" "$stale" "$failed" "$held"
fi

[ "$failed" -gt 0 ] && exit 1
[ "$WRITE" = 0 ] && [ "$stale" -gt 0 ] && exit 2
exit 0
