# shellcheck shell=bash
# lib/family/redhat.sh — the RedHat family's names: AlmaLinux, Rocky Linux, Fedora,
# and RHEL, CentOS Stream, Oracle Linux and the rest of ID_LIKE=rhel|centos|fedora.
#
# DATA, NOT CODE — the shape and the rules are in lib/family/debian.sh's header.
#
# FAM_CA_BUNDLE is the file update-ca-trust WRITES, not the legacy alias of it.
# /etc/pki/tls/certs/ca-bundle.crt was a symlink to it through Fedora 43 and EL 10,
# and Fedora 44 ships without it (checked in the fedora:44 image). The extracted
# bundle is present on all six releases of the matrix.
# shellcheck disable=SC2034  # read by everything that sources lib/common.sh

FAM_ADMIN_GROUP=wheel
FAM_CA_ANCHOR_DIR=/etc/pki/ca-trust/source/anchors
FAM_CA_REFRESH=update-ca-trust
FAM_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
FAM_PKG_QUERY=rpm
FAM_MAC=selinux
FAM_PKG_FINGERPRINT="rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n'"
