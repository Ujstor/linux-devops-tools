#!/usr/bin/env bash
# meta: name=base-packages
# meta: desc=the one apt base package set, plus tldr
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=yes
#
# SPEC §5.5 and the *base* rows of the §7.1 catalog, in ONE list instead of the
# three overlapping lists the old repo had (install.sh installed `nala unzip wget
# build-essential`, then `psmisc vim htop tldr git trash-cli autojump curl fzf bat
# ripgrep fd-find lynx python3-pip`, then tools.sh installed more).
#
# What is deliberately NOT here:
#   apt-transport-https        a no-op transitional package since apt 1.5 (SPEC §8)
#   software-properties-common only installed by pkg_ensure_universe, and only when
#                              `add-apt-repository` is genuinely the way in
#   python3-pip                D7/K17: uv is the only Python installer. Installing
#                              pip is what led to the EXTERNALLY-MANAGED removal loop
#   lynx                       SPEC-ADDENDUM: /etc/alternatives/www-browser resolves
#                              to it, so an unguarded xdg-open seizes the TTY
#                              mid-kubectl and looks like a hang. Verified live
#   gnupg                      K14: keys are stored armored, so nothing dearmors
#   nala                       installed below, but ONLY if it already has a
#                              candidate — never behind a repo or a backport (K20)
#
# Tiers. `pkg_install` silently drops a name that has no candidate on this
# distro, so one list works on all four targets.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# --- tier 1: every profile, including `minimal` ------------------------------
# bash-completion is a HARD dependency of the lazy-completion design (D9): the
# generated cache in ~/.local/share/bash-completion/completions is only ever read
# by bash-completion's own __load_completion().
BASE_CORE=(
  ca-certificates curl wget git
  tar xz-utils unzip zip
  build-essential
  bash-completion
  less vim htop tree jq
  psmisc net-tools
  ripgrep fd-find bat
  trash-cli autojump
)

# --- tier 2: `devops` and up -------------------------------------------------
# Drift captured from the live box: none of these was in any script, and DNS,
# ingress basic-auth and WireGuard are all load-bearing on this fleet.
BASE_DEVOPS=(
  bind9-dnsutils nmap mtr-tiny traceroute tcpdump iputils-ping
  apache2-utils
  sshpass
  cmake pkg-config libssl-dev
  # `wireguard-tools`, NOT `wireguard`: the metapackage pulls wireguard-dkms, and
  # WSL2's own kernel cannot load the module. `wg` / `wg-quick` is what is wanted.
  wireguard-tools
)

# --- tier 3: INSTALL_EXTRAS=1 (set by the `full` profile) --------------------
# Justified by on-prem and out-of-band work: multitail for tailing several logs,
# ipmitool for the Proxmox/bare-metal side, putty-tools for `puttygen`, the JRE
# for the handful of vendor tools that still need one. clang/libclang-dev are the
# build dependency of the -sys cargo crates and of a full nvim-treesitter build;
# modules/91-purge-desktop.sh explicitly keeps them for that reason.
BASE_EXTRAS=(
  multitail ipmitool putty-tools openjdk-17-jre-headless
  clang libclang-dev
)

# install_tldr
#   K18 settles a direct contradiction between two input specs about whether
#   `tealdeer` exists in the Ubuntu archive: try tealdeer, then tldr, and only if
#   NEITHER has a candidate fall back to the pinned release binary. tealdeer ships
#   its binary as /usr/bin/tldr either way, so the command name is stable.
install_tldr() {
  if have tldr; then
    log_skip "tldr is already installed ($(command -v tldr))"
    return 0
  fi
  if pkg_install_first tealdeer tldr; then
    return 0
  fi
  log_info "neither tealdeer nor tldr is in this archive — installing the pinned release binary"
  local rc=0
  gh_release_install tealdeer-rs/tealdeer \
    'tealdeer-linux-{arch_rust}-musl' tldr "${TEALDEER_VERSION:?}" \
    --checksum-url 'https://github.com/tealdeer-rs/tealdeer/releases/download/{tag}/tealdeer-linux-{arch_rust}-musl.sha256' \
    --version-cmd '--version' || rc=$?
  case $rc in
    0) ;;
    78) log_skip "tealdeer publishes no ${OS_ARCH_RUST:-?} musl build — no tldr on this box" ;;
    *) log_warn "could not install tealdeer $TEALDEER_VERSION" ;;
  esac
  return 0
}

# seed_tldr_cache
#   `tldr <page>` fails with "page not found" until the cache exists, which reads
#   like a broken install. Seed it ONCE — the marker is the cache directory that
#   tealdeer/tldr creates itself, so a second run does nothing.
seed_tldr_cache() {
  have tldr || return 0
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/tealdeer"
  [ -d "$cache" ] && return 0
  [ -d "$HOME/.local/share/tldr" ] && return 0
  [ -d "${XDG_CACHE_HOME:-$HOME/.cache}/tldr" ] && return 0
  log_info "seeding the tldr page cache"
  run_quiet tldr --update || log_warn "could not download the tldr pages (offline?)"
  return 0
}

# install_nala
#   K20: nala is a cosmetic apt front-end. It is installed when the archive
#   already has it and skipped with one line when it does not — never by adding a
#   repository, a backport or a suite. The `apt` -> `nala` ALIAS is opt-in
#   (ENABLE_NALA_ALIAS=1, honoured by ~/.bashrc.d/70-tools.sh) and `sudo` is never
#   redefined, which is what the old scripts/usenala.sh did.
install_nala() {
  if pkg_installed nala; then
    log_skip "nala is already installed"
    return 0
  fi
  if ! pkg_available nala; then
    log_skip "nala has no candidate on ${OS_ID:-this system} ${OS_CODENAME:-} — not adding a repository for it (K20)"
    return 0
  fi
  pkg_install nala
}

module_main() {
  os_require_supported || die "cannot install packages on an unsupported distribution"

  if ! have_root; then
    skip "installing apt packages needs root, and none is available here"
  fi

  log_step "base packages"

  local want=("${BASE_CORE[@]}")
  case "${DEVENV_PROFILE:-devops}" in
    minimal) ;;
    *) want+=("${BASE_DEVOPS[@]}") ;;
  esac
  if [ "${INSTALL_EXTRAS:-0}" = 1 ]; then
    want+=("${BASE_EXTRAS[@]}")
  fi

  pkg_install "${want[@]}" || log_warn "some base packages could not be installed"

  install_nala
  install_tldr
  seed_tldr_cache

  # Reported, never removed (MUST-FIX S9). `wireguard` drags in wireguard-dkms on
  # a box whose kernel cannot load it; xtightvncviewer and tigervnc-viewer fight
  # over the `vncviewer` alternative. Both are the user's call.
  pkg_conflicts_report \
    "these are installed and have no working kernel module under WSL2" \
    wireguard || true

  log_step_end
  return 0
}

module_main "$@"
