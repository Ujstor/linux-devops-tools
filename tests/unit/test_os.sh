#!/usr/bin/env bash
#
# tests/unit/test_os.sh — lib/os.sh: detection against synthetic /etc/os-release
# files, so the Debian/Ubuntu split and the derivative mapping are testable on any
# machine. Nothing here reads the real /etc/os-release except the last section.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

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

t_section 'a non-Debian distribution is refused, not guessed at'

detect fedora
assert_eq '' "${OS_FAMILY:-}" 'fedora: no family'
assert_fail 'fedora: os_require_supported returns non-zero' os_require_supported

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
assert_ok 'have bash' have bash
assert_fail 'have a command that cannot exist' have devenv-no-such-command

t_summary
