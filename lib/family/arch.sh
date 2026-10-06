# shellcheck shell=bash
# lib/family/arch.sh — the Arch family's names: Arch Linux, and Manjaro, EndeavourOS
# and the rest of ID_LIKE=arch.
#
# DATA, NOT CODE — the shape and the rules are in lib/family/debian.sh's header.
#
# FAM_ADMIN_GROUP is `wheel`, but the stock /etc/sudoers ships the %wheel line
# COMMENTED OUT: membership alone grants nothing until it is enabled. lib/run.sh's
# hint says so.
# shellcheck disable=SC2034  # read by everything that sources lib/common.sh

FAM_ADMIN_GROUP=wheel
FAM_CA_ANCHOR_DIR=/etc/ca-certificates/trust-source/anchors
FAM_CA_REFRESH='trust extract-compat'
FAM_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
FAM_PKG_QUERY=pacman
FAM_MAC=none
FAM_PKG_FINGERPRINT='pacman -Q'
