# shellcheck shell=bash
# lib/pkg_dnf.sh — the dnf backend of lib/pkg.sh: AlmaLinux, Rocky Linux, Fedora.
#
# linux-devops-tools :: shared library. Sourced by lib/pkg.sh only, which owns the
# policy and the contract (see its header); this file is mechanism.
#
# ONE SPELLING FOR TWO PROGRAMS. EL9 and EL10 run dnf 4; Fedora 43 and 44 run
# dnf5, which is a rewrite with the same name. Every command here is spelled so
# that both accept it, and each of these was found by running it on all six
# releases:
#   * no `--` before package names. dnf5 5.2 (Fedora 43) rejects it outright:
#       Unknown argument "--" for command "install".
#     Names come from the modules and config/packages.map, never from user input.
#   * `--qf` with an explicit `\n`, blank lines dropped: dnf5 adds no newline of
#     its own, dnf 4 adds one more.
#   * every read is `dnf -C`. As a non-root user that reads the SYSTEM metadata
#     cache; without it dnf downloads its own copy — 107 MB into ~/.cache on a
#     fresh fedora:43, for one question. A missing cache is exit 1; "no such
#     package" is exit 0 with no output.
#   * names are matched by what packages PROVIDE (`rpm -q --whatprovides`,
#     `repoquery --whatprovides`), which is how `dnf install` resolves them too:
#     Fedora's `wget` is wget2-wget, EL9's `curl` is curl-minimal.
#   * install_weak_deps=False is the dnf spelling of apt's --no-install-recommends.

[ -n "${_DEVENV_PKG_DNF:-}" ] && return 0
_DEVENV_PKG_DNF=1

# _pkg_dnf_is5   (private) — 0 when `dnf` is dnf5 (Fedora 41 and later).
#   Asked once a process: every cache read below asks it.
_pkg_dnf_is5() {
  if [ -z "${_PKG_DNF_IS5:-}" ]; then
    case $(dnf --version 2>/dev/null) in dnf5*) _PKG_DNF_IS5=yes ;; *) _PKG_DNF_IS5=no ;; esac
  fi
  [ "$_PKG_DNF_IS5" = yes ]
}

# _pkg_dnf_read ARGS…   (private) — `dnf -q -C ARGS…`, the one spelling of every
#   read from the system metadata cache.
#   dnf5, not root: a repository with repo_gpgcheck=1 (Docker's) fails to load
#   from the system cache with a bare "std::exception" in ~/.local/state/dnf5.log
#   and is skipped, so its packages had no candidate at all — every docker
#   package on the Fedora lab guests. A read therefore does not re-check the
#   metadata signature: root checked it when makecache downloaded the cache, the
#   cache is root's and not writable from here, and every install runs as root
#   with repo_gpgcheck in force. Reads only; dnf 4 and root need none of this.
_pkg_dnf_read() {
  if ! is_root && _pkg_dnf_is5; then
    dnf -q -C --setopt='*.repo_gpgcheck=0' "$@"
  else
    dnf -q -C "$@"
  fi
}

# _pkg_dnf_refresh [--force]   — pkg_update on dnf: `dnf makecache`, once a run.
#   makecache downloads only what has expired, so a refresh of a fresh cache costs
#   one metadata check. Honours --dry-run. Returns 0.
_pkg_dnf_refresh() {
  local force=0
  [ "${1:-}" = --force ] && force=1
  _pkg_refresh_once 'dnf metadata cache' "$force" dnf -y -q makecache
}

# _pkg_dnf_prepare
#   Every candidate query below reads the system cache with -C, and a box that
#   has never run dnf as root has none — every name would then look like it had
#   no candidate. So the first install with work to do refreshes it first (once a
#   run; a no-op the second time). Returns 0.
_pkg_dnf_prepare() { pkg_update; }

# _pkg_dnf_installed NAME   — 0 when an installed package provides NAME. Read-only.
_pkg_dnf_installed() { _pkg_rpm_installed "${1-}"; }

# _pkg_dnf_installed_version NAME   — VERSION-RELEASE of the provider. Read-only.
_pkg_dnf_installed_version() { _pkg_rpm_version "${1-}"; }

# _pkg_dnf_candidate NAME
#   Prints VERSION-RELEASE of the newest package that provides NAME — the one
#   named NAME when there is one, else the first provider. Returns 1 when there is
#   none, or when there is no metadata cache to ask. Read-only, no network.
_pkg_dnf_candidate() {
  local n=${1-} v
  [ -n "$n" ] || return 1
  v=$(_pkg_dnf_read repoquery --latest-limit=1 --qf '%{name} %{version}-%{release}\n' --whatprovides "$n" 2>/dev/null \
    | awk -v n="$n" 'NF >= 2 { if ($1 == n && !e) e = $2; if (!f) f = $2 } END { print (e ? e : f) }') || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# _pkg_dnf_install NAME…   — installs exactly these, without weak dependencies.
#   Honours --dry-run. Returns dnf's status.
_pkg_dnf_install() {
  run_sudo dnf -y install --setopt=install_weak_deps=False "$@"
}

# _pkg_dnf_install_local RPMFILE   — pkg_install_local on dnf.
#   dnf resolves the file's dependencies from the configured repositories up
#   front, like `apt-get install ./file.deb`, and fails cleanly when it cannot.
#   The file was checksum-verified by its caller (lib/net.sh); release rpms are
#   mostly unsigned, and dnf does not check a local file's signature by default.
#   root reads the file in place, so there is no sandbox to stage around.
#   Honours --dry-run. Returns 1 when the install fails.
_pkg_dnf_install_local() {
  local f=${1:?pkg_install_local: RPMFILE required} abs
  [ -r "$f" ] || {
    log_error "no such .rpm: $f"
    return 1
  }
  case $f in
    *.rpm) ;;
    *)
      log_error "dnf installs a .rpm, not $(basename -- "$f")"
      return 1
      ;;
  esac
  abs=$(readlink -f -- "$f")
  pkg_update
  run_sudo dnf -y install --setopt=install_weak_deps=False "$abs" || {
    log_error "dnf refused to install $abs (unsatisfiable dependencies)"
    return 1
  }
  changed "rpm install $(basename -- "$abs")"
  return 0
}

# _pkg_dnf_hint VERB   — the operator's spelling: dnf has no purge.
_pkg_dnf_hint() {
  case ${1:?_pkg_dnf_hint: VERB required} in
    purge) printf 'dnf remove\n' ;;
    *) printf 'dnf %s\n' "$1" ;;
  esac
}

# _pkg_dnf_remove VERB NAME…   — behind pkg_remove/pkg_purge's opt-in only.
_pkg_dnf_remove() {
  shift
  run_sudo dnf -y remove "$@"
}

# _pkg_dnf_upgrade_all   — pkg_upgrade on dnf, once it has been opted into.
#   `dnf check-update` exits 100 when there is something to upgrade and 0 when
#   there is not; only the first is a change, so a second --upgrade run is silent.
#   Honours --dry-run. Always returns 0.
_pkg_dnf_upgrade_all() {
  local rc=0
  pkg_update --force
  _pkg_dnf_read check-update >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    log_debug "dnf: nothing to upgrade"
    return 0
  fi
  run_sudo dnf -y upgrade || {
    log_warn "dnf upgrade failed"
    return 0
  }
  changed "system upgrade"
  return 0
}

# _pkg_dnf_upgrade_one NAME   — pkg_upgrade_one on dnf.
#   `dnf upgrade NAME` already installs nothing new; check-update (exit 100 =
#   newer available) is what keeps a second run from recording a change.
#   Honours --dry-run. Returns 0, or 1 when the upgrade failed (warned).
_pkg_dnf_upgrade_one() {
  local name pkg cur cand rc=0
  name=${1:?pkg_upgrade_one: NAME required}
  pkg=$(_pkg_rpm_name "$name") || return 0
  pkg_update
  _pkg_dnf_read check-update "$pkg" >/dev/null 2>&1 || rc=$?
  cur=$(_pkg_rpm_version "$pkg") || cur='?'
  if [ "$rc" != 100 ]; then
    log_debug "$pkg $cur is already the newest the repositories offer"
    return 0
  fi
  cand=$(_pkg_dnf_candidate "$pkg") || cand='?'
  log_info "$pkg $cur -> $cand (following the configured stream)"
  run_sudo dnf -y upgrade "$pkg" || {
    log_warn "could not upgrade $pkg to $cand — leaving $cur in place"
    return 1
  }
  changed "dnf upgrade $pkg $cand"
  return 0
}

# _pkg_dnf_mark_manual NAME…   — pkg_mark_manual on dnf: user-installed, which
#   `dnf autoremove` never takes. dnf 4 says `mark install`, dnf5 `mark user`.
#   Names already user-installed, or not installed, are left alone.
#   Honours --dry-run. Returns 1 when dnf refused.
_pkg_dnf_mark_manual() {
  local n pkg user='' todo=()
  user=$(_pkg_dnf_read repoquery --userinstalled --qf '%{name}\n' 2>/dev/null) || user=''
  for n in "$@"; do
    pkg=$(_pkg_rpm_name "$n") || continue
    if grep -Fxq -- "$pkg" <<<"$user"; then continue; fi
    todo+=("$pkg")
  done
  [ ${#todo[@]} -gt 0 ] || return 0
  if _pkg_dnf_is5; then
    run_sudo dnf -y mark user "${todo[@]}" >/dev/null || return 1
  else
    run_sudo dnf -y mark install "${todo[@]}" >/dev/null || return 1
  fi
  changed "dnf mark ${todo[*]} as user-installed"
  return 0
}

# _pkg_dnf_repo_enabled ID   (private)
#   Returns 0 when the repository ID is configured AND enabled in
#   /etc/yum.repos.d. Read from the files, not from `dnf repolist`: the files are
#   what config-manager edits, and reading them needs neither root, nor a cache,
#   nor the network. A section with no enabled= line is enabled (dnf's default).
_pkg_dnf_repo_enabled() {
  local id=${1:?_pkg_dnf_repo_enabled: ID required} f
  for f in /etc/yum.repos.d/*.repo; do
    [ -r "$f" ] || continue
    if awk -v id="$id" '
      /^[[:space:]]*\[/ { s = $0; gsub(/[][[:space:]]/, "", s); in_s = (s == id); if (in_s) { seen = 1; en = "1" }; next }
      in_s && /^[[:space:]]*enabled[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); en = v }
      END { exit !(seen && (en == "1" || en == "true" || en == "True" || en == "yes")) }
    ' "$f"; then
      return 0
    fi
  done
  return 1
}

# _pkg_dnf_ensure_addon   — pkg_ensure_addon on dnf (FR-010).
#   Enterprise Linux (AlmaLinux, Rocky and their kin): CRB, then EPEL. A large
#   part of the catalog — ripgrep, fd-find, bat, fzf, htop, neovim, ShellCheck,
#   gh, ffmpeg-free — is in EPEL there, and EPEL packages are built against CRB,
#   which every EL release ships disabled. Enabling them is the EL form of
#   Ubuntu's `universe`, and reported as a change exactly like it.
#   Fedora carries all of it in its own repositories: nothing to do.
#   `dnf config-manager` is a plugin on dnf 4, installed only when it is missing
#   (Rocky's image has none). No-op once both are in place.
#   Honours --dry-run. Always returns 0.
_pkg_dnf_ensure_addon() {
  case ${OS_DISTRO:-${OS_ID:-}} in
    fedora)
      log_debug "Fedora needs no add-on repository"
      return 0
      ;;
  esac
  if ! _pkg_dnf_repo_enabled crb; then
    if _pkg_dnf_is5; then
      run_sudo dnf config-manager setopt crb.enabled=1 || {
        log_warn "could not enable the CRB repository — some EPEL packages will not install"
        return 0
      }
    else
      if ! dnf config-manager --help >/dev/null 2>&1; then
        pkg_install dnf-plugins-core || {
          log_warn "no dnf config-manager: cannot enable the CRB repository"
          return 0
        }
      fi
      run_sudo dnf config-manager --set-enabled crb || {
        log_warn "could not enable the CRB repository — some EPEL packages will not install"
        return 0
      }
    fi
    changed "enabled the CRB repository"
    # Before anything else asks dnf a question: `dnf -C` refuses to answer at all
    # while one enabled repository has no cache, so the epel-release lookup
    # below would find nothing. NEED_APT_UPDATE makes the next pkg_update real.
    NEED_APT_UPDATE=1
    export NEED_APT_UPDATE
  fi
  if ! pkg_installed epel-release; then
    pkg_install epel-release || {
      log_warn "could not install epel-release — the packages only EPEL carries will be skipped"
      return 0
    }
    if pkg_installed epel-release || is_dry_run; then
      NEED_APT_UPDATE=1
      export NEED_APT_UPDATE
    fi
  fi
  if [ "${NEED_APT_UPDATE:-0}" = 1 ]; then pkg_update; fi
  return 0
}
