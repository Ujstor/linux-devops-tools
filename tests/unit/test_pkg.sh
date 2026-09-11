#!/usr/bin/env bash
#
# tests/unit/test_pkg.sh — lib/pkg.sh, the parts that need neither root nor apt:
# the apt-sandbox staging that keeps `_apt` able to read a local .deb.
#
# THE BUG THIS PINS DOWN. Every .deb this repository installs is downloaded to
# $DEVENV_CACHE/dl — under $HOME, which is 0750 on Ubuntu. apt fetches local files
# with its `copy:` method, which runs as the unprivileged user `_apt`, so every
# dpkg-style install printed
#
#     N: Download is performed unsandboxed as root as file
#        '/home/<user>/.cache/devops-env/dl/<pkg>.deb' couldn't be accessed by
#        user '_apt'.
#
# — apt announcing that it had turned its own privilege separation off. Seen for
# k9s, kubecolor, dive, grpcurl, openbao and glab on one real install.
#
# apt-get itself is never run here: `_apt_get` and `pkg_update` are replaced with
# stubs, so what is measured is which path pkg_install_local hands to apt and what
# it leaves behind. The staging copy does land in /var/tmp (or /tmp) — that IS the
# behaviour under test — and every assertion below also proves it was removed
# again. A box where neither directory is usable exercises the fallback instead.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

# A home-shaped cache: 0750 the whole way down, exactly like $HOME on Ubuntu.
CACHE="$T_SANDBOX/home/u/.cache/devops-env/dl"
mkdir -p "$CACHE"
chmod 0750 "$T_SANDBOX/home/u"
CLOSED="$CACHE/k9s.deb"
printf 'not really a deb\n' >"$CLOSED"
chmod 0644 "$CLOSED"

# ... and one that anybody can read.
mkdir -p "$T_SANDBOX/pub"
chmod 0755 "$T_SANDBOX" "$T_SANDBOX/pub"
OPEN="$T_SANDBOX/pub/open.deb"
printf 'not really a deb\n' >"$OPEN"
chmod 0644 "$OPEN"

t_section '_apt_can_read: could the sandbox user open this file?'

assert_fail 'a 0750 directory above the file means no' _apt_can_read "$CLOSED"
assert_ok 'a world-readable path means yes' _apt_can_read "$OPEN"
assert_fail 'a file that does not exist means no' _apt_can_read "$CACHE/absent.deb"
chmod 0640 "$OPEN"
assert_fail 'o-r on the file itself means no' _apt_can_read "$OPEN"
chmod 0644 "$OPEN"

t_section '_apt_stage_deb: a copy apt can read'

STAGED=$(_apt_stage_deb "$CLOSED") || STAGED=''
if [ -n "$STAGED" ]; then
  assert_ok 'the staged copy is readable by the sandbox user' _apt_can_read "$STAGED"
  assert_ok 'the staged copy has the same bytes' cmp -s "$CLOSED" "$STAGED"
  case $STAGED in
    "$T_SANDBOX"/*) t_not_ok "the copy was made inside the unreadable tree: $STAGED" ;;
    /var/tmp/* | /tmp/*) t_ok 'the copy is outside the home-shaped tree' ;;
    *) t_not_ok "the copy landed somewhere unexpected: $STAGED" ;;
  esac
  rm -rf -- "${STAGED%/*}"
else
  t_ok 'neither /var/tmp nor /tmp is usable here — the fallback path is what runs'
fi

t_section 'pkg_install_local hands apt a path it can read'

# The stubs. `${*: -1}` is the last argument, i.e. the file apt was pointed at.
# Readability is recorded HERE, at the only moment it matters: when apt has the
# path in its hand. Afterwards the copy is gone, so it could not be asked again.
APT_SAW=''
APT_COULD_READ=''
_apt_get() {
  APT_SAW=${*: -1}
  APT_COULD_READ=no
  _apt_can_read "$APT_SAW" && APT_COULD_READ=yes
  return 0
}
pkg_update() { return 0; }

# Anything named devenv-deb.* that is already lying about is somebody else's.
leaked_stage_dirs() {
  find /var/tmp /tmp -maxdepth 1 -name 'devenv-deb.*' 2>/dev/null | LC_ALL=C sort || true
}
STAGE_DIRS_BEFORE=$(leaked_stage_dirs)

DEVENV_DRY_RUN=0
pkg_install_local "$CLOSED" >/dev/null 2>&1
if [ -n "$STAGED" ]; then
  assert_ne "$CLOSED" "$APT_SAW" 'apt was given a copy, not the unreadable cache path'
  assert_eq yes "$APT_COULD_READ" 'the sandbox user could read what apt was given'
  assert_no_file "$APT_SAW" 'the staging copy is removed after the install'
  assert_fail 'and so is its directory' test -d "${APT_SAW%/*}"
else
  assert_eq "$CLOSED" "$APT_SAW" 'with nowhere to stage, the original path is used'
fi

APT_SAW=''
pkg_install_local "$OPEN" >/dev/null 2>&1
assert_eq "$OPEN" "$APT_SAW" 'a world-readable .deb is installed in place, uncopied'

APT_SAW=''
DEVENV_DRY_RUN=1
pkg_install_local "$CLOSED" >/dev/null 2>&1
assert_eq "$CLOSED" "$APT_SAW" 'a dry run copies nothing and plans the real path'
DEVENV_DRY_RUN=0

assert_eq "$STAGE_DIRS_BEFORE" "$(leaked_stage_dirs)" \
  'no devenv-deb.* scratch directory is left behind'

t_summary
