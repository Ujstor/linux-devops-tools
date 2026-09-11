#!/usr/bin/env bash
# meta: name=editors
# meta: desc=neovim from upstream, tmux, and the external config repos
# meta: profiles=devops,full
# meta: os=any
# meta: needs=
# meta: root=no
#
# root=no although the neovim and tmux halves DO need root: MUST-FIX P1. A
# `root=yes` header makes lib/registry.sh skip the WHOLE module on a box where
# the user is not a sudoer, and the half that matters most on such a box — the
# nvim-config and tmux-config checkouts and their symlinks — needs no privileges
# at all. The privileged steps guard themselves with have_root and log a skip.
#
# SPEC §5.5 and §8's "Curl-piping Ujstor/tmux-config and Ujstor/nvim-config
# install.sh" ruling, which exists because of direct evidence of loss on this box:
# ~/.tmux.conf is a HAND-PATCHED regular file (2026-09-09 20:04, next to a
# ~/fix-tmux-clipboard.sh written in the same minute) that the next blind pipe
# would overwrite, and ~/.config/nvim is an EMPTY DIRECTORY, so the pipe was not
# even achieving anything. Replaced by: clone -> refuse if dirty -> symlink after
# a backup.
#
# neovim always comes from upstream. bookworm ships 0.7.2 and noble 0.9.5; a
# modern Lua config needs 0.10+, and the failure mode of a too-old nvim is a wall
# of Lua stack traces on every start, not a clear message.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

NVIM_PREFIX=/usr/local
REPO_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/devops-env/repos"

# ---------------------------------------------------------------------------
# neovim
# ---------------------------------------------------------------------------

# nvim_asset — upstream's own arch spelling, which matches no token exactly:
# x86_64 (uname-ish) for amd64 but arm64 (dpkg-ish) for aarch64.
nvim_asset() {
  case ${OS_ARCH_DPKG:-} in
    amd64) printf 'nvim-linux-x86_64.tar.gz\n' ;;
    arm64) printf 'nvim-linux-arm64.tar.gz\n' ;;
    *) return 1 ;;
  esac
}

install_neovim() {
  local want=${NEOVIM_VERSION:?} tag ver cur asset url dl ar

  if ! is_dry_run && ! have_root; then
    log_skip "installing neovim into $NVIM_PREFIX needs root"
    return 0
  fi

  tag=$(gh_resolve_version neovim/neovim "$want") || {
    log_warn "could not resolve a neovim release for '$want'"
    return 0
  }
  ver=$(tag_to_version "$tag")
  # NVIM_LOG_FILE=/dev/null: `nvim --version` creates and appends to
  # ~/.local/state/nvim/nvim.log, which would make a --dry-run show up in the
  # "a dry run changes nothing" fingerprint of $HOME even though this module
  # wrote nothing at all.
  # No pipeline: `… | head -n1` would kill the producer with SIGPIPE, and under
  # this file's `set -o pipefail` the whole substitution would report failure, so
  # the version gate would never fire and neovim would be reinstalled every run.
  local nvim_out=''
  cur=''
  nvim_out=$(NVIM_LOG_FILE=/dev/null nvim --version 2>/dev/null) || nvim_out=''
  if [[ $nvim_out =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    cur=${BASH_REMATCH[1]}
  fi
  if [ -n "$cur" ]; then
    if [ "$cur" = "$ver" ]; then
      log_skip "neovim is already $ver"
      return 0
    fi
    log_info "neovim $cur -> $ver"
  fi

  asset=$(nvim_asset) || {
    log_skip "neovim publishes no linux build for ${OS_ARCH_DPKG:-this architecture}"
    return 0
  }
  url="https://github.com/neovim/neovim/releases/download/$tag/$asset"

  if is_dry_run; then
    log_dryrun "install neovim $ver from $url -> $NVIM_PREFIX"
    changed "neovim $ver"
    return 0
  fi
  if ! http_ok "$url"; then
    log_warn "no asset $asset in neovim $tag"
    return 0
  fi

  dl="${DEVENV_CACHE:?}/dl"
  ensure_dir "$dl" || return 1
  ar="$dl/$asset"
  [ -f "$ar" ] || download "$url" "$ar" || return 1

  # neovim publishes NO checksum asset — verified for v0.12.5: the release has
  # only the tarballs, appimages and .zsync files, and the sums live in the
  # release-notes body, which is not a stable machine-readable artefact.
  log_warn "installing neovim $ver WITHOUT a checksum: neovim publishes no checksum asset,"
  log_warn "  only sums inside the release-notes text. Source: $url"

  # The tarball is a self-contained prefix (bin/ lib/ share/), so
  # --strip-components=1 into /usr/local is upstream's own documented install.
  # Nothing under /usr/local is dpkg-owned, so no packaged file can be clobbered.
  run_sudo tar -C "$NVIM_PREFIX" --strip-components=1 -xzf "$ar" || return 1
  log_success "installed neovim $ver -> $NVIM_PREFIX/bin/nvim"
  changed "neovim $ver"
  return 0
}

# ---------------------------------------------------------------------------
# tmux
# ---------------------------------------------------------------------------

# tmux_build_deps — the reason libevent-dev, libncurses-dev and bison are on the
# live box. modules/91-purge-desktop.sh keeps them for exactly this.
tmux_build_deps() {
  pkg_install libevent-dev libncurses-dev bison pkg-config autoconf automake
}

install_tmux_from_source() {
  local want=${TMUX_VERSION:-latest} tag ver cur url work dl ar
  tag=$(gh_resolve_version tmux/tmux "$want") || {
    log_warn "could not resolve a tmux release — falling back to the distro package"
    pkg_install tmux
    return 0
  }
  ver=$(tag_to_version "$tag")
  if cur=$(bin_version tmux -V); then
    if [ "${cur#v}" = "$ver" ]; then
      log_skip "tmux is already $ver"
      return 0
    fi
  fi
  if is_dry_run; then
    log_dryrun "build tmux $ver from source into /usr/local"
    changed "tmux $ver (source)"
    return 0
  fi
  if ! have_root; then
    log_skip "TMUX_FROM_SOURCE=1 needs root to install into /usr/local"
    return 0
  fi

  tmux_build_deps || {
    log_warn "the tmux build dependencies are not available — using the distro package"
    pkg_install tmux
    return 0
  }

  url="https://github.com/tmux/tmux/releases/download/$tag/tmux-$ver.tar.gz"
  if ! http_ok "$url"; then
    log_warn "no source tarball at $url — using the distro package"
    pkg_install tmux
    return 0
  fi
  dl="${DEVENV_CACHE:?}/dl"
  ensure_dir "$dl" || return 1
  ar="$dl/tmux-$ver.tar.gz"
  [ -f "$ar" ] || download "$url" "$ar" || return 1
  log_warn "building tmux $ver WITHOUT a checksum: tmux publishes no checksum asset"

  # devenv_execdir: `./configure` and everything the build generates is executed
  # out of this tree, so it cannot live on a noexec filesystem.
  work=$(devenv_execdir) || return 1
  run tar -C "$work" -xzf "$ar" || return 1
  local src="$work/tmux-$ver"
  [ -d "$src" ] || {
    log_error "tmux-$ver is not the top-level directory inside $ar"
    return 1
  }
  (
    cd "$src" || exit 1
    run ./configure --prefix=/usr/local
  ) || {
    log_error "tmux configure failed"
    return 1
  }
  run make -C "$src" -j"$(nproc 2>/dev/null || printf 1)" || {
    log_error "tmux build failed"
    return 1
  }
  run_sudo make -C "$src" install || {
    log_error "tmux install failed"
    return 1
  }
  log_success "installed tmux $ver -> /usr/local/bin/tmux"
  changed "tmux $ver (source)"
  return 0
}

install_tmux() {
  if [ "${TMUX_FROM_SOURCE:-0}" = 1 ]; then
    install_tmux_from_source
    return 0
  fi
  if have tmux; then
    log_skip "tmux is already installed ($(command -v tmux))"
    return 0
  fi
  have_root && pkg_install tmux
  return 0
}

# ---------------------------------------------------------------------------
# The external config repos
# ---------------------------------------------------------------------------

# link_config SRC DST
#   symlink_file refuses to clobber a real FILE without a backup, but it cannot
#   back up a real DIRECTORY. ~/.config/nvim is exactly that case — empty on this
#   box, but not necessarily on someone else's — so a directory is handled here:
#   empty gets removed, non-empty is left completely alone and reported.
link_config() {
  local src=$1 dst=$2
  if [ -L "$dst" ]; then
    symlink_file "$src" "$dst"
    return
  fi
  if [ -d "$dst" ]; then
    if [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
      log_warn "$dst is a non-empty directory — leaving your own config in place"
      log_warn "  move it aside and re-run if you want the shipped one:  mv '$dst' '$dst.bak'"
      return 0
    fi
    if is_dry_run; then
      log_dryrun "rmdir empty $dst, then link it to $src"
      return 0
    fi
    run rmdir -- "$dst" || return 0
  fi
  symlink_file "$src" "$dst"
}

install_external_configs() {
  ensure_dir "$REPO_ROOT" || return 0

  # nvim-config: init.lua is at the repository root, so the CHECKOUT is what
  # ~/.config/nvim must point at.
  devenv_sync_repo "https://github.com/Ujstor/nvim-config.git" \
    "$REPO_ROOT/nvim-config" "${NVIM_CONFIG_REF:-master}" \
    || log_warn "could not sync nvim-config"
  if [ -d "$REPO_ROOT/nvim-config" ]; then
    link_config "$REPO_ROOT/nvim-config" "${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
  fi

  # tmux-config: the file at the repository root is .tmux.conf, so the SYMLINK
  # target is that file, not the directory.
  devenv_sync_repo "https://github.com/Ujstor/tmux-config.git" \
    "$REPO_ROOT/tmux-config" "${TMUX_CONFIG_REF:-master}" \
    || log_warn "could not sync tmux-config"
  install_tmux_conf
  return 0
}

# install_tmux_conf
#   SPEC §8 and SPEC-ADDENDUM C10: ~/.tmux.conf is NEVER edited in place. It is
#   either linked to the clone (when the user has no file of their own) or left
#   entirely alone with a report. The clipboard snippet that fixes the hardcoded
#   clip.exe / powershell.exe lines lives in
#   ~/.config/devops-env/tmux/devenv-clipboard.conf and is installed by
#   modules/38-auth-sso.sh; here we only say how to source it.
install_tmux_conf() {
  local conf="$HOME/.tmux.conf" src="$REPO_ROOT/tmux-config/.tmux.conf"
  local snippet="${XDG_CONFIG_HOME:-$HOME/.config}/devops-env/tmux/devenv-clipboard.conf"

  if [ ! -e "$conf" ]; then
    if [ -r "$src" ]; then
      symlink_file "$src" "$conf"
    elif [ -r "$DEVENV_HOME/config/tmux/minimal.tmux.conf" ]; then
      log_info "no tmux-config checkout — installing the minimal fallback tmux.conf"
      write_if_changed "$conf" 0644 <"$DEVENV_HOME/config/tmux/minimal.tmux.conf"
    fi
  elif [ -L "$conf" ]; then
    [ -r "$src" ] && symlink_file "$src" "$conf"
  else
    log_info "$conf is a regular file of your own — not touched, not overwritten"
  fi

  # The three findings 90-doctor.sh reports in full. Printed here too, because
  # this is the module that just put a tmux config in place.
  if [ -f "$conf" ] || [ -L "$conf" ]; then
    if ! grep -q 'devenv-clipboard.conf' "$conf" 2>/dev/null; then
      log_info "to get portable copy/paste inside tmux, add this line to $conf:"
      log_info "    source-file $snippet"
    fi
    if grep -qE 'clip\.exe|powershell\.exe' "$conf" 2>/dev/null; then
      log_warn "$conf still calls clip.exe / powershell.exe by name."
      log_warn "  Neither resolves on this box (the Windows PATH is not inherited), so those"
      log_warn "  bindings are already dead. Replace them with 'clip' and 'clip-paste'."
    fi
    if grep -qE '^[[:space:]]*set-environment[[:space:]]+-g[[:space:]]+DISPLAY' "$conf" 2>/dev/null; then
      log_warn "$conf sets DISPLAY unconditionally. Inside tmux that makes a headless box"
      log_warn "  look graphical to every tool that tries to open a browser. Delete the line."
    fi
  fi
  return 0
}

module_main() {
  log_step "editors"

  install_neovim

  # Reported, never removed (MUST-FIX S9). Two nvim binaries on PATH is a real
  # confusion — /usr/bin/nvim from apt and /usr/local/bin/nvim from upstream —
  # but the apt one may be a dependency of something the user installed.
  pkg_conflicts_report \
    "a distro neovim is installed as well as the upstream one in $NVIM_PREFIX/bin; 'command -v nvim' says which wins" \
    neovim || true

  install_tmux
  install_external_configs

  if have_root; then
    pkg_install_optional vim
  fi

  log_step_end
  return 0
}

module_main "$@"
