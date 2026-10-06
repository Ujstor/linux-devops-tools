#!/usr/bin/env bash
#
# tests/unit/test_packages_map.sh — config/packages.map, the one place a package
# name differs between families (spec 002 FR-007, plan D5).
#
# What a broken map costs is silent: a misspelt name is "no installation
# candidate" on one family only, a row with a column missing would shift every
# later column by one, and a module that grows a new package with no row is
# looked up under its Debian spelling on three families nobody runs by hand. So:
#
#   * every row has exactly four columns, each `=`, `-` or comma-separated names;
#   * no Debian name has two rows (the second would silently win);
#   * the library reads the shipped map without a single warning;
#   * every package name the default-set modules ask for — 00, 05, 10, 20, 28,
#     45, 50 and 55 — has a row, so "no row" never means "nobody checked".
#
# Whether each name EXISTS on each family is a network question and is answered
# by the container matrix, not here.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

MAP="$DEVENV_HOME/config/packages.map"
NAME_RE='[A-Za-z0-9][A-Za-z0-9.+_-]*'

t_section 'the shape of every row'

assert_file "$MAP" 'config/packages.map exists'

BAD=$(awk -v re="^(=|-|$NAME_RE(,$NAME_RE)*)\$" '
  { sub(/#.*/, "") }
  NF == 0 { next }
  NF != 4 { printf "line %d: %d columns\n", NR, NF; next }
  $1 !~ ("^" "'"$NAME_RE"'" "$") { printf "line %d: debian name %s\n", NR, $1 }
  { for (i = 2; i <= 4; i++) if ($i !~ re) printf "line %d: column %d is %s\n", NR, i, $i }
' "$MAP")
assert_eq '' "$BAD" 'four columns per row; each one =, - or a comma list of names'

DUPS=$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$MAP" | LC_ALL=C sort | uniq -d)
assert_eq '' "$DUPS" 'no Debian name has two rows'

ROWS=$(awk '{ sub(/#.*/, "") } NF { n++ } END { print n + 0 }' "$MAP")
if [ "$ROWS" -ge 50 ]; then t_ok "the map has $ROWS rows"; else t_not_ok "the map has only $ROWS rows"; fi

t_section 'the library reads it cleanly, column by column'

for m in dnf zypper pacman; do
  OUT=$(
    unset DEVENV_PKG_MAP
    OS_PKG_MGR=$m
    _PKG_MAP_KEY=''
    DEVENV_QUIET=0 _pkg_map_load 2>&1
  )
  assert_eq '' "$OUT" "$m: no warning while loading"
done

t_section 'every package the default-set modules ask for has a row'

# module_package_names FILE — the literal package names FILE hands to the pkg_*
# API: the arguments of every pkg_install/…/pkg_conflicts_report call (quoted
# labels and variables dropped, `\` continuations joined), the first argument
# of apt_or_release, and the members of every *_PKGS / BASE_* array.
module_package_names() {
  awk '
    function emit(s,    n, i, w) {
      gsub(/"[^"]*"|'"'"'[^'"'"']*'"'"'/, " ", s)
      gsub(/;/, " ; ", s)
      n = split(s, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (w[i] ~ /^(\|\||&&|;|then|\)|\|)$/) break
        if (w[i] ~ /^[a-z0-9][a-z0-9.+-]*$/) print w[i]
      }
    }
    { sub(/[[:space:]]#.*/, ""); sub(/^[[:space:]]*#.*/, "") }
    cont != "" { $0 = cont " " $0; cont = "" }
    /\\$/ { cont = substr($0, 1, length($0) - 1); next }
    inarr { if ($0 ~ /\)/) { sub(/\).*/, ""); inarr = 0 } emit($0); next }
    /^[A-Z_]*(PKGS|BASE_[A-Z]+)=\(/ { s = $0; sub(/^[^(]*\(/, "", s); if (s ~ /\)/) sub(/\).*/, "", s); else inarr = 1; emit(s); next }
    {
      line = $0
      while (match(line, /pkg_(install|install_optional|install_first|installed|available|conflicts_report)[[:space:]]/)) {
        line = substr(line, RSTART + RLENGTH)
        emit(line)
      }
      if (match($0, /apt_or_release[[:space:]]+[a-z0-9][a-z0-9.+-]*/)) {
        s = substr($0, RSTART, RLENGTH); sub(/apt_or_release[[:space:]]+/, "", s); print s
      }
    }
  ' "$1" | LC_ALL=C sort -u
}

HAVE=$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$MAP" | LC_ALL=C sort -u)
for mod in 00-preflight 05-base-packages 10-shell 20-lang-go 28-repo-dev 45-cloud 50-editors 55-media; do
  f="$DEVENV_HOME/modules/$mod.sh"
  map_wants=$(module_package_names "$f")
  map_gaps=$(LC_ALL=C comm -23 <(printf '%s\n' "$map_wants") <(printf '%s\n' "$HAVE") | tr '\n' ' ')
  count=$(printf '%s\n' "$map_wants" | grep -c . || true)
  if [ "$count" -eq 0 ]; then
    t_not_ok "$mod: found no package name at all — the extractor is broken, not the map"
    continue
  fi
  assert_eq '' "${map_gaps% }" "$mod: all $count package name(s) have a row"
done

t_summary
