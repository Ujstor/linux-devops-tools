#!/usr/bin/env bash
#
# tests/policy/os-support.sh — the supported releases are declared once (SC-006).
#
# config/os-support.list is THE list (spec 002 FR-002): lib/os.sh reads it to
# decide "tested", tests/docker/matrix.sh reads it for its default images. Two
# places cannot read it and carry a COPY instead — GitLab resolves an include's
# `inputs:` and GitHub resolves `strategy.matrix` when the pipeline is created,
# before any file in the checkout is opened — and the lab inventory is a second
# file about the same releases. A copy drifts silently: a release dropped from a
# CI matrix keeps its row, keeps OS_SUPPORT=tested, and is never exercised again;
# a release added to the list but not to CI is "supported" on no evidence at all.
# This gate is what keeps the copies honest.
#
#   list     every row is `family distro release image lab`, family and lab are
#            valid values, the image is fully qualified and tagged, and no
#            release or image appears twice
#   gitlab   .gitlab-ci.yml: container_matrix_images is the image column, as a
#            set; container_registry_prefix is '' (the images are already
#            qualified); enable_container_soft_matrix is false — the component
#            defaults it to TRUE, so leaving it out is an allowed-to-fail lane
#            (SC-007)
#   github   .github/workflows/ci.yml: the container matrix's `image:` list is
#            the image column, and nothing in the workflow is continue-on-error
#   matrix   tests/docker/matrix.sh --print-images, with IMAGES and SOFT_IMAGES
#            unset, resolves to the image column and to no soft image
#   lab      tests/lab/inventory.list (`guest address distro release project`):
#            exactly one guest per lab=yes row, and no guest for anything else.
#            INTERNAL ONLY. The public variant has no lab inventory, so there
#            this comparison is skipped — and the verdict line says so.
#
# Source of truth is always the list. When this fails, fix the copy.
#
# Usage:
#     bash tests/policy/os-support.sh
#     bash tests/policy/os-support.sh --self-test   # prove every check still fires
#     make lint-os-support

set -euo pipefail

PROG=${0##*/}

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
FAILED=0
FIRED=''
SKIPPED=''

LIST_REL='config/os-support.list'
GITLAB_REL='.gitlab-ci.yml'
GITHUB_REL='.github/workflows/ci.yml'
MATRIX_REL='tests/docker/matrix.sh'
LAB_REL='tests/lab/inventory.list'

FAMILIES='debian redhat suse arch'

fail() {
  local check=$1 msg=$2
  printf 'OS-SUPPORT [%s] %s\n' "$check" "$msg" >&2
  FAILED=$((FAILED + 1))
  case " $FIRED " in
    *" $check "*) ;;
    *) FIRED="$FIRED $check" ;;
  esac
  return 0
}

# rows FILE — the non-comment, non-blank lines of a whitespace table, each
# squeezed to single spaces. Only WHOLE-line comments: a trailing `# note` makes
# a row six columns, which is reported rather than guessed at, because lib/os.sh
# reads the same file and must not have to guess either.
rows() {
  awk '!/^[[:space:]]*(#|$)/ { $1 = $1; print }' "$1"
}

# yaml_list FILE KEY [AFTER] — the items of the sequence under the first `KEY:`
# (after the first line matching the ERE AFTER, when given). Block form
# (`- item` lines) and flow form (`[a, b]`), quotes and trailing comments
# stripped. Prints nothing when the key is absent or holds a scalar — which the
# caller reports, because "no item" can never equal a non-empty list.
#
# awk, not a YAML library: the shell-ci image has PyYAML and the GitHub lint
# runner does not, and this gate must run wherever `make check` does.
yaml_list() {
  awk -v key="$2" -v after="${3:-}" '
    function unquote(s) {
      sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) s = substr(s, 2, length(s) - 2)
      return s
    }
    BEGIN { armed = (after == "") }
    !armed { if ($0 ~ after) armed = 1; next }
    !inlist {
      if (match($0, "^[[:space:]]*" key ":")) {
        rest = substr($0, RLENGTH + 1)
        sub(/[[:space:]]+#.*$/, "", rest); sub(/^[[:space:]]+/, "", rest)
        keyind = match($0, /[^[:space:]]/) - 1
        if (rest == "") { inlist = 1; next }
        if (rest ~ /^\[/) {
          gsub(/^\[|\][[:space:]]*$/, "", rest)
          n = split(rest, items, ",")
          for (i = 1; i <= n; i++) { it = unquote(items[i]); if (it != "") print it }
        }
        exit
      }
      next
    }
    /^[[:space:]]*(#.*)?$/ { next }
    {
      ind = match($0, /[^[:space:]]/) - 1
      if ($0 ~ /^[[:space:]]*-[[:space:]]/ && ind >= keyind) {
        it = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", it); sub(/[[:space:]]+#.*$/, "", it)
        print unquote(it)
        next
      }
      exit
    }' "$1"
}

# yaml_scalar FILE KEY — the value of the first `KEY: value`, quotes and a
# trailing comment stripped; `<empty>` for '' or "", nothing when absent.
yaml_scalar() {
  awk -v key="$2" '
    match($0, "^[[:space:]]*" key ":") {
      v = substr($0, RLENGTH + 1)
      sub(/[[:space:]]+#.*$/, "", v); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      if (v == "\"\"" || v == "'\'''\''") v = "<empty>"
      else if (v ~ /^".*"$/ || v ~ /^'\''.*'\''$/) v = substr(v, 2, length(v) - 2)
      print v
      exit
    }' "$1"
}

# compare CHECK WHERE EXPECTED ACTUAL — EXPECTED and ACTUAL are newline lists.
# Reports each item missing from WHERE, each item WHERE has that the list does
# not, and each item WHERE names twice (a duplicate parallel:matrix entry is a
# second job over the same release, not a second release).
compare() {
  local check=$1 where=$2 expected=$3 actual=$4 item
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    fail "$check" "$item is in $LIST_REL but not in $where"
  done < <(comm -23 <(printf '%s\n' "$expected" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(printf '%s\n' "$actual" | sed '/^$/d' | LC_ALL=C sort -u))
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    fail "$check" "$item is in $where but not in $LIST_REL"
  done < <(comm -13 <(printf '%s\n' "$expected" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(printf '%s\n' "$actual" | sed '/^$/d' | LC_ALL=C sort -u))
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    fail "$check" "$item appears more than once in $where"
  done < <(printf '%s\n' "$actual" | sed '/^$/d' | LC_ALL=C sort | uniq -d)
  return 0
}

# ---------------------------------------------------------------------------
# The checks. LIST_* are filled by check_list and read by every other check.
# ---------------------------------------------------------------------------

LIST_ROWS=''
LIST_IMAGES=''
LIST_LAB=''
LIST_NOLAB=''

check_list() {
  local f=$ROOT/$LIST_REL row family distro release image lab n=0 seen_rel='' seen_img=''
  local -a col=()
  LIST_ROWS='' LIST_IMAGES='' LIST_LAB='' LIST_NOLAB=''
  if [ ! -r "$f" ]; then
    fail list "$LIST_REL is missing — it is the one declaration every other copy is checked against"
    return 1
  fi
  while IFS= read -r row; do
    n=$((n + 1))
    read -r -a col <<<"$row"
    if [ "${#col[@]}" -ne 5 ]; then
      fail list "row $n is ${#col[@]} column(s), not 'family distro release image lab': $row"
      continue
    fi
    family=${col[0]} distro=${col[1]} release=${col[2]} image=${col[3]} lab=${col[4]}
    case " $FAMILIES " in
      *" $family "*) ;;
      *) fail list "row $n: unknown family '$family' (one of: $FAMILIES)" ;;
    esac
    case $lab in
      yes | no) ;;
      *) fail list "row $n: lab must be yes or no, found '$lab'" ;;
    esac
    # Fully qualified: a registry host (it has a dot) before the first slash,
    # and an explicit tag. podman resolves no short name, and the GitLab input
    # carries the same string with container_registry_prefix ''.
    [[ $image =~ ^[a-z0-9.-]+\.[a-z]+(:[0-9]+)?/[^[:space:]:]+:[^[:space:]/:]+$ ]] \
      || fail list "row $n: image '$image' is not fully qualified and tagged (registry/path:tag)"
    case " $seen_rel " in
      *" $distro/$release "*) fail list "row $n: $distro $release is listed twice" ;;
    esac
    case " $seen_img " in
      *" $image "*) fail list "row $n: image $image is listed twice" ;;
    esac
    seen_rel="$seen_rel $distro/$release" seen_img="$seen_img $image"
    LIST_IMAGES="$LIST_IMAGES$image"$'\n'
    if [ "$lab" = yes ]; then
      LIST_LAB="$LIST_LAB$distro $release"$'\n'
    else
      LIST_NOLAB="$LIST_NOLAB$distro $release"$'\n'
    fi
  done < <(rows "$f")
  LIST_ROWS=$n
  if [ "$n" -eq 0 ]; then
    fail list "$LIST_REL has no release row — every comparison below would be against nothing"
    return 1
  fi
  return 0
}

check_gitlab() {
  local f=$ROOT/$GITLAB_REL images prefix soft
  if [ ! -r "$f" ]; then
    fail gitlab "$GITLAB_REL is missing"
    return 0
  fi
  images=$(yaml_list "$f" container_matrix_images)
  if [ -z "$images" ]; then
    fail gitlab "$GITLAB_REL sets no container_matrix_images list — the component default is not this list"
  fi
  compare gitlab "$GITLAB_REL container_matrix_images" "$LIST_IMAGES" "$images"

  prefix=$(yaml_scalar "$f" container_registry_prefix)
  [ "$prefix" = '<empty>' ] \
    || fail gitlab "container_registry_prefix must be '' — the images are fully qualified, and the component default would prefix them a second time (found: ${prefix:-absent})"

  soft=$(yaml_scalar "$f" enable_container_soft_matrix)
  [ "$soft" = false ] \
    || fail gitlab "enable_container_soft_matrix must be false — the component defaults it to true, an allowed-to-fail lane (SC-007; found: ${soft:-absent})"
  return 0
}

check_github() {
  local f=$ROOT/$GITHUB_REL images hit
  if [ ! -r "$f" ]; then
    fail github "$GITHUB_REL is missing"
    return 0
  fi
  images=$(yaml_list "$f" image '^[[:space:]]*matrix:[[:space:]]*$')
  if [ -z "$images" ]; then
    fail github "$GITHUB_REL has no 'image:' list under a 'matrix:' key"
  fi
  compare github "$GITHUB_REL matrix" "$LIST_IMAGES" "$images"

  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    fail github "$GITHUB_REL:${hit%%:*}: continue-on-error is an allowed-to-fail job (SC-007): ${hit#*:}"
  done < <(grep -nE '^[[:space:]]*continue-on-error:' "$f" \
    | grep -vE ':[[:space:]]*continue-on-error:[[:space:]]*false[[:space:]]*(#.*)?$' || true)
  return 0
}

check_matrix() {
  local f=$ROOT/$MATRIX_REL out err images soft
  if [ ! -r "$f" ]; then
    fail matrix "$MATRIX_REL is missing"
    return 0
  fi
  err=$(mktemp "${TMPDIR:-/tmp}/os-support-matrix.XXXXXXXX")
  # IMAGES and SOFT_IMAGES are unset on purpose: what is checked is the DEFAULT,
  # which is what `make test-docker` and every CI leg without an override runs.
  if ! out=$(env -u IMAGES -u SOFT_IMAGES bash "$f" --print-images 2>"$err"); then
    fail matrix "$MATRIX_REL --print-images failed: $(tr '\n' ' ' <"$err")"
    rm -f -- "$err"
    return 0
  fi
  rm -f -- "$err"
  images=$(printf '%s\n' "$out" | sed -n 's/^image //p')
  soft=$(printf '%s\n' "$out" | sed -n 's/^soft //p')
  compare matrix "$MATRIX_REL's default IMAGES" "$LIST_IMAGES" "$images"
  [ -z "$soft" ] \
    || fail matrix "SOFT_IMAGES defaults to: $(printf '%s' "$soft" | tr '\n' ' ')— every supported release is a gate (SC-007)"
  return 0
}

check_lab() {
  local f=$ROOT/$LAB_REL row n=0 guest distro release rel count guests=''
  local -a col=()
  if [ ! -e "$f" ]; then
    SKIPPED="$SKIPPED lab"
    printf '%s: note: %s is not in this checkout (it is internal only) — the lab comparison was skipped\n' \
      "$PROG" "$LAB_REL"
    return 0
  fi
  local -A by_rel=() names=()
  while IFS= read -r row; do
    n=$((n + 1))
    read -r -a col <<<"$row"
    if [ "${#col[@]}" -ne 5 ]; then
      fail lab "row $n is ${#col[@]} column(s), not 'guest address distro release project': $row"
      continue
    fi
    guest=${col[0]} distro=${col[2]} release=${col[3]}
    [ -z "${names[$guest]:-}" ] || fail lab "guest $guest is listed twice"
    names[$guest]=1
    by_rel["$distro $release"]="${by_rel["$distro $release"]:-}${by_rel["$distro $release"]:+ }$guest"
    guests="$guests$distro $release"$'\n'
  done < <(rows "$f")
  [ "$n" -gt 0 ] || fail lab "$LAB_REL has no guest — every lab=yes release would be unproven"

  # Every lab=yes release has exactly one guest. Two would be proven twice by
  # the loop and recorded twice in the evidence, one of them for nothing.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    count=$(printf '%s\n' "${by_rel[$rel]:-}" | wc -w)
    case $count in
      1) ;;
      0) fail lab "$rel is lab=yes in $LIST_REL but has no guest in $LAB_REL" ;;
      *) fail lab "$rel has $count guests in $LAB_REL (${by_rel[$rel]}) — lab=yes means exactly one" ;;
    esac
  done <<<"$LIST_LAB"

  # Every guest is for a lab=yes release.
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if printf '%s' "$LIST_LAB" | grep -qxF -e "$rel"; then continue; fi
    if printf '%s' "$LIST_NOLAB" | grep -qxF -e "$rel"; then
      fail lab "$LAB_REL has a guest for $rel (${by_rel[$rel]}), which $LIST_REL marks lab=no"
    else
      fail lab "$LAB_REL has a guest for $rel (${by_rel[$rel]}), which is not a release in $LIST_REL"
    fi
  done < <(printf '%s' "$guests" | LC_ALL=C sort -u)
  return 0
}

run_checks() {
  FAILED=0 FIRED='' SKIPPED=''
  # Without a readable, non-empty list there is nothing to compare a copy with:
  # every other check would report each of its entries as "not in the list",
  # which buries the one real finding.
  check_list || return 0
  check_gitlab
  check_github
  check_matrix
  check_lab
  return 0
}

verdict() {
  local agree='gitlab, github, matrix.sh, lab agree'
  case " $SKIPPED " in
    *" lab "*) agree='gitlab, github, matrix.sh agree; lab skipped' ;;
  esac
  printf '%s: clean (%d release(s); %s)\n' "$PROG" "$LIST_ROWS" "$agree"
}

# ---------------------------------------------------------------------------
# Self-test — a compliant tree must pass, and every check must fire on its own
# planted drift. A drift gate that has stopped noticing drift is a copy of the
# list that nobody checks, which is where this started.
# ---------------------------------------------------------------------------

st_fixture() {
  local d=$1
  mkdir -p "$d/config" "$d/.github/workflows" "$d/tests/docker" "$d/tests/lab"
  cat >"$d/$LIST_REL" <<'EOF'
# family distro        release image                               lab
debian    debian        12      docker.io/library/debian:12         yes
debian    ubuntu        22.04   docker.io/library/ubuntu:22.04      no
redhat    almalinux     9       docker.io/library/almalinux:9       yes
arch      arch          rolling docker.io/library/archlinux:latest  yes
EOF
  cat >"$d/$GITLAB_REL" <<'EOF'
---
include:
  - component: $CI_SHELL@1.3.0
    inputs:
      container_matrix_images:
        - docker.io/library/debian:12
        - docker.io/library/ubuntu:22.04
        # a comment between items is allowed
        - 'docker.io/library/almalinux:9'
        - docker.io/library/archlinux:latest
      container_registry_prefix: ''
      enable_container_soft_matrix: false
EOF
  cat >"$d/$GITHUB_REL" <<'EOF'
name: ci
jobs:
  container:
    name: ${{ matrix.image }}
    strategy:
      fail-fast: false
      matrix:
        image:
          - docker.io/library/debian:12
          - docker.io/library/ubuntu:22.04
          - docker.io/library/almalinux:9
          - docker.io/library/archlinux:latest
    steps:
      - run: echo "${{ matrix.image }}"
EOF
  cp -- "$ROOT/$MATRIX_REL" "$d/$MATRIX_REL"
  cat >"$d/$LAB_REL" <<'EOF'
# guest  address  distro  release  project
lab-debian12  192.0.2.11  debian     12       1
lab-alma9     192.0.2.12  almalinux  9        2
lab-arch      192.0.2.13  arch       rolling  3
EOF
}

# Planted drifts: NAME|CHECK|what the finding must say. Each is applied to a
# fresh copy of the compliant fixture by st_plant, alone.
ST_CASES='gitlab-missing|gitlab|docker.io/library/archlinux:latest is in config/os-support.list but not in .gitlab-ci.yml
gitlab-extra|gitlab|docker.io/library/fedora:44 is in .gitlab-ci.yml container_matrix_images but not in
gitlab-short-name|gitlab|debian:12 is in .gitlab-ci.yml container_matrix_images but not in
gitlab-duplicate|gitlab|docker.io/library/debian:12 appears more than once in .gitlab-ci.yml
gitlab-prefix|gitlab|container_registry_prefix must be
gitlab-soft-lane|gitlab|enable_container_soft_matrix must be false
github-missing|github|docker.io/library/almalinux:9 is in config/os-support.list but not in .github/workflows/ci.yml
github-continue-on-error|github|continue-on-error is an allowed-to-fail job
matrix-hardcoded|matrix|docker.io/library/almalinux:9 is in config/os-support.list but not in tests/docker/matrix.sh
matrix-soft|matrix|SOFT_IMAGES defaults to
list-columns|list|is 4 column(s)
list-short-image|list|is not fully qualified
list-family|list|unknown family
list-twice|list|is listed twice
lab-missing|lab|almalinux 9 is lab=yes in config/os-support.list but has no guest
lab-two-guests|lab|debian 12 has 2 guests
lab-nolab-guest|lab|ubuntu 22.04 (lab-jammy), which config/os-support.list marks lab=no
lab-unknown-guest|lab|fedora 44 (lab-f44), which is not a release in'

# st_plant NAME DIR — apply one drift to the fixture in DIR. sed -i is fine
# here: these are throwaway files, not a symlinked ~/.bashrc.
# shellcheck disable=SC2016  # sed programs: a literal $ and backticks, by design
st_plant() {
  local d=$2
  case $1 in
    gitlab-missing) sed -i '/archlinux/d' "$d/$GITLAB_REL" ;;
    gitlab-extra) sed -i 's|^\(        \)- docker.io/library/debian:12$|&\n\1- docker.io/library/fedora:44|' "$d/$GITLAB_REL" ;;
    gitlab-short-name) sed -i 's|- docker.io/library/debian:12|- debian:12|' "$d/$GITLAB_REL" ;;
    gitlab-duplicate) sed -i 's|^\(        \)- docker.io/library/debian:12$|&\n&|' "$d/$GITLAB_REL" ;;
    gitlab-prefix) sed -i '/container_registry_prefix/d' "$d/$GITLAB_REL" ;;
    gitlab-soft-lane) sed -i 's/enable_container_soft_matrix: false/enable_container_soft_matrix: true/' "$d/$GITLAB_REL" ;;
    github-missing) sed -i '/almalinux/d' "$d/$GITHUB_REL" ;;
    github-continue-on-error) sed -i 's/^    strategy:$/    continue-on-error: ${{ matrix.soft || false }}\n&/' "$d/$GITHUB_REL" ;;
    matrix-hardcoded) sed -i 's/^set -euo pipefail$/&\nIMAGES=${IMAGES-"docker.io\/library\/debian:12"}/' "$d/$MATRIX_REL" ;;
    matrix-soft) sed -i 's/^SOFT_IMAGES=.*/SOFT_IMAGES=${SOFT_IMAGES-"docker.io\/library\/ubuntu:26.04"}/' "$d/$MATRIX_REL" ;;
    list-columns) sed -i 's/^\(arch .*\) yes$/\1/' "$d/$LIST_REL" ;;
    list-short-image) sed -i 's|docker.io/library/ubuntu:22.04|ubuntu:22.04|' "$d/$LIST_REL" ;;
    list-family) sed -i 's/^redhat /gentoo /' "$d/$LIST_REL" ;;
    list-twice) printf 'debian debian 12 docker.io/library/debian:bookworm no\n' >>"$d/$LIST_REL" ;;
    lab-missing) sed -i '/lab-alma9/d' "$d/$LAB_REL" ;;
    lab-two-guests) printf 'lab-debian12b 192.0.2.14 debian 12 4\n' >>"$d/$LAB_REL" ;;
    lab-nolab-guest) printf 'lab-jammy 192.0.2.15 ubuntu 22.04 5\n' >>"$d/$LAB_REL" ;;
    lab-unknown-guest) printf 'lab-f44 192.0.2.16 fedora 44 6\n' >>"$d/$LAB_REL" ;;
    *)
      printf 'st_plant: no such case: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

self_test() {
  local base dir findings rc=0 name check want
  base=$(mktemp -d "${TMPDIR:-/tmp}/os-support-selftest.XXXXXXXX")
  findings=$(mktemp "${TMPDIR:-/tmp}/os-support-findings.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: fresh mktemp paths
  trap "rm -rf -- '$base' '$findings'" EXIT
  local real=$ROOT

  # Phase 1: the compliant fixture, including a block list with a comment and a
  # quoted item, must be clean and must have compared every copy.
  ROOT=$real
  st_fixture "$base/good"
  ROOT=$base/good
  run_checks 2>"$findings"
  if [ "$FAILED" -eq 0 ] && [ -z "$SKIPPED" ] && [ "$LIST_ROWS" -eq 4 ]; then
    printf '  ok    a compliant tree is clean (4 releases, every copy compared)\n'
  else
    printf '  FAIL  the compliant tree: %d finding(s), skipped:%s, %s row(s)\n' \
      "$FAILED" "${SKIPPED:- none}" "$LIST_ROWS"
    sed 's/^/        /' "$findings"
    rc=1
  fi

  # Phase 2: each planted drift, alone, on a fresh copy.
  while IFS='|' read -r name check want; do
    [ -n "$name" ] || continue
    dir=$base/$name
    cp -a -- "$base/good" "$dir"
    st_plant "$name" "$dir" || {
      rc=1
      continue
    }
    ROOT=$dir
    run_checks 2>"$findings"
    if grep -F -e "OS-SUPPORT [$check]" "$findings" | grep -qF -e "$want"; then
      printf '  ok    %-26s %s fires\n' "$name" "$check"
    else
      printf '  FAIL  %-26s %s did not report "%s"\n' "$name" "$check" "$want"
      sed 's/^/        /' "$findings"
      rc=1
    fi
  done <<<"$ST_CASES"

  # Phase 3: no lab inventory (the public variant) is a stated skip, not a
  # failure — and not a silent pass either: the verdict must say it.
  dir=$base/no-lab
  cp -a -- "$base/good" "$dir"
  rm -f -- "$dir/$LAB_REL"
  ROOT=$dir
  run_checks 2>"$findings" >/dev/null
  if [ "$FAILED" -eq 0 ] && verdict | grep -q 'lab skipped'; then
    printf '  ok    no lab inventory is a skip the verdict names\n'
  else
    printf '  FAIL  no lab inventory: %d finding(s), verdict: %s\n' "$FAILED" "$(verdict)"
    rc=1
  fi

  ROOT=$real
  [ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
  return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  case ${1:-} in
    '') ;;
    --self-test)
      self_test
      return
      ;;
    *)
      printf 'usage: %s [--self-test]\n' "$PROG" >&2
      return 64
      ;;
  esac

  run_checks
  if [ "$FAILED" -gt 0 ]; then
    printf '\n%s: %d disagreement(s) with %s in:%s\n' "$PROG" "$FAILED" "$LIST_REL" "$FIRED" >&2
    printf 'The list is the source of truth — fix the copy, or change the list and every copy together.\n' >&2
    return 1
  fi
  verdict
  return 0
}

main "$@"
