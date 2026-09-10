#!/usr/bin/env bash
# meta: name=purge-desktop
# meta: desc=one-shot report and optional removal of the desktop layer left by the old wsl2-config
# meta: profiles=
# meta: os=any
# meta: root=yes
#
# NEVER in a profile. Run it explicitly:  devenv --only purge-desktop
#
# SPEC-ADDENDUM §5.4, under MUST-FIX S9: it REPORTS by default and removes nothing.
# Every removal needs DEVENV_ALLOW_PKG_REMOVE=1 (`--allow-pkg-remove`) or an
# interactive yes, and every step goes through run/run_sudo so --dry-run is a true
# no-op.
#
# HARD RULE, and the reason this module hand-lists every package:
#   NEVER `apt purge 'libxcb*'`, and no wildcard of any kind.
# libxcb1, libxcb-shm0, libxcb-sync1 and libxcb-xkb1 are runtime dependencies of
# Playwright's Chromium; a wildcard purge silently breaks every browser test on the
# box and surfaces days later as a launch error. libepoxy0, libgles2, libgbm1 and
# libevent-2.1-7t64 stay for the same reason — the last one is also what the
# source-built /usr/local/bin/tmux links against.
#
# These look like picom's build deps and are NOT — they stay in the base set:
#   build-essential, pkg-config, libssl-dev, clang, libclang-dev  (nvim-config and
#   every -sys cargo crate), libevent-dev, libncurses-dev, bison  (tmux-config
#   builds tmux from a release tarball), and cmake (a generic build driver).
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# 1. Debris a package manager can never reach: `sudo ninja install` put it there.
DEBRIS=(
  /usr/local/bin/picom
  /usr/local/bin/picom-trans
  /usr/local/bin/compton
  /usr/local/bin/compton-trans
)

# 2. picom's build dependencies. `cmake` is deliberately NOT in this list.
BUILD_DEPS=(
  libconfig-dev libdbus-1-dev libegl-dev libev-dev libgl-dev libepoxy-dev
  libpcre2-dev libpixman-1-dev libx11-xcb-dev libxcb1-dev libxcb-composite0-dev
  libxcb-damage0-dev libxcb-dpms0-dev libxcb-glx0-dev libxcb-image0-dev
  libxcb-present-dev libxcb-randr0-dev libxcb-render0-dev libxcb-render-util0-dev
  libxcb-shape0-dev libxcb-util-dev libxcb-xfixes0-dev libxcb-res0-dev
  libxext-dev libxft-dev libimlib2-dev libxinerama-dev
  meson ninja-build uthash-dev alsa-utils
)

# 3. GUI applications with no consumer on a terminal-only box. Brave is 449 MB of
#    it, and cannot run on half the target matrix anyway.
GUI_APPS=(brave-browser brave-keyring mpv tigervnc-viewer xtightvncviewer autocutsel)

# 4. Playwright's own runtime set. `apt-mark manual` protects it BEFORE autoremove,
#    so removing Brave cannot drag fonts-liberation (a dependency of both) out with
#    it. Both the t64 and the pre-t64 names are listed; only installed ones are used.
PLAYWRIGHT_KEEP=(
  xvfb fonts-liberation fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf
  fonts-unifont fonts-freefont-ttf fonts-noto-color-emoji xfonts-cyrillic
  xfonts-scalable libnss3 libnspr4
  libatk1.0-0t64 libatk1.0-0 libatk-bridge2.0-0t64 libatk-bridge2.0-0
  libatspi2.0-0t64 libatspi2.0-0 libcups2t64 libcups2 libasound2t64 libasound2
  libgbm1 libdrm2 libxkbcommon0 libgles2 libepoxy0
  libgtk-3-0t64 libgtk-3-0 libgtk-4-1
  gstreamer1.0-gl gstreamer1.0-libav gstreamer1.0-plugins-bad
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good
  libxcb1 libxcb-shm0 libxcb-sync1 libxcb-xkb1 libevent-2.1-7t64 libevent-2.1-7
)

BRAVE_SOURCES=/etc/apt/sources.list.d/brave-browser-release.list
BRAVE_KEYRING=/usr/share/keyrings/brave-browser-archive-keyring.gpg

# installed_of NAME… — prints the subset that dpkg reports as installed.
installed_of() {
  local p out=()
  for p in "$@"; do
    if pkg_installed "$p"; then out+=("$p"); fi
  done
  [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

report() {
  local -a debris apps deps
  local f
  debris=()
  for f in "${DEBRIS[@]}" "$HOME/build/picom"; do
    if [ -e "$f" ]; then debris+=("$f"); fi
  done
  mapfile -t apps < <(installed_of "${GUI_APPS[@]}")
  mapfile -t deps < <(installed_of "${BUILD_DEPS[@]}")

  log_info 'what this box still carries from the old desktop layer:'
  if [ ${#debris[@]} -gt 0 ]; then
    log_warn "  non-apt files (sudo ninja install put them there): ${debris[*]}"
  else
    log_info '  non-apt files: none'
  fi
  if [ ${#apps[@]} -gt 0 ]; then
    log_warn "  GUI applications: ${apps[*]}"
  else
    log_info '  GUI applications: none'
  fi
  if [ ${#deps[@]} -gt 0 ]; then
    log_warn "  picom build dependencies: ${#deps[@]} package(s)"
    log_info "    ${deps[*]}"
  else
    log_info '  picom build dependencies: none'
  fi
  if [ -f "$BRAVE_SOURCES" ] || [ -f "$BRAVE_KEYRING" ]; then
    log_warn '  the brave apt repository is still configured'
  fi

  if [ ${#debris[@]} = 0 ] && [ ${#apps[@]} = 0 ] && [ ${#deps[@]} = 0 ] \
    && [ ! -f "$BRAVE_SOURCES" ]; then
    log_success 'nothing to do — this box is already terminal-only'
    return 1
  fi
  log_info ''
  log_info 'Nothing above is removed unless you say so. To go ahead:'
  log_info '  devenv --only purge-desktop --allow-pkg-remove'
  return 0
}

remove_debris() {
  local f present=()
  for f in "${DEBRIS[@]}"; do
    if [ -e "$f" ]; then present+=("$f"); fi
  done
  [ ${#present[@]} -gt 0 ] || return 0
  if ! confirm_dangerous "delete ${present[*]} (root-owned, not apt-managed)?" \
    DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  run_sudo rm -f -- "${present[@]}" || return 0
  changed "removed ${present[*]}"
  return 0
}

remove_build_dir() {
  local d="$HOME/build/picom"
  [ -d "$d" ] || return 0
  if ! confirm_dangerous "delete the picom source tree at $d?" DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  run rm -rf -- "$d" || return 0
  changed "removed $d"
  return 0
}

protect_playwright() {
  local -a keep
  mapfile -t keep < <(installed_of "${PLAYWRIGHT_KEEP[@]}")
  [ ${#keep[@]} -gt 0 ] || return 0
  log_info "marking ${#keep[@]} Playwright runtime package(s) as manually installed"
  log_info '  so that autoremove cannot take them out with Brave'
  run_sudo apt-mark manual "${keep[@]}" >/dev/null || {
    log_warn 'apt-mark manual failed — NOT continuing to autoremove'
    return 1
  }
  return 0
}

remove_packages() {
  # pkg_purge is report-only unless DEVENV_ALLOW_PKG_REMOVE=1 and the user agrees:
  # that is MUST-FIX S9, and it is the whole safety model of this module.
  local -a apps deps
  mapfile -t apps < <(installed_of "${GUI_APPS[@]}")
  mapfile -t deps < <(installed_of "${BUILD_DEPS[@]}")
  [ ${#apps[@]} -gt 0 ] && pkg_purge "${apps[@]}"
  [ ${#deps[@]} -gt 0 ] && pkg_purge "${deps[@]}"
  return 0
}

remove_brave_repo() {
  local files=()
  [ -f "$BRAVE_SOURCES" ] && files+=("$BRAVE_SOURCES")
  [ -f "$BRAVE_KEYRING" ] && files+=("$BRAVE_KEYRING")
  [ ${#files[@]} -gt 0 ] || return 0
  if pkg_installed brave-browser; then
    log_info 'brave-browser is still installed — keeping its apt source for now'
    return 0
  fi
  if ! confirm_dangerous "remove the brave apt source and keyring (${files[*]})?" \
    DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  run_sudo rm -f -- "${files[@]}" || return 0
  NEED_APT_UPDATE=1
  export NEED_APT_UPDATE
  changed "removed ${files[*]}"
  pkg_update
  return 0
}

autoremove() {
  # Only ever AFTER protect_playwright, and only when the user opted in.
  if [ "${DEVENV_ALLOW_PKG_REMOVE:-0}" != 1 ]; then
    log_info 'skipping "apt-get autoremove --purge" (needs --allow-pkg-remove)'
    return 0
  fi
  if ! confirm_dangerous 'run apt-get autoremove --purge now?' DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  protect_playwright || return 0
  # env-on-the-command, not exported: sudo's env_reset would drop it (see
  # lib/pkg.sh's _apt_get) and a purge could stop on a debconf prompt.
  run_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get autoremove --purge -y || { # policy-allow: no-bare-apt
    log_warn 'autoremove failed — nothing else was changed'
    return 0
  }
  changed 'apt autoremove --purge'
  return 0
}

offer_duplicate_font() {
  local d="$HOME/.local/share/fonts/MesloLGS Nerd Font Mono"
  [ -d "$d" ] || return 0
  log_info "a full Meslo Nerd Font family is installed at: $d"
  log_info '  glyphs are rasterised by the terminal emulator on the machine you SIT at,'
  log_info '  so on WSL or over SSH this copy draws nothing. 10-shell.sh installs the'
  log_info '  Symbols-Only fallback instead, and only on a local box.'
  if ! confirm_dangerous "delete $d?" DEVENV_ALLOW_PKG_REMOVE; then
    return 0
  fi
  run rm -rf -- "$d" || return 0
  have fc-cache && run fc-cache -f "$HOME/.local/share/fonts"
  changed "removed $d"
  return 0
}

verify() {
  log_info ''
  log_info 'verify that browser automation still has everything it needs:'
  log_info '  npx --yes playwright@latest install-deps --dry-run'
  if have npx && [ -d "$HOME/.cache/ms-playwright" ] && [ "${DEVENV_VERIFY_PLAYWRIGHT:-0}" = 1 ]; then
    run npx --yes playwright@latest install-deps --dry-run || {
      log_warn 'playwright reports missing dependencies — reinstall them with:'
      log_warn '  devenv --only headless-browser'
    }
  fi
  return 0
}

module_main() {
  if ! report; then
    return 0
  fi
  remove_debris
  remove_build_dir
  remove_packages
  remove_brave_repo
  autoremove
  offer_duplicate_font
  verify
  log_info ''
  log_info 'the shell/dotfile half of the old repo is a different module:'
  log_info '  devenv --only migrate            (reports; --apply acts, with backups)'
  return 0
}

module_main "$@"
