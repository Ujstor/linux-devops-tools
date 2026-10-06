#!/usr/bin/env bash
#
# tests/unit/test_repo.sh — lib/repo.sh on the families spec 002 added, the parts
# that need no network and no root:
#
#   * _repo_pgp_fingerprints — the bash OpenPGP walk that lets the rpm families
#     ask "is this vendor key trusted already?" without gpg. Checked here against
#     the fingerprints `gpg --show-keys` prints for two real vendor keys, one with
#     an armor header and one without, and both in one file;
#   * _repo_rpm_import — both spellings of a key in the rpm database (rpm 4's
#     low 32 bits of the key id, rpm 6's whole fingerprint), and an import only
#     when a key is missing;
#   * repo_add_rpm — the .repo file each family's package manager reads, written
#     once, idempotent, and nothing at all under --dry-run;
#   * the dispatch: arch, and a vendor with nothing for a family, return 78 before
#     any download; the Debian docker source says `stable`, not `main`.
#
# rpm and the network are stubs: every function that would reach either is
# replaced below, after lib/common.sh has been sourced.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

# Two public vendor signing keys, verbatim: Microsoft's microsoft.asc (with a
# `Version:` armor header) and Docker's rpm key (without one). Public keys are
# published for exactly this kind of use; neither is a secret.
KEYS="$T_SANDBOX/keys"
mkdir -p "$KEYS"
cat >"$KEYS/microsoft.asc" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: BSN Pgp v1.1.0.0

mQENBFYxWIwBCADAKoZhZlJxGNGWzqV+1OG1xiQeoowKhssGAKvd+buXCGISZJwT
LXZqIcIiLP7pqdcZWtE9bSc7yBY2MalDp9Liu0KekywQ6VVX1T72NPf5Ev6x6DLV
7aVWsCzUAF+eb7DC9fPuFLEdxmOEYoPjzrQ7cCnSV4JQxAqhU4T6OjbvRazGl3ag
OeizPXmRljMtUUttHQZnRhtlzkmwIrUivbfFPD+fEoHJ1+uIdfOzZX8/oKHKLe2j
H632kvsNzJFlROVvGLYAk2WRcLu+RjjggixhwiB+Mu/A8Tf4V6b+YppS44q8EvVr
M+QvY7LNSOffSO6Slsy9oisGTdfE39nC7pVRABEBAAG0N01pY3Jvc29mdCAoUmVs
ZWFzZSBzaWduaW5nKSA8Z3Bnc2VjdXJpdHlAbWljcm9zb2Z0LmNvbT6JATQEEwEI
AB4FAlYxWIwCGwMGCwkIBwMCAxUIAwMWAgECHgECF4AACgkQ6z6Urb4SKc+P9gf/
diY2900wvWEgV7iMgrtGzx79W/PbwWiOkKoD9sdzhARXWiP8Q5teL/t5TUH6TZ3B
ENboDjwr705jLLPwuEDtPI9jz4kvdT86JwwG6N8gnWM8Ldi56SdJEtXrzwtlB/Fe
6tyfMT1E/PrJfgALUG9MWTIJkc0GhRJoyPpGZ6YWSLGXnk4c0HltYKDFR7q4wtI8
4cBu4mjZHZbxIO6r8Cci+xxuJkpOTIpr4pdpQKpECM6x5SaT2gVnscbN0PE19KK9
nPsBxyK4wW0AvAhed2qldBPTipgzPhqB2gu0jSryil95bKrSmlYJd1Y1XfNHno5D
xfn5JwgySBIdWWvtOI05gw==
=zPfd
-----END PGP PUBLIC KEY BLOCK-----
EOF
cat >"$KEYS/docker-rpm.asc" <<'EOF'
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFit5IEBEADDt86QpYKz5flnCsOyZ/fk3WwBKxfDjwHf/GIflo+4GWAXS7wJ
1PSzPsvSDATV10J44i5WQzh99q+lZvFCVRFiNhRmlmcXG+rk1QmDh3fsCCj9Q/yP
w8jn3Hx0zDtz8PIB/18ReftYJzUo34COLiHn8WiY20uGCF2pjdPgfxE+K454c4G7
gKFqVUFYgPug2CS0quaBB5b0rpFUdzTeI5RCStd27nHCpuSDCvRYAfdv+4Y1yiVh
KKdoe3Smj+RnXeVMgDxtH9FJibZ3DK7WnMN2yeob6VqXox+FvKYJCCLkbQgQmE50
uVK0uN71A1mQDcTRKQ2q3fFGlMTqJbbzr3LwnCBE6hV0a36t+DABtZTmz5O69xdJ
WGdBeePCnWVqtDb/BdEYz7hPKskcZBarygCCe2Xi7sZieoFZuq6ltPoCsdfEdfbO
+VBVKJnExqNZCcFUTEnbH4CldWROOzMS8BGUlkGpa59Sl1t0QcmWlw1EbkeMQNrN
spdR8lobcdNS9bpAJQqSHRZh3cAM9mA3Yq/bssUS/P2quRXLjJ9mIv3dky9C3udM
+q2unvnbNpPtIUly76FJ3s8g8sHeOnmYcKqNGqHq2Q3kMdA2eIbI0MqfOIo2+Xk0
rNt3ctq3g+cQiorcN3rdHPsTRSAcp+NCz1QF9TwXYtH1XV24A6QMO0+CZwARAQAB
tCtEb2NrZXIgUmVsZWFzZSAoQ0UgcnBtKSA8ZG9ja2VyQGRvY2tlci5jb20+iQI3
BBMBCgAhBQJYrep4AhsvBQsJCAcDBRUKCQgLBRYCAwEAAh4BAheAAAoJEMUv62ti
Hp816C0P/iP+1uhSa6Qq3TIc5sIFE5JHxOO6y0R97cUdAmCbEqBiJHUPNQDQaaRG
VYBm0K013Q1gcJeUJvS32gthmIvhkstw7KTodwOM8Kl11CCqZ07NPFef1b2SaJ7l
TYpyUsT9+e343ph+O4C1oUQw6flaAJe+8ATCmI/4KxfhIjD2a/Q1voR5tUIxfexC
/LZTx05gyf2mAgEWlRm/cGTStNfqDN1uoKMlV+WFuB1j2oTUuO1/dr8mL+FgZAM3
ntWFo9gQCllNV9ahYOON2gkoZoNuPUnHsf4Bj6BQJnIXbAhMk9H2sZzwUi9bgObZ
XO8+OrP4D4B9kCAKqqaQqA+O46LzO2vhN74lm/Fy6PumHuviqDBdN+HgtRPMUuao
xnuVJSvBu9sPdgT/pR1N9u/KnfAnnLtR6g+fx4mWz+ts/riB/KRHzXd+44jGKZra
IhTMfniguMJNsyEOO0AN8Tqcl0eRBxcOArcri7xu8HFvvl+e+ILymu4buusbYEVL
GBkYP5YMmScfKn+jnDVN4mWoN1Bq2yMhMGx6PA3hOvzPNsUoYy2BwDxNZyflzuAi
g59mgJm2NXtzNbSRJbMamKpQ69mzLWGdFNsRd4aH7PT7uPAURaf7B5BVp3UyjERW
5alSGnBqsZmvlRnVH5BDUhYsWZMPRQS9rRr4iGW0l+TH+O2VJ8aQ
=0Zqq
-----END PGP PUBLIC KEY BLOCK-----
EOF
cat "$KEYS/microsoft.asc" "$KEYS/docker-rpm.asc" >"$KEYS/both.asc"
MS_FPR=bc528686b50d79e339d3721ceb3e94adbe1229cf
DOCKER_FPR=060a61c51b558a7f742b77aac52feb6b621e9f35

t_section '_repo_pgp_fingerprints: the identity rpm files a key under, without gpg'

assert_eq "$MS_FPR" "$(_repo_pgp_fingerprints "$KEYS/microsoft.asc")" \
  'an armor header (Version:) is skipped, and the fingerprint is gpg'"'"'s'
assert_eq "$DOCKER_FPR" "$(_repo_pgp_fingerprints "$KEYS/docker-rpm.asc")" \
  'a key with no armor header at all'
assert_eq "$MS_FPR $DOCKER_FPR" "$(_repo_pgp_fingerprints "$KEYS/both.asc" | tr '\n' ' ' | sed 's/ $//')" \
  'every armor block in one file is read'
printf 'not a key\n' >"$KEYS/junk.asc"
assert_eq '' "$(_repo_pgp_fingerprints "$KEYS/junk.asc" 2>/dev/null || true)" \
  'a file with no key block yields no fingerprint'
sed 's/^mQENBFYx/mQENBFYy/' "$KEYS/microsoft.asc" >"$KEYS/tampered.asc"
assert_ne "$MS_FPR" "$(_repo_pgp_fingerprints "$KEYS/tampered.asc" 2>/dev/null || true)" \
  'one changed byte of key material is a different fingerprint'

t_section '_repo_rpm_import: read-only when the rpm database already trusts the key'

# rpm is a stub: `rpm -q gpg-pubkey --qf …` prints $RPM_KNOWN; anything else fails.
RPM_KNOWN=''
rpm() {
  case "$*" in
    '-q gpg-pubkey --qf %{VERSION}\n') [ -n "$RPM_KNOWN" ] && printf '%s\n' "$RPM_KNOWN" ;;
    *) return 1 ;;
  esac
}
# run_sudo is a recorder: what would have run as root, and nothing else.
SUDO_LOG="$T_SANDBOX/sudo.log"
run_sudo() { printf '%s\n' "$*" >>"$SUDO_LOG"; }
: >"$SUDO_LOG"

RPM_KNOWN=$(printf '%s\n' 6fedfc85 be1229cf)
_repo_rpm_import microsoft "$KEYS/microsoft.asc" 2>/dev/null
assert_eq '' "$(cat "$SUDO_LOG")" 'rpm 4: the low 32 bits of the key id are enough — no import'

RPM_KNOWN=$MS_FPR
_repo_rpm_import microsoft "$KEYS/microsoft.asc" 2>/dev/null
assert_eq '' "$(cat "$SUDO_LOG")" 'rpm 6 (Fedora 43+): the whole fingerprint — no import'

RPM_KNOWN=$(printf '%s\n' "${MS_FPR^^}")
_repo_rpm_import microsoft "$KEYS/microsoft.asc" 2>/dev/null
assert_eq '' "$(cat "$SUDO_LOG")" 'upper-case hex from rpm is the same key'

RPM_KNOWN=be1229cf
_repo_rpm_import both "$KEYS/both.asc" 2>/dev/null
assert_eq "rpm --import $KEYS/both.asc" "$(cat "$SUDO_LOG")" \
  'one key of two missing: the file is imported'

: >"$SUDO_LOG"
RPM_KNOWN=''
_repo_rpm_import junk "$KEYS/junk.asc" 2>/dev/null
assert_eq "rpm --import $KEYS/junk.asc" "$(cat "$SUDO_LOG")" \
  'a key that cannot be fingerprinted is imported, not guessed about'

t_section 'repo_key KIND=rpm: the file lives in RPM_KEY_DIR'

RPM_KEY_DIR="$T_SANDBOX/rpm-gpg"
assert_eq "$T_SANDBOX/rpm-gpg/RPM-GPG-KEY-docker" "$(_repo_key_path docker rpm)" \
  'the EL/Fedora naming convention'
assert_ok 'an armored key is a valid rpm key' _repo_key_valid "$KEYS/docker-rpm.asc" rpm
assert_fail 'anything else is not' _repo_key_valid "$KEYS/junk.asc" rpm

t_section 'repo_add_rpm: one .repo file per vendor, written once'

YUM_REPOS_DIR="$T_SANDBOX/yum.repos.d"
ZYPP_REPOS_DIR="$T_SANDBOX/zypp.repos.d"
OS_FAMILY=redhat OS_PKG_MGR=dnf
NEED_APT_UPDATE=0
# shellcheck disable=SC2016  # $basearch is dnf's variable, written verbatim
repo_add_rpm trivy 'Trivy repository' 'https://get.trivy.dev/rpm/releases/$basearch/' \
  "$RPM_KEY_DIR/RPM-GPG-KEY-trivy" 0 2>/dev/null
assert_file "$YUM_REPOS_DIR/trivy.repo" 'redhat: /etc/yum.repos.d/<name>.repo'
# shellcheck disable=SC2016
assert_eq '# Managed by linux-devops-tools. Local edits are overwritten.
[trivy]
name=Trivy repository
baseurl=https://get.trivy.dev/rpm/releases/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://'"$RPM_KEY_DIR"'/RPM-GPG-KEY-trivy' "$(cat "$YUM_REPOS_DIR/trivy.repo")" \
  'dnf: gpgcheck always, repo_gpgcheck as given, the key by its local path'
assert_eq 1 "$NEED_APT_UPDATE" 'a new source asks pkg_update for a refresh'

NEED_APT_UPDATE=0
# shellcheck disable=SC2016
repo_add_rpm trivy 'Trivy repository' 'https://get.trivy.dev/rpm/releases/$basearch/' \
  "$RPM_KEY_DIR/RPM-GPG-KEY-trivy" 0 2>/dev/null
assert_eq 0 "${DEVENV_CHANGED_LAST:-1}" 'the same content again changes nothing'
assert_eq 0 "$NEED_APT_UPDATE" 'and forces no refresh'

repo_add_rpm azure-cli 'Azure CLI' 'https://packages.microsoft.com/rhel/9/prod/' \
  "$RPM_KEY_DIR/RPM-GPG-KEY-microsoft" 1 includepkgs=azure-cli 2>/dev/null
assert_eq 'includepkgs=azure-cli' "$(tail -n1 "$YUM_REPOS_DIR/azure-cli.repo")" \
  'extra KEY=VALUE lines are appended verbatim'

OS_FAMILY=suse OS_PKG_MGR=zypper
repo_add_rpm kubernetes 'Kubernetes v1.34' 'https://pkgs.k8s.io/core:/stable:/v1.34/rpm/' \
  "$RPM_KEY_DIR/RPM-GPG-KEY-kubernetes" 1 2>/dev/null
assert_file "$ZYPP_REPOS_DIR/kubernetes.repo" 'suse: /etc/zypp/repos.d/<name>.repo'
assert_contains "$(cat "$ZYPP_REPOS_DIR/kubernetes.repo")" 'type=rpm-md' 'zypper is told the repository type'
assert_contains "$(cat "$ZYPP_REPOS_DIR/kubernetes.repo")" 'pkg_gpgcheck=1' \
  'and both checks are spelled out, so an unsigned repomd.xml is never a prompt'

DEVENV_DRY_RUN=1 repo_add_rpm github-cli 'GitHub CLI' 'https://cli.github.com/packages/rpm' \
  "$RPM_KEY_DIR/RPM-GPG-KEY-github-cli" 1 2>/dev/null
assert_no_file "$ZYPP_REPOS_DIR/github-cli.repo" '--dry-run writes nothing'

OS_FAMILY=arch OS_PKG_MGR=pacman
assert_fail 'a family without .repo files is an error, not a stray file' \
  repo_add_rpm x 'X' 'https://example.com/' /dev/null 1

t_section 'the dispatch: 78 before any download where a vendor publishes nothing'

# Nothing below may reach the network or a key: both are tripwires.
http_ok() {
  printf 'http_ok %s\n' "$*" >>"$SUDO_LOG"
  return 1
}
download() {
  printf 'download %s\n' "$*" >>"$SUDO_LOG"
  return 1
}
: >"$SUDO_LOG"

OS_FAMILY=arch OS_PKG_MGR=pacman OS_DISTRO=arch
for v in docker hashicorp github_cli azure_cli trivy; do
  assert_status 78 "arch: repo_ensure_$v" "repo_ensure_$v"
done
assert_status 78 'arch: repo_ensure_kubernetes' repo_ensure_kubernetes v1.34

OS_FAMILY=suse OS_PKG_MGR=zypper OS_DISTRO=opensuse-leap
assert_status 78 'suse: docker (the distribution builds it)' repo_ensure_docker
assert_status 78 'suse: hashicorp (no SUSE tree; the release zip)' repo_ensure_hashicorp
assert_status 78 'suse: azure-cli (uv tool install)' repo_ensure_azure_cli

OS_FAMILY=redhat OS_PKG_MGR=dnf OS_DISTRO=fedora OS_VERSION_MAJOR=44
assert_status 78 'Fedora: Microsoft builds no azure-cli' repo_ensure_azure_cli
assert_eq '' "$(cat "$SUDO_LOG")" 'none of those touched the network'

t_section 'Debian: the docker source names the component Docker actually has'

# `main` made apt skip the index and drop every docker package (30-containers
# carried a private copy of this function because of it).
OS_FAMILY=debian OS_PKG_MGR=apt OS_FLAVOR=debian OS_UPSTREAM_CODENAME=bookworm
SOURCES_DIR="$T_SANDBOX/sources.list.d"
repo_suite_pick() { printf 'bookworm\n'; }
repo_key() { printf '/etc/apt/keyrings/docker.asc\n'; }
repo_ensure_docker 2>/dev/null
assert_contains "$(cat "$SOURCES_DIR/docker.sources" 2>/dev/null)" 'Components: stable' \
  'Components: stable'
assert_contains "$(cat "$SOURCES_DIR/docker.sources" 2>/dev/null)" \
  'URIs: https://download.docker.com/linux/debian' 'the deb822 source is otherwise unchanged'

t_summary
