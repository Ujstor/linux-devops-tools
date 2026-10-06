# shellcheck shell=bash
# lib/pkg_pacman.sh — the pacman backend of lib/pkg.sh: Arch Linux.
#
# linux-devops-tools :: shared library. Sourced by lib/pkg.sh only, which owns the
# policy and the contract (see its header); this file is mechanism.
#
# ARCH IS ROLLING, AND THAT IS THE WHOLE DESIGN OF THIS FILE (spec 002 FR-012).
# Arch supports exactly one state: every installed package at the version of the
# sync database it was installed from. `pacman -Sy` followed by an install
# refreshes the database WITHOUT upgrading the system — a partial upgrade, which
# Arch does not support and which breaks a box in ways that surface weeks later
# (a library soname bumped under binaries that were never rebuilt). So:
#
#   * NEVER `-Sy` without `-u`. pkg_update is a no-op here. The only command in
#     this file that syncs is `pacman -Syu`, the full upgrade, and it runs only
#     under the operator's existing opt-in, --upgrade (DEVENV_UPGRADE=1), at most
#     once a run.
#   * Without --upgrade, an install is `pacman -S --needed` against the database
#     the box already has. That is consistent by construction, but the database
#     can be behind the mirrors: the version it names is gone and the download
#     404s. That — or a box with no sync database at all — is a skip with the
#     reason "the package index needs a full upgrade: re-run with --upgrade",
#     never a sync behind the operator's back.
#   * With --upgrade, the first install of the run is ONE transaction,
#     `pacman -Syu --needed --noconfirm <targets>`: the system and the new
#     packages arrive together.
#
# `pacman -T` (deptest) answers "installed?" by what packages provide, as pacman's
# own install resolves a name. Messages are parsed under LC_ALL=C.

[ -n "${_DEVENV_PKG_PACMAN:-}" ] && return 0
_DEVENV_PKG_PACMAN=1

# The reason every skip below gives. One string, so the matrix and the summary can
# match on it.
PKG_PACMAN_NEEDS_UPGRADE='the package index needs a full upgrade: re-run with --upgrade'

# _pkg_pacman_db_ok   (private)
#   Returns 0 when the box has a sync database to answer from at all. A fresh
#   archlinux image ships with an empty sync directory; every query then fails
#   with "database file for 'core' does not exist". Read-only.
_pkg_pacman_db_ok() {
  local dbpath
  dbpath=$(pacman-conf DBPath 2>/dev/null) || dbpath=''
  [ -n "$dbpath" ] || dbpath=/var/lib/pacman/
  compgen -G "${dbpath%/}/sync/*.db" >/dev/null
}

# _pkg_pacman_upgraded / _pkg_pacman_set_upgraded   (private)
#   The once-a-run record of the full upgrade, in $DEVENV_RUNDIR like apt's
#   refresh stamp, so the child modules of one run share it.
_pkg_pacman_upgraded() { [ -f "${DEVENV_RUNDIR:-/nonexistent}/pacman-upgraded" ]; }
_pkg_pacman_set_upgraded() {
  if [ -d "${DEVENV_RUNDIR:-}" ]; then : >"$DEVENV_RUNDIR/pacman-upgraded"; fi
  return 0
}

# _pkg_pacman_full_upgrade [TARGET…]   (private)
#   `pacman -Syu --needed --noconfirm [TARGET…]`, at most once a run and only
#   under --upgrade (the caller checks). Records the upgrade as a change.
#   Honours --dry-run. Returns pacman's status.
_pkg_pacman_full_upgrade() {
  log_info "--upgrade: one full system upgrade${1:+, together with $*} (pacman never upgrades partially)"
  run_sudo pacman -Syu --needed --noconfirm "$@" || return 1
  _pkg_pacman_set_upgraded
  changed "system upgrade (pacman -Syu)"
  return 0
}

# _pkg_pacman_refresh [--force]   — pkg_update on pacman: deliberately nothing.
#   A sync without an upgrade is the partial upgrade this file exists to prevent.
#   The database is refreshed only by _pkg_pacman_full_upgrade. Returns 0.
_pkg_pacman_refresh() {
  log_debug "pacman: the sync database is refreshed only together with a full upgrade (--upgrade)"
  return 0
}

# _pkg_pacman_prepare
#   With no sync database nothing can be looked up, let alone installed: under
#   --upgrade that is the full upgrade now (it creates the database); otherwise a
#   skip with the reason. Returns 0, 1 when the upgrade failed, or 78.
_pkg_pacman_prepare() {
  _pkg_pacman_db_ok && return 0
  if [ "${DEVENV_UPGRADE:-0}" = 1 ] && ! _pkg_pacman_upgraded; then
    _pkg_pacman_full_upgrade || return 1
    if is_dry_run; then
      log_warn "(dry run) this box has no pacman sync database yet: what would be installed is decided after the upgrade"
      return 78
    fi
    return 0
  fi
  log_warn "pacman has no sync database on this box — $PKG_PACMAN_NEEDS_UPGRADE"
  return 78
}

# _pkg_pacman_installed NAME   — 0 when an installed package satisfies NAME.
_pkg_pacman_installed() {
  [ -n "${1-}" ] || return 1
  pacman -T "$1" >/dev/null 2>&1
}

# _pkg_pacman_installed_version NAME   — the local database's version. Read-only.
_pkg_pacman_installed_version() {
  local v
  [ -n "${1-}" ] || return 1
  v=$(LC_ALL=C pacman -Q "$1" 2>/dev/null | awk 'NF >= 2 && !v {v = $2} END {print v}') || true
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_pacman_candidate NAME
#   Prints the version the box's sync database offers for NAME. Returns 1 when it
#   offers none — or has no database. Read-only, no network, no root.
_pkg_pacman_candidate() {
  local n=${1-} v
  [ -n "$n" ] || return 1
  v=$(LC_ALL=C pacman -Si "$n" 2>/dev/null | awk '/^Version/ && !v {v = $3} END {print v}') || true
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_pacman_install NAME…   — see the header for why it is shaped like this.
#   Honours --dry-run. Returns 0, 1 on a failure, or 78 — reason logged — when
#   the database is behind the mirrors and --upgrade was not given.
_pkg_pacman_install() {
  local log='' rc=0
  if [ "${DEVENV_UPGRADE:-0}" = 1 ] && ! _pkg_pacman_upgraded; then
    _pkg_pacman_full_upgrade "$@"
    return
  fi
  # Captured so a stale database can be told from a real failure, then replayed:
  # the operator still sees what pacman said.
  log=$(devenv_tmpfile 2>/dev/null) || log=''
  if [ -z "$log" ]; then
    run_sudo pacman -S --needed --noconfirm "$@"
    return
  fi
  run_sudo env LC_ALL=C pacman -S --needed --noconfirm "$@" >"$log" 2>&1 || rc=$?
  cat -- "$log" >&2
  [ "$rc" = 0 ] && return 0
  if grep -qE 'failed retrieving file|failed to retrieve some files|returned error: 404' "$log"; then
    log_warn "pacman could not download $*: $PKG_PACMAN_NEEDS_UPGRADE"
    return 78
  fi
  return 1
}

# _pkg_pacman_install_local FILE   — 78: Arch has no foreign package format to
#   install, and a .deb or .rpm is never unpacked into place by hand (FR-015).
#   The caller falls back to the release archive.
_pkg_pacman_install_local() {
  log_info "pacman installs no .deb or .rpm ($(basename -- "${1:-?}")) — the caller uses the release archive instead"
  return 78
}

# _pkg_pacman_hint VERB   — the operator's spelling.
_pkg_pacman_hint() {
  case ${1:?_pkg_pacman_hint: VERB required} in
    install) printf 'pacman -S\n' ;;
    remove) printf 'pacman -R\n' ;;
    purge) printf 'pacman -Rn\n' ;;
    upgrade) printf 'pacman -Syu\n' ;;
    *) printf 'pacman %s\n' "$1" ;;
  esac
}

# _pkg_pacman_remove VERB NAME…   — behind pkg_remove/pkg_purge's opt-in only.
#   purge is -Rn: pacman's way of not keeping the .pacsave copies of config files.
_pkg_pacman_remove() {
  local verb=${1:?_pkg_pacman_remove: VERB required}
  shift
  if [ "$verb" = purge ]; then
    run_sudo pacman -Rn --noconfirm "$@"
  else
    run_sudo pacman -R --noconfirm "$@"
  fi
}

# _pkg_pacman_upgrade_all   — pkg_upgrade on pacman, once it has been opted into.
#   The full upgrade, once a run. Honours --dry-run. Always returns 0.
_pkg_pacman_upgrade_all() {
  if _pkg_pacman_upgraded; then
    log_debug "pacman: the system was already upgraded this run"
    return 0
  fi
  _pkg_pacman_full_upgrade || log_warn "pacman -Syu failed"
  return 0
}

# _pkg_pacman_upgrade_one NAME   — pkg_upgrade_one on pacman.
#   Upgrading ONE package is the partial upgrade Arch forbids. When the database
#   offers a different version than the one installed, the answer is the full
#   upgrade under --upgrade, or a skip with the reason.
#   Honours --dry-run. Returns 0, 1 when the upgrade failed, or 78.
_pkg_pacman_upgrade_one() {
  local name=${1:?pkg_upgrade_one: NAME required} cur cand
  cur=$(LC_ALL=C pacman -Q "$name" 2>/dev/null | awk 'NF >= 2 && !v {v = $2} END {print v}') || cur=''
  [ -n "$cur" ] || return 0
  cand=$(_pkg_pacman_candidate "$name") || return 0
  if [ "$cur" = "$cand" ]; then
    log_debug "$name $cur is what the sync database offers"
    return 0
  fi
  if [ "${DEVENV_UPGRADE:-0}" = 1 ]; then
    _pkg_pacman_upgraded && return 0
    _pkg_pacman_full_upgrade || return 1
    return 0
  fi
  log_warn "$name $cur -> $cand is part of a system upgrade: $PKG_PACMAN_NEEDS_UPGRADE"
  return 78
}

# _pkg_pacman_mark_manual NAME…   — pkg_mark_manual on pacman: --asexplicit, which
#   `pacman -Qdt` (the orphan list everyone removes) never shows. Names already
#   explicit, or not installed, are left alone. Honours --dry-run.
_pkg_pacman_mark_manual() {
  local n todo=() explicit=''
  explicit=$(pacman -Qqe 2>/dev/null) || explicit=''
  for n in "$@"; do
    pacman -Q "$n" >/dev/null 2>&1 || continue
    if grep -Fxq -- "$n" <<<"$explicit"; then continue; fi
    todo+=("$n")
  done
  [ ${#todo[@]} -gt 0 ] || return 0
  run_sudo pacman -D --asexplicit "${todo[@]}" >/dev/null || return 1
  changed "pacman: ${todo[*]} marked as explicitly installed"
  return 0
}

# _pkg_pacman_ensure_addon   — nothing: Arch's official repositories are the
#   catalog, and the AUR is not a repository this library will ever build from.
_pkg_pacman_ensure_addon() {
  log_debug "Arch needs no add-on repository"
  return 0
}
