#!/usr/bin/env bash
#
# tests/unit/test_family.sh — lib/family/*.sh: four files, ONE key set.
#
# The family files are the bash form of the host automation's vars/<family>.yml
# (plan D3), and are held to the same rule its test holds those to: every family
# defines exactly the same keys, and no value is empty. A key added to one family
# and forgotten in another is not a subtle bug — a module would read an empty
# admin group or trust store on that family only, which is exactly the
# release-specific failure nobody sees until they are on that machine.
#
# Also proved here: the files are DATA (assignments and comments, nothing that
# runs), the key set is the one lib/os.sh resets and exports, and the Debian
# family's values are the literals the code used before families existed (FR-008).

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

fam_dir="$DEVENV_HOME/lib/family"

# keys_of FILE — the FAM_* names FILE defines, sorted, one per line. Sourced in a
# clean subshell, so nothing the test process already holds can leak into the set.
keys_of() {
  (
    for v in $(compgen -v FAM_ || true); do unset "$v"; done
    # shellcheck source=lib/family/debian.sh
    . "$1"
    compgen -v FAM_ | LC_ALL=C sort
  )
}

# value_of FILE KEY — KEY's value as FILE sets it.
value_of() {
  (
    # shellcheck source=lib/family/debian.sh
    . "$1"
    printf '%s' "${!2-}"
  )
}

t_section 'there is one file per family, and nothing else'

found=''
for f in "$fam_dir"/*.sh; do
  [ -f "$f" ] || continue
  found="$found $(basename -- "$f" .sh)"
done
assert_eq ' arch debian redhat suse' "$found" 'lib/family holds arch, debian, redhat, suse'

listed=$(os_support_rows | awk '{print $1}' | LC_ALL=C sort -u | tr '\n' ' ')
assert_eq 'arch debian redhat suse ' "$listed" 'config/os-support.list names exactly those four families'

t_section 'the key set is identical in every family, and it is the one lib/os.sh knows'

want=$(printf '%s\n' "${_OS_FAM_KEYS[@]}" | LC_ALL=C sort)
assert_ne '' "$want" 'lib/os.sh declares a key set'
for fam in debian redhat suse arch; do
  f="$fam_dir/$fam.sh"
  got=$(keys_of "$f")
  assert_eq "$want" "$got" "$fam: defines exactly lib/os.sh's FAM_* keys"
done

t_section 'no value is empty'

for fam in debian redhat suse arch; do
  f="$fam_dir/$fam.sh"
  for k in "${_OS_FAM_KEYS[@]}"; do
    v=$(value_of "$f" "$k")
    if [ -n "$v" ]; then
      t_ok "$fam: $k = $v"
    else
      t_not_ok "$fam: $k is empty"
    fi
  done
done

t_section 'the files are data: comments and FAM_ assignments, nothing that runs'

for fam in debian redhat suse arch; do
  f="$fam_dir/$fam.sh"
  code=$(grep -vnE '^[[:space:]]*(#.*)?$|^FAM_[A-Z_]+=' "$f" || true)
  assert_eq '' "$code" "$fam: no line that is not a comment or an assignment"
  # shellcheck disable=SC2016  # a literal $( is what is being looked for
  assert_eq '' "$(grep -n '\$(' "$f" || true)" "$fam: no command substitution"
done

t_section 'the values have the shape the code relies on'

for fam in debian redhat suse arch; do
  f="$fam_dir/$fam.sh"
  for k in FAM_CA_ANCHOR_DIR FAM_CA_BUNDLE; do
    v=$(value_of "$f" "$k")
    case $v in
      /*) t_ok "$fam: $k is an absolute path" ;;
      *) t_not_ok "$fam: $k is not an absolute path: [$v]" ;;
    esac
  done
  case $(value_of "$f" FAM_MAC) in
    none | selinux) t_ok "$fam: FAM_MAC is none or selinux" ;;
    *) t_not_ok "$fam: FAM_MAC is [$(value_of "$f" FAM_MAC)], expected none or selinux" ;;
  esac
  fp=$(value_of "$f" FAM_PKG_FINGERPRINT)
  assert_eq "$(value_of "$f" FAM_PKG_QUERY)" "${fp%% *}" \
    "$fam: the fingerprint runs the family's own query tool"
done

t_section 'the Debian family is the code as it was (FR-008)'

f="$fam_dir/debian.sh"
assert_eq 'sudo' "$(value_of "$f" FAM_ADMIN_GROUP)" 'debian: the admin group is still sudo'
assert_eq '/usr/local/share/ca-certificates' "$(value_of "$f" FAM_CA_ANCHOR_DIR)" 'debian: anchors'
assert_eq 'update-ca-certificates' "$(value_of "$f" FAM_CA_REFRESH)" 'debian: refresh'
assert_eq '/etc/ssl/certs/ca-certificates.crt' "$(value_of "$f" FAM_CA_BUNDLE)" 'debian: bundle'
assert_eq 'wheel' "$(value_of "$fam_dir/redhat.sh" FAM_ADMIN_GROUP)" 'redhat: the admin group is wheel'

t_section 'os_detect loads the family it detected, and only that one'

# SC2031 below: keys_of/value_of unset FAM_* in THEIR subshells only; os_detect
# sets them here, in this shell, which is the point of the section.
real="$DEVENV_HOME/tests/unit/fixtures/os-release"
OS_RELEASE_FILE="$real/opensuse-leap-16.0" os_detect
# shellcheck disable=SC2031
assert_eq '/etc/ssl/ca-bundle.pem' "$FAM_CA_BUNDLE" 'leap: the SUSE bundle'
OS_RELEASE_FILE="$real/debian-13" os_detect
# shellcheck disable=SC2031
assert_eq '/etc/ssl/certs/ca-certificates.crt' "$FAM_CA_BUNDLE" 'debian 13 after leap: nothing of SUSE is left'
# shellcheck disable=SC2031
assert_eq 'dpkg-query' "$FAM_PKG_QUERY" 'debian 13: dpkg-query'

t_section 'module_gate: family= says "not applicable", and says it before any other gate'

# log_skip is silent under the harness's DEVENV_QUIET=1, so the message checks turn it off.
mods="$T_SANDBOX/modules"
mkdir -p "$mods"
printf '%s\n' '#!/usr/bin/env bash' '# meta: name=debonly' '# meta: desc=x' \
  '# meta: family=debian' '# meta: os=any' >"$mods/91-debonly.sh"
printf '%s\n' '#!/usr/bin/env bash' '# meta: name=rpmish' '# meta: desc=x' \
  '# meta: family=redhat, suse   # a trailing comment' >"$mods/50-rpmish.sh"
printf '%s\n' '#!/usr/bin/env bash' '# meta: name=anywhere' '# meta: desc=x' \
  '# meta: os=any' >"$mods/10-anywhere.sh"
# family= must win over a gate that would also refuse: a module that means nothing
# on this family is "not applicable", not "needs root" or "needs a command".
printf '%s\n' '#!/usr/bin/env bash' '# meta: name=strict' '# meta: desc=x' \
  '# meta: family=arch' '# meta: needs=devenv-no-such-command' '# meta: root=yes' \
  >"$mods/60-strict.sh"

OS_RELEASE_FILE="$real/fedora-44" os_detect
assert_status 78 'fedora: a family=debian module is skipped (78)' module_gate "$mods/91-debonly.sh"
out=$(DEVENV_QUIET=0 module_gate "$mods/91-debonly.sh" 2>&1 || true)
assert_contains "$out" 'debonly: not applicable on the redhat family' 'fedora: the skip names the family'
assert_status 0 'fedora: family=redhat,suse runs (spaces and a trailing comment tolerated)' \
  module_gate "$mods/50-rpmish.sh"
assert_status 0 'fedora: no family= means every family' module_gate "$mods/10-anywhere.sh"
out=$(DEVENV_QUIET=0 module_gate "$mods/60-strict.sh" 2>&1 || true)
assert_contains "$out" 'strict: not applicable on the redhat family' 'family= is decided before needs= and root='

OS_RELEASE_FILE="$real/debian-12" os_detect
assert_status 0 'debian: the family=debian module runs' module_gate "$mods/91-debonly.sh"
assert_status 78 'debian: the family=redhat,suse module is skipped' module_gate "$mods/50-rpmish.sh"

OS_RELEASE_FILE="$real/void" os_detect
out=$(DEVENV_QUIET=0 module_gate "$mods/91-debonly.sh" 2>&1 || true)
assert_contains "$out" 'not applicable on the unknown family' 'an unknown family is never a member of family='

for m in purge-desktop:91-purge-desktop migrate:92-migrate; do
  assert_eq 'debian' "$(module_meta "$DEVENV_HOME/modules/${m#*:}.sh" family)" \
    "modules/${m#*:}.sh is family=debian"
done
row=$(print_plan | awk -F'\t' '$1 == "purge-desktop"')
assert_eq 'debian' "$(printf '%s' "$row" | cut -f9)" 'devenv list: family is column 9'
assert_eq 'yes' "$(printf '%s' "$row" | cut -f7)" 'devenv list: root is still column 7'
assert_eq 'all' "$(print_plan | awk -F'\t' '$1 == "preflight" {print $9}')" \
  'devenv list: a module with no family= lists all'

t_section 'the Debian fingerprint runs here (when this machine has dpkg)'

if have dpkg-query; then
  fp=$(value_of "$fam_dir/debian.sh" FAM_PKG_FINGERPRINT)
  # `|| true`: head closing the pipe early is SIGPIPE to the query, and pipefail.
  first=$(eval "$fp" 2>/dev/null | head -n1) || true
  case $first in
    *' '*) t_ok "the fingerprint prints 'name version' lines: $first" ;;
    *) t_not_ok "the fingerprint printed [$first], expected 'name version'" ;;
  esac
else
  t_skip 'no dpkg-query on this machine'
fi

t_summary
