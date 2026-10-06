# shellcheck shell=bash
# lib/pkg_zypper.sh — the zypper backend of lib/pkg.sh: openSUSE Leap.
#
# linux-devops-tools :: shared library. Sourced by lib/pkg.sh only, which owns the
# policy and the contract (see its header); this file is mechanism.
#
# Rules that hold everywhere in this file:
#   * `--non-interactive` on every call, and NEVER `--gpg-auto-import-keys`. A
#     repository's signing key is imported explicitly and verified by lib/repo.sh,
#     as on every other family; a key zypper has not been given is a refusal, not a
#     question to answer "yes" to (the fleet's host automation keeps the same rule).
#   * `--no-recommends`: zypper installs recommended packages by default, apt's
#     --no-install-recommends is the policy.
#   * every read is `--no-refresh`. A non-root user cannot refresh anyway; the
#     read then answers from the system cache and never touches the network. With
#     no cache at all (a fresh image) zypper skips the repository and exits 106 —
#     _pkg_zypper_prepare refreshes before the first install that needs it.
#   * names are matched by what packages PROVIDE, like zypper's own install does
#     ("'ffmpeg' not found in package names. Trying capabilities."): Leap 16's
#     ffmpeg is ffmpeg-7, its node is nodejs22.

[ -n "${_DEVENV_PKG_ZYPPER:-}" ] && return 0
_DEVENV_PKG_ZYPPER=1

# _pkg_zypper_refresh [--force]   — pkg_update on zypper, once a run.
#   `zypper refresh` downloads only what is out of date. Honours --dry-run.
_pkg_zypper_refresh() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  _pkg_refresh_once 'zypper repository metadata' "$force" zypper --non-interactive --quiet refresh
}

# _pkg_zypper_prepare   — a usable cache before the first candidate query.
_pkg_zypper_prepare() { pkg_update; }

# _pkg_zypper_installed NAME   — 0 when an installed package provides NAME.
_pkg_zypper_installed() { _pkg_rpm_installed "${1-}"; }

# _pkg_zypper_installed_version NAME   — VERSION-RELEASE of the provider. Read-only.
_pkg_zypper_installed_version() { _pkg_rpm_version "${1-}"; }

# _pkg_zypper_candidate NAME
#   Prints the edition (VERSION-RELEASE) of the newest package that provides
#   NAME — the one named NAME when there is one, else the first provider. Parsed
#   from `zypper --xmlout search`, one <solvable …/> element per line, newest
#   first. Returns 1 when there is none. Read-only, no network, no root.
_pkg_zypper_candidate() {
  local n=${1-} v
  [ -n "$n" ] || return 1
  v=$(zypper --non-interactive --no-refresh --xmlout search --provides --match-exact \
    --details --type package -- "$n" 2>/dev/null \
    | awk -v n="$n" '
        /<solvable / {
          nm = $0; sub(/.* name="/, "", nm); sub(/".*/, "", nm)
          ed = $0; sub(/.* edition="/, "", ed); sub(/".*/, "", ed)
          if (nm == n && !e) e = ed
          if (!f) f = ed
        }
        END { print (e ? e : f) }') || true
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_zypper_install NAME…   — installs exactly these, without recommends.
#   Honours --dry-run. Returns zypper's status.
_pkg_zypper_install() {
  run_sudo zypper --non-interactive install --no-recommends -- "$@"
}

# _pkg_zypper_install_local RPMFILE   — pkg_install_local on zypper.
#   --allow-unsigned-rpm: a release rpm is mostly unsigned, and zypper would stop
#   to ask about it; the file was checksum-verified by its caller (lib/net.sh),
#   which is the same trust apt gives a downloaded .deb. It says nothing about
#   repository keys, which stay as strict as above.
#   Honours --dry-run. Returns 1 when the install fails.
_pkg_zypper_install_local() {
  local f=${1:?pkg_install_local: RPMFILE required} abs
  [ -r "$f" ] || {
    log_error "no such .rpm: $f"
    return 1
  }
  case $f in
    *.rpm) ;;
    *)
      log_error "zypper installs a .rpm, not $(basename -- "$f")"
      return 1
      ;;
  esac
  abs=$(readlink -f -- "$f")
  pkg_update
  # A release .rpm is signed with its vendor's key, which no repository here
  # imports (kubecolor, openbao), and zypper refuses it with exit 8. The file was
  # sha256-verified against the release's published digest before it got here
  # (001 FR-017), the same trust a .deb gets from dpkg and a local .rpm gets from
  # dnf (localpkg_gpgcheck=0). --no-refresh keeps this one transaction on the
  # metadata the last verified refresh fetched.
  run_sudo zypper --non-interactive --no-gpg-checks --no-refresh install --no-recommends \
    --allow-unsigned-rpm -- "$abs" || {
    log_error "zypper refused to install $abs (unsatisfiable dependencies)"
    return 1
  }
  changed "rpm install $(basename -- "$abs")"
  return 0
}

# _pkg_zypper_hint VERB   — the operator's spelling: zypper has no purge.
_pkg_zypper_hint() {
  case ${1:?_pkg_zypper_hint: VERB required} in
    purge) printf 'zypper remove\n' ;;
    upgrade) printf 'zypper update\n' ;;
    *) printf 'zypper %s\n' "$1" ;;
  esac
}

# _pkg_zypper_remove VERB NAME…   — behind pkg_remove/pkg_purge's opt-in only.
_pkg_zypper_remove() {
  shift
  run_sudo zypper --non-interactive remove -- "$@"
}

# _pkg_zypper_upgrade_all   — pkg_upgrade on zypper, once it has been opted into.
#   `zypper update`, not `dup`: Leap is a release, not a rolling one. A run with
#   nothing listed by list-updates records no change.
#   Honours --dry-run. Always returns 0.
_pkg_zypper_upgrade_all() {
  local pending
  pkg_update --force
  pending=$(zypper --non-interactive --no-refresh --xmlout list-updates 2>/dev/null \
    | awk '/<update / {c++} END {print c + 0}') || pending=0
  if [ "${pending:-0}" = 0 ]; then
    log_debug "zypper: nothing to update"
    return 0
  fi
  run_sudo zypper --non-interactive update --no-recommends || {
    log_warn "zypper update failed"
    return 0
  }
  changed "system upgrade"
  return 0
}

# _pkg_zypper_upgrade_one NAME   — pkg_upgrade_one on zypper.
#   `zypper update NAME` installs nothing new. Whether there IS an update is
#   zypper's own answer (list-updates), not a version comparison here: rpm
#   orders 20241218+leap-lp160.1.1 after 20241218-lp160.5.1, a sort -V does not.
#   That is what keeps a second run from recording a change. Honours --dry-run.
#   Returns 0, or 1 when the update failed (warned).
_pkg_zypper_upgrade_one() {
  local name pkg cur cand
  name=${1:?pkg_upgrade_one: NAME required}
  pkg=$(_pkg_rpm_name "$name") || return 0
  pkg_update
  cur=$(_pkg_rpm_version "$pkg") || return 0
  cand=$(zypper --non-interactive --no-refresh --xmlout list-updates 2>/dev/null \
    | awk -v n="$pkg" '
        /<update / && index($0, " name=\"" n "\"") && !v && match($0, / edition="[^"]*"/) {
          v = substr($0, RSTART + 10, RLENGTH - 11)
        }
        END { print v }') || cand=''
  if [ -z "$cand" ]; then
    log_debug "$pkg $cur is already the newest the repositories offer"
    return 0
  fi
  log_info "$pkg $cur -> $cand (following the configured stream)"
  run_sudo zypper --non-interactive update --no-recommends -- "$pkg" || {
    log_warn "could not upgrade $pkg to $cand — leaving $cur in place"
    return 1
  }
  changed "zypper upgrade $pkg $cand"
  return 0
}

# _pkg_zypper_mark_manual NAME…
#   Nothing to do. zypper removes a package only when told to, and drops the
#   dependencies nobody needs only under an explicit `zypper remove
#   --clean-deps` — there is no implicit autoremove for a mark to protect from,
#   and zypper has no command that sets one. Returns 0.
_pkg_zypper_mark_manual() {
  log_debug "zypper never auto-removes a package — nothing to mark: $*"
  return 0
}

# _pkg_zypper_ensure_addon   — nothing: Leap's own repo-oss carries the catalog,
#   and openSUSE's add-on repositories (Packman, OBS projects) are third-party
#   sources, which lib/repo.sh adds one by one with a verified key or not at all.
_pkg_zypper_ensure_addon() {
  log_debug "openSUSE needs no add-on repository"
  return 0
}
