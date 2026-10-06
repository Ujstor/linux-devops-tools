# shellcheck shell=bash
# lib/pkg_apt.sh — the apt backend of lib/pkg.sh: Debian and Ubuntu.
#
# linux-devops-tools :: shared library. Sourced by lib/pkg.sh only.
#
# THIS IS THE CODE lib/pkg.sh WAS BEFORE IT LEARNED OTHER FAMILIES, MOVED HERE
# VERBATIM (spec 002 FR-008). The Debian family must install the same packages,
# write the same files and add the same sources as before, so every body below is
# the old public function's body under its `_pkg_apt_<op>` name. Change one only
# for a reason that is about apt itself, never to make it look like its siblings.
#
# Rules that hold everywhere in this file:
#   * `apt-get` only. `apt` is explicitly not a stable scripting interface, and
#     `nala` is a FRONT-END, used only when it already exists and only for
#     `pkg_upgrade` (K20). The old repo's usenala.sh redefined the `sudo` and `apt`
#     SHELL FUNCTIONS; that is gone and must never come back (SPEC 8).
#   * Never add a repository, backport or suite to obtain nala.
#   * Every apt invocation goes through run_sudo, so --dry-run mutates nothing.

[ -n "${_DEVENV_PKG_APT:-}" ] && return 0
_DEVENV_PKG_APT=1

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Keep the admin's conffiles. --force-confdef+--force-confold is the only safe
# unattended combination: it never asks and never overwrites a modified conffile.
_APT_OPTS=(-y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef)

# _apt_get ARG…   (private)
#   apt-get as root, with the non-interactive environment ATTACHED TO THE COMMAND
#   rather than merely exported into this shell.
#
#   THE EXPORTS ABOVE DO NOT SURVIVE sudo. `env_reset` is the default sudoers
#   policy on Debian and Ubuntu, and it drops every variable that is not in
#   `env_keep` — DEBIAN_FRONTEND and NEEDRESTART_MODE are not. So `run_sudo
#   apt-get install …` reaches root with an *interactive* debconf frontend, and on
#   Ubuntu 22.04 the first package that pulls tzdata stops dead on
#
#       1. Africa   2. America   …
#       Geographic area:
#
#   waiting for input that an unattended `--yes` install will never provide. That
#   is not theoretical: it hung the container matrix on ubuntu:22.04 until the run
#   was killed. Every apt-get in this file goes through here.
#
#   The exports are still needed for the unprivileged half of the library
#   (apt-cache, dpkg-query) and for a run that is already root.
#
#   DPkg::Lock::Timeout: wait up to ten minutes for the dpkg lock instead of
#   failing at once. A freshly booted Ubuntu runs unattended-upgrades within
#   minutes, and on the Ubuntu 24.04 lab guest it held the lock through the shell
#   module: zoxide, gdu, 7zip and git-delta each failed with "Could not get lock
#   /var/lib/dpkg/lock-frontend … held by unattended-upgr", and the second run
#   installed them. apt older than 1.9.11 ignores the option.
#   Honours --dry-run through run_sudo. Returns apt-get's status.
_apt_get() {
  run_sudo env \
    DEBIAN_FRONTEND=noninteractive \
    DEBCONF_NONINTERACTIVE_SEEN=true \
    NEEDRESTART_MODE=a \
    apt-get -o DPkg::Lock::Timeout=600 "$@"
}

# _pkg_apt_refresh [--force]   — pkg_update on apt.
#   Refreshes the apt index at most ONCE per run (state in $DEVENV_RUNDIR), unless
#   --force is given or a repo helper set NEED_APT_UPDATE=1.
#   Honours --dry-run. Returns apt-get's status; a failure is the caller's problem.
_pkg_apt_refresh() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  if [ "${NEED_APT_UPDATE:-0}" = 1 ]; then force=1; fi
  local stamp="${DEVENV_RUNDIR:-/nonexistent}/apt-updated"
  if [ "$force" = 0 ] && [ -f "$stamp" ]; then
    log_debug "apt index already refreshed this run"
    return 0
  fi
  log_info "refreshing the apt package index"
  _apt_get update -qq || {
    log_warn "apt-get update reported an error — continuing with the cached index"
    return 0
  }
  [ -d "${DEVENV_RUNDIR:-}" ] && : >"$stamp"
  NEED_APT_UPDATE=0
  export NEED_APT_UPDATE
  return 0
}

# _pkg_apt_prepare   — nothing: apt answers from the index it has, as it always did.
_pkg_apt_prepare() { return 0; }

# _pkg_apt_installed PKG
#   Returns 0 when PKG is installed (dpkg status "installed"). Read-only predicate.
_pkg_apt_installed() {
  local st
  st=$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) || return 1
  [ "$st" = installed ]
}

# _pkg_apt_installed_version PKG   — dpkg's version of an installed PKG. Read-only.
_pkg_apt_installed_version() {
  local v
  _pkg_apt_installed "${1-}" || return 1
  v=$(dpkg-query -W -f='${Version}' "$1" 2>/dev/null) || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_apt_candidate PKG
#   Prints apt's candidate version for PKG, or nothing when there is none.
#   Returns 1 when there is no candidate. Read-only.
_pkg_apt_candidate() {
  local v
  have apt-cache || return 1
  # NO `exit` IN THE awk PROGRAM. `awk '/Candidate:/ {print $2; exit}'` closes the
  # pipe while apt-cache is still writing, apt-cache dies of SIGPIPE, and under
  # `set -o pipefail` — which EVERY module and bin/devenv set — the command
  # substitution's status is 141. This function then returned 1, `pkg_available`
  # answered "no candidate", and `pkg_install` SILENTLY DROPPED a package that is
  # perfectly installable. Reproduced on ubuntu 24.04, where mtr-tiny, traceroute,
  # tcpdump and sshpass were each dropped with "no installation candidate" while
  # `apt-cache policy` listed a candidate for all four.
  # Reading the whole stream and printing in END costs nothing and cannot SIGPIPE.
  v=$(apt-cache policy -- "$1" 2>/dev/null | awk '/Candidate:/ {v = $2} END {print v}') || return 1
  case ${v:-} in '' | '(none)') return 1 ;; esac
  printf '%s\n' "$v"
}

# _pkg_apt_install PKG…
#   The install itself, once pkg_install has filtered the list. Never recommends.
#   Honours --dry-run. Returns 1 when apt-get fails.
_pkg_apt_install() {
  _apt_get install "${_APT_OPTS[@]}" --no-install-recommends -- "$@" || return 1
}

# _apt_can_read PATH   (private)
#   Returns 0 when PATH and every directory above it are open to `other` — that is,
#   when apt's unprivileged sandbox user `_apt` can open the file for itself.
#
#   Mode bits, not a live `sudo -u _apt test -r`: dropping to another uid needs
#   root, and this question is asked BEFORE any privilege is acquired (a plain
#   `devenv --dry-run`, or a box with no sudo, must still answer it). An ACL that
#   grants _apt what the mode bits do not is therefore read as "no" — the only cost
#   of that is one needless copy of a file we were about to install anyway.
#
#   `stat -c %A` is used rather than %a because its output is fixed-width from the
#   left: index 7 is other-read, index 9 other-execute, and a trailing ACL "+" or
#   SELinux "." cannot shift them. `t` counts as `x` — /tmp is drwxrwxrwt.
#   Read-only; safe under --dry-run.
_apt_can_read() {
  local p=${1:?_apt_can_read: PATH required} mode d
  mode=$(stat -Lc '%A' -- "$p" 2>/dev/null) || return 1
  [ "${mode:7:1}" = r ] || return 1
  d=${p%/*}
  [ -n "$d" ] || d=/
  while :; do
    mode=$(stat -Lc '%A' -- "$d" 2>/dev/null) || return 1
    case ${mode:9:1} in
      x | t) ;;
      *) return 1 ;;
    esac
    [ "$d" = / ] && break
    d=${d%/*}
    [ -n "$d" ] || d=/
  done
  return 0
}

# _apt_stage_deb DEBFILE   (private)
#   Prints the path of a copy of DEBFILE that `_apt` can read; returns 1 when no
#   such copy could be made. The caller owns the printed path and must remove its
#   directory. Never called under --dry-run (it writes).
#
#   $TMPDIR is deliberately NOT honoured: on the boxes that need this at all it is
#   as likely as not to point back inside $HOME, which is the thing being worked
#   around. /var/tmp first (it is rarely a size-limited tmpfs, and a .deb can be
#   hundreds of MB), then /tmp. Both are 1777 on every supported system; a hardened
#   host may mount them noexec and nosuid, which is irrelevant here — apt only ever
#   READS this file, and dpkg unpacks into / from it.
_apt_stage_deb() {
  local src=${1:?_apt_stage_deb: DEBFILE required} dir='' cand base
  base=$(basename -- "$src")
  for cand in /var/tmp /tmp; do
    # An explicit `if`, not `[ ] && [ ] || continue`: shellcheck 0.9 flags that
    # shape as SC2015 (the `||` also fires when the first test passes and the
    # second fails, which is exactly what is meant here — but the linter cannot
    # know that, and CI runs 0.9).
    if [ ! -d "$cand" ] || [ ! -w "$cand" ]; then
      continue
    fi
    dir=$(mktemp -d "$cand/devenv-deb.XXXXXXXX" 2>/dev/null) && break
    dir=''
  done
  [ -n "$dir" ] || return 1
  # mktemp -d gives 0700, which is exactly the problem being solved.
  chmod 0755 "$dir" 2>/dev/null || :
  if ! cp -- "$src" "$dir/$base" 2>/dev/null; then
    rm -rf -- "$dir"
    return 1
  fi
  chmod 0644 "$dir/$base" 2>/dev/null || :
  if ! _apt_can_read "$dir/$base"; then
    rm -rf -- "$dir"
    return 1
  fi
  printf '%s\n' "$dir/$base"
}

# _pkg_apt_install_local DEBFILE   — pkg_install_local on apt.
#   Installs a local .deb.
#   idempotency F16: uses `apt-get install ./file.deb`, which resolves dependencies
#   UP FRONT and fails cleanly. `dpkg -i` followed by `apt-get -f install -y` is
#   forbidden here: it is allowed to REMOVE packages to repair the broken state it
#   created, unattended, after a third-party .deb.
#
#   THE SANDBOX. Every .deb this repository installs is downloaded to
#   $DEVENV_CACHE/dl, i.e. under $HOME, which is 0750 on Ubuntu. apt hands local
#   files to its `copy:` method, which runs as the unprivileged user `_apt`, so
#   every single install printed
#
#       N: Download is performed unsandboxed as root as file
#          '/home/<user>/.cache/devops-env/dl/<pkg>.deb' couldn't be accessed by
#          user '_apt'.
#
#   — apt telling us it had switched its own privilege separation OFF because it
#   could not read the file otherwise. Observed for k9s, kubecolor, dive, grpcurl,
#   openbao and glab on a real install. The fix is a world-readable copy in
#   /var/tmp for the duration of the install, removed afterwards. NOT `chmod o+x
#   $HOME`: the sandbox is worth less than the home directory's permissions.
#   Honours --dry-run. Returns non-zero when the install fails.
_pkg_apt_install_local() {
  local deb=${1:?pkg_install_local: DEBFILE required} abs staged='' stagedir='' rc=0
  [ -r "$deb" ] || {
    log_error "no such .deb: $deb"
    return 1
  }
  abs=$(readlink -f -- "$deb")
  local target=$abs

  if ! is_dry_run && ! _apt_can_read "$abs"; then
    if staged=$(_apt_stage_deb "$abs"); then
      stagedir=${staged%/*}
      target=$staged
      log_debug "installing from $staged — apt's sandbox user cannot read $abs"
    else
      log_debug "no world-readable staging directory: apt will drop its download sandbox for $abs"
    fi
  fi

  pkg_update
  _apt_get install "${_APT_OPTS[@]}" -- "$target" || rc=$?
  if [ -n "$stagedir" ]; then
    rm -rf -- "$stagedir"
  fi
  if [ "$rc" -ne 0 ]; then
    log_error "apt-get refused to install $abs (unsatisfiable dependencies)"
    return 1
  fi
  changed "dpkg install $(basename -- "$abs")"
  return 0
}

# _pkg_apt_hint VERB   — prints the operator's spelling of VERB (install, remove,
#   purge, upgrade) on apt, for messages that tell a human what to run.
_pkg_apt_hint() { printf 'apt-get %s\n' "${1:?_pkg_apt_hint: VERB required}"; }

# _pkg_apt_remove VERB PKG…   — the removal behind pkg_remove/pkg_purge, which
#   decide whether it may happen at all. VERB is remove or purge.
#   Honours --dry-run. Returns apt-get's status.
_pkg_apt_remove() {
  local verb=${1:?_pkg_apt_remove: VERB required}
  shift
  _apt_get "$verb" "${_APT_OPTS[@]}" -- "$@"
}

# _pkg_apt_upgrade_all   — pkg_upgrade on apt, once it has been opted into.
#   A full upgrade, and the ONE place `nala` may be used as a front-end.
#   Honours --dry-run. Always returns 0.
_pkg_apt_upgrade_all() {
  pkg_update --force
  if [ "${PKG_FRONTEND:-apt}" = nala ] && have nala; then
    run_sudo nala upgrade -y || log_warn "nala upgrade failed"
  else
    _apt_get upgrade "${_APT_OPTS[@]}" || log_warn "apt-get upgrade failed"
  fi
  changed "system upgrade"
  return 0
}

# _pkg_apt_upgrade_one PKG   — pkg_upgrade_one on apt (formerly
#   modules/35-kubernetes.sh's k8s_apt_upgrade_to_candidate).
#   Moves an ALREADY-INSTALLED package to the candidate of the repositories that
#   are configured right now, and installs nothing new: `--only-upgrade` is the one
#   apt operation pkg_install does not express. Idempotent: nothing happens once
#   the installed version is >= the candidate.
#   Honours --dry-run. Returns 0, or 1 when apt-get failed (a warning is logged).
_pkg_apt_upgrade_one() {
  local pkg=${1:?pkg_upgrade_one: PKG required} cur cand
  have dpkg-query || return 0
  _pkg_apt_installed "$pkg" || return 0
  pkg_update
  cur=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null) || return 0
  cand=$(_pkg_apt_candidate "$pkg") || return 0
  if version_ge "$cur" "$cand"; then
    log_debug "$pkg $cur is already at or above the candidate $cand"
    return 0
  fi
  log_info "$pkg $cur -> $cand (following the configured stream)"
  _apt_get install "${_APT_OPTS[@]}" --only-upgrade -- "$pkg" || {
    log_warn "could not upgrade $pkg to $cand — leaving $cur in place"
    return 1
  }
  changed "apt upgrade $pkg $cand"
  return 0
}

# _pkg_apt_mark_manual PKG…   — pkg_mark_manual on apt.
#   `apt-mark manual` for the installed names that apt still holds as
#   automatically installed, so that an autoremove cannot take them. A name that
#   is already manual, or not installed, is left alone — a second run is silent.
#   Honours --dry-run. Returns 1 when apt-mark failed.
_pkg_apt_mark_manual() {
  local p todo=() manual=''
  manual=$(apt-mark showmanual "$@" 2>/dev/null) || manual=''
  for p in "$@"; do
    _pkg_apt_installed "$p" || continue
    if grep -Fxq -- "$p" <<<"$manual"; then continue; fi
    todo+=("$p")
  done
  [ ${#todo[@]} -gt 0 ] || return 0
  run_sudo apt-mark manual "${todo[@]}" >/dev/null || return 1
  changed "apt-mark manual ${todo[*]}"
  return 0
}

# _pkg_apt_ensure_addon   — pkg_ensure_addon on apt: Ubuntu's `universe`.
#   Ubuntu only: makes sure the `universe` component is enabled, because half the
#   catalog (wslu, tealdeer, resvg, …) lives there. deb822-aware: it edits nothing
#   when universe is already configured, and it installs
#   software-properties-common ONLY when `add-apt-repository` is genuinely needed.
#   idempotency F24e: the distro's own ubuntu.sources is backed up before any edit.
#   No-op on Debian. Honours --dry-run. Always returns 0.
_pkg_apt_ensure_addon() {
  os_is_ubuntu || return 0
  # Read whole, never `| grep -q`: once the vendor sources are configured the
  # policy outgrows a pipe buffer, grep's early exit SIGPIPEs apt-cache, pipefail
  # reads that as "no universe", and the second run installed
  # software-properties-common (and dbus, packagekit, gpg…) on Ubuntu 22.04.
  local policy
  policy=$(apt-cache policy 2>/dev/null) || policy=''
  if [[ $policy == */universe* ]]; then
    log_debug "universe is already enabled"
    return 0
  fi
  local src=/etc/apt/sources.list.d/ubuntu.sources
  if [ -f "$src" ] && grep -q '^Components:' "$src"; then
    local tmp
    tmp=$(devenv_tmpfile) || return 0
    awk '/^Components:/ && $0 !~ /universe/ { print $0 " universe"; next } { print }' "$src" >"$tmp"
    if ! cmp -s -- "$tmp" "$src"; then
      backup_file "$src" >/dev/null
      write_if_changed "$src" 0644 <"$tmp"
      NEED_APT_UPDATE=1
      export NEED_APT_UPDATE
      pkg_update --force
    fi
    return 0
  fi
  if ! have add-apt-repository; then
    pkg_install software-properties-common || return 0
  fi
  run_sudo add-apt-repository -y universe || log_warn "could not enable the universe component"
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  pkg_update --force
  return 0
}
