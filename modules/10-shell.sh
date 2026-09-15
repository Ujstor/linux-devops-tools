#!/usr/bin/env bash
# meta: name=shell
# meta: desc=bashrc hook, the bashrc.d fragments, prompt, cli tools and completions
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=no
#
# D4: shell integration is ONE marker-fenced block in ~/.bashrc that sources
# ~/.bashrc.d/00-init.bash. Every fragment is a whole-file drop-in, so a second
# run appends nothing and duplicates nothing. Nothing here ever runs `sed -i` on
# a dotfile — that is what replaced the mybash symlink with a regular file on the
# live box and left ~/.bashrc 43 lines adrift from its own repo.
#
# root=no on purpose (SPEC §5.5). The dotfile half — which is the point of this
# module — needs no privileges at all, so it must still run on a box where the
# user is not a sudoer. The package/binary half is guarded by have_root and
# installs into ~/.local/bin instead of /usr/local/bin when root is unavailable.
#
# mybash — the P8 decision, REVERSED on 2026-09-15, and why:
#   The old rule was "this repo never installs Ujstor/mybash and never runs its
#   setup.sh, which symlinks ~/.bashrc and would be a data-loss event on a box
#   that already has one". The premise stopped being true: mybash's link_file()
#   backs a real ~/.bashrc up to ~/.bashrc.bak before it links, never overwrites
#   an existing backup, and is a no-op when the link is already correct.
#   So mybash is now ON by default and its setup.sh is what activates it, through
#   the `post=` field of its entry in config/external-repos.sh. This file still
#   knows nothing about it beyond the reporting below — the list decides.
#   Turn it off with DEVENV_EXTREPO_MYBASH=0 (or DEVENV_INSTALL_MYBASH=0).
#
#   What has NOT changed: no fragment requires it. Each alias, prompt and
#   completion is guarded by `command -v` and by a "did something else already do
#   this" probe, so the set behaves identically with mybash and without it — which
#   is what makes turning it off a real option rather than a broken one.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

LOCAL_BIN="$HOME/.local/bin"
FONT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fonts"

# The nine fragments of SPEC §6.3, in load order. ~/.bashrc.d/55-sso.sh is the
# addendum's tenth and belongs to modules/38-auth-sso.sh; ~/.bashrc.d/90-local.sh
# is the user's and is created empty exactly once.
FRAGMENTS=(
  00-init.bash
  05-env.sh
  10-path.sh
  20-lang.sh
  30-k8s.sh
  40-shellui.sh
  50-platform.sh
  60-aliases.sh
  70-tools.sh
)

# Where release binaries go. Resolved ONCE in module_main: /usr/local/bin when we
# can become root, else the user's own ~/.local/bin — which 10-path.sh puts at the
# front of PATH anyway. Resolving it once matters, because have_root prints its
# (long, actionable) explanation the first time it fails, and a $(subshell) would
# lose the cached answer and reprint it on every call.
BIN_DEST=/usr/local/bin

# ---------------------------------------------------------------------------
# ~/.bashrc and ~/.bashrc.d
# ---------------------------------------------------------------------------

install_fragments() {
  local f src
  bashrc_ensure_hook || return 1

  for f in "${FRAGMENTS[@]}"; do
    src="$DEVENV_HOME/config/bashrc.d/$f"
    if [ ! -r "$src" ]; then
      log_warn "shipped fragment is missing from the checkout: config/bashrc.d/$f"
      continue
    fi
    bashrc_dropin "$f" <"$src" || log_warn "could not install ~/.bashrc.d/$f"
  done

  bashrc_ensure_local

  # MUST-FIX S3: opt-in (DEVENV_PRUNE=1), marker-only, never 90-local.sh. The
  # keep-list carries 55-sso.sh so that pruning from a `minimal` run cannot
  # delete the fragment modules/38-auth-sso.sh installed.
  bashrc_dropin_prune "${FRAGMENTS[@]}" 55-sso.sh
}

# install_external_configs — every entry in the list that this module owns.
#   Today that is mybash and nothing else, and the module does not know that: the
#   list decides. An entry of yours with module=shell is synced here too, with the
#   same guarantees (never over a dirty worktree, never over a file of yours) and
#   without this file changing.
install_external_configs() {
  extrepo_seed_user_list
  extrepo_sync_module shell
  return 0
}

# report_mybash — the reporting half. Syncing and activating are the list's job
# (see the header); this only says what ended up on the box, and it asks the list
# where mybash lives so there is still exactly one place that knows the path. An
# entry the user deleted from the list is not reported on at all.
report_mybash() {
  local dir
  extrepo_load
  dir=$(extrepo_get mybash dest) || {
    log_debug "no mybash entry in the external-repos list — nothing to report"
    return 0
  }

  if ! extrepo_enabled mybash; then
    if [ -d "$dir" ]; then
      log_info "mybash is switched off but still checked out at $dir — left exactly as it is"
    else
      log_debug "mybash is switched off and not installed — nothing here depends on it"
    fi
    return 0
  fi

  if [ ! -d "$dir" ]; then
    log_warn "mybash is enabled but there is no checkout at $dir — see the sync warnings above"
    return 0
  fi

  if [ -L "$HOME/.bashrc" ]; then
    log_info "mybash is active: ~/.bashrc -> $(readlink "$HOME/.bashrc")"
    log_info "  the linux-devops-tools block is written through the link, into the checkout"
  elif [ -e "$HOME/.bashrc.bak" ]; then
    log_warn "mybash is checked out at $dir but ~/.bashrc is still a regular file."
    log_warn "  A ~/.bashrc.bak exists, so its setup.sh has run before — re-run it to relink:"
    log_warn "      (cd '$dir' && ./setup.sh)"
  else
    log_info "mybash is checked out at $dir; ~/.bashrc is a regular file and was not replaced"
    log_info "  every ~/.bashrc.d fragment works either way — run its setup.sh to adopt it:"
    log_info "      (cd '$dir' && ./setup.sh)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# ~/.local/bin name fixes
# ---------------------------------------------------------------------------

# link_alt_bin NAME REAL
#   Debian and Ubuntu rename two binaries to avoid a clash (`fdfind` for fd,
#   `batcat` for bat) and 7zip installs `7zz`. Give each its usual name in
#   ~/.local/bin — but only when nothing else already provides it, so we never
#   shadow a real /usr/bin/NAME or a brew build the user prefers.
link_alt_bin() {
  local name=$1 real=$2 cur
  local dst="$LOCAL_BIN/$name"
  if cur=$(command -v "$name" 2>/dev/null); then
    if [ "$cur" != "$dst" ]; then
      log_skip "$name is already provided by $cur"
      return 0
    fi
  fi
  if ! have "$real"; then
    log_debug "$real is not installed — no $name shim"
    return 0
  fi
  ensure_dir "$LOCAL_BIN" || return 0
  symlink_file "$(command -v "$real")" "$dst" || log_warn "could not link $dst"
  return 0
}

# ---------------------------------------------------------------------------
# starship
# ---------------------------------------------------------------------------

# starship_kubernetes_block
#   The [kubernetes] half of the K31 patch. `detect_env_vars = ['KUBECONFIG']`
#   is what makes it render ONLY in a shell where a cluster was chosen with `kc`
#   — a prompt that shows a context in every window is a prompt nobody reads.
starship_kubernetes_block() {
  cat <<'TOML'
[kubernetes]
disabled = false
format = '[$symbol$context( \($namespace\))]($style) '
symbol = "☸ "
style = "bold blue"
# Render only where a kubeconfig was deliberately selected (see `kc`).
detect_env_vars = ["KUBECONFIG"]

[kubernetes.context_aliases]
# Shorten your own long context names here, e.g. keep the last two dash-separated
# fields of a context named like "<org>-<site>-<cluster>":
# '^.*-(?P<var_site>[^-]+)-(?P<var_cluster>[^-]+)$' = '$var_site-$var_cluster'
TOML
}

starship_format_note() {
  log_info "The [kubernetes] block alone renders nothing: starship's top-level"
  log_info "\`format\` string decides which modules are drawn. Add \$kubernetes to it,"
  log_info "between \$git_status and the language segment:"
  log_info "      \$git_branch\\"
  log_info "      \$git_status\\"
  log_info "  +   \$kubernetes\\"
  log_info "      \$c\\"
  if [ -r "$DEVENV_HOME/config/git/starship-kubernetes.patch" ]; then
    log_info "The full patch is shipped at config/git/starship-kubernetes.patch"
  fi
}

# starship_config — K31. Default is `print`: change nothing, show the patch.
starship_config() {
  local mode=${DEVENV_STARSHIP:-print}
  local user_cfg="${STARSHIP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml}"
  local overlay="$DEVENV_CONFIG/starship.toml"
  local target

  have starship || return 0

  case $mode in
    print)
      log_info "starship: the kubernetes prompt segment is NOT installed (--starship=print)."
      log_info "Add this to ${user_cfg}:"
      starship_kubernetes_block | while IFS= read -r line; do log_info "  $line"; done
      starship_format_note
      log_info "Or re-run with --starship=overlay|adopt|upstream to have it written for you."
      ;;
    overlay)
      # A separate config this repo owns, so a symlinked ~/.config/starship.toml
      # (mybash's) is never touched and the other repo never goes dirty.
      ensure_dir "$DEVENV_CONFIG" || return 0
      if [ -r "$user_cfg" ] && [ ! -e "$overlay" ]; then
        write_if_changed "$overlay" 0644 <"$user_cfg" || return 0
      fi
      starship_kubernetes_block | ensure_block_in_file "$overlay" starship || return 0
      log_info "starship overlay written to $overlay"
      log_info "Activate it by adding this line to ~/.config/devops-env/shell.env:"
      log_info "  export STARSHIP_CONFIG=\"$overlay\""
      starship_format_note
      ;;
    adopt)
      if [ -L "$user_cfg" ]; then
        target=$(readlink -f -- "$user_cfg" 2>/dev/null) || target=''
        log_warn "severing $user_cfg -> ${target:-?} so this box owns its own prompt config"
        backup_file "$user_cfg" >/dev/null
        if ! is_dry_run && [ -n "$target" ] && [ -r "$target" ]; then
          run rm -f -- "$user_cfg" || return 0
          write_if_changed "$user_cfg" 0644 <"$target" || return 0
        fi
      fi
      starship_kubernetes_block | ensure_block_in_file "$user_cfg" starship || return 0
      starship_format_note
      ;;
    upstream)
      target=$(readlink -f -- "$user_cfg" 2>/dev/null) || target=$user_cfg
      if [ ! -e "$target" ]; then
        log_warn "no starship config at $user_cfg — nothing to patch upstream"
        return 0
      fi
      local repo_dir
      repo_dir=$(dirname -- "$target")
      if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1 \
        && [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        log_warn "$repo_dir has uncommitted changes — refusing to patch $target"
        return 0
      fi
      log_warn "patching $target, which lives in another git worktree — commit and upstream it"
      starship_kubernetes_block | ensure_block_in_file "$target" starship || return 0
      starship_format_note
      ;;
    *)
      log_warn "unknown --starship mode '$mode' (use print|overlay|adopt|upstream)"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# CLI tools
# ---------------------------------------------------------------------------

install_starship() {
  local rc=0
  gh_release_install starship/starship \
    'starship-{arch_rust}-unknown-linux-musl.tar.gz' starship "${STARSHIP_VERSION:?}" \
    --checksum-url 'https://github.com/starship/starship/releases/download/{tag}/starship-{arch_rust}-unknown-linux-musl.tar.gz.sha256' \
    --dest "$BIN_DEST" || rc=$?
  [ "$rc" = 78 ] && log_skip "starship publishes no ${OS_ARCH_RUST:-?} musl build"
  return 0
}

# install_fzf / install_zoxide — K19, one runtime probe instead of a distro matrix.
#   fzf   0.48.0 is the `fzf --bash` cutover (bookworm 0.38, noble 0.44.1 are below it)
#   zoxide 0.9.0 — bookworm and jammy ship 0.4.3, from 2020
install_fzf() {
  local rc=0
  if ! have_root; then
    gh_release_install junegunn/fzf 'fzf-{version}-linux_{arch_go}.tar.gz' fzf \
      "${FZF_VERSION:?}" --checksum-asset 'fzf_{version}_checksums.txt' \
      --dest "$LOCAL_BIN" || rc=$?
  else
    apt_or_release fzf fzf 0.48.0 junegunn/fzf 'fzf-{version}-linux_{arch_go}.tar.gz' \
      --release-version "${FZF_VERSION:?}" \
      --checksum-asset 'fzf_{version}_checksums.txt' \
      --dest "$BIN_DEST" || rc=$?
  fi
  [ "$rc" = 78 ] && log_skip "no fzf release asset for ${OS_ARCH_GO:-?}"
  return 0
}

install_zoxide() {
  local rc=0
  local pattern='zoxide-{version}-{arch_rust}-unknown-linux-musl.tar.gz'
  local why='ajeetdsouza/zoxide publishes no checksum file with its release archives (verified for v0.10.0)'
  if ! have_root; then
    gh_release_install ajeetdsouza/zoxide "$pattern" zoxide "${ZOXIDE_VERSION:?}" \
      --no-verify --no-verify-reason "$why" --dest "$LOCAL_BIN" || rc=$?
  else
    apt_or_release zoxide zoxide 0.9.0 ajeetdsouza/zoxide "$pattern" \
      --release-version "${ZOXIDE_VERSION:?}" \
      --no-verify --no-verify-reason "$why" \
      --dest "$BIN_DEST" || rc=$?
  fi
  [ "$rc" = 78 ] && log_skip "no zoxide release asset for ${OS_ARCH_RUST:-?}"
  return 0
}

# install_eza — K19's exception: eza is ABSENT from bookworm and jammy entirely,
# so branching on the apt candidate buys nothing. Always the release tarball.
# musl where upstream builds it (that is what keeps it working on bookworm's
# older glibc); arm64 only has a gnu build.
install_eza() {
  local asset='eza_{arch_rust}-unknown-linux-musl.tar.gz' rc=0
  case ${OS_ARCH_DPKG:-} in
    amd64) ;;
    *) asset='eza_{arch_rust}-unknown-linux-gnu.tar.gz' ;;
  esac
  gh_release_install eza-community/eza "$asset" eza "${EZA_VERSION:?}" \
    --no-verify \
    --no-verify-reason 'eza-community/eza publishes no checksum asset (verified for v0.23.5)' \
    --dest "$BIN_DEST" || rc=$?
  [ "$rc" = 78 ] && log_skip "no eza release asset for ${OS_ARCH_RUST:-?}"
  return 0
}

# install_gdu — packaged on every target; stop compiling it. The pinned
# GO_TOOL_GDU is only the fallback for an archive that does not carry it.
install_gdu() {
  have gdu && {
    log_skip "gdu is already installed"
    return 0
  }
  if have_root && pkg_install_first gdu; then
    return 0
  fi
  go_install "github.com/dundee/gdu/v5/cmd/gdu@${GO_TOOL_GDU:?}" gdu \
    || log_warn "could not install gdu"
  return 0
}

install_archivers() {
  if have_root; then
    # 7zip provides /usr/bin/7zz, p7zip-full provides /usr/bin/7z.
    pkg_install_first 7zip p7zip-full || log_skip "no 7-zip package in this archive"
  fi
  link_alt_bin 7z 7zz
  return 0
}

# install_extras — the `full` tier of the §7.1 shell rows.
install_extras() {
  local rc=0
  [ "${INSTALL_EXTRAS:-0}" = 1 ] || {
    log_debug "INSTALL_EXTRAS is off — skipping duf/yazi/fastfetch"
    return 0
  }

  have_root && pkg_install_optional duf

  # yazi is in no distro archive. Its .deb assets are named by rust triple.
  if ! have yazi; then
    deb_release_install sxyazi/yazi \
      'yazi-{arch_rust}-unknown-linux-gnu.deb' yazi "${YAZI_VERSION:?}" --bin yazi \
      --no-verify \
      --no-verify-reason 'sxyazi/yazi publishes no checksum asset (verified for v26.9.1)' \
      || rc=$?
    [ "$rc" != 0 ] && log_skip "yazi ${YAZI_VERSION:-} is not available for ${OS_ARCH_RUST:-?}"
  fi

  # fastfetch is absent from bookworm and noble; its assets use uname-ish arch
  # names that match neither the dpkg nor the go token, so they are spelled out.
  if ! have fastfetch; then
    local ff=''
    case ${OS_ARCH_DPKG:-} in
      amd64) ff=fastfetch-linux-amd64.deb ;;
      arm64) ff=fastfetch-linux-aarch64.deb ;;
      armhf) ff=fastfetch-linux-armv7l.deb ;;
    esac
    if have_root && pkg_install_first fastfetch; then
      :
    elif [ -n "$ff" ]; then
      rc=0
      deb_release_install fastfetch-cli/fastfetch "$ff" fastfetch "${FASTFETCH_VERSION:?}" \
        --no-verify \
        --no-verify-reason 'fastfetch-cli/fastfetch publishes no checksum asset (verified for 2.68.1)' \
        || rc=$?
      [ "$rc" != 0 ] && log_skip "fastfetch ${FASTFETCH_VERSION:-} is not available here"
    else
      log_skip "fastfetch publishes no build for ${OS_ARCH_DPKG:-?}"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Nerd Font — SPEC-ADDENDUM §5.2
# ---------------------------------------------------------------------------
#
# Glyphs are rasterised by the process that OWNS THE TERMINAL WINDOW. On WSL2
# that is WindowsTerminal.exe; over SSH it is the laptop's emulator. A Linux-side
# font only helps the third case: sitting at this box's own console. So the font
# is installed only when this is neither WSL nor headless — and it is
# Symbols-Only, a fallback face, so the user's real monospace font keeps drawing
# latin text while fontconfig fills in the private-use codepoints.
install_nerd_font() {
  if os_is_wsl || os_is_headless; then
    log_info "Nerd Font: install it on the machine running your terminal, not here"
    log_info "  Windows Terminal 1.21+ already bundles Cascadia Code NF; otherwise"
    log_info "  winget install --id DEVCOM.JetBrainsMonoNerdFont --exact  (see docs/tools.md)"
    return 0
  fi
  if ! have fc-list; then
    have_root && pkg_install_optional fontconfig
    have fc-list || {
      log_skip "fontconfig is not installed — no font work"
      return 0
    }
  fi
  # Read fc-list into a variable and match from a here-string. Piping straight
  # into `grep -q` would make grep exit on the first match, kill fc-list with
  # SIGPIPE, and — under this file's `set -o pipefail` — make the whole test read
  # as FALSE, so the font would be reinstalled on every single run.
  local families=''
  families=$(fc-list :family 2>/dev/null) || families=''
  if grep -qi 'Symbols Nerd Font' <<<"$families"; then
    log_skip "Symbols Nerd Font is already installed"
    return 0
  fi
  if is_dry_run; then
    log_dryrun "install NerdFontsSymbolsOnly ${NERD_FONT_VERSION:-} into $FONT_DIR"
    return 0
  fi

  local tag base work want
  tag=$(gh_resolve_version ryanoasis/nerd-fonts "${NERD_FONT_VERSION:?}") || {
    log_warn "could not resolve a nerd-fonts release"
    return 0
  }
  base="https://github.com/ryanoasis/nerd-fonts/releases/download/$tag"
  work=$(devenv_tmpdir) || return 0
  download "$base/SHA-256.txt" "$work/SHA-256.txt" || {
    log_warn "could not fetch the nerd-fonts checksum file — not installing the font"
    return 0
  }
  want=$(checksum_lookup "$work/SHA-256.txt" NerdFontsSymbolsOnly.zip) || {
    log_warn "NerdFontsSymbolsOnly.zip is not listed in SHA-256.txt — not installing the font"
    return 0
  }
  download "$base/NerdFontsSymbolsOnly.zip" "$work/font.zip" || return 0
  verify_sha256 "$work/font.zip" "$want" || return 0
  ensure_dir "$work/unpacked" || return 0
  run unzip -q -o "$work/font.zip" -d "$work/unpacked" || return 0
  ensure_dir "$FONT_DIR" || return 0
  local ttf n=0
  for ttf in "$work"/unpacked/SymbolsNerdFont*.ttf; do
    [ -e "$ttf" ] || continue
    run install -m 0644 -- "$ttf" "$FONT_DIR/" || continue
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || {
    log_warn "no SymbolsNerdFont*.ttf inside NerdFontsSymbolsOnly.zip"
    return 0
  }
  # -f, not -fv: -v dumps several hundred lines into the install log.
  run fc-cache -f "$FONT_DIR" || log_warn "fc-cache failed"
  changed "Symbols Nerd Font $tag"
  return 0
}

# ---------------------------------------------------------------------------

module_main() {
  log_step "shell"

  # Resolve the privilege question ONCE, before anything branches on it.
  if have_root; then
    BIN_DEST=/usr/local/bin
  else
    BIN_DEST=$LOCAL_BIN
    log_info "no root available — release binaries go to $BIN_DEST instead of /usr/local/bin"
  fi
  # Every install below is version-gated on `<bin> --version`, which resolves
  # through PATH. This module may run with a PATH that predates the directory it
  # installs into (a curl-piped first run, or `devenv` from cron), and without
  # this a second run would re-download everything instead of short-circuiting.
  case ":$PATH:" in
    *":$BIN_DEST:"*) ;;
    *) PATH="$BIN_DEST:$PATH" ;;
  esac
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *) PATH="$LOCAL_BIN:$PATH" ;;
  esac
  export PATH

  if [ "${DEVENV_ADOPT_BASHRC:-0}" = 1 ]; then
    bashrc_adopt || log_warn "could not adopt ~/.bashrc"
  fi

  install_fragments || die "could not install the shell fragments"
  install_external_configs
  report_mybash

  ensure_dir "$LOCAL_BIN" || true
  link_alt_bin fd fdfind
  link_alt_bin bat batcat

  install_starship
  install_fzf
  install_zoxide
  install_eza
  install_gdu
  install_archivers
  install_extras
  install_nerd_font
  starship_config

  # D9: generate the completion cache once, here, instead of paying 0.23 s of
  # `source <(x completion bash)` in every interactive shell forever.
  if [ -x "$DEVENV_HOME/bin/devenv-completions" ]; then
    "$DEVENV_HOME/bin/devenv-completions" || log_warn "some completions could not be generated"
  else
    log_warn "bin/devenv-completions is missing — no completion cache was generated"
  fi

  log_info "run 'exec bash -l' (or open a new terminal) to pick up the new shell setup"
  log_step_end
  return 0
}

module_main "$@"
