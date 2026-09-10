#!/usr/bin/env bash
# meta: name=containers
# meta: desc=docker engine from the vendor apt repository
# meta: profiles=devops,full
# meta: os=!container
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=yes
#
# modules/30-containers.sh — Docker CE, installed the careful way.
#
# FOUR THINGS THIS MODULE DELIBERATELY DOES NOT DO. Each one is a ruled finding,
# not an oversight; do not "fix" any of them.
#
#   1. It never removes containerd, runc, podman-docker, docker.io or
#      docker-compose (MUST-FIX S9). The old scripts/docker.sh purged seven
#      packages unconditionally. containerd and runc are real runtimes that other
#      software on the box may own, and podman-docker is somebody's deliberate
#      choice. Overlaps are DETECTED and REPORTED, and the install then stops
#      until the user resolves them or explicitly allows apt to replace them.
#
#   2. It never writes /etc/wsl.conf (VERIFIED-FACTS 1). The old script wrote the
#      whole file in its non-systemd branch, which would erase `[user] default=`
#      and disable `appendWindowsPath`. Only `modules/70-wsl.sh` touches that
#      file, additively, and it never touches [automount] or [interop] either.
#
#   3. It never adds anyone to the `docker` group behind their back (MUST-FIX
#      S5). Group membership is root-equivalent, so it goes through
#      confirm_dangerous, which refuses under --yes unless
#      DEVENV_ALLOW_DOCKER_GROUP=1 (--allow-docker-group) is set.
#
#   4. It never runs `docker run hello-world` (SPEC 8). That pulls an image into
#      the ROOT image store, needs the daemon up within a timeout on a cold WSL
#      start, and proves nothing about the invoking user's own access. The check
#      is `docker version --format '{{.Server.Version}}'`.

set -euo pipefail
# shellcheck source=lib/common.sh
source "${DEVENV_HOME:?}/lib/common.sh"

# What the vendor repository provides. Compose and buildx are PLUGINS now: the
# standalone `docker-compose` binary is v1 (Python, end-of-life) and is a
# different command from `docker compose`.
CONTAINERS_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# Packages that own /usr/bin/docker, the compose CLI or the OCI runtime, and that
# apt would therefore have to remove to satisfy docker-ce's own Conflicts and
# containerd.io's Replaces. Listed to be REPORTED, never to be removed here.
CONTAINERS_CONFLICTS=(
  docker.io docker-compose docker-compose-v2 docker-doc docker-buildx
  podman-docker containerd runc
)

# apt_run CMD [ARGS…]
#   Runs ONE lib/pkg.sh helper with `pipefail` switched off, and restores it.
#
#   WHY THIS EXISTS. lib/pkg.sh's pkg_candidate_version is
#       v=$(apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}') || return 1
#   The awk `exit` closes the pipe while apt-cache is still writing, apt-cache
#   dies of SIGPIPE, and under `set -o pipefail` — which EVERY module sets — the
#   command substitution's status is 141. pkg_candidate_version therefore returns
#   1, pkg_available says "no candidate", and pkg_install silently DROPS a package
#   that is perfectly installable. Verified on ubuntu 24.04: mtr-tiny, traceroute,
#   tcpdump and sshpass were each dropped with "no installation candidate", while
#   `apt-cache policy` lists a candidate for all four.
#
#   THE ROOT CAUSE IS NOW FIXED IN lib/pkg.sh: pkg_candidate_version reads the
#   whole apt-cache stream and prints in END, so it can no longer SIGPIPE. This
#   wrapper is therefore belt-and-braces — it is still correct, it still costs
#   nothing, and it protects any OTHER lib helper that grows the same shape — but
#   it is no longer load-bearing and may be deleted with its call sites.
#   Returns the wrapped command's exit status.
apt_run() {
  local rc=0
  set +o pipefail
  "$@" || rc=$?
  set -o pipefail
  return "$rc"
}

CONTAINERS_FAILURES=()

# _containers_fail MSG   (private) — record a real failure and keep going.
_containers_fail() {
  CONTAINERS_FAILURES+=("$1")
  log_error "$1"
  return 0
}

# _containers_docker_desktop_note
#   Docker Desktop's WSL integration mounts its own CLI and talks to a daemon on
#   the Windows side. Installing docker-ce next to it gives the shell two
#   `docker` binaries whose precedence depends on PATH order. Warn, do not act.
#   Always returns 0.
_containers_docker_desktop_note() {
  os_is_wsl || return 0
  [ -d /mnt/wsl/docker-desktop ] || return 0
  log_warn "Docker Desktop's WSL integration is active in this distribution."
  log_warn "  Its CLI is mounted from /mnt/wsl/docker-desktop and talks to the"
  log_warn "  Windows-side daemon. Installing docker-ce here gives you two"
  log_warn "  'docker' commands, and which one wins depends on PATH order."
  log_warn "  Either turn the integration off for this distribution in Docker"
  log_warn "  Desktop's settings, or skip this module:  devenv --skip containers"
  return 0
}

# _containers_docker_repo
#   Configures https://download.docker.com/linux/<flavor>.
#
#   THIS DELIBERATELY DOES NOT CALL lib/repo.sh's repo_ensure_docker. That helper
#   writes `Components: main`, and Docker's archive has no `main` component — its
#   Release file publishes `stable edge test nightly` (verified live for both
#   debian/bookworm and ubuntu/noble). apt then says
#       Skipping acquire of configured file 'main/binary-amd64/Packages' as
#       repository '.../linux/debian bookworm InRelease' doesn't have the
#       component 'main'
#   and every docker package is reported as having no installation candidate, on
#   every distribution. Reproduced in debian:12.
#   Switch this function back to repo_ensure_docker the moment lib/repo.sh says
#   `stable`; everything else here is the same logic.
#
#   The suite steps DOWN the vendor's own published list and never up: a trixie
#   box may fall back to bookworm, never forward to forky.
#   Returns 0, 78 when Docker publishes nothing usable for this release, or 1.
_containers_docker_repo() {
  os_is_debian || os_is_ubuntu || {
    log_skip "docker apt repo: unsupported distribution"
    return 78
  }
  [ -n "${OS_UPSTREAM_CODENAME:-}" ] || {
    log_skip "docker apt repo: no upstream codename for ${OS_CODENAME:-unknown}"
    return 78
  }
  local uri="https://download.docker.com/linux/${OS_FLAVOR}" key suite i mine=-1
  local ladder=() cands=()
  if os_is_debian; then
    ladder=(bullseye bookworm trixie forky)
  else
    ladder=(jammy noble oracular plucky questing resolute)
  fi
  for i in "${!ladder[@]}"; do
    if [ "${ladder[i]}" = "$OS_UPSTREAM_CODENAME" ]; then mine=$i; fi
  done
  if [ "$mine" -lt 0 ]; then
    mine=$((${#ladder[@]} - 1))
    log_debug "docker: '$OS_UPSTREAM_CODENAME' is not in the known ladder — starting at '${ladder[mine]}'"
  fi
  for ((i = mine; i >= 0; i--)); do cands+=("${ladder[i]}"); done
  suite=$(repo_suite_pick "$uri" "${cands[@]}") || suite=''
  [ -n "$suite" ] || {
    log_warn "docker publishes no suite for ${OS_FLAVOR} ${OS_UPSTREAM_CODENAME} — skipping the docker repository"
    return 78
  }
  if [ "$suite" != "$OS_UPSTREAM_CODENAME" ]; then
    log_warn "docker has no '$OS_UPSTREAM_CODENAME' suite — falling back to '$suite'"
  fi
  key=$(repo_key docker "$uri/gpg" asc --sha256 "${DOCKER_KEY_SHA256:-}") || return 1
  repo_add docker "$uri" "$suite" stable "$key"
}

# _containers_check_conflicts
#   Reports every installed package that overlaps with docker-ce.
#   Returns 0 when the install may proceed, 1 when the user has to decide first.
#   Removes nothing under any circumstance (MUST-FIX S9).
_containers_check_conflicts() {
  local p present=()
  for p in "${CONTAINERS_CONFLICTS[@]}"; do
    if pkg_installed "$p"; then present+=("$p"); fi
  done
  if [ ${#present[@]} -eq 0 ]; then
    return 0
  fi
  if pkg_installed docker-ce; then
    log_warn "docker-ce is installed alongside: ${present[*]}"
    log_warn "  Nothing here removes them. 'devenv doctor' reports the overlap so"
    log_warn "  you can decide; two container runtimes on one box is a choice, not"
    log_warn "  necessarily a mistake."
    return 0
  fi
  log_warn "these installed packages overlap with docker-ce: ${present[*]}"
  log_warn "  docker-ce Conflicts docker.io, and containerd.io Replaces containerd"
  log_warn "  and runc — so apt would REMOVE them to complete the install."
  log_warn "  This repository never removes a package you installed (MUST-FIX S9),"
  log_warn "  so the docker install stops here."
  log_warn "  Decide yourself, then re-run 'devenv --only containers':"
  log_warn "    sudo apt-get remove ${present[*]}"
  if ! confirm_dangerous "let apt replace ${present[*]} while installing docker-ce?" \
    DEVENV_ALLOW_PKG_REMOVE; then
    log_skip "docker-ce was not installed — the overlap above is unresolved"
    return 1
  fi
  return 0
}

# _containers_service
#   Starts and enables the daemon, branching on INIT_SYSTEM (K26) and NEVER on
#   "is this WSL" — PID 1 on a modern WSL distribution is systemd.
#   Idempotent: a running daemon produces no action and no output beyond one skip
#   line. Honours --dry-run through run_sudo. Always returns 0.
_containers_service() {
  case ${INIT_SYSTEM:-unknown} in
    systemd)
      if systemctl is-active --quiet docker.service 2>/dev/null; then
        log_skip "docker.service is already running"
        return 0
      fi
      if ! run_sudo systemctl enable --now docker.service; then
        _containers_fail "docker.service could not be started (systemctl status docker)"
        return 0
      fi
      changed "docker.service enabled and started"
      ;;
    sysv)
      if service docker status >/dev/null 2>&1; then
        log_skip "the docker service is already running"
      elif run_sudo service docker start; then
        changed "docker service started"
      else
        _containers_fail "the docker service could not be started"
      fi
      if os_is_wsl; then
        log_info "this distribution boots without systemd, so the daemon will not"
        log_info "  come back by itself after 'wsl --shutdown'. 'devenv --only wsl'"
        log_info "  can add the [boot] command line to /etc/wsl.conf for you —"
        log_info "  this module never edits that file."
      fi
      ;;
    *)
      log_warn "unknown init system: start the docker daemon the way this box expects"
      ;;
  esac
  return 0
}

# _containers_group
#   Offers docker-group membership, with the root-equivalence warning, behind
#   confirm_dangerous + DEVENV_ALLOW_DOCKER_GROUP (MUST-FIX S5).
#   Idempotent: an existing member produces one skip line. Always returns 0.
_containers_group() {
  local user
  user=${SUDO_USER:-${USER:-$(id -un)}}
  if [ "$user" = root ]; then
    log_skip "running as root — no docker group membership to change"
    return 0
  fi
  # No pipeline here on purpose: `set -o pipefail` is on in every module, and a
  # `… | grep -q …` returns 141 when grep exits on the first match and the writer
  # gets SIGPIPE. That would read as "not a member" and re-prompt on every run.
  local groups
  groups=" $(id -nG "$user" 2>/dev/null) "
  case $groups in
    *" docker "*)
      log_skip "$user is already in the 'docker' group"
      return 0
      ;;
  esac
  log_warn "membership of the 'docker' group is equivalent to root on this machine:"
  log_warn "  any member can start a container that bind-mounts / and writes to it."
  log_warn "  The alternatives are 'sudo docker …' or rootless docker"
  log_warn "  (dockerd-rootless-setuptool.sh install)."
  if ! confirm_dangerous "add '$user' to the 'docker' group?" DEVENV_ALLOW_DOCKER_GROUP; then
    log_info "group membership unchanged. Allow it with --allow-docker-group"
    log_info "  (or DEVENV_ALLOW_DOCKER_GROUP=1) when you want it."
    return 0
  fi
  if ! getent group docker >/dev/null 2>&1 && ! is_dry_run; then
    log_warn "there is no 'docker' group on this system — nothing to join"
    return 0
  fi
  if ! run_sudo usermod -aG docker "$user"; then
    _containers_fail "could not add $user to the docker group"
    return 0
  fi
  changed "added $user to the docker group"
  log_warn "the new group membership is NOT active in this shell."
  if os_is_wsl; then
    log_warn "  Under WSL, run 'wsl.exe --shutdown' from Windows and open a new shell."
  else
    log_warn "  Log out and back in (or run 'newgrp docker' in a single shell)."
  fi
  return 0
}

# _containers_verify
#   Read-only proof that the CLI, the plugins and the daemon agree. No image is
#   ever pulled (SPEC 8). Always returns 0 — a daemon that is not up yet is a
#   normal state right after an install, not a module failure.
_containers_verify() {
  local v x
  have docker || {
    log_debug "docker is not on PATH yet"
    return 0
  }
  if is_dry_run; then
    return 0
  fi
  if v=$(docker version --format '{{.Server.Version}}' 2>/dev/null); then
    log_success "docker server $v answers as $(id -un)"
  else
    log_warn "the docker CLI cannot reach the daemon as $(id -un) yet."
    log_warn "  That is expected until the daemon is running and your group"
    log_warn "  membership is active. Check with:  docker version"
  fi
  for x in buildx compose; do
    if docker "$x" version >/dev/null 2>&1; then
      log_debug "docker $x is available"
    else
      log_warn "'docker $x' did not answer — is docker-$x-plugin installed?"
    fi
  done
  return 0
}

# _containers_ufw_note
#   Docker publishes ports by writing its own iptables DOCKER chain, which is
#   traversed BEFORE ufw's rules. A published port is therefore reachable from
#   the network even when ufw says it denies it. Read-only detection: both probes
#   below work without root, so a dry run never prompts for a password.
#   Always returns 0.
_containers_ufw_note() {
  have ufw || return 0
  local enabled=0
  if [ -r /etc/ufw/ufw.conf ] && grep -qi '^ENABLED=yes' /etc/ufw/ufw.conf; then
    enabled=1
  elif systemctl is-active --quiet ufw 2>/dev/null; then
    enabled=1
  fi
  [ "$enabled" = 1 ] || return 0
  log_warn "ufw is active, and docker bypasses it."
  log_warn "  Docker inserts its own iptables chain ahead of ufw's rules, so"
  log_warn "  'docker run -p 8080:80' is reachable from the network whatever ufw"
  log_warn "  says. Publish to the loopback instead — -p 127.0.0.1:8080:80 —"
  log_warn "  or add the DOCKER-USER rules yourself."
  return 0
}

module_main() {
  local rc=0

  _containers_docker_desktop_note

  # 1. The vendor repository. 78 means this release has no docker suite at all,
  #    which is a precondition failure for the whole module, not a warning.
  _containers_docker_repo || rc=$?
  case $rc in
    0) ;;
    78) skip "docker publishes no apt suite for ${OS_PRETTY:-this release}" ;;
    *)
      _containers_fail "the docker apt repository could not be configured"
      trap - ERR
      exit 1
      ;;
  esac

  # 2. Overlapping packages: report, never remove.
  if ! _containers_check_conflicts; then
    return 0
  fi

  # 3. Install. pkg_install is the idempotency short-circuit: on a second run
  #    every name is already installed and apt is never invoked.
  # _containers_docker_repo set NEED_APT_UPDATE=1 if it wrote the sources file,
  # and
  # pkg_install checks candidates BEFORE refreshing the index — so refresh here or
  # the first run drops all five names as "no installation candidate".
  pkg_update
  if ! apt_run pkg_install "${CONTAINERS_PKGS[@]}"; then
    _containers_fail "the docker packages could not be installed"
    trap - ERR
    exit 1
  fi

  # 4. Daemon, group, proof, firewall note.
  _containers_service
  _containers_group
  _containers_verify
  _containers_ufw_note

  if [ ${#CONTAINERS_FAILURES[@]} -gt 0 ]; then
    log_error "${#CONTAINERS_FAILURES[@]} step(s) in this module failed:"
    printf '  - %s\n' "${CONTAINERS_FAILURES[@]}" >&2
    # A deliberate failure exit: clear the ERR trap first, or lib/common.sh's
    # trap prints two more "failed (exit 1) … command: return 1" lines after the
    # list above and buries the real reason.
    trap - ERR
    exit 1
  fi
  return 0
}

module_main "$@"
