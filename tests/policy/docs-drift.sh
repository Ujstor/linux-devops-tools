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
#     profiles · family · os · arch · needs · root   match the header
#
# Columns are found by their HEADER NAME, not by position: a column added,
# dropped or moved is then either still checked or reported as missing, never
# silently compared against its neighbour's values.
#
# Source of truth is always the module file. When this fails, fix the table.
#
# Usage:
#     bash tests/policy/docs-drift.sh
#     bash tests/policy/docs-drift.sh --self-test   # prove a drift is still caught
#     make lint-docs

set -euo pipefail

PROG=${0##*/}
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)

FAIL=0

bad() {
  printf 'DOCS-DRIFT  %s\n' "$*" >&2
  FAIL=$((FAIL + 1))
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

# family_canon VALUE — no family= (every family) has three spellings: an absent
# key, `—` in the table, and `all`. They are one value here.
family_canon() {
  local v
  v=$(sort_list "$(canon "$1")")
  case $v in '' | - | all) v=all ;; esac
  printf '%s' "$v"
}

meta_get() {
  # meta_get FILE KEY — the value of `# meta: KEY=...`, empty when absent.
  sed -n "s/^# meta: $2=//p" "$1" | head -1 | tr -d '\r'
}

# The columns the module table must have, by header name.
COLUMNS='module profiles family os arch needs root'

# check_docs — compare $ROOT/docs/modules.md with $ROOT/modules/*.sh. Reports
# through bad(); prints the verdict line only when nothing was reported.
check_docs() {
  local doc=$ROOT/docs/modules.md moddir=$ROOT/modules
  local f name mod rows=0 line first i want table=''
  local d_prof d_fam d_os d_arch d_needs d_root
  local -a cells=()
  local -A M_PROFILES=() M_FAMILY=() M_OS=() M_ARCH=() M_NEEDS=() M_ROOT=() M_SEEN=()
  local -A DOCUMENTED=() COL=()
  FAIL=0

  [ -r "$doc" ] || {
    printf 'not readable: %s\n' "$doc" >&2
    FAIL=1
    return 1
  }

  # --- collect the module headers -----------------------------------------
  for f in "$moddir"/[0-9][0-9]-*.sh; do
    [ -e "$f" ] || continue
    name=$(meta_get "$f" name)
    if [ -z "$name" ]; then
      bad "${f#"$ROOT"/}: no '# meta: name='"
      continue
    fi
    M_SEEN[$name]=${f#"$ROOT"/}
    M_PROFILES[$name]=$(sort_list "$(canon "$(meta_get "$f" profiles)")")
    M_FAMILY[$name]=$(family_canon "$(meta_get "$f" family)")
    M_OS[$name]=$(canon "$(meta_get "$f" os)")
    M_ARCH[$name]=$(sort_list "$(canon "$(meta_get "$f" arch)")")
    M_NEEDS[$name]=$(sort_list "$(canon "$(meta_get "$f" needs)")")
    M_ROOT[$name]=$(canon "$(meta_get "$f" root)")
    [ -n "${M_OS[$name]}" ] || M_OS[$name]=any
    [ -n "${M_ROOT[$name]}" ] || M_ROOT[$name]=no
    if [ "${M_ARCH[$name]}" = "any" ]; then M_ARCH[$name]=''; fi
  done

  [ ${#M_SEEN[@]} -gt 0 ] || {
    printf 'no modules found under %s\n' "$moddir" >&2
    FAIL=1
    return 1
  }

  # --- walk the table ------------------------------------------------------
  while IFS= read -r line; do
    case $line in
      '|'*'|') ;;
      *) continue ;;
    esac
    case $line in
      *'---'*) continue ;;
    esac

    # cells[0] is the empty string before the leading `|`.
    IFS='|' read -r -a cells <<<"$line"
    first=$(canon "${cells[1]:-}")

    # docs/modules.md carries several tables (gate semantics, the plan-only
    # modules). Only the module table's header starts with `#`, and only its
    # rows have a two-digit run-order first column — everything else is prose.
    if [ "$first" = '#' ]; then
      COL=()
      for i in "${!cells[@]}"; do
        [ "$i" -gt 0 ] || continue
        want=$(canon "${cells[$i]}")
        [ -z "$want" ] || COL[$want]=$i
      done
      table=ok
      for want in $COLUMNS; do
        if [ -z "${COL[$want]:-}" ]; then
          bad "docs/modules.md: the module table has no '$want' column"
          table=broken
        fi
      done
      continue
    fi
    case $first in
      [0-9][0-9]) ;;
      *) continue ;;
    esac
    case $table in
      ok) ;;
      broken) continue ;;
      *)
        bad "docs/modules.md: a module row before the table header: $line"
        continue
        ;;
    esac

    mod=$(canon "${cells[${COL[module]}]:-}")
    case $mod in '' | module) continue ;; esac

    rows=$((rows + 1))

    if [ -z "${M_SEEN[$mod]:-}" ]; then
      bad "docs/modules.md names a module that does not exist: '$mod'"
      continue
    fi
    DOCUMENTED[$mod]=1

    d_prof=$(sort_list "$(expand_profiles "${cells[${COL[profiles]}]:-}")")
    d_fam=$(family_canon "${cells[${COL[family]}]:-}")
    d_os=$(canon "${cells[${COL[os]}]:-}")
    d_arch=$(sort_list "$(canon "${cells[${COL[arch]}]:-}")")
    d_needs=$(sort_list "$(canon "${cells[${COL[needs]}]:-}")")
    d_root=$(canon "${cells[${COL[root]}]:-}")

    if [ "$d_arch" = "any" ]; then d_arch=''; fi
    if [ "$d_needs" = "-" ]; then d_needs=''; fi

    [ "$d_prof" = "${M_PROFILES[$mod]}" ] \
      || bad "$mod: profiles table='$d_prof' header='${M_PROFILES[$mod]}' (${M_SEEN[$mod]})"
    [ "$d_fam" = "${M_FAMILY[$mod]}" ] \
      || bad "$mod: family table='$d_fam' header='${M_FAMILY[$mod]}' (${M_SEEN[$mod]})"
    [ "$d_os" = "${M_OS[$mod]}" ] \
      || bad "$mod: os table='$d_os' header='${M_OS[$mod]}' (${M_SEEN[$mod]})"
    [ "$d_arch" = "${M_ARCH[$mod]}" ] \
      || bad "$mod: arch table='$d_arch' header='${M_ARCH[$mod]}' (${M_SEEN[$mod]})"
    [ "$d_needs" = "${M_NEEDS[$mod]}" ] \
      || bad "$mod: needs table='$d_needs' header='${M_NEEDS[$mod]}' (${M_SEEN[$mod]})"
    [ "$d_root" = "${M_ROOT[$mod]}" ] \
      || bad "$mod: root table='$d_root' header='${M_ROOT[$mod]}' (${M_SEEN[$mod]})"
  done <"$doc"

  [ -n "$table" ] || bad "docs/modules.md: no module table (a header row starting '| # |')"

  # A broken table already said so once; listing every module as undocumented
  # on top would bury that one line.
  if [ "$table" = ok ]; then
    for mod in "${!M_SEEN[@]}"; do
      [ -n "${DOCUMENTED[$mod]:-}" ] \
        || bad "module '$mod' (${M_SEEN[$mod]}) has no row in docs/modules.md"
    done
  fi

  if [ "$FAIL" -gt 0 ]; then
    printf '\n%s: %d mismatch(es) between docs/modules.md and modules/*.sh\n' "$PROG" "$FAIL" >&2
    printf 'The module file is the source of truth — update the table to match it.\n' >&2
    return 1
  fi

  printf '%s: clean (%d module(s), %d table row(s))\n' "$PROG" "${#M_SEEN[@]}" "$rows"
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — a compliant tree is clean, and each planted drift is reported by
# what it is. The family column is new, and a column nobody has ever seen fail
# is a column nobody knows is checked.
# ---------------------------------------------------------------------------

st_fixture() {
  local d=$1
  mkdir -p "$d/modules" "$d/docs"
  cat >"$d/modules/10-shell.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=shell
# meta: profiles=minimal,devops
# meta: root=no
EOF
  cat >"$d/modules/91-purge.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=purge
# meta: family=debian
# meta: os=any
# meta: root=yes
EOF
  cat >"$d/docs/modules.md" <<'EOF'
# Modules

| # | module | profiles | family | os | arch | needs | root | what it does |
|---|---|---|---|---|---|---|---|---|
| 10 | `shell` | min, dev | — | any | any | — | no | the shell |
| 91 | `purge` | **none** | debian | any | any | — | **yes** | report the residue |

| module | default |
|---|---|
| `git` | prints the diff |
EOF
}

# NAME|what the finding must say
ST_CASES='family-absent-in-table|purge: family table='\''all'\'' header='\''debian'\''
family-wrong-in-table|shell: family table='\''redhat'\'' header='\''all'\''
family-header-changed|purge: family table='\''debian'\'' header='\''debian,suse'\''
no-family-column|the module table has no '\''family'\'' column
os-drift|purge: os table='\''wsl'\'' header='\''any'\''
module-without-row|module '\''shell'\'' (modules/10-shell.sh) has no row
row-without-module|names a module that does not exist: '\''ghost'\'''

# st_plant NAME DIR — apply one drift to the fixture in DIR (throwaway files).
# shellcheck disable=SC2016  # sed programs: markdown backticks, by design
st_plant() {
  local d=$2
  case $1 in
    family-absent-in-table) sed -i 's/^| 91 | `purge` | \*\*none\*\* | debian |/| 91 | `purge` | **none** | — |/' "$d/docs/modules.md" ;;
    family-wrong-in-table) sed -i 's/^| 10 | `shell` | min, dev | — |/| 10 | `shell` | min, dev | redhat |/' "$d/docs/modules.md" ;;
    family-header-changed) sed -i 's/^# meta: family=debian$/# meta: family=suse,debian/' "$d/modules/91-purge.sh" ;;
    no-family-column) sed -i -e 's/ family |//' -e 's/^|---|---|---|---|/|---|---|---|/' \
      -e 's/ — | any | any | — | no |/ any | any | — | no |/' \
      -e 's/ debian | any | any | — |/ any | any | — |/' "$d/docs/modules.md" ;;
    os-drift) sed -i 's/^| 91 | `purge` | \*\*none\*\* | debian | any |/| 91 | `purge` | **none** | debian | wsl |/' "$d/docs/modules.md" ;;
    module-without-row) sed -i '/^| 10 | `shell`/d' "$d/docs/modules.md" ;;
    row-without-module) sed -i 's/^| 91 | `purge` |.*$/&\n| 92 | `ghost` | **none** | — | any | any | — | no | not a module |/' "$d/docs/modules.md" ;;
    *)
      printf 'st_plant: no such case: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

self_test() {
  local base dir findings rc=0 name want real=$ROOT
  base=$(mktemp -d "${TMPDIR:-/tmp}/docs-drift-selftest.XXXXXXXX")
  findings=$(mktemp "${TMPDIR:-/tmp}/docs-drift-findings.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: fresh mktemp paths
  trap "rm -rf -- '$base' '$findings'" EXIT

  st_fixture "$base/good"
  ROOT=$base/good
  if check_docs >"$findings" 2>&1 && grep -qx "$PROG: clean (2 module(s), 2 table row(s))" "$findings"; then
    printf '  ok    a compliant table is clean (2 modules, 2 rows, a second table ignored)\n'
  else
    printf '  FAIL  the compliant table was not clean:\n'
    sed 's/^/        /' "$findings"
    rc=1
  fi

  while IFS='|' read -r name want; do
    [ -n "$name" ] || continue
    dir=$base/$name
    cp -a -- "$base/good" "$dir"
    st_plant "$name" "$dir" || {
      rc=1
      continue
    }
    ROOT=$dir
    if ! check_docs >"$findings" 2>&1 && grep -qF -e "$want" "$findings"; then
      printf '  ok    %-24s caught\n' "$name"
    else
      printf '  FAIL  %-24s not reported as "%s"\n' "$name" "$want"
      sed 's/^/        /' "$findings"
      rc=1
    fi
  done <<<"$ST_CASES"

  ROOT=$real
  [ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
  return "$rc"
}

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
  check_docs
}

main "$@"
