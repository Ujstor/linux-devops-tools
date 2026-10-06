#!/usr/bin/env bash
#
# tests/unit/test_net.sh — lib/net.sh, the parts that need no network:
# THE TAG RULE (MUST-FIX C7), asset-pattern expansion, and checksum handling.
#
# The tag rule is the one that keeps biting: every *_VERSION in versions.env is
# the upstream tag verbatim, `{tag}` is that tag and `{version}` is the tag minus
# any component prefix and one leading `v`. dive's tag really is `v0.13.1` while
# its asset really is `dive_0.13.1_…`, and kustomize's tag really is
# `kustomize/v5.8.1`. Getting this wrong is a 404 at install time, on someone
# else's machine.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

t_section 'tag_to_version'

assert_eq '0.13.1' "$(tag_to_version v0.13.1)" 'a leading v is stripped'
assert_eq '2.68.1' "$(tag_to_version 2.68.1)" 'a tag without a v is unchanged'
assert_eq '5.8.1' "$(tag_to_version kustomize/v5.8.1)" 'a component prefix is stripped'
assert_eq '1.18.2' "$(tag_to_version v1.18.2)" 'ordinary release tag'
assert_eq '0.7.1-rc.1' "$(tag_to_version v0.7.1-rc.1)" 'a pre-release suffix survives'
assert_eq 'v1.0' "$(tag_to_version vv1.0)" 'only ONE leading v is stripped'

t_section 'expand_asset'

OS_ARCH_DPKG=amd64
OS_ARCH_GO=amd64
OS_ARCH_UNAME=x86_64
OS_ARCH_RUST=x86_64

assert_eq 'k9s_Linux_amd64.tar.gz' "$(expand_asset 'k9s_{Os}_{arch}.tar.gz' v0.51.0)" \
  'k9s tarball: capital-L Linux and the Go architecture'
assert_eq 'k9s_linux_amd64.deb' "$(expand_asset 'k9s_{os}_{arch_dpkg}.deb' v0.51.0)" \
  'k9s deb: lower-case linux and the dpkg architecture'
assert_eq 'dive_0.13.1_linux_amd64.deb' \
  "$(expand_asset 'dive_{version}_linux_{arch_dpkg}.deb' v0.13.1)" \
  'dive: the tag keeps its v, the asset does not'
assert_eq 'kustomize_v5.8.1_linux_amd64.tar.gz' \
  "$(expand_asset 'kustomize_v{version}_{os}_{arch}.tar.gz' kustomize/v5.8.1)" \
  'kustomize: a component-prefixed tag'
assert_eq 'openbao_2.6.2_linux_amd64.deb' \
  "$(expand_asset 'openbao_{version}_linux_{arch_dpkg}.deb' v2.6.2)" \
  'openbao: the package is openbao even though the binary is bao'
assert_eq 'tool-x86_64-unknown-linux-gnu.tar.gz' \
  "$(expand_asset 'tool-{arch_rust}-unknown-linux-gnu.tar.gz' v1.0.0)" \
  'a rust triple'
assert_eq 'thing-v1.2.3-x86_64' "$(expand_asset 'thing-{tag}-{arch_uname}' v1.2.3)" \
  '{tag} is verbatim and {arch_uname} is the uname spelling'

assert_fail 'an unknown {token} is a hard error, never a literal brace in a URL' \
  expand_asset 'tool-{bogus}.tar.gz' v1.0.0

t_section 'arm64 produces arm64 assets, not a silent amd64 one'

OS_ARCH_DPKG=arm64
OS_ARCH_GO=arm64
OS_ARCH_UNAME=aarch64
OS_ARCH_RUST=aarch64
assert_eq 'k9s_Linux_arm64.tar.gz' "$(expand_asset 'k9s_{Os}_{arch}.tar.gz' v0.51.0)" \
  'the Go architecture follows'
assert_eq 'tool_linux_aarch64' "$(expand_asset 'tool_{os}_{arch_uname}' v1)" \
  'and so does the uname spelling'

t_section 'checksums'

sums="$T_SANDBOX/checksums.txt"
payload="$T_SANDBOX/payload.bin"
printf 'the payload\n' >"$payload"
digest=$(sha256_of "$payload")
assert_ne '' "$digest" 'sha256_of returns a digest'

{
  printf '%s  tool_1.0.0_linux_amd64.tar.gz\n' "$digest"
  printf '%s *tool_1.0.0_linux_arm64.tar.gz\n' 0000000000000000000000000000000000000000000000000000000000000000
  printf '%s  ./dist/tool_1.0.0_linux_386.tar.gz\n' 1111111111111111111111111111111111111111111111111111111111111111
} >"$sums"

assert_eq "$digest" "$(checksum_lookup "$sums" tool_1.0.0_linux_amd64.tar.gz)" \
  'a plain two-space entry'
assert_eq '0000000000000000000000000000000000000000000000000000000000000000' \
  "$(checksum_lookup "$sums" tool_1.0.0_linux_arm64.tar.gz)" \
  'the binary-mode * form'
assert_eq '1111111111111111111111111111111111111111111111111111111111111111' \
  "$(checksum_lookup "$sums" tool_1.0.0_linux_386.tar.gz)" \
  'a path in the name column'
assert_fail 'an asset that is not listed is a failure, not an empty digest' \
  checksum_lookup "$sums" not-in-the-file.tar.gz

assert_ok 'verify_sha256 accepts the right digest' verify_sha256 "$payload" "$digest"
assert_ok 'verify_sha256 is case-insensitive' verify_sha256 "$payload" "${digest^^}"
assert_fail 'verify_sha256 rejects a wrong digest' \
  verify_sha256 "$payload" 0000000000000000000000000000000000000000000000000000000000000000
assert_fail 'verify_sha256 fails on a missing file' \
  verify_sha256 "$T_SANDBOX/not-here" "$digest"

t_section 'the download cache is keyed on the tag, not on the asset name alone'

# k3d-linux-amd64 is the asset of EVERY k3d release. Cached under that name alone,
# a pin bump would verify (or, unverified, install) the previous release.
DEVENV_CACHE="$T_SANDBOX/cache"
assert_eq "$T_SANDBOX/cache/dl/v5.9.0.k3d-linux-amd64" "$(net_cache_path v5.9.0 k3d-linux-amd64)" \
  'a version-less asset is cached under its tag'
assert_ne "$(net_cache_path v5.8.3 k3d-linux-amd64)" "$(net_cache_path v5.9.0 k3d-linux-amd64)" \
  'two releases of one asset never share a cache file'
assert_eq "$T_SANDBOX/cache/dl/kustomize_v5.8.1.kustomize_v5.8.1_linux_amd64.tar.gz" \
  "$(net_cache_path kustomize/v5.8.1 kustomize_v5.8.1_linux_amd64.tar.gz)" \
  'a component-prefixed tag cannot make a subdirectory'

cache_dl="$DEVENV_CACHE/dl"
mkdir -p "$cache_dl"
keep=$(net_cache_path v5.9.0 k3d-linux-amd64)
: >"$keep"
: >"$cache_dl/v5.8.3.k3d-linux-amd64"
: >"$cache_dl/k3d-linux-amd64"
: >"$cache_dl/v5.9.0.kind-linux-amd64"
: >"$cache_dl/v5.9.0.checksums.txt"

DEVENV_DRY_RUN=1 net_cache_prune "$keep" k3d-linux-amd64 2>/dev/null
assert_ok 'a dry run prunes nothing' test -f "$cache_dl/v5.8.3.k3d-linux-amd64"

net_cache_prune "$keep" k3d-linux-amd64
assert_ok 'the release just downloaded is kept' test -f "$keep"
assert_fail 'an older release of the same asset is pruned' test -e "$cache_dl/v5.8.3.k3d-linux-amd64"
assert_fail 'so is the version-less copy the old cache layout left' test -e "$cache_dl/k3d-linux-amd64"
assert_ok 'another asset is left alone' test -f "$cache_dl/v5.9.0.kind-linux-amd64"
assert_ok 'and so is a checksum file' test -f "$cache_dl/v5.9.0.checksums.txt"

# ===========================================================================
# spec 002 FR-015 / P3: a package file is installed by a package manager, or not
# at all — never placed where an executable belongs.
# ===========================================================================
#
# The network, the package manager and the archive installer are stubs that
# record what they were handed. http_ok answers 2xx for the URLs in $PUBLISHED.

OS_ARCH_DPKG=amd64 OS_ARCH_GO=amd64 OS_ARCH_UNAME=x86_64 OS_ARCH_RUST=x86_64
CALLS="$T_SANDBOX/calls.log"
PUBLISHED=''
INSTALLED=''
http_ok() { case " $PUBLISHED " in *" $1 "*) return 0 ;; *) return 1 ;; esac }
download() {
  printf 'download %s\n' "$1" >>"$CALLS"
  is_dry_run && return 0
  mkdir -p "$(dirname -- "$2")" && printf 'payload of %s\n' "${1##*/}" >"$2"
}
pkg_install_local() { printf 'pkg_install_local %s\n' "${1##*/}" >>"$CALLS"; }
gh_release_install() { printf 'gh_release_install %s\n' "$*" >>"$CALLS"; }
installed_pkg_version() { [ -n "$INSTALLED" ] && printf '%s\n' "$INSTALLED"; }

GH=https://github.com/acme/tool/releases/download/v1.2.3
tool_release() {
  pkg_release_install acme/tool tool v1.2.3 \
    --deb 'tool_{version}_linux_{arch_dpkg}.deb' --rpm 'tool_{version}_linux_{arch_go}.rpm' \
    --tarball 'tool_{version}_linux_{arch_go}.tar.gz' \
    --no-verify --no-verify-reason 'a unit test'
}

t_section 'pkg_release_install: one package mechanism per family'

: >"$CALLS"
OS_PKG_MGR=apt PUBLISHED="$GH/tool_1.2.3_linux_amd64.deb"
tool_release 2>/dev/null
assert_eq "download $GH/tool_1.2.3_linux_amd64.deb
pkg_install_local v1.2.3.tool_1.2.3_linux_amd64.deb" "$(cat "$CALLS")" \
  'apt: the .deb, through the package manager'

: >"$CALLS"
OS_PKG_MGR=dnf PUBLISHED="$GH/tool_1.2.3_linux_amd64.rpm"
tool_release 2>/dev/null
assert_eq "download $GH/tool_1.2.3_linux_amd64.rpm
pkg_install_local v1.2.3.tool_1.2.3_linux_amd64.rpm" "$(cat "$CALLS")" \
  'dnf: the .rpm of the same release'

: >"$CALLS"
OS_PKG_MGR=zypper PUBLISHED="$GH/tool_1.2.3_linux_amd64.rpm"
tool_release 2>/dev/null
assert_contains "$(cat "$CALLS")" 'pkg_install_local v1.2.3.tool_1.2.3_linux_amd64.rpm' \
  'zypper: the .rpm as well'

: >"$CALLS"
OS_PKG_MGR=pacman PUBLISHED=''
tool_release 2>/dev/null
assert_eq "gh_release_install acme/tool tool_{version}_linux_{arch_go}.tar.gz tool v1.2.3 --base-url $GH --no-verify --no-verify-reason a unit test" \
  "$(cat "$CALLS")" 'pacman: the archive — and only the archive'

: >"$CALLS"
OS_PKG_MGR=dnf PUBLISHED=''
tool_release 2>/dev/null
assert_contains "$(cat "$CALLS")" 'gh_release_install acme/tool tool_{version}_linux_{arch_go}.tar.gz' \
  'a 404 .rpm falls back to the archive the call site named'
assert_eq 0 "$(grep -c 'pkg_install_local' "$CALLS" || true)" 'and installs no package file'

t_section 'the old fallbacks are gone (spec 002 P3)'

: >"$CALLS"
OS_PKG_MGR=apt PUBLISHED=''
assert_status 78 'a 404 .deb with no archive named is a skip' \
  pkg_release_install acme/tool tool v1.2.3 --deb 'tool_{version}_linux_{arch_dpkg}.deb' \
  --no-verify --no-verify-reason 'a unit test'
assert_eq '' "$(cat "$CALLS")" 'and no archive name is guessed from the package name'

: >"$CALLS"
OS_PKG_MGR=pacman
assert_status 78 'pacman with no archive is a skip, not a .deb installed as a binary' \
  pkg_release_install acme/tool tool v1.2.3 --deb 'tool_{version}_linux_{arch_dpkg}.deb' \
  --rpm 'tool_{version}_linux_{arch_go}.rpm' --no-verify --no-verify-reason 'a unit test'
assert_eq '' "$(cat "$CALLS")" 'nothing at all was handed on'

t_section 'idempotency and --dry-run'

: >"$CALLS"
OS_PKG_MGR=apt PUBLISHED="$GH/tool_1.2.3_linux_amd64.deb" INSTALLED='1.2.3-1'
tool_release 2>/dev/null
assert_eq '' "$(cat "$CALLS")" 'apt: dpkg already has {version}-<revision> — no network at all'
OS_PKG_MGR=dnf INSTALLED='1.2.3-1'
tool_release 2>/dev/null
assert_eq '' "$(cat "$CALLS")" 'dnf: rpm already has {version}-<release> — no network at all'
INSTALLED='1.2.2-1'
DEVENV_DRY_RUN=1 tool_release 2>/dev/null
assert_eq '' "$(cat "$CALLS")" 'an upgrade under --dry-run downloads and installs nothing'
INSTALLED=''

t_section '--base-url: a release that does not live on GitHub'

: >"$CALLS"
OS_PKG_MGR=dnf
GL='https://gitlab.com/gitlab-org/cli/-/releases/v1.120.0/downloads'
PUBLISHED="$GL/glab_1.120.0_linux_amd64.rpm"
pkg_release_install gitlab-org/cli glab v1.120.0 \
  --base-url 'https://gitlab.com/gitlab-org/cli/-/releases/{tag}/downloads' \
  --deb 'glab_{version}_linux_amd64.deb' --rpm 'glab_{version}_linux_amd64.rpm' \
  --no-verify --no-verify-reason 'a unit test' 2>/dev/null
assert_contains "$(cat "$CALLS")" "download $GL/glab_1.120.0_linux_amd64.rpm" \
  'the asset is fetched from the expanded base, not from github.com'

t_section 'http_ok: published, absent, or could not tell'

# The real http_ok again — the release-install tests above replaced it with a
# stub. curl is stubbed instead: it prints the final status code the way
# `-w %{http_code}` does, and fails like a transport error when asked to.
# shellcheck source=/dev/null
source <(sed -n '/^http_ok() {/,/^}/p' "$DEVENV_HOME/lib/net.sh")
FAKE_CODE=200 FAKE_FAIL=0
# shellcheck disable=SC2329  # invoked by http_ok, through the name curl
curl() {
  printf '%s' "$FAKE_CODE"
  [ "$FAKE_FAIL" = 0 ]
}
http_rc() {
  local rc=0
  http_ok https://example.invalid/asset || rc=$?
  printf '%s' "$rc"
}
FAKE_CODE=200
assert_eq 0 "$(http_rc)" 'a 2xx is published'
FAKE_CODE=404
assert_eq 1 "$(http_rc)" 'a 404 is absent — the only answer a caller may skip on'
FAKE_CODE=410
assert_eq 1 "$(http_rc)" 'a 410 is absent'
FAKE_CODE=503
assert_eq 2 "$(http_rc)" 'a 5xx is "could not tell", never "absent"'
FAKE_CODE=429
assert_eq 2 "$(http_rc)" 'a 429 rate limit is "could not tell"'
FAKE_CODE=403
assert_eq 2 "$(http_rc)" 'a 403 (GitHub rate limit) is "could not tell"'
FAKE_CODE=000 FAKE_FAIL=1
assert_eq 2 "$(http_rc)" 'a transport failure is "could not tell"'
unset -f curl

t_summary
