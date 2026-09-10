#!/usr/bin/env bash
# meta: name=preflight
# meta: desc=distribution support check, the bootstrap package set and the XDG directories
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=no
#
# The first module in every profile. It decides whether this box is one this
# repository actually targets, tells the user what it found, makes the three
# directories every later module writes into, and installs the handful of
# packages nothing else can work without.
#
# WHY `root=no` WHEN SPEC §5.5 SAYS `root=yes` (MUST-FIX P1 + S14 win over SPEC,
# see scratchpad/PRECEDENCE.md):
#
#   A `root=yes` meta gate makes `module_gate` call `have_root` BEFORE the module
#   starts. On stock Debian — no `sudo` package, user not in a sudo group — the
#   whole of preflight would then be gated out, and the first thing the user sees
#   is the run silently skipping its own first step. That is precisely the
#   "obscure failure" P1 exists to prevent.
#
#   So this module is declared root=no and asks for privilege ITSELF, and only
#   when it has something to do with it: the bootstrap set is compared against
#   what is installed first, and `have_root` is not called at all when nothing is
#   missing. A box that already has curl/git/tar therefore never sees a password
#   prompt from preflight (S14), and a box that is missing something gets one
#   explicit, actionable paragraph naming the two ways out.
#
# What it deliberately does NOT do:
#   * `sudo -v` up front "to get it out of the way"          (S14)
#   * install anything beyond the five bootstrap packages    (05-base-packages)
#   * touch /etc/wsl.conf                                    (70-wsl, opt-in)
#   * remove or rewrite an apt source it did not recognise   (S9)
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# The set every other module assumes exists. Deliberately tiny: `install.sh`
# already needed curl or git to get here, so this is about the remainder.
#   ca-certificates  every https:// fetch in lib/net.sh and lib/repo.sh
#   curl             lib/net.sh's only transport
#   git              devenv_sync_repo, `devenv update`, krew
#   tar              every release tarball
#   xz-utils         several vendors ship .tar.xz (neovim, shellcheck)
BOOTSTRAP_PKGS=(ca-certificates curl git tar xz-utils)

# missing_bootstrap
#   Prints the bootstrap packages that are neither installed nor already on PATH,
#   one per line. Prints nothing when the box is complete. Always returns 0.
#   The PATH check matters: a package may be absent from dpkg's database and the
#   command still be present (a container image built with a different base, a
#   binary in /usr/local). Installing over that would be noise, not a fix.
missing_bootstrap() {
  local p cmd
  for p in "${BOOTSTRAP_PKGS[@]}"; do
    case $p in
      ca-certificates)
        [ -e /etc/ssl/certs/ca-certificates.crt ] && continue
        cmd=''
        ;;
      xz-utils) cmd=xz ;;
      *) cmd=$p ;;
    esac
    if [ -n "$cmd" ] && have "$cmd"; then continue; fi
    pkg_installed "$p" && continue
    printf '%s\n' "$p"
  done
  return 0
}

# ensure_bootstrap
#   Installs whatever `missing_bootstrap` reports, acquiring privilege only if
#   there is something to install. Returns 0 when the box is usable afterwards,
#   and 78 (via `skip`) when packages are missing and root is not available —
#   the run then continues with the modules that need no root.
ensure_bootstrap() {
  local -a missing=()
  mapfile -t missing < <(missing_bootstrap)
  if [ ${#missing[@]} -eq 0 ]; then
    log_skip "the bootstrap set is already installed: ${BOOTSTRAP_PKGS[*]}"
    return 0
  fi

  log_info "missing from the bootstrap set: ${missing[*]}"
  if ! have_root; then
    # need_sudo has already printed the two ways out. Add what it costs here.
    log_error "preflight cannot install ${missing[*]} without root."
    log_error "Modules that need no root (shell, git config, k9s-config) will still run."
    skip "the bootstrap packages ${missing[*]} are missing and root is not available"
  fi
  pkg_install "${missing[@]}" || {
    log_error "could not install ${missing[*]} — later modules will fail on their own"
    return 1
  }
  changed "bootstrap packages: ${missing[*]}"
  return 0
}

# ensure_xdg_dirs
#   $DEVENV_CONFIG / $DEVENV_CACHE / $DEVENV_STATE. Everything below $HOME, so
#   this needs no privilege and runs on a box with no sudo at all.
ensure_xdg_dirs() {
  local d
  for d in "$DEVENV_CONFIG" "$DEVENV_CACHE" "$DEVENV_STATE"; do
    ensure_dir "$d" 0755 || log_warn "could not create $d"
  done
  return 0
}

# report_container
#   A container is a legitimate target — tests/docker runs the whole `ci` profile
#   in one — but three module families cannot work there, and saying so once here
#   is better than four separate "skipped" lines with no explanation.
report_container() {
  os_is_container || return 0
  log_info "this is a container (init=${INIT_SYSTEM:-none}) — docker-in-docker, systemd units"
  log_info "  and the WSL layer are gated out by their own os= meta, not by an error"
  return 0
}

module_main() {
  os_require_supported || die "linux-devops-tools targets Debian and Ubuntu; this box is ${OS_PRETTY:-unknown}"

  # bin/devenv prints this once for the whole run. Standalone
  # (`DEVENV_HOME=$PWD ./modules/00-preflight.sh`) nobody has, so print it here.
  [ -n "${DEVENV_MODULE:-}" ] || os_summary

  report_container
  ensure_xdg_dirs
  ensure_bootstrap

  # Ubuntu only, and only when `universe` is genuinely not enabled: bat, fd-find,
  # ripgrep and wslu all live there. A no-op on Debian.
  pkg_ensure_universe

  # Removes the stale .list/keyring pairs the OLD repo left behind so that
  # `apt update` stops warning about duplicate sources. Reports every removal,
  # honours --dry-run, and never touches a source it does not recognise.
  repo_migrate_legacy

  return 0
}

module_main "$@"
