#!/usr/bin/env bash
#
# tests/unit/test_registry.sh — lib/registry.sh: meta headers, name resolution and
# the profile lists.
#
# The last section is the integration check that matters most: every name in every
# profiles/*.list must resolve to a module that exists. A profile naming a module
# nobody wrote is not a subtle bug — `devenv --profile X` refuses to run at all —
# and it is exactly the kind of break that only shows up when two people finish
# their work at different times.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

t_section 'module_meta reads the header without running the file'

fake="$T_SANDBOX/modules"
mkdir -p "$fake"
cat >"$fake/36-k8s-plugins.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=k8s-plugins
# meta: desc=krew, kubectl plugins and helm plugins   # a trailing comment
# meta: profiles=devops,full
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=kubectl
# meta: root=no
set -euo pipefail
printf 'THIS MODULE MUST NEVER RUN DURING A UNIT TEST\n' >"$T_SANDBOX/executed"
EOF
cat >"$fake/99-summary.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=summary
# meta: desc=what changed and what to do next
EOF
chmod 0755 "$fake"/*.sh

assert_eq 'k8s-plugins' "$(module_meta "$fake/36-k8s-plugins.sh" name)" 'name='
assert_eq 'krew, kubectl plugins and helm plugins' \
  "$(module_meta "$fake/36-k8s-plugins.sh" desc)" 'desc=, with the trailing comment stripped'
assert_eq 'kubectl' "$(module_meta "$fake/36-k8s-plugins.sh" needs)" 'needs='
assert_eq 'no' "$(module_meta "$fake/36-k8s-plugins.sh" root)" 'root='
assert_fail 'an absent key returns non-zero' module_meta "$fake/36-k8s-plugins.sh" nosuchkey
assert_no_file "$T_SANDBOX/executed" 'reading the header never executes the module'

assert_eq 'summary' "$(module_name "$fake/99-summary.sh")" 'module_name uses meta name='

t_section 'module_resolve: exact name, filename stem, unique suffix'

(
  export DEVENV_MODULE_DIR="$fake"
  assert_eq "$fake/36-k8s-plugins.sh" "$(module_resolve k8s-plugins)" 'by meta name'
  assert_eq "$fake/36-k8s-plugins.sh" "$(module_resolve 36-k8s-plugins)" 'by filename stem'
  assert_eq "$fake/36-k8s-plugins.sh" "$(module_resolve 36-k8s-plugins.sh)" 'by filename'
  assert_fail 'an unknown name is an error, not a silent no-op' module_resolve nosuchmodule
  t_summary >/dev/null
  exit $((T_FAIL > 0))
) || t_not_ok 'module_resolve section had failures (see above)'

t_section 'profile_modules strips comments and blank lines'

profiles="$T_SANDBOX/profiles"
mkdir -p "$profiles"
cat >"$profiles/unit.list" <<'EOF'
# a comment line

k8s-plugins               # 36 — with an inline comment
summary                   # 99
EOF

got=$(DEVENV_PROFILE_DIR="$profiles" profile_modules unit | tr '\n' ' ')
assert_eq 'k8s-plugins summary ' "$got" 'only the names survive'
# shellcheck disable=SC2016  # $1 belongs to the child shell
assert_fail 'an unknown profile is an error' \
  bash -c '. "$DEVENV_HOME/lib/common.sh"; DEVENV_PROFILE_DIR="$1" profile_modules nosuchprofile' \
  _ "$profiles"

t_section 'every profile in this checkout resolves to modules that exist'

shipped=0
for list in "$DEVENV_HOME"/profiles/*.list; do
  [ -f "$list" ] || continue
  shipped=$((shipped + 1))
  p=$(basename -- "$list" .list)
  mods=$(profile_modules "$p" 2>/dev/null | tr '\n' ' ')
  assert_ne '' "$mods" "profile $p lists at least one module"
  for n in $mods; do
    if module_resolve "$n" >/dev/null 2>&1; then
      : # resolved
    else
      t_not_ok "profile $p names '$n', which no module provides (devenv --profile $p would refuse to run)"
    fi
  done
done
if [ "$shipped" -gt 0 ]; then
  t_ok "checked $shipped profile(s)"
else
  t_not_ok 'no profiles/*.list found in the checkout'
fi

t_section 'every module in this checkout has the header devenv list depends on'

count=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  count=$((count + 1))
  module_meta "$f" name >/dev/null 2>&1 \
    || t_not_ok "$(basename -- "$f") has no '# meta: name='"
  module_meta "$f" desc >/dev/null 2>&1 \
    || t_not_ok "$(basename -- "$f") has no '# meta: desc='"
done < <(module_list)
if [ "$count" -gt 0 ]; then
  t_ok "checked $count module header(s)"
else
  t_not_ok 'module_list found no modules at all'
fi

t_summary
