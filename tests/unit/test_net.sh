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

t_summary
