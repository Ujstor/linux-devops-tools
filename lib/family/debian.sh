# shellcheck shell=bash
# lib/family/debian.sh — the Debian family's names: Debian, Ubuntu and derivatives.
#
# DATA, NOT CODE (plan D3; FR-007, FR-013). The bash form of the host automation's
# vars/<family>.yml: one assignment per key, no function, no branch, no command.
# A family difference is a value here; the code that uses it exists once.
#
# Sourced by os_detect (lib/os.sh) once the family is known, on EVERY call — so
# there is no include guard: re-detecting against another os-release must replace
# every value. All four lib/family/*.sh define the IDENTICAL key set and no value
# is empty; tests/unit/test_family.sh fails the moment one drifts. The keys are
# documented once, in lib/os.sh's variable contract.
#
# Every value below is the one in today's code: on this family nothing moves (FR-008).
# shellcheck disable=SC2034  # read by everything that sources lib/common.sh

FAM_ADMIN_GROUP=sudo
FAM_CA_ANCHOR_DIR=/usr/local/share/ca-certificates
FAM_CA_REFRESH=update-ca-certificates
FAM_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
FAM_PKG_QUERY=dpkg-query
FAM_MAC=none
FAM_PKG_FINGERPRINT="dpkg-query -W -f='\${Package} \${Version}\n'"
