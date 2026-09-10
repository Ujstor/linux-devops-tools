#!/usr/bin/env bash
#
# tests/policy/docs-drift.sh — keep docs/modules.md honest.
#
# docs/modules.md is written BY HAND and that is deliberate: its "what it does"
# column carries prose that no `# meta: desc=` one-liner could replace, so a
# generator would downgrade the page rather than maintain it.
#
# The cost of hand-writing is rot: someone edits a module's gates and the table
# still claims the old ones. This closes exactly that gap. It does not check the
# prose — it checks the FACTS the table repeats from the meta headers:
#
#     every module has a row · no row names a module that does not exist
#     profiles · os · arch · needs · root   match the header
#
# Source of truth is always the module file. When this fails, fix the table.
#
# Usage:
#     bash tests/policy/docs-drift.sh
#     make lint-docs

set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
DOC=$ROOT/docs/modules.md
MODDIR=$ROOT/modules

FAIL=0

bad() {
  printf 'DOCS-DRIFT  %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
}

[ -r "$DOC" ] || {
  printf 'not readable: %s\n' "$DOC" >&2
  exit 1
}

# --- normalisation ---------------------------------------------------------
#
# The table is markdown: values arrive wrapped in ` `, ** ** or both, lists are
# ", "-separated, and an empty value is an em dash. Profile names are abbreviated
# in the table for width. Both sides are reduced to the same canonical form: a
# comma-separated, sorted, lowercase list with no decoration.

canon() {
  printf '%s' "$1" \
    | tr -d '`*' \
    | sed -e 's/—/-/g' -e 's/[[:space:]]//g' \
    | tr '[:upper:]' '[:lower:]'
}

# Expand the table's abbreviations back to real profile names.
expand_profiles() {
  local v=$1 out='' p
  v=$(canon "$v")
  [ "$v" = "none" ] && {
    printf ''
    return
  }
  [ "$v" = "-" ] && {
    printf ''
    return
  }
  local IFS=,
  for p in $v; do
    case $p in
      min) p=minimal ;;
      dev) p=devops ;;
    esac
    out="$out,$p"
  done
  printf '%s' "${out#,}"
}

sort_list() {
  local v=$1
  [ -z "$v" ] && return 0
  printf '%s' "$v" | tr ',' '\n' | sed '/^$/d' | LC_ALL=C sort | paste -sd, -
}

meta_get() {
  # meta_get FILE KEY — the value of `# meta: KEY=...`, empty when absent.
  sed -n "s/^# meta: $2=//p" "$1" | head -1 | tr -d '\r'
}

# --- collect the module headers -------------------------------------------

declare -A M_PROFILES M_OS M_ARCH M_NEEDS M_ROOT M_SEEN
for f in "$MODDIR"/[0-9][0-9]-*.sh; do
  [ -e "$f" ] || continue
  name=$(meta_get "$f" name)
  if [ -z "$name" ]; then
    bad "${f#"$ROOT"/}: no '# meta: name='"
    continue
  fi
  M_SEEN[$name]=${f#"$ROOT"/}
  M_PROFILES[$name]=$(sort_list "$(canon "$(meta_get "$f" profiles)")")
  M_OS[$name]=$(canon "$(meta_get "$f" os)")
  M_ARCH[$name]=$(sort_list "$(canon "$(meta_get "$f" arch)")")
  M_NEEDS[$name]=$(sort_list "$(canon "$(meta_get "$f" needs)")")
  M_ROOT[$name]=$(canon "$(meta_get "$f" root)")
  [ -n "${M_OS[$name]}" ] || M_OS[$name]=any
  [ -n "${M_ROOT[$name]}" ] || M_ROOT[$name]=no
done

[ ${#M_SEEN[@]} -gt 0 ] || {
  printf 'no modules found under %s\n' "$MODDIR" >&2
  exit 1
}

# --- walk the table --------------------------------------------------------

declare -A DOCUMENTED
rows=0

while IFS= read -r line; do
  case $line in
    '|'*'|') ;;
    *) continue ;;
  esac
  case $line in
    *'---'*) continue ;;
  esac

  # | # | module | profiles | os | arch | needs | root | what it does |
  IFS='|' read -r _ _num c_mod c_prof c_os c_arch c_needs c_root _rest <<<"$line"
  [ -n "${c_mod:-}" ] || continue

  # docs/modules.md carries several tables (gate semantics, the plan-only
  # modules). Only the module table has a two-digit run-order first column, so
  # that is what identifies a row worth checking — everything else is prose.
  case $(canon "${_num:-}") in
    [0-9][0-9]) ;;
    *) continue ;;
  esac

  mod=$(canon "$c_mod")
  case $mod in '' | module) continue ;; esac

  rows=$((rows + 1))

  if [ -z "${M_SEEN[$mod]:-}" ]; then
    bad "docs/modules.md names a module that does not exist: '$mod'"
    continue
  fi
  DOCUMENTED[$mod]=1

  d_prof=$(sort_list "$(expand_profiles "${c_prof:-}")")
  d_os=$(canon "${c_os:-}")
  d_arch=$(sort_list "$(canon "${c_arch:-}")")
  d_needs=$(sort_list "$(canon "${c_needs:-}")")
  d_root=$(canon "${c_root:-}")

  [ "$d_arch" = "any" ] && d_arch=''
  [ "${M_ARCH[$mod]}" = "any" ] && M_ARCH[$mod]=''
  [ "$d_needs" = "-" ] && d_needs=''

  [ "$d_prof" = "${M_PROFILES[$mod]}" ] \
    || bad "$mod: profiles table='$d_prof' header='${M_PROFILES[$mod]}' (${M_SEEN[$mod]})"
  [ "$d_os" = "${M_OS[$mod]}" ] \
    || bad "$mod: os table='$d_os' header='${M_OS[$mod]}' (${M_SEEN[$mod]})"
  [ "$d_arch" = "${M_ARCH[$mod]}" ] \
    || bad "$mod: arch table='$d_arch' header='${M_ARCH[$mod]}' (${M_SEEN[$mod]})"
  [ "$d_needs" = "${M_NEEDS[$mod]}" ] \
    || bad "$mod: needs table='$d_needs' header='${M_NEEDS[$mod]}' (${M_SEEN[$mod]})"
  [ "$d_root" = "${M_ROOT[$mod]}" ] \
    || bad "$mod: root table='$d_root' header='${M_ROOT[$mod]}' (${M_SEEN[$mod]})"
done <"$DOC"

for mod in "${!M_SEEN[@]}"; do
  [ -n "${DOCUMENTED[$mod]:-}" ] \
    || bad "module '$mod' (${M_SEEN[$mod]}) has no row in docs/modules.md"
done

if [ "$FAIL" -gt 0 ]; then
  printf '\ndocs-drift.sh: %d mismatch(es) between docs/modules.md and modules/*.sh\n' "$FAIL" >&2
  printf 'The module file is the source of truth — update the table to match it.\n' >&2
  exit 1
fi

printf 'docs-drift.sh: clean (%d module(s), %d table row(s))\n' "${#M_SEEN[@]}" "$rows"
