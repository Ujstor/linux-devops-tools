#!/usr/bin/env bash
# meta: name=editors
# meta: desc=neovim from upstream, the tree-sitter cli, tmux, the tmux session saver and the external config repos
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
# even achieving anything. Replaced by: clone -> refuse if dirty -> symlink, and
# never over anything of yours.
#
# WHICH repositories those are is no longer written here. They are entries in
# config/external-repos.sh, which lib/extrepo.sh reads together with your own
# ~/.config/devops-env/external-repos.sh; this module only says "sync the entries
# I own". Adding a fourth checkout does not touch this file.
#
# neovim always comes from upstream. bookworm ships 0.7.2 and noble 0.9.5; a
# modern Lua config needs 0.10+, and the failure mode of a too-old nvim is a wall
# of Lua stack traces on every start, not a clear message.
#
# The tree-sitter CLI is here because nvim-config cannot work without it — see
# the tree-sitter section below for why it is sometimes BUILT rather than
# downloaded.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

NVIM_PREFIX=/usr/local

# Where tmux-save-session.sh is installed, and — because the script defaults
# OUT_DIR to its own directory — where the restore scripts it generates land.
# That is the whole reason it does not go in ~/.local/bin: its output belongs
# beside it, in a directory of its own, and never inside this checkout.
TMUX_SESSIONS_DIR="$HOME/.tmux-sessions"

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
  # The tag is part of the cached name (lib/net.sh: net_cache_path): the asset is
  # nvim-linux-x86_64.tar.gz in every release, so a name-only cache would unpack
  # the previous neovim after a pin bump and report the new one.
  ar=$(net_cache_path "$tag" "$asset")
  if [ ! -f "$ar" ]; then
    download "$url" "$ar" || return 1
    net_cache_prune "$ar" "$asset"
  fi

  # neovim publishes NO checksum asset — verified for v0.12.5: the release has
  # only the tarballs, appimages and .zsync files, and the sums live in the
  # release-notes body, which is not a stable machine-readable artefact.
  log_warn "installing neovim $ver WITHOUT a checksum: neovim publishes no checksum asset,"
  log_warn "  only sums inside the release-notes text. Source: $url"

  # The tarball is a self-contained prefix (bin/ lib/ share/), so
  # --strip-components=1 into /usr/local is upstream's own documented install.
  # Nothing under /usr/local is dpkg-owned, so no packaged file can be clobbered.
  #
  # --no-same-owner is load-bearing. tar running as root restores each entry's
  # owner from the archive, and every entry in this one belongs to uid 1001 —
  # GitHub's `runner` user, verified for v0.12.5 — including the bin/, lib/ and
  # share/ directories themselves. Without the flag, /usr/local/bin, lib and share
  # end up owned by uid 1001: whichever account holds that uid on this box (often
  # the second human user) could then replace any binary root runs.
  run_sudo tar -C "$NVIM_PREFIX" --strip-components=1 --no-same-owner -xzf "$ar" || return 1
  log_success "installed neovim $ver -> $NVIM_PREFIX/bin/nvim"
  changed "neovim $ver"
  return 0
}

# ---------------------------------------------------------------------------
# tree-sitter CLI
# ---------------------------------------------------------------------------
#
# nvim-config runs nvim-treesitter's `main` branch, which ships no parsers: it
# COMPILES every one of them with the tree-sitter CLI. Without the CLI the config
# starts with no syntax highlighting, and only says why inside nvim. The config's
# own install.sh builds the CLI, but that installer is deliberately not run from
# here (config/external-repos.sh says why), so the CLI is this module's job. It
# lands beside nvim in /usr/local/bin, where root's nvim finds it too —
# modules/52-root-configs.sh gives root the same config.
#
# WHICH BUILD IS PROBED, NOT ASSUMED. Upstream links its release binary against a
# recent glibc — v0.26.3, v0.26.8 and v0.27.0 all need GLIBC_2.39 — so it runs on
# trixie and noble and dies at load time on bookworm (2.36) and jammy (2.35):
#     tree-sitter: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.39' not found
# So the release binary is unpacked into an exec-capable scratch directory and RUN
# there, and installed only when it answers with the pinned version. Where it
# cannot run, the same version is built from crates.io with cargo, which links it
# against this host's own glibc — the reason nvim-config's installer builds it
# too. That costs a few minutes of CPU once; the version gate makes every later
# run free.

TS_REPO=tree-sitter/tree-sitter

# ts_asset — upstream's own arch spelling, which matches no {token}: x64 for
# amd64, arm64 for arm64. Returns 1 anywhere else; the cargo build still covers an
# architecture that has no release binary.
ts_asset() {
  case ${OS_ARCH_DPKG:-} in
    amd64) printf 'tree-sitter-cli-linux-x64.zip\n' ;;
    arm64) printf 'tree-sitter-cli-linux-arm64.zip\n' ;;
    *) return 1 ;;
  esac
}

# ts_version_of BIN — prints the version BIN reports (`tree-sitter 0.26.8` ->
# 0.26.8). Returns 1 when BIN is missing, cannot run, or prints no version.
# Read-only — it writes nothing under $HOME either — so it is safe under --dry-run.
ts_version_of() {
  local bin=${1:?ts_version_of: BIN required} out=''
  [ -x "$bin" ] || return 1
  out=$("$bin" --version 2>/dev/null) || return 1
  [[ $out =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# ts_place SRC DEST — installs SRC as DEST/tree-sitter. Into the system prefix it
# is ALWAYS installed as root, never merely because the directory happens to be
# writable: that is how a /usr/local/bin left owned by another uid would end up
# holding a user-owned binary that root's nvim runs. `install` unlinks the target
# first, so the symlink into ~/.cargo/bin that nvim-config's installer leaves in
# /usr/local/bin is replaced, never written through.
ts_place() {
  local src=$1 dest=$2
  if [ "$dest" = "$NVIM_PREFIX/bin" ]; then
    run_sudo install -m 0755 -- "$src" "$dest/tree-sitter"
  else
    run install -m 0755 -- "$src" "$dest/tree-sitter"
  fi
}

# ts_install_release TAG DEST
#   The upstream release binary, if it runs here: fetched into the download cache,
#   unpacked into devenv_execdir, RUN there, and installed to DEST only when it
#   reports the pinned version. Returns 1, having said why, whenever the cargo
#   build should be tried instead — no asset for this architecture, or a binary
#   this glibc cannot load. Not for --dry-run.
ts_install_release() {
  local tag=$1 dest=$2 ver asset url ar work out got
  ver=$(tag_to_version "$tag")
  asset=$(ts_asset) || {
    log_info "tree-sitter publishes no release binary for ${OS_ARCH_DPKG:-this architecture}"
    return 1
  }
  have unzip || {
    log_info "unzip is not installed, so the tree-sitter release zip cannot be unpacked"
    return 1
  }
  url="https://github.com/$TS_REPO/releases/download/$tag/$asset"

  # The asset name carries no version; net_cache_path adds the tag so a pin bump
  # never unpacks the previous release out of the cache.
  ensure_dir "${DEVENV_CACHE:?}/dl" || return 1
  ar=$(net_cache_path "$tag" "$asset")
  if [ ! -f "$ar" ]; then
    if ! http_ok "$url"; then
      log_info "tree-sitter $tag has no asset $asset"
      return 1
    fi
    download "$url" "$ar" || return 1
    net_cache_prune "$ar" "$asset"
  fi

  # devenv_execdir, NOT devenv_tmpdir: the binary is executed right here, and /tmp
  # is mounted noexec on every hardened host.
  work=$(devenv_execdir) || return 1
  run unzip -q -o "$ar" -d "$work" || return 1
  if [ ! -f "$work/tree-sitter" ]; then
    log_warn "$asset has no tree-sitter binary at its top level"
    return 1
  fi
  run chmod 0755 "$work/tree-sitter" || return 1
  if ! out=$("$work/tree-sitter" --version 2>&1); then
    log_info "the tree-sitter $ver release binary does not run on this host:"
    log_info "  ${out%%$'\n'*}"
    return 1
  fi
  got=$(ts_version_of "$work/tree-sitter") || got=''
  if [ "$got" != "$ver" ]; then
    log_warn "$asset from $tag reports version '${got:-none}', not $ver"
    return 1
  fi
  # Verified for v0.26.8: the release holds the binaries and no checksum file.
  # GitHub keeps a digest per asset, but only behind api.github.com, which nothing
  # in this repository calls.
  log_warn "installing tree-sitter $ver WITHOUT a checksum: tree-sitter publishes no checksum asset."
  log_warn "  source: $url"
  ts_place "$work/tree-sitter" "$dest" || return 1
  log_success "installed tree-sitter $ver (release binary) -> $dest/tree-sitter"
  changed "tree-sitter $ver"
  return 0
}

# ts_have_libclang — 0 when a libclang shared object is installed. bindgen
# dlopen()s it while BUILDING rquickjs-sys, a dependency of tree-sitter-cli 0.26,
# and without it the build dies minutes in with "Unable to find libclang".
# libclang-cpp is a different library and deliberately does not match.
ts_have_libclang() {
  local f
  for f in /usr/lib/llvm-*/lib/libclang.so* /usr/lib/*/libclang.so* /usr/lib/*/libclang-[0-9]*.so*; do
    [ -e "$f" ] && return 0
  done
  return 1
}

# ts_cargo — prints the cargo to build with, or returns 1. rustup's proxy comes
# first: modules/21-lang-rust.sh may have installed it earlier in THIS run, after
# the invoking shell computed PATH, so `have cargo` alone would miss it.
ts_cargo() {
  local c="${CARGO_HOME:-$HOME/.cargo}/bin/cargo"
  if [ -x "$c" ]; then
    printf '%s\n' "$c"
    return 0
  fi
  command -v cargo 2>/dev/null
}

# ts_install_cargo VERSION DEST
#   `cargo install --locked tree-sitter-cli --version VERSION`, built entirely
#   inside devenv_execdir and then installed to DEST. --root keeps the result out
#   of ~/.cargo/bin, which precedes /usr/local/bin on PATH and is not on root's
#   PATH at all. The build executes the build scripts it compiles, so
#   CARGO_TARGET_DIR pins the build tree into the exec scratch, and TMPDIR follows
#   it for whatever else cargo puts in the temp dir — which cargo versions differ
#   on. The build dependencies are the list nvim-config's installer uses,
#   installed only on this path. Returns 1, having said why, when nothing could be
#   built. Not for --dry-run.
ts_install_cargo() {
  local ver=$1 dest=$2 cargo work got
  cargo=$(ts_cargo) || {
    log_warn "the tree-sitter CLI has to be built here and there is no cargo to build it with."
    log_warn "  install rust first:  devenv --only lang-rust   then re-run:  devenv --only editors"
    return 1
  }
  if have_root; then
    pkg_install build-essential pkg-config libssl-dev clang libclang-dev \
      || log_warn "not every tree-sitter build dependency could be installed; trying the build anyway"
  fi
  # Checked rather than hoped for: without root nothing above ran, and a build
  # that cannot link would fail minutes in on EVERY run instead of once, here.
  if ! have cc || ! ts_have_libclang; then
    log_warn "building tree-sitter-cli needs a C compiler and libclang, and this box lacks one."
    log_warn "  as root:  apt-get install build-essential clang libclang-dev   then re-run this module"
    return 1
  fi
  work=$(devenv_execdir) || return 1
  log_info "building tree-sitter-cli $ver with cargo — a few minutes, once"
  run env TMPDIR="$work" CARGO_TARGET_DIR="$work/target" \
    "$cargo" install --locked --root "$work/root" tree-sitter-cli --version "$ver" || {
    log_warn "cargo could not build tree-sitter-cli $ver"
    return 1
  }
  got=$(ts_version_of "$work/root/bin/tree-sitter") || got=''
  if [ "$got" != "$ver" ]; then
    log_warn "the tree-sitter cargo just built reports version '${got:-none}', not $ver"
    return 1
  fi
  ts_place "$work/root/bin/tree-sitter" "$dest" || return 1
  log_success "installed tree-sitter $ver (built with cargo) -> $dest/tree-sitter"
  changed "tree-sitter $ver"
  return 0
}

# ts_report_shadow DEST VERSION
#   ~/.bashrc.d/10-path.sh puts ~/.local/bin and then ~/.cargo/bin AHEAD of
#   /usr/local/bin, so a tree-sitter in either one is the one nvim actually runs.
#   Reported when it is not the pinned version, never removed (MUST-FIX S9) — it
#   is most likely an earlier nvim-config install.sh's cargo build. Returns 0.
ts_report_shadow() {
  local dest=$1 ver=$2 p v cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  # In PATH order: once the loop reaches DEST, everything after it comes later on
  # PATH and shadows nothing.
  for p in "$HOME/.local/bin/tree-sitter" "$cargo_bin/tree-sitter"; do
    [ "$p" != "$dest/tree-sitter" ] || break
    [ -x "$p" ] || continue
    v=$(ts_version_of "$p") || v=''
    [ "$v" != "$ver" ] || continue
    log_warn "$p (${v:-version unknown}) comes before $dest/tree-sitter on PATH, so nvim runs it, not $ver."
    case $p in
      "$cargo_bin"/*) log_warn "  it is a cargo install; to drop it:  cargo uninstall tree-sitter-cli" ;;
      *) log_warn "  remove it, or replace it with $ver" ;;
    esac
  done
  return 0
}

# install_tree_sitter
#   The CLI nvim-treesitter's `main` branch compiles every parser with, pinned by
#   TREE_SITTER_VERSION. Gated on the version of the file this module writes, so
#   a converged box costs one `tree-sitter --version` and no network. A failure
#   warns and returns 0: neovim and the config still install, without parsers
#   until a later run succeeds.
install_tree_sitter() {
  local tag ver dest cur=''
  tag=$(gh_resolve_version "$TS_REPO" "${TREE_SITTER_VERSION:?}") || {
    log_warn "could not resolve a tree-sitter release for '${TREE_SITTER_VERSION:-}'"
    return 0
  }
  ver=$(tag_to_version "$tag")
  if have_root; then
    dest=$NVIM_PREFIX/bin
  else
    dest=$HOME/.local/bin
  fi

  cur=$(ts_version_of "$dest/tree-sitter") || cur=''
  # In the system prefix the CLI must be root's own regular file. Older
  # nvim-config installers left a SYMLINK there into ~/.cargo/bin: whatever runs
  # as that user could swap the target, and root's nvim runs tree-sitter by
  # itself at startup to build parsers. A version read through such a link says
  # nothing about who controls it, so it counts as not installed, and ts_place
  # replaces it with a fresh root-owned copy (never a copy of the link's target).
  if [ -n "$cur" ] && [ "$dest" = "$NVIM_PREFIX/bin" ]; then
    if [ -L "$dest/tree-sitter" ]; then
      log_warn "$dest/tree-sitter is a symlink -> $(readlink "$dest/tree-sitter"); replacing it with a root-owned copy"
      cur=''
    elif [ "$(stat -c %u -- "$dest/tree-sitter" 2>/dev/null)" != 0 ]; then
      log_warn "$dest/tree-sitter is not owned by root; replacing it with a root-owned copy"
      cur=''
    fi
  fi
  if [ "$cur" = "$ver" ]; then
    log_skip "tree-sitter is already $ver ($dest/tree-sitter)"
    ts_report_shadow "$dest" "$ver"
    return 0
  fi
  if [ -n "$cur" ]; then log_info "tree-sitter $cur -> $ver"; fi

  if is_dry_run; then
    log_dryrun "install tree-sitter $ver -> $dest/tree-sitter: the release binary where it runs on this glibc, else cargo install --locked tree-sitter-cli"
    changed "tree-sitter $ver"
    return 0
  fi

  ensure_dir "$dest" || return 0
  if ! ts_install_release "$tag" "$dest" && ! ts_install_cargo "$ver" "$dest"; then
    log_warn "no tree-sitter CLI was installed — nvim-treesitter cannot compile parsers until one is"
    return 0
  fi
  ts_report_shadow "$dest" "$ver"
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

# install_external_configs
#   The whole of it. Which repositories, which refs, which symlinks and whether
#   each one is switched on are DATA, in config/external-repos.sh and in the
#   user's own ~/.config/devops-env/external-repos.sh; lib/extrepo.sh keeps
#   devenv_sync_repo's guarantees (never over a dirty worktree, never over a file
#   or a non-empty directory of yours) and warns-and-continues on a repository it
#   cannot reach. Nothing below aborts the module.
install_external_configs() {
  extrepo_seed_user_list
  extrepo_sync_module editors
  install_tmux_conf
  return 0
}

# install_tmux_conf
#   The half of the tmux configuration that is NOT a symlink — extrepo places
#   ~/.tmux.conf itself, from the tmux-config entry's link=/link_src= fields.
#
#   SPEC §8 and SPEC-ADDENDUM C10: ~/.tmux.conf is NEVER edited in place. It is
#   either linked to the clone (when the user has no file of their own) or left
#   entirely alone with a report. What is left here is the fallback for a box with
#   no checkout at all, and the three findings worth printing about whatever file
#   ended up there. The clipboard snippet that fixes the hardcoded clip.exe /
#   powershell.exe lines lives in ~/.config/devops-env/tmux/devenv-clipboard.conf
#   and is installed by modules/38-auth-sso.sh; here we only say how to source it.
install_tmux_conf() {
  local conf="$HOME/.tmux.conf"
  local snippet="${XDG_CONFIG_HOME:-$HOME/.config}/devops-env/tmux/devenv-clipboard.conf"

  if [ ! -e "$conf" ] && [ -r "$DEVENV_HOME/config/tmux/minimal.tmux.conf" ]; then
    log_info "no tmux config was linked — installing the minimal fallback tmux.conf"
    write_if_changed "$conf" 0644 <"$DEVENV_HOME/config/tmux/minimal.tmux.conf"
  fi

  # The three findings 90-doctor.sh reports in full. Printed here too, because
  # this is the module that just put a tmux config in place.
  if [ -f "$conf" ] || [ -L "$conf" ]; then
    # Only worth saying to a config that has no clipboard handling of its own.
    # Ujstor/tmux-config resolves a backend at copy time; pointing it at a second,
    # competing set of bindings is worse than saying nothing at all.
    if ! grep -q 'devenv-clipboard.conf' "$conf" 2>/dev/null \
      && ! grep -qE '@clip_copy_command|@override_copy_command|\.local/bin/clip' "$conf" 2>/dev/null; then
      log_info "to get portable copy/paste inside tmux, add this line to $conf:"
      log_info "    source-file $snippet"
    fi
    # BARE names only. An absolute path reached after probing for a Windows root is
    # the correct portable spelling, not a finding; comments are stripped because
    # that config explains in prose that it contains no bare clip.exe, and the
    # naive pattern matched the explanation. See check_tmux in modules/90-doctor.sh.
    if grep -vE '^[[:space:]]*#' "$conf" 2>/dev/null | grep -qE '(^|[^/])(clip|powershell)\.exe'; then
      log_warn "$conf calls clip.exe / powershell.exe by name."
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

# ---------------------------------------------------------------------------
# tmux session saver
# ---------------------------------------------------------------------------

# install_tmux_session_saver
#   Installs config/tmux/tmux-save-session.sh into ~/.tmux-sessions/, mode 0755.
#
#   Only the SCRIPT is vendored here. Its own repository holds ~45 generated
#   `sessions-*.sh` restore scripts, and each of those is a verbatim transcript of
#   somebody's working day — every pane's working directory and the command it was
#   running. That is personal data and it is not going in a public repository, so
#   this repository does not clone that repository at all. (It is also why the
#   script's OUT_DIR defaults to its own directory and why that directory is
#   ~/.tmux-sessions and not this checkout: what it writes must land beside it, in
#   your home, and never anywhere that gets committed.)
#
#   write_managed makes it idempotent: byte-identical is a silent no-op, a
#   different version is BACKED UP before it is replaced, and a copy you edited
#   yourself is backed up and reported (or kept, with DEVENV_KEEP_LOCAL=1). It is
#   recorded in the manifest, so `devenv uninstall` removes the script and leaves
#   every session file you saved alone.
install_tmux_session_saver() {
  local src="$DEVENV_HOME/config/tmux/tmux-save-session.sh"
  local dst="$TMUX_SESSIONS_DIR/tmux-save-session.sh"

  if [ ! -r "$src" ]; then
    log_warn "config/tmux/tmux-save-session.sh is missing from the checkout — not installed"
    return 0
  fi
  ensure_dir "$TMUX_SESSIONS_DIR" || return 0
  # Redirection, not a pipe: the right-hand side of a pipeline is a subshell, and
  # DEVENV_CHANGED_LAST set in one cannot be read back here (lib/fs.sh:19).
  write_managed "$dst" 0755 <"$src" || {
    log_warn "could not install $dst"
    return 0
  }
  if [ "${DEVENV_CHANGED_LAST:-0}" = 1 ]; then
    log_info "tmux sessions: save them with  $dst"
    log_info "  it writes $TMUX_SESSIONS_DIR/sessions-<date>-<n>.sh — run that to restore them"
  else
    log_debug "the tmux session saver is already current at $dst"
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

  install_tree_sitter
  install_tmux
  install_external_configs
  install_tmux_session_saver

  if have_root; then
    pkg_install_optional vim
  fi

  log_step_end
  return 0
}

module_main "$@"
