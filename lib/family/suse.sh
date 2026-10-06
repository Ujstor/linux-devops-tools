# shellcheck shell=bash
# lib/family/suse.sh — the SUSE family's names: openSUSE Leap, and Tumbleweed, SLES
# and the rest of ID_LIKE=suse|opensuse|sles.
#
# DATA, NOT CODE — the shape and the rules are in lib/family/debian.sh's header.
#
# FAM_ADMIN_GROUP is `wheel`, but on Leap it is NOT a sudo grant by default: the
# group comes from system-group-wheel, and the stock sudo policy is `targetpw` (any
# user, ROOT's password). sudo-policy-wheel-auth-self is what lets wheel members
# authenticate as themselves. lib/run.sh's hint says exactly that.
# shellcheck disable=SC2034  # read by everything that sources lib/common.sh

FAM_ADMIN_GROUP=wheel
FAM_CA_ANCHOR_DIR=/etc/pki/trust/anchors
FAM_CA_REFRESH=update-ca-certificates
FAM_CA_BUNDLE=/etc/ssl/ca-bundle.pem
FAM_PKG_QUERY=rpm
FAM_MAC=selinux
FAM_PKG_FINGERPRINT="rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n'"
