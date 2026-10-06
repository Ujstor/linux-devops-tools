#!/usr/bin/env bash
#
# tests/unit/test_pkg.sh — lib/pkg.sh and its four backends, the parts that need
# neither root nor a package manager:
#
#   * the apt-sandbox staging that keeps `_apt` able to read a local .deb;
#   * the dispatch: every public call reaches `_pkg_${OS_PKG_MGR}_<op>`, and the
#     commands the real backends hand to root are the ones the plan names;
#   * config/packages.map: the identity on the Debian family, which never even
#     opens it (spec 002 FR-008); several packages for one name; `-` as a logged
#     skip that never fails;
#   * pacman never syncs without upgrading (FR-012), with and without --upgrade;
#   * pkg_ensure_addon's CRB + EPEL on Enterprise Linux and nothing on Fedora.
#
# THE BUG THE FIRST PART PINS DOWN. Every .deb this repository installs is downloaded to
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

# ===========================================================================
# spec 002: one policy, four backends, one name map
# ===========================================================================
#
# No package manager runs below. run_sudo is replaced by a recorder, so what is
# measured is the exact command each backend WOULD hand to root; the backends'
# read-only queries are replaced by a fake package database where they would
# otherwise ask a real one.

# The recorder. RUN_OUT is what the "command" prints, RUN_RC its exit status.
RAN=()
ALL_RAN=()
RUN_OUT=''
RUN_RC=0
run_sudo() {
  RAN+=("$*")
  ALL_RAN+=("$*")
  if [ -n "$RUN_OUT" ]; then printf '%s\n' "$RUN_OUT"; fi
  return "$RUN_RC"
}

# The fake database: INSTALLED and NOCAND are space-padded name lists.
INSTALLED=' '
NOCAND=' '
_fake_installed() {
  case $INSTALLED in *" $1 "*) return 0 ;; esac
  return 1
}
_fake_candidate() {
  case $NOCAND in *" $1 "*) return 1 ;; esac
  printf '2.0-1\n'
}

last_change() { changed_list | tail -n 1 | cut -f 2; }

# Commands that would sync pacman's database WITHOUT upgrading: -S with a y and
# no u anywhere in the flag cluster (-Sy, -Syy, -Sywd …). Comment lines are prose.
partial_syncs() {
  local c
  for c in "$@"; do
    case " $c " in
      *' pacman '*) grep -qE '(^|[[:space:]])-S[a-tv-z]*y[a-tv-z]*([[:space:]]|$)' <<<"$c" && printf '%s\n' "$c" ;;
    esac
  done
  return 0
}

MAP="$T_SANDBOX/packages.map"
cat >"$MAP" <<'EOF'
# a fixture in the shipped format: debian redhat suse arch
build-essential   gcc,gcc-c++,make   gcc,gcc-c++,make   base-devel
nala              -                  -                  -
xz-utils          xz                 xz                 xz     # a trailing comment
same              =                  =                  =
twin              jq                 jq                 jq
broken            only-two
EOF
export DEVENV_PKG_MAP=$MAP

t_section 'the real backends: the commands they hand to root'

RPM="$T_SANDBOX/pub/tool-1.0.x86_64.rpm"
printf 'not really an rpm\n' >"$RPM"
DEB="$T_SANDBOX/pub/tool_1.0_amd64.deb"
printf 'not really a deb\n' >"$DEB"

OS_PKG_MGR=dnf
RAN=()
_pkg_dnf_install gcc make
assert_eq 'dnf -y install --setopt=install_weak_deps=False gcc make' "${RAN[*]}" \
  'dnf: no weak dependencies, and no "--" (dnf5 on Fedora 43 rejects it)'
RAN=()
pkg_install_local "$RPM" >/dev/null 2>&1
assert_eq "dnf -y install --setopt=install_weak_deps=False $(readlink -f "$RPM")" "${RAN[*]: -1}" \
  'dnf: a local .rpm is installed by dnf, which resolves its dependencies'
assert_eq "rpm install $(basename "$RPM")" "$(last_change)" 'dnf: the local install is recorded as a change'
assert_status 1 'dnf: a .deb is refused, never unpacked into place' pkg_install_local "$DEB"

OS_PKG_MGR=zypper
RAN=()
_pkg_zypper_install gcc make
assert_eq 'zypper --non-interactive install --no-recommends -- gcc make' "${RAN[*]}" \
  'zypper: non-interactive, no recommends'
RAN=()
pkg_install_local "$RPM" >/dev/null 2>&1
assert_eq "zypper --non-interactive --no-gpg-checks --no-refresh install --no-recommends --allow-unsigned-rpm -- $(readlink -f "$RPM")" "${RAN[*]: -1}" \
  'zypper: a checksum-verified local .rpm installs unsigned or vendor-signed'
assert_status 1 'zypper: a .deb is refused' pkg_install_local "$DEB"

GPG_AUTO=$(grep -nE -- '--gpg-auto-import-keys' "$DEVENV_HOME"/lib/*.sh | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
assert_eq '' "$GPG_AUTO" 'no library code ever passes --gpg-auto-import-keys'

OS_PKG_MGR=pacman
assert_status 78 'pacman: a .deb or .rpm is a skip (78), the caller uses the release archive' \
  pkg_install_local "$RPM"

t_section 'dispatch: every public call reaches OS_PKG_MGR'"'"'s backend'

# From here on the four backends' queries answer from the fake database, and
# their mutations are recorded instead of run.
CALLS=()
for m in apt dnf zypper; do
  eval "_pkg_${m}_installed() { _fake_installed \"\$1\"; }"
  eval "_pkg_${m}_candidate() { _fake_candidate \"\$1\"; }"
  eval "_pkg_${m}_install() { CALLS+=(\"$m install \$*\"); }"
  eval "_pkg_${m}_prepare() { CALLS+=(\"$m prepare\"); }"
  eval "_pkg_${m}_refresh() { CALLS+=(\"$m refresh\"); }"
  eval "_pkg_${m}_ensure_addon() { CALLS+=(\"$m addon\"); }"
done

for m in apt dnf zypper; do
  OS_PKG_MGR=$m
  CALLS=()
  pkg_install jq 2>/dev/null
  assert_contains "${CALLS[*]}" "$m install jq" "$m: pkg_install reaches _pkg_${m}_install"
  assert_eq "$m install jq" "$(last_change)" "$m: the install is recorded as '$m install …'"
  CALLS=()
  pkg_update
  assert_eq "$m refresh" "${CALLS[*]}" "$m: pkg_update reaches _pkg_${m}_refresh"
  CALLS=()
  pkg_ensure_universe
  assert_eq "$m addon" "${CALLS[*]}" "$m: pkg_ensure_universe is pkg_ensure_addon, on every family"
done

OS_PKG_MGR=apk
assert_status 1 'a package manager with no backend is an error, not a silent no-op' pkg_install jq
OS_PKG_MGR=apt

t_section 'the Debian family never reads the map (FR-008)'

OS_PKG_MGR=apt
_PKG_MAP_KEY=''
CALLS=()
pkg_install build-essential nala xz-utils 2>/dev/null
assert_contains "${CALLS[*]}" 'apt install build-essential nala xz-utils' \
  'apt installs exactly the names the module spells'
assert_eq '' "$_PKG_MAP_KEY" 'and packages.map was never opened'
assert_eq 'apt-get install build-essential nala' "$(pkg_hint install build-essential nala)" \
  'the operator hint is the apt-get line it always was'

t_section 'the map: translation, several packages, none at all'

OS_PKG_MGR=dnf
INSTALLED=' '
CALLS=()
pkg_install build-essential 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install gcc gcc-c++ make' 'one Debian name can stand for several packages'
INSTALLED=' gcc '
CALLS=()
pkg_install build-essential 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install gcc-c++ make' 'only the ones that are missing are installed'
assert_fail 'pkg_installed is false while one of them is missing' pkg_installed build-essential
INSTALLED=' gcc gcc-c++ make '
assert_ok 'and true once all of them are there' pkg_installed build-essential
INSTALLED=' '

CALLS=()
pkg_install xz-utils same jq 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install xz same jq' 'a renamed name, an "=" row and a name with no row'
CALLS=()
pkg_install jq twin 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install jq' 'two Debian names that are one package here ...'
assert_eq 'jq' "$(pkg_names jq twin 2>/dev/null)" '... are installed and named once'

CALLS=()
OUT=$(pkg_install nala 2>&1 && printf 'rc=0')
pkg_install nala 2>/dev/null
assert_eq '' "${CALLS[*]}" 'a "-" row installs nothing, and asks no backend anything'
assert_contains "$OUT" 'rc=0' 'and is not a failure'
OUT=$(DEVENV_QUIET=0 pkg_install nala 2>&1)
assert_contains "$OUT" 'no redhat package for nala' 'it is logged as a skip that names the family'
assert_fail 'pkg_installed: a "-" name is never installed' pkg_installed nala
assert_fail 'pkg_available: and never available' pkg_available nala
assert_fail 'pkg_candidate_version: and has no candidate' pkg_candidate_version nala
CALLS=()
pkg_install_first nala xz-utils 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install xz' 'pkg_install_first moves past a "-" name to the next one'

NOCAND=' xz '
CALLS=()
pkg_install xz-utils 2>/dev/null
case "${CALLS[*]}" in
  *install*) t_not_ok "no candidate: nothing may be installed (${CALLS[*]})" ;;
  *) t_ok 'no candidate: dropped with a warning, nothing installed' ;;
esac
NOCAND=' '

OS_PKG_MGR=pacman
assert_eq 'base-devel' "$(pkg_names build-essential nala 2>/dev/null)" 'pkg_names reads the arch column, and leaves out "-"'
OS_PKG_MGR=zypper
assert_eq 'zypper install gcc gcc-c++ make xz' "$(pkg_hint install build-essential nala xz-utils 2>/dev/null)" \
  'pkg_hint gives the family command with the family names'
assert_eq 'zypper remove' "$(pkg_hint purge 2>/dev/null)" 'and zypper has no purge'

OS_PKG_MGR=dnf
INSTALLED=' gcc '
OUT=$(pkg_conflicts_report 'two toolchains' build-essential 2>&1 || printf 'rc=1')
assert_contains "$OUT" "two toolchains: gcc
rc=1" 'pkg_conflicts_report names the family packages it found'
INSTALLED=' '

_PKG_MAP_KEY=''
OUT=$(_pkg_map_load 2>&1)
assert_contains "$OUT" "row for 'broken' does not have four columns" 'a malformed row is ignored, with a warning'
CALLS=()
pkg_install broken 2>/dev/null
assert_contains "${CALLS[*]}" 'dnf install broken' 'and never becomes a package name'

t_section 'nothing to do touches nothing'

INSTALLED=' gcc gcc-c++ make xz jq '
CALLS=()
pkg_install build-essential xz-utils jq nala 2>/dev/null
assert_eq '' "${CALLS[*]}" 'all installed: no prepare, no refresh, no install — the second run is silent'
INSTALLED=' '

t_section 'pacman never upgrades partially (FR-012)'

OS_PKG_MGR=pacman
DB=yes
_pkg_pacman_db_ok() { [ "$DB" = yes ]; }
_pkg_pacman_installed() { _fake_installed "$1"; }
_pkg_pacman_candidate() { _fake_candidate "$1"; }
fresh_run() {
  rm -f -- "$DEVENV_RUNDIR/pacman-upgraded"
  RAN=()
  RUN_OUT=''
  RUN_RC=0
}

fresh_run
pkg_update
pkg_update --force
assert_eq '' "${RAN[*]}" 'pkg_update syncs nothing on pacman, even with --force'

fresh_run
DEVENV_UPGRADE=0
pkg_install build-essential 2>/dev/null
assert_eq 'env LC_ALL=C pacman -S --needed --noconfirm base-devel' "${RAN[*]}" \
  'without --upgrade: -S --needed against the database the box has'

fresh_run
DB=no
assert_status 78 'no sync database and no --upgrade: a skip (78)' pkg_install jq
assert_eq '' "${RAN[*]}" 'and nothing was run'
OUT=$(DEVENV_QUIET=0 pkg_install jq 2>&1 || true)
assert_contains "$OUT" 'the package index needs a full upgrade: re-run with --upgrade' 'with the reason'
DB=yes

fresh_run
RUN_RC=1
RUN_OUT="error: failed retrieving file 'jq-1.8.1-1-x86_64.pkg.tar.zst' from geo.mirror.pkgbuild.com : The requested URL returned error: 404"
assert_status 78 'a database behind the mirrors (404) is a skip (78), not a sync' pkg_install jq
OUT=$(pkg_install jq 2>&1 || true)
assert_contains "$OUT" 'the package index needs a full upgrade: re-run with --upgrade' 'with the same reason'
RUN_OUT='error: target not found: jq'
assert_status 1 'any other pacman failure is a failure' pkg_install jq

fresh_run
DEVENV_UPGRADE=1
pkg_install jq 2>/dev/null
pkg_install tmux 2>/dev/null
assert_eq 'pacman -Syu --needed --noconfirm jq' "${RAN[0]:-}" \
  '--upgrade: the first install is ONE transaction with the full upgrade'
assert_eq 'env LC_ALL=C pacman -S --needed --noconfirm tmux' "${RAN[1]:-}" '-Syu runs once a run, not once a call'
assert_contains "$(changed_list)" 'system upgrade (pacman -Syu)' 'the upgrade is recorded as a change'

fresh_run
DB=no
pkg_install jq 2>/dev/null
assert_eq 'pacman -Syu --needed --noconfirm' "${RAN[0]:-}" '--upgrade with no database: the full upgrade creates it'
assert_eq 'env LC_ALL=C pacman -S --needed --noconfirm jq' "${RAN[1]:-}" 'and the install follows against it'
DB=yes

# shellcheck disable=SC2329  # called by the code under test, as the command it stands in for
pacman() {
  case $1 in
    -Q) printf '%s 1.0-1\n' "$2" ;;
    *) return 1 ;;
  esac
}
fresh_run
DEVENV_UPGRADE=0
INSTALLED=' kubectl '
assert_status 78 'pkg_upgrade_one: one package newer than the rest is a skip (78)' pkg_upgrade_one kubectl
assert_eq '' "${RAN[*]}" 'and nothing was run'
DEVENV_UPGRADE=1
pkg_upgrade_one kubectl 2>/dev/null
assert_eq 'pacman -Syu --needed --noconfirm' "${RAN[*]}" 'under --upgrade it is the full upgrade instead'
INSTALLED=' '
unset -f pacman
DEVENV_UPGRADE=0

assert_eq '' "$(partial_syncs "${ALL_RAN[@]}")" 'no command run in this whole file syncs without upgrading'
SY=$(grep -nE 'pacman[^#]*[[:space:]]-S[a-tv-z]*y[a-tv-z]*([[:space:]]|$)' "$DEVENV_HOME"/lib/*.sh \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
assert_eq '' "$SY" 'and no line of library code does'

t_section 'pkg_ensure_addon: CRB and EPEL on Enterprise Linux, nothing on Fedora'

unset -f _pkg_dnf_ensure_addon
# shellcheck source=lib/pkg_dnf.sh
_DEVENV_PKG_DNF='' . "$DEVENV_HOME/lib/pkg_dnf.sh"
OS_PKG_MGR=dnf
_pkg_dnf_installed() { _fake_installed "$1"; }
_pkg_dnf_candidate() { _fake_candidate "$1"; }
_pkg_dnf_install() {
  CALLS+=("dnf install $*")
  INSTALLED="$INSTALLED$* "
}
_pkg_dnf_prepare() { :; }
_pkg_dnf_refresh() {
  CALLS+=("dnf refresh")
  NEED_APT_UPDATE=0
}
_pkg_dnf_is5() { return 1; }
CRB=no
_pkg_dnf_repo_enabled() { [ "$CRB" = yes ]; }
# shellcheck disable=SC2329  # called by the code under test, as the command it stands in for
dnf() { return 0; }

OS_DISTRO=fedora
RAN=()
CALLS=()
pkg_ensure_addon
assert_eq '' "${RAN[*]}${CALLS[*]}" 'Fedora: nothing to enable'

OS_DISTRO=almalinux
RAN=()
CALLS=()
pkg_ensure_addon 2>/dev/null
assert_eq 'dnf config-manager --set-enabled crb' "${RAN[*]}" 'EL: CRB is enabled'
assert_contains "${CALLS[*]}" 'dnf install epel-release' 'EL: epel-release is installed'
assert_eq 'dnf refresh|dnf install epel-release|dnf refresh' "$(IFS='|' && printf '%s' "${CALLS[*]}")" \
  'EL: the metadata is refreshed after CRB, before the EPEL lookup, and after EPEL'
assert_contains "$(changed_list)" 'enabled the CRB repository' 'enabling CRB is reported as a change (FR-010)'

CRB=yes
INSTALLED=' epel-release '
RAN=()
CALLS=()
pkg_ensure_addon
assert_eq '' "${RAN[*]}${CALLS[*]}" 'EL: once both are there, a second run does nothing'
INSTALLED=' '
unset -f dnf
unset OS_DISTRO

t_section 'a failed metadata refresh makes "no candidate" a failure, not a skip'

# EPEL on a fresh Rocky 10 (pipeline 65179): the refresh failed, every EPEL name
# had no candidate, the run skipped them and exited 0, and run 2 installed them.
NOCAND=' fd-find '
INSTALLED=' '
CALLS=()
unset PKG_REFRESH_FAILED
rc=0
pkg_install fd-find 2>/dev/null || rc=$?
assert_eq 0 "$rc" 'refresh fine: a package with no candidate is a skip'
PKG_REFRESH_FAILED=1
rc=0
err=$(pkg_install fd-find 2>&1 >/dev/null) || rc=$?
assert_eq 1 "$rc" 'refresh failed: no candidate fails the call'
assert_contains "$err" 'could not be refreshed: fd-find' 'and names what was not installed'
NOCAND=' '
rc=0
CALLS=()
pkg_install fd-find 2>/dev/null || rc=$?
assert_eq 0 "$rc" 'refresh failed but the candidate is there: installed as usual'
assert_contains "${CALLS[*]}" 'dnf install fd-find' 'the install still runs'
unset PKG_REFRESH_FAILED
INSTALLED=' '

t_section 'apt_or_release keeps an archive package that is good enough'

# The EL9 lab guests (pipeline 65184): run 1 installed fzf and zoxide from EPEL,
# run 2's candidate query came back empty, and run 2 then added the release
# binaries to /usr/local/bin. An installed package at >= MIN is the answer by itself.
GH=()
gh_release_install() { GH+=("$1"); }
FAKE_INST_VER=0.60.3-1.el9
# shellcheck disable=SC2329  # reached through _pkg_call
_pkg_dnf_installed_version() {
  _fake_installed "$1" || return 1
  printf '%s\n' "$FAKE_INST_VER"
}
OS_PKG_MGR=dnf
INSTALLED=' fzf '
NOCAND=' fzf '
CALLS=()
apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}.tar.gz' --release-version 0.70.0 >/dev/null 2>&1
assert_eq '' "${GH[*]}" 'installed 0.60.3 >= 0.48.0 and no candidate: no release binary'
assert_eq '' "${CALLS[*]}" 'and no package call either'
FAKE_INST_VER=0.38.0-1
apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}.tar.gz' --release-version 0.70.0 >/dev/null 2>&1
assert_eq 'junegunn/fzf' "${GH[*]}" 'installed but older than MIN: the release binary, as before'
GH=()
INSTALLED=' '
NOCAND=' '
apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}.tar.gz' --release-version 0.70.0 >/dev/null 2>&1
assert_eq '' "${GH[*]}" 'not installed, candidate 2.0 >= MIN: the package'
assert_contains "${CALLS[*]}" 'dnf install fzf' 'installed through pkg_install'
unset -f gh_release_install _pkg_dnf_installed_version
unset GH FAKE_INST_VER
INSTALLED=' '
NOCAND=' '

# Back to the apt backend for the sections below, which test its .deb staging.
OS_PKG_MGR=apt
unset DEVENV_PKG_MAP

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
