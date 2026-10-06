#!/usr/bin/env bash
#
# tests/unit/test_os.sh — lib/os.sh: detection against /etc/os-release files, so
# the family gate, the Debian/Ubuntu split and the derivative mapping are testable
# on any machine. Nothing here reads the real /etc/os-release except the last
# section.
#
# Two kinds of fixture:
#
#   tests/unit/fixtures/os-release/   REAL files, one per release in
#       config/os-support.list (named <distro>-<release>, copied out of the very
#       image the container matrix runs) plus a derivative per family and four
#       unsupported families. Real where an image exists: oraclelinux:9-slim,
#       centos:stream10-minimal, ubi9-minimal (RHEL 9), opensuse/tumbleweed,
#       manjarolinux/base, alpine:3.22, void-glibc. Written from the shipped file
#       where none does: Linux Mint 22 (its docker image carries Ubuntu's file),
#       Pop!_OS 24.04, EndeavourOS, Gentoo and NixOS.
#   $T_SANDBOX/os-release/            synthetic edge cases written below.
#
# SC-004 is the section "the gate, release by release": every supported release
# accepted as tested, a derivative of each family accepted with exactly one
# notice, an unsupported family refused before any change.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

real="$DEVENV_HOME/tests/unit/fixtures/os-release"
fixtures="$T_SANDBOX/os-release"
mkdir -p "$fixtures"

cat >"$fixtures/debian12" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
VERSION_CODENAME=bookworm
ID=debian
EOF

cat >"$fixtures/debian13" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION_CODENAME=trixie
ID=debian
EOF

cat >"$fixtures/ubuntu2204" <<'EOF'
PRETTY_NAME="Ubuntu 22.04.5 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION_CODENAME=jammy
ID=ubuntu
ID_LIKE=debian
UBUNTU_CODENAME=jammy
EOF

cat >"$fixtures/ubuntu2404" <<'EOF'
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian
UBUNTU_CODENAME=noble
EOF

# A derivative: its own codename, an upstream one that vendors actually publish.
cat >"$fixtures/mint" <<'EOF'
NAME="Linux Mint"
VERSION="22 (Wilma)"
ID=linuxmint
ID_LIKE="ubuntu debian"
VERSION_ID="22"
VERSION_CODENAME=wilma
UBUNTU_CODENAME=noble
EOF

# Debian testing/sid: no upstream codename a vendor repository can serve.
cat >"$fixtures/sid" <<'EOF'
PRETTY_NAME="Debian GNU/Linux trixie/sid"
NAME="Debian GNU/Linux"
ID=debian
VERSION_CODENAME=sid
EOF

cat >"$fixtures/fedora" <<'EOF'
NAME="Fedora Linux"
VERSION_ID=41
ID=fedora
EOF

detect() { OS_RELEASE_FILE="$fixtures/$1" os_detect; }

t_section 'Debian'

detect debian12
assert_eq 'debian' "$OS_ID" 'debian 12: ID'
assert_eq 'debian' "$OS_FLAVOR" 'debian 12: flavour'
assert_eq 'bookworm' "$OS_CODENAME" 'debian 12: codename'
assert_eq 'bookworm' "$OS_UPSTREAM_CODENAME" 'debian 12: upstream codename'
assert_eq '12' "$OS_VERSION_MAJOR" 'debian 12: major version'
assert_ok 'debian 12: os_is_debian' os_is_debian
assert_fail 'debian 12: not os_is_ubuntu' os_is_ubuntu

detect debian13
assert_eq 'trixie' "$OS_UPSTREAM_CODENAME" 'debian 13: upstream codename'
assert_eq '13' "$OS_VERSION_MAJOR" 'debian 13: major version'

t_section 'Ubuntu'

detect ubuntu2204
assert_eq 'ubuntu' "$OS_FLAVOR" 'ubuntu 22.04: flavour'
assert_eq 'jammy' "$OS_UPSTREAM_CODENAME" 'ubuntu 22.04: upstream codename'
assert_eq '22' "$OS_VERSION_MAJOR" 'ubuntu 22.04: major version'
assert_ok 'ubuntu 22.04: os_is_ubuntu' os_is_ubuntu

detect ubuntu2404
assert_eq 'noble' "$OS_UPSTREAM_CODENAME" 'ubuntu 24.04: upstream codename'
assert_ok 'ubuntu 24.04: os_upstream_ge jammy' os_upstream_ge jammy
assert_fail 'ubuntu 24.04: not os_upstream_ge a later release' os_upstream_ge questing
assert_fail 'ubuntu 24.04: a Debian codename never satisfies os_upstream_ge' \
  os_upstream_ge bookworm

t_section 'a derivative takes its upstream codename, not its own'

detect mint
assert_eq 'linuxmint' "$OS_ID" 'mint: ID is preserved'
assert_eq 'ubuntu' "$OS_FLAVOR" 'mint: flavour is ubuntu'
assert_eq 'wilma' "$OS_CODENAME" 'mint: its own codename'
assert_eq 'noble' "$OS_UPSTREAM_CODENAME" 'mint: the codename vendors actually publish'
assert_ok 'mint: os_is_ubuntu is true for the family' os_is_ubuntu

t_section 'Debian sid has no upstream codename, and that is not an error'

detect sid
assert_eq 'debian' "$OS_FLAVOR" 'sid: still the debian family'
assert_eq 'sid' "$OS_CODENAME" 'sid: its own codename'
assert_eq '' "$OS_UPSTREAM_CODENAME" 'sid: no upstream codename, so repos take their fallback'
assert_fail 'sid: os_upstream_ge is false rather than fatal' os_upstream_ge bookworm

t_section 'a Fedora release off the list is the redhat family, untested — not refused'

detect fedora
assert_eq 'redhat' "$OS_FAMILY" 'fedora 41: the redhat family'
assert_eq '41' "$OS_RELEASE" 'fedora 41: release 41'
assert_eq 'untested' "$OS_SUPPORT" 'fedora 41: untested, because 41 has no row'
assert_eq '' "$OS_FLAVOR" 'fedora 41: no Debian flavour, so no Debian-only path runs'
assert_ok 'fedora 41: os_require_supported accepts it' os_require_supported

# --- the gate, release by release (SC-004) ----------------------------------

# gate FIXTURE — runs os_require_supported on a fresh run directory's worth of
# state, and leaves GATE_RC, GATE_WARN (count of warning lines), GATE_ERR (count
# of error lines) and GATE_OUT (everything it printed).
gate() {
  OS_RELEASE_FILE="$real/$1" os_detect
  rm -f -- "$DEVENV_RUNDIR/os-untested"
  GATE_RC=0
  GATE_OUT=$(os_require_supported 2>&1) || GATE_RC=$?
  GATE_WARN=$(printf '%s\n' "$GATE_OUT" | grep -c '^\[ !! \]' || true)
  GATE_ERR=$(printf '%s\n' "$GATE_OUT" | grep -c '^\[ xx \]' || true)
}

t_section 'the gate, release by release: what each os-release is detected as'

# fixture  family  distro  release  pkg-mgr  support   ('-' = empty)
expected=$(
  cat <<'EOF'
debian-12           debian debian              12      apt    tested
debian-13           debian debian              13      apt    tested
ubuntu-22.04        debian ubuntu              22.04   apt    tested
ubuntu-24.04        debian ubuntu              24.04   apt    tested
ubuntu-26.04        debian ubuntu              26.04   apt    tested
almalinux-9         redhat almalinux           9       dnf    tested
almalinux-10        redhat almalinux           10      dnf    tested
rocky-9             redhat rocky               9       dnf    tested
rocky-10            redhat rocky               10      dnf    tested
fedora-43           redhat fedora              43      dnf    tested
fedora-44           redhat fedora              44      dnf    tested
opensuse-leap-16.0  suse   opensuse-leap       16.0    zypper tested
arch-rolling        arch   arch                rolling pacman tested
linuxmint-22        debian linuxmint           22      apt    untested
pop-24.04           debian pop                 24.04   apt    untested
centos-stream-10    redhat centos              10      dnf    untested
rhel-9              redhat rhel                9       dnf    untested
oraclelinux-9       redhat ol                  9       dnf    untested
manjaro             arch   manjaro             rolling pacman untested
endeavouros         arch   endeavouros         rolling pacman untested
opensuse-tumbleweed suse   opensuse-tumbleweed rolling zypper untested
alpine-3.22         -      alpine              -       -      -
gentoo              -      gentoo              -       -      -
nixos               -      nixos               -       -      -
void                -      void                -       -      -
EOF
)

n_tested=0 n_untested=0 n_refused=0
while read -r fx fam distro rel pkg sup; do
  [ -n "$fx" ] || continue
  [ "$fam" != - ] || fam=''
  [ "$rel" != - ] || rel=''
  [ "$pkg" != - ] || pkg=''
  [ "$sup" != - ] || sup=''
  if [ ! -f "$real/$fx" ]; then
    t_not_ok "$fx: no fixture at tests/unit/fixtures/os-release/$fx"
    continue
  fi
  gate "$fx"
  assert_eq "$fam" "$OS_FAMILY" "$fx: family '${fam:-none}'"
  assert_eq "$distro" "$OS_DISTRO" "$fx: distro $distro"
  assert_eq "$rel" "$OS_RELEASE" "$fx: release '${rel:-none}'"
  assert_eq "$pkg" "$OS_PKG_MGR" "$fx: package manager '${pkg:-none}'"
  assert_eq "$sup" "$OS_SUPPORT" "$fx: support '${sup:-unsupported}'"
  case $sup in
    tested)
      n_tested=$((n_tested + 1))
      assert_eq '0' "$GATE_RC" "$fx: accepted"
      assert_eq '0' "$GATE_WARN" "$fx: accepted silently — a tested release gets no notice"
      ;;
    untested)
      n_untested=$((n_untested + 1))
      assert_eq '0' "$GATE_RC" "$fx: accepted"
      assert_eq '1' "$GATE_WARN" "$fx: exactly one notice"
      assert_contains "$GATE_OUT" 'untested release' "$fx: the notice says untested"
      assert_contains "$GATE_OUT" "as the $fam family" "$fx: the notice names the family it runs as"
      assert_eq '0' "$GATE_ERR" "$fx: and no error"
      ;;
    '')
      n_refused=$((n_refused + 1))
      assert_eq '1' "$GATE_RC" "$fx: refused"
      assert_eq '0' "$GATE_WARN" "$fx: refused, not warned about"
      for want in 'debian 12, 13' 'ubuntu 22.04, 24.04, 26.04' 'almalinux 9, 10' \
        'rocky 9, 10' 'fedora 43, 44' 'opensuse-leap 16.0' 'arch rolling'; do
        assert_contains "$GATE_OUT" "$want" "$fx: the refusal lists $want"
      done
      ;;
  esac
done <<<"$expected"
assert_eq '13' "$n_tested" '13 supported releases accepted as tested'
assert_eq '8' "$n_untested" 'a derivative of every family accepted as untested'
assert_eq '4' "$n_refused" 'four unsupported families refused'

t_section 'every row of config/os-support.list has a real fixture, detected as that row'

rows=0
while read -r fam distro rel _image _lab; do
  rows=$((rows + 1))
  fx="$distro-$rel"
  if [ ! -f "$real/$fx" ]; then
    t_not_ok "config/os-support.list has $fam $distro $rel, but there is no fixture $fx"
    continue
  fi
  OS_RELEASE_FILE="$real/$fx" os_detect
  assert_eq "$fam $distro $rel tested" "$OS_FAMILY $OS_DISTRO $OS_RELEASE $OS_SUPPORT" \
    "$fx: detected as its own row"
done < <(os_support_rows)
assert_eq '13' "$rows" 'the list declares 13 releases'
assert_eq '5' "$(os_support_rows debian | wc -l | tr -d ' ')" 'os_support_rows FAMILY filters to that family'

t_section 'the untested notice is said ONCE per run, however many modules ask'

gate linuxmint-22
assert_eq '1' "$GATE_WARN" 'mint: the first asker warns'
again=$(os_require_supported 2>&1 | grep -c '^\[ !! \]' || true)
assert_eq '0' "$again" 'mint: the second asker in the same run stays quiet'
gate manjaro
assert_eq '1' "$GATE_WARN" 'a different machine in a fresh run is told again'

t_section 'the refusal happens before any change'

# 00-preflight is the first module of every profile. On an unsupported family it
# must die before it creates the first directory.
probe="$T_SANDBOX/refused"
rc=0
DEVENV_CONFIG="$probe/config" DEVENV_CACHE="$probe/cache" DEVENV_STATE="$probe/state" \
  OS_RELEASE_FILE="$real/alpine-3.22" bash "$DEVENV_HOME/modules/00-preflight.sh" \
  >/dev/null 2>&1 || rc=$?
assert_ne '0' "$rc" 'preflight on Alpine exits non-zero'
assert_no_file "$probe" 'preflight on Alpine created nothing'
gate gentoo
assert_no_file "$DEVENV_RUNDIR/os-untested" 'a refusal leaves no run state behind'

t_section 'the gate reads the list: the list, not the code, decides what is tested'

alt="$T_SANDBOX/os-support.list"
printf '%s\n' '# a planted list' 'redhat fedora 41 docker.io/library/fedora:41 no' >"$alt"
DEVENV_OS_SUPPORT_LIST="$alt" OS_RELEASE_FILE="$fixtures/fedora" os_detect
assert_eq 'tested' "$OS_SUPPORT" 'fedora 41 becomes tested when a row names it'
DEVENV_OS_SUPPORT_LIST="$alt" OS_RELEASE_FILE="$real/debian-12" os_detect
assert_eq 'untested' "$OS_SUPPORT" 'debian 12 becomes untested when no row names it'
DEVENV_OS_SUPPORT_LIST="$T_SANDBOX/no-such-list" OS_RELEASE_FILE="$real/debian-12" os_detect
assert_eq 'debian untested' "$OS_FAMILY $OS_SUPPORT" 'an unreadable list never claims tested'
rc=0
out=$(DEVENV_OS_SUPPORT_LIST="$T_SANDBOX/no-such-list" OS_RELEASE_FILE="$real/void" \
  bash -c '. "$DEVENV_HOME/lib/common.sh"; os_require_supported' 2>&1) || rc=$?
assert_eq '1' "$rc" 'an unreadable list still refuses an unknown family'
assert_contains "$out" 'could not be read' 'and says the list is missing'

t_section 'os_family_is and the family data'

OS_RELEASE_FILE="$real/rocky-9" os_detect
assert_ok 'rocky: os_family_is redhat' os_family_is redhat
assert_ok 'rocky: os_family_is debian redhat (any of)' os_family_is debian redhat
assert_fail 'rocky: not os_family_is debian' os_family_is debian
assert_fail 'rocky: not os_is_debian (that is the Debian flavour)' os_is_debian
assert_eq 'wheel' "$FAM_ADMIN_GROUP" 'rocky: the admin group is wheel'
OS_RELEASE_FILE="$real/ubuntu-24.04" os_detect
assert_eq 'sudo' "$FAM_ADMIN_GROUP" 'ubuntu: the admin group is sudo'
assert_eq 'update-ca-certificates' "$FAM_CA_REFRESH" 'ubuntu: update-ca-certificates'
OS_RELEASE_FILE="$real/nixos" os_detect
assert_fail 'nixos: os_family_is is false for every family' os_family_is debian redhat suse arch
for k in "${_OS_FAM_KEYS[@]}"; do
  if declare -p "$k" >/dev/null 2>&1 && [ -z "${!k}" ]; then
    t_ok "nixos: $k is defined and empty"
  else
    t_not_ok "nixos: $k should be defined and empty, is [${!k:-<unset>}]"
  fi
done

t_section 'version_ge'

assert_ok 'version_ge 1.2.3 1.2.0' version_ge 1.2.3 1.2.0
assert_ok 'version_ge 1.2.3 1.2.3 (equal counts)' version_ge 1.2.3 1.2.3
assert_fail 'not version_ge 1.2 1.10 (numeric, not lexical)' version_ge 1.2 1.10
assert_ok 'version_ge 0.48.0 0.48 (missing components are zero)' version_ge 0.48.0 0.48
assert_fail 'not version_ge 0.38.0 0.48.0' version_ge 0.38.0 0.48.0

t_section 'require_arch skips the module with exit 78, it does not fail it'

rc=0
(require_arch definitely-not-an-arch) >/dev/null 2>&1 || rc=$?
assert_eq '78' "$rc" 'require_arch on a foreign architecture exits 78'

rc=0
(require_arch "$OS_ARCH_DPKG") >/dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'require_arch on this architecture returns 0'

t_section 'this machine (a smoke test of the real detection)'

os_detect
assert_ne '' "$OS_ARCH_DPKG" 'a dpkg architecture was resolved'
assert_ne '' "$OS_ARCH_GO" 'a Go architecture was resolved'
assert_ne '' "$OS_ARCH_RPM" 'an rpm architecture was resolved'
case $OS_ARCH_DPKG in
  amd64) assert_eq 'x86_64' "$OS_ARCH_RPM" 'amd64 is x86_64 to rpm' ;;
  arm64) assert_eq 'aarch64' "$OS_ARCH_RPM" 'arm64 is aarch64 to rpm' ;;
esac
assert_ok 'have bash' have bash
assert_fail 'have a command that cannot exist' have devenv-no-such-command

t_summary
