# shellcheck shell=bash
# lib/pkg.sh — the ONE package policy, on every family.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# Rules that hold everywhere:
#   * POLICY HERE, MECHANISM IN A BACKEND (spec 002 D4). This file decides what
#     to install — which names are missing, which have a candidate, what a name
#     is called on this family — and every public function's body ends in a call
#     to `_pkg_<mgr>_<op>` in lib/pkg_<mgr>.sh, where <mgr> is OS_PKG_MGR (apt,
#     dnf, zypper, pacman; lib/os.sh). Nothing outside those four files runs a
#     package manager. The apt backend is the code this file used to be, moved
#     verbatim (FR-008).
#   * NAMES ARE DATA (FR-007). A module spells a package the way Debian does, once;
#     config/packages.map says what that name is on the other families. The Debian
#     family never reads the map. A name the map gives no package on this family
#     (`-`) is a logged skip, never a failure.
#   * MUST-FIX S9 / idempotency F17: this library NEVER removes a package the user
#     installed. `pkg_remove`/`pkg_purge` REPORT by default and act only behind an
#     explicit opt-in. Conflicts are detected and reported; the user decides.
#   * Every package-manager call goes through run_sudo, so --dry-run mutates
#     nothing. The read-only queries (installed, candidate) never refresh an index
#     and never need root.
#   * On a rolling release nothing here ever leaves the system partially upgraded
#     (FR-012): lib/pkg_pacman.sh never syncs without upgrading.
#
# The backend contract — every lib/pkg_<mgr>.sh defines all of these:
#
#   _pkg_<mgr>_refresh [--force]   the index, at most once per run (pkg_update)
#   _pkg_<mgr>_prepare             before the first candidate query of an install
#                                  that has work to do; non-zero is returned by
#                                  pkg_install as is (pacman: 78, a reasoned skip)
#   _pkg_<mgr>_installed NAME      0 when NAME is installed. Read-only
#   _pkg_<mgr>_candidate NAME      prints the version an install would get; 1 = none
#   _pkg_<mgr>_install NAME…       installs exactly these; never weak deps/recommends
#   _pkg_<mgr>_install_local FILE  a downloaded .deb (apt) or .rpm (dnf, zypper);
#                                  pacman returns 78
#   _pkg_<mgr>_remove VERB NAME…   VERB remove|purge; only ever behind the opt-in
#   _pkg_<mgr>_hint VERB           prints the operator's command for VERB
#   _pkg_<mgr>_upgrade_one NAME    move one installed package to its candidate
#   _pkg_<mgr>_upgrade_all         the whole system; only ever behind --upgrade
#   _pkg_<mgr>_mark_manual NAME…   keep NAME… from being auto-removed
#   _pkg_<mgr>_ensure_addon        the family's standard add-on repository
#
# NAMES that reach a backend are already this family's names: translation
# happens once, here, and never twice.

[ -n "${_DEVENV_PKG:-}" ] && return 0
_DEVENV_PKG=1

# shellcheck source=lib/pkg_apt.sh
. "$DEVENV_HOME/lib/pkg_apt.sh"
# shellcheck source=lib/pkg_dnf.sh
. "$DEVENV_HOME/lib/pkg_dnf.sh"
# shellcheck source=lib/pkg_zypper.sh
. "$DEVENV_HOME/lib/pkg_zypper.sh"
# shellcheck source=lib/pkg_pacman.sh
. "$DEVENV_HOME/lib/pkg_pacman.sh"

# ---------------------------------------------------------------------------
# Dispatch and the name map
# ---------------------------------------------------------------------------

# _pkg_call OP ARG…   (private)
#   Runs `_pkg_${OS_PKG_MGR}_OP ARG…` and returns its status. OS_PKG_MGR is unset
#   only when this library is used without lib/os.sh's detection (a unit test that
#   sets nothing); apt is then the answer, which is what this file always was.
_pkg_call() {
  local op=$1 fn
  shift
  fn="_pkg_${OS_PKG_MGR:-apt}_$op"
  if ! declare -F "$fn" >/dev/null; then
    log_error "no package backend for '${OS_PKG_MGR:-}' (wanted: $op)"
    return 1
  fi
  "$fn" "$@"
}

# _pkg_family   (private) — prints the family whose column of the map applies.
#   Named after the package manager, because that is what picks the column; on
#   a machine lib/os.sh detected, it is the same word as OS_FAMILY.
_pkg_family() {
  case ${OS_PKG_MGR:-apt} in
    apt) printf 'debian\n' ;;
    dnf) printf 'redhat\n' ;;
    zypper) printf 'suse\n' ;;
    pacman) printf 'arch\n' ;;
    *) printf '%s\n' "${OS_FAMILY:-${OS_PKG_MGR:-unknown}}" ;;
  esac
}

# The map, loaded once per process into an associative array keyed by the Debian
# name. _PKG_MAP_KEY records which file and column it holds, so a test that swaps
# DEVENV_PKG_MAP or OS_PKG_MGR gets a reload instead of a stale answer.
declare -gA _PKG_MAP=()
_PKG_MAP_KEY=''
_PKG_RESOLVED=()

# _pkg_map_load   (private)
#   Reads config/packages.map (or $DEVENV_PKG_MAP) for this package manager's
#   column. Rows are `debian redhat suse arch`, `#` starts a comment. A row with
#   the wrong number of fields is ignored with one warning — a broken row must not
#   become a wrong package name. A missing map leaves every name as spelled.
#   Never called on apt. Always returns 0.
_pkg_map_load() {
  local file=${DEVENV_PKG_MAP:-$DEVENV_HOME/config/packages.map} col line deb f2 f3 f4 extra
  case ${OS_PKG_MGR:-apt} in
    dnf) col=2 ;;
    zypper) col=3 ;;
    pacman) col=4 ;;
    *) col=0 ;;
  esac
  [ "$_PKG_MAP_KEY" = "$file:$col" ] && return 0
  unset _PKG_MAP
  declare -gA _PKG_MAP=()
  _PKG_MAP_KEY="$file:$col"
  [ "$col" != 0 ] || return 0
  if [ ! -r "$file" ]; then
    log_warn "no package map at $file — every package is looked up under its Debian name"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    read -r deb f2 f3 f4 extra <<<"$line"
    [ -n "${deb:-}" ] || continue
    if [ -z "${f4:-}" ] || [ -n "${extra:-}" ]; then
      log_warn "$file: the row for '$deb' does not have four columns — ignored"
      continue
    fi
    case $col in
      2) _PKG_MAP[$deb]=$f2 ;;
      3) _PKG_MAP[$deb]=$f3 ;;
      4) _PKG_MAP[$deb]=$f4 ;;
    esac
  done <"$file"
  return 0
}

# _pkg_resolve NAME   (private)
#   Sets _PKG_RESOLVED to the package name(s) NAME stands for on this family and
#   returns 0; returns 1, with _PKG_RESOLVED empty, when the map says this family
#   has no such package (`-`). On apt it is the identity and the map is NEVER
#   opened (FR-008). A name with no row is its own spelling everywhere.
#   An array in a global rather than printed output, so the map stays loaded in
#   THIS shell instead of being re-read in every command substitution.
_pkg_resolve() {
  local name=${1-} v
  _PKG_RESOLVED=("$name")
  case ${OS_PKG_MGR:-apt} in apt) return 0 ;; esac
  [ -n "$name" ] || return 0
  _pkg_map_load
  v=${_PKG_MAP[$name]-=}
  case $v in
    =) return 0 ;;
    -)
      _PKG_RESOLVED=()
      return 1
      ;;
  esac
  IFS=, read -r -a _PKG_RESOLVED <<<"$v"
  return 0
}

# pkg_names NAME…
#   Prints what NAME… are called on this family, one package per line, leaving out
#   the ones this family has none of. For messages and doctor checks; installing
#   goes through pkg_install, which translates by itself. Always returns 0.
pkg_names() {
  local p seen=' ' n
  for p in "$@"; do
    _pkg_resolve "$p" || continue
    for n in "${_PKG_RESOLVED[@]}"; do
      case $seen in *" $n "*) continue ;; esac
      seen="$seen$n "
      printf '%s\n' "$n"
    done
  done
  return 0
}

# pkg_hint VERB [NAME…]
#   Prints the command an operator runs for VERB (install, remove, purge, upgrade)
#   on this family, with NAME… translated: `apt-get install build-essential` on
#   Debian, `dnf install gcc gcc-c++ make` on Fedora. For log lines that tell a
#   human what to type — never executed by this library. Always returns 0.
pkg_hint() {
  local verb=${1:?pkg_hint: VERB required} names
  shift
  names=$(pkg_names "$@" | tr '\n' ' ')
  names=${names% }
  printf '%s%s\n' "$(_pkg_call hint "$verb")" "${names:+ $names}"
}

# ---------------------------------------------------------------------------
# The public API
# ---------------------------------------------------------------------------

# pkg_update [--force]
#   Refreshes the package index at most ONCE per run (state in $DEVENV_RUNDIR),
#   unless --force is given or a repo helper set NEED_APT_UPDATE=1 — the flag keeps
#   its historical name on every family. On pacman it is a no-op: a sync without
#   an upgrade is a partial upgrade waiting to happen (FR-012).
#   Honours --dry-run. A failed refresh is a warning; returns 0.
pkg_update() { _pkg_call refresh "$@"; }

# pkg_installed PKG
#   Returns 0 when PKG (translated) is installed — every package it stands for.
#   Read-only predicate; 1 for a name this family has no package for.
pkg_installed() {
  local n
  local -a names=()
  _pkg_resolve "${1-}" || return 1
  names=("${_PKG_RESOLVED[@]}")
  for n in "${names[@]}"; do
    _pkg_call installed "$n" || return 1
  done
  return 0
}

# pkg_installed_version PKG
#   Prints the installed version of PKG (translated; the first package when it
#   stands for several). Returns 1 when it is not installed. Read-only.
pkg_installed_version() {
  _pkg_resolve "${1-}" || return 1
  _pkg_call installed_version "${_PKG_RESOLVED[0]}"
}

# pkg_candidate_version PKG
#   Prints the candidate version of PKG (translated; the first package when it
#   stands for several), or nothing when there is none.
#   Returns 1 when there is no candidate. Read-only.
pkg_candidate_version() {
  _pkg_resolve "${1-}" || return 1
  _pkg_call candidate "${_PKG_RESOLVED[0]}"
}

# pkg_available PKG
#   Returns 0 when PKG has an installation candidate in the configured archives —
#   every package it stands for.
pkg_available() {
  local n
  local -a names=()
  _pkg_resolve "${1-}" || return 1
  names=("${_PKG_RESOLVED[@]}")
  for n in "${names[@]}"; do
    _pkg_call candidate "$n" >/dev/null 2>&1 || return 1
  done
  return 0
}

# pkg_install PKG…
#   Installs the packages that are not installed yet and that HAVE a candidate.
#   Each PKG is translated through config/packages.map first; a name this family
#   has no package for is logged as a skip. Names with no candidate are dropped
#   with one warning each (a Debian box must not die because an Ubuntu-only
#   package is in the list).
#   Returns 0 immediately when nothing is left to do — that is the idempotency
#   short-circuit that makes a second run silent.
#   Honours --dry-run. Returns 1 on a real failure, and 78 — the reason already
#   logged — when the backend cannot proceed without something the operator has
#   to allow (pacman: a full upgrade, FR-012).
pkg_install() {
  local want=() p n ready='' unproven=()
  local -a names=()
  for p in "$@"; do
    [ -n "$p" ] || continue
    if ! _pkg_resolve "$p"; then
      log_skip "no $(_pkg_family) package for $p — skipping it"
      continue
    fi
    names=("${_PKG_RESOLVED[@]}")
    for n in "${names[@]}"; do
      # Two Debian names can be one package elsewhere (clang, libclang-dev ->
      # clang on Arch): ask and install it once.
      case " ${want[*]} " in *" $n "*) continue ;; esac
      if _pkg_call installed "$n"; then
        log_debug "already installed: $n"
        continue
      fi
      if [ -z "$ready" ]; then
        ready=0
        _pkg_call prepare || ready=$?
      fi
      [ "$ready" = 0 ] || return "$ready"
      if ! _pkg_call candidate "$n" >/dev/null 2>&1; then
        if [ "${PKG_REFRESH_FAILED:-0}" = 1 ]; then
          # Not a skip: with the metadata refresh failed, "no candidate" proves
          # nothing, and the next run would install it — a run that is not done.
          unproven+=("$n")
          continue
        fi
        log_warn "no installation candidate for '$n' on ${OS_ID:-this system} ${OS_CODENAME:-} — skipping it"
        continue
      fi
      want+=("$n")
    done
  done
  local rc=0
  if [ ${#want[@]} -gt 0 ]; then
    pkg_update
    log_info "installing: ${want[*]}"
    _pkg_call install "${want[@]}" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    changed "${OS_PKG_MGR:-apt} install ${want[*]}"
  fi
  if [ ${#unproven[@]} -gt 0 ]; then
    log_error "not installed — no candidate while the package metadata could not be refreshed: ${unproven[*]}"
    log_error "  that is no proof they do not exist; re-run once the repositories answer"
    return 1
  fi
  return 0
}

# pkg_install_optional PKG…
#   As pkg_install, but a failure is logged and swallowed: the module continues.
#   Always returns 0.
pkg_install_optional() {
  pkg_install "$@" || log_warn "optional packages failed to install: $*"
  return 0
}

# pkg_install_first PKG…
#   Installs the FIRST name that has a candidate and stops. This is how one call
#   covers `tealdeer` on trixie/noble and `tldr` on bookworm/jammy, or `7zip` and
#   `p7zip-full`. Returns 0 when one was installed or one is already present;
#   returns 1 when none of the names exists anywhere (the caller then falls back to
#   a release binary).
pkg_install_first() {
  local p
  for p in "$@"; do
    if pkg_installed "$p"; then
      log_debug "already installed: $p"
      return 0
    fi
  done
  for p in "$@"; do
    if pkg_available "$p"; then
      pkg_install "$p"
      return
    fi
  done
  log_debug "none of these packages has a candidate: $*"
  return 1
}

# pkg_install_local FILE
#   Installs a downloaded package file through this family's package manager: a
#   .deb on apt (see _pkg_apt_install_local for the sandbox staging), a .rpm on dnf
#   and zypper. pacman has no foreign package format: 78, so the caller falls back
#   to the release archive. A package file is never put where an executable
#   belongs (FR-015).
#   Honours --dry-run. Returns non-zero when the install fails.
pkg_install_local() { _pkg_call install_local "$@"; }

# pkg_remove PKG…
#   MUST-FIX S9 / idempotency F17: REPORT-ONLY BY DEFAULT.
#   Prints which of PKG… are installed and the exact command to remove them, then
#   returns 0 WITHOUT removing anything. A bootstrapper must not delete packages the
#   user installed deliberately (neovim, yq, containerd, podman-docker were all on
#   the live box and all in the old scripts' purge lists).
#   Removal happens only when DEVENV_ALLOW_PKG_REMOVE=1 and confirm_dangerous agrees.
#   Always returns 0 so a module never fails over a conflict it only needed to report.
pkg_remove() { _pkg_remove_impl remove "$@"; }

# pkg_purge PKG…   — as pkg_remove, with --purge. Same report-only default.
pkg_purge() { _pkg_remove_impl purge "$@"; }

_pkg_remove_impl() {
  local mode=$1
  shift
  local present=() p n
  local -a names=()
  for p in "$@"; do
    [ -n "$p" ] || continue
    _pkg_resolve "$p" || continue
    names=("${_PKG_RESOLVED[@]}")
    for n in "${names[@]}"; do
      if _pkg_call installed "$n"; then present+=("$n"); fi
    done
  done
  [ ${#present[@]} -gt 0 ] || return 0
  log_warn "these packages conflict with what this module installs: ${present[*]}"
  log_warn "  linux-devops-tools does not remove packages you installed."
  log_warn "  To remove them yourself:  sudo $(_pkg_call hint "$mode") ${present[*]}"
  if ! confirm_dangerous "remove ${present[*]} now?" DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  local verb=remove
  [ "$mode" = purge ] && verb=purge
  _pkg_call remove "$verb" "${present[@]}" || {
    log_error "$(_pkg_call hint "$verb") failed"
    return 0
  }
  changed "${OS_PKG_MGR:-apt} $verb ${present[*]}"
  return 0
}

# pkg_conflicts_report LABEL PKG…
#   Pure reporting: names the conflicting packages under LABEL and returns 0 when
#   there are none, 1 when there is at least one. Removes nothing, ever. The names
#   reported are this family's.
#   Use it in `90-doctor.sh` and wherever a module only needs to warn.
pkg_conflicts_report() {
  local label=${1:?pkg_conflicts_report: LABEL required}
  shift
  local present=() p n
  local -a names=()
  for p in "$@"; do
    _pkg_resolve "$p" || continue
    names=("${_PKG_RESOLVED[@]}")
    for n in "${names[@]}"; do
      if _pkg_call installed "$n"; then present+=("$n"); fi
    done
  done
  [ ${#present[@]} -gt 0 ] || return 0
  log_warn "$label: ${present[*]}"
  return 1
}

# pkg_upgrade
#   A full system upgrade (apt: the ONE place `nala` may be used as a front-end).
#   Opt-in only: it no-ops unless DEVENV_UPGRADE=1 (`--upgrade`). "Install my tools"
#   must never pull a new kernel on someone's VM.
#   Honours --dry-run. Always returns 0.
pkg_upgrade() {
  if [ "${DEVENV_UPGRADE:-0}" != 1 ]; then
    log_debug "pkg_upgrade: not requested (--upgrade / DEVENV_UPGRADE=1)"
    return 0
  fi
  _pkg_call upgrade_all || true
  return 0
}

# pkg_upgrade_one PKG
#   Moves ONE already-installed package (translated) to the candidate of the
#   repositories configured right now, and installs nothing new. It is neither
#   pkg_install (which never touches an installed package) nor pkg_upgrade (the
#   whole system, behind --upgrade): it is how a module follows a vendor stream it
#   just re-pointed, e.g. kubectl after a new kubernetes minor.
#   Idempotent: nothing happens once the installed version is at the candidate.
#   On pacman a single-package upgrade would be a partial upgrade, so there it is
#   the full upgrade under --upgrade, or a reasoned skip (78).
#   Honours --dry-run. Returns 0, 1 when the upgrade failed (warned), or 78.
pkg_upgrade_one() {
  local n rc=0
  local -a names=()
  _pkg_resolve "${1:?pkg_upgrade_one: PKG required}" || return 0
  names=("${_PKG_RESOLVED[@]}")
  for n in "${names[@]}"; do
    _pkg_call upgrade_one "$n" || rc=$?
  done
  return "$rc"
}

# pkg_mark_manual PKG…
#   Marks the installed PKG… (translated) as installed on purpose, so that an
#   automatic cleanup (apt autoremove, dnf autoremove, pacman -Qdt) cannot take
#   them. Names that are not installed, or already marked, are left alone.
#   Honours --dry-run. Returns 1 when the package manager refused.
pkg_mark_manual() {
  local p names=()
  for p in "$@"; do
    _pkg_resolve "$p" || continue
    names+=("${_PKG_RESOLVED[@]}")
  done
  [ ${#names[@]} -gt 0 ] || return 0
  _pkg_call mark_manual "${names[@]}"
}

# pkg_ensure_addon
#   Enables this family's standard add-on repository when a capability needs it,
#   and reports that as a change (FR-010) — the same decision on every family:
#     Ubuntu            the `universe` component
#     AlmaLinux, Rocky  CRB, then EPEL (epel-release)
#     Debian, Fedora, openSUSE Leap, Arch   nothing
#   No-op when it is already enabled. Honours --dry-run. Always returns 0.
pkg_ensure_addon() {
  _pkg_call ensure_addon || true
  return 0
}

# pkg_ensure_universe   — the name pkg_ensure_addon had before it had families.
#   Kept so that no caller has to change at once.
pkg_ensure_universe() { pkg_ensure_addon; }

# apt_or_release PKG BIN MIN_VERSION REPO ASSET_PATTERN [OPTS…]
#   K19, one runtime probe instead of a distro version matrix: install PKG from the
#   distribution when its CANDIDATE is >= MIN_VERSION, otherwise install the
#   pinned GitHub release binary. The name is historical: PKG is translated like
#   any other, so this works on every family. OPTS are passed to
#   gh_release_install unchanged (checksum options included) — so pass the
#   release VERSION as --release-version, e.g.
#       apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}-linux_{arch_go}.tar.gz' \
#           --release-version "$FZF_VERSION" --checksum-asset fzf_{version}_checksums.txt
#   Used for zoxide (min 0.9.0), fzf (0.48.0, the `fzf --bash` cutover) and
#   git-delta (0.16.0). eza is always the release tarball — it is absent from
#   bookworm and jammy entirely, so branching would buy nothing.
#   Returns 0, or gh_release_install's status (78 = no asset for this arch).
apt_or_release() {
  local pkg=${1:?apt_or_release: PKG required} bin=${2:?apt_or_release: BIN required}
  local minv=${3:?apt_or_release: MIN_VERSION required} repo=${4:?apt_or_release: REPO required}
  local pattern=${5:?apt_or_release: ASSET_PATTERN required}
  shift 5
  local relver=latest opts=()
  while [ $# -gt 0 ]; do
    case $1 in
      --release-version)
        relver=$2
        shift 2
        ;;
      *)
        opts+=("$1")
        shift
        ;;
    esac
  done
  local cand inst mgr=${OS_PKG_MGR:-apt}
  # Installed from the archive at a good enough version already: done, without
  # asking the archive again. The candidate query is the fragile half — a cache
  # being rewritten under it, or a small machine short of memory, makes it come
  # back empty — and on the EL9 lab guests that turned run 2's "not in the
  # archive" into a second copy of fzf and zoxide in /usr/local/bin.
  if inst=$(pkg_installed_version "$pkg") && version_ge "$inst" "$minv"; then
    log_skip "$pkg $inst is installed from the $mgr archive (>= $minv)"
    return 0
  fi
  if cand=$(pkg_candidate_version "$pkg"); then
    if version_ge "$cand" "$minv"; then
      log_debug "$pkg: $mgr candidate $cand >= $minv"
      pkg_install "$pkg"
      return
    fi
    log_info "$pkg: $mgr has only $cand (< $minv) — using the pinned release binary"
  else
    log_info "$pkg: not in the archive — using the pinned release binary"
  fi
  gh_release_install "$repo" "$pattern" "$bin" "$relver" "${opts[@]}"
}

# ---------------------------------------------------------------------------
# Shared by the two rpm backends (dnf, zypper)
# ---------------------------------------------------------------------------

# _pkg_rpm_installed NAME   (private)
#   Returns 0 when an installed package PROVIDES NAME. By what it provides, not
#   by its own name, because that is how both dnf and zypper resolve a name on
#   install: EL9's image ships curl-minimal, which provides curl, and asking rpm
#   for the package NAMED curl would send dnf into a conflict on every run.
#   Read-only; needs no root.
_pkg_rpm_installed() {
  [ -n "${1-}" ] || return 1
  rpm -q --quiet --whatprovides "$1" 2>/dev/null
}

# _pkg_rpm_name NAME   (private)
#   Prints the name of the installed package that provides NAME (the first, when
#   several do). Returns 1 when none does — asked first, because rpm prints its
#   "no package provides" verdict on stdout. Read-only.
_pkg_rpm_name() {
  local n
  _pkg_rpm_installed "${1-}" || return 1
  n=$(rpm -q --qf '%{NAME}\n' --whatprovides "${1-}" 2>/dev/null | awk 'NF && !s {s = $1} END {print s}') || return 1
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# _pkg_rpm_version NAME   (private)
#   Prints VERSION-RELEASE of the installed package that provides NAME. Read-only.
_pkg_rpm_version() {
  local v
  _pkg_rpm_installed "${1-}" || return 1
  v=$(rpm -q --qf '%{VERSION}-%{RELEASE}\n' --whatprovides "${1-}" 2>/dev/null | awk 'NF && !s {s = $1} END {print s}') || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_refresh_once LABEL FORCE CMD…   (private)
#   The once-per-run refresh the non-apt backends share (apt keeps its own,
#   verbatim). Runs CMD through run_sudo unless the index was already refreshed
#   this run and neither FORCE=1 nor NEED_APT_UPDATE=1 asks again. A failure is a
#   warning: the cached index is still an index. Honours --dry-run. Returns 0.
_pkg_refresh_once() {
  local label=$1 force=$2
  shift 2
  if [ "${NEED_APT_UPDATE:-0}" = 1 ]; then force=1; fi
  local stamp="${DEVENV_RUNDIR:-/nonexistent}/${OS_PKG_MGR:-pkg}-updated"
  if [ "$force" = 0 ] && [ -f "$stamp" ]; then
    log_debug "$label already refreshed this run"
    return 0
  fi
  log_info "refreshing the $label"
  # One retry: a mirror hiccup is the common failure. If it still fails, the run
  # REMEMBERS it (PKG_REFRESH_FAILED): a package that then has no candidate may
  # only be missing because a repository's metadata never arrived — EPEL on a
  # fresh Rocky 10 in pipeline 65179 — and pkg_install must not call that a skip.
  if ! run_sudo "$@"; then
    sleep 5
    if ! run_sudo "$@"; then
      log_warn "the $label refresh failed twice — continuing with the cached one"
      PKG_REFRESH_FAILED=1
      export PKG_REFRESH_FAILED
      return 0
    fi
  fi
  if [ -d "${DEVENV_RUNDIR:-}" ]; then : >"$stamp"; fi
  NEED_APT_UPDATE=0
  export NEED_APT_UPDATE
  return 0
}
