#!/usr/bin/env bash
# meta: name=brew
# meta: desc=audit an existing homebrew install and print where each leaf goes instead
# meta: profiles=full
# meta: os=any
# meta: needs=
# meta: root=no
#
# D13/K9. Homebrew leaves the default install path. This module is the migration
# tool, not an installer:
#
#     devenv --only brew                    audit + the migration map (default)
#     INSTALL_HOMEBREW=1 devenv --only brew  install it, glibc >= 2.39 required
#     devenv --only brew --uninstall        the vendor uninstall, confirmed
#
# WHY IT LEFT THE DEFAULT PATH. Linuxbrew's bottles are built against glibc 2.39,
# so on Debian 12 (2.36) and Ubuntu 22.04 (2.35) every formula is built FROM
# SOURCE — a documented Tier-2 path, and hours of CPU for tools that all have an
# apt or release-binary home. It also caused a live, reproduced breakage on the
# author's box: brew's own `python3` (3.14) shadowed the system one while `pip3`
# stayed the system 3.12, because `brew shellenv` was emitted BEFORE the system
# paths in ~/.bashrc. config/bashrc.d/70-tools.sh now emits it AFTER them, which
# is the half of this that is mandatory whether or not brew is ever installed.
#
# It is in `full.list` as an AUDIT: on a box with no brew it prints one line and
# returns, and it never installs anything unless INSTALL_HOMEBREW=1.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# The map SPEC §7.6 defines. One row per brew leaf found on the author's box,
# with where this repository puts it instead. Printed for the leaves that are
# actually installed, so the output is about THIS machine.
brew_new_home() {
  case ${1:-} in
    fd | ripgrep | jq | sshpass | poppler | sevenzip | imagemagick | ffmpeg | tree-sitter)
      printf 'apt (base-packages / media)\n'
      ;;
    fzf | zoxide) printf 'apt when new enough, else a pinned release binary (shell)\n' ;;
    eza | tealdeer | tldr) printf 'release binary or apt — no longer cargo install (shell)\n' ;;
    grpcurl) printf 'release .deb, or go install (kubernetes)\n' ;;
    yazi) printf 'release .deb (shell)\n' ;;
    resvg) printf 'apt where packaged, else skipped — never built (media)\n' ;;
    tree-sitter-cli) printf 'DROPPED — only needed to author grammars\n' ;;
    font-symbols-only-nerd-font)
      printf '%s/.local/share/fonts + fc-cache, or install it on Windows under WSL\n' "$HOME"
      ;;
    *) printf 'no mapping recorded — check whether apt or an upstream release has it\n' ;;
  esac
}

brew_prefix() {
  local p
  for p in /home/linuxbrew/.linuxbrew /opt/homebrew "$HOME/.linuxbrew"; do
    [ -x "$p/bin/brew" ] && {
      printf '%s\n' "$p"
      return 0
    }
  done
  have brew || return 1
  p=$(brew --prefix 2>/dev/null) || return 1
  printf '%s\n' "$p"
}

audit() {
  local prefix leaves leaf n=0
  if ! prefix=$(brew_prefix); then
    log_skip "homebrew is not installed here — nothing to migrate"
    return 0
  fi
  log_info "homebrew found at $prefix"

  if ! have brew; then
    log_warn "$prefix/bin/brew exists but brew is not on PATH — run the audit from a shell that has it"
    return 0
  fi

  leaves=$(brew leaves 2>/dev/null) || leaves=''
  if [ -z "$leaves" ]; then
    log_info "no explicitly-installed formulae — this brew can simply be removed"
  else
    log_step "where each brew leaf goes instead"
    while IFS= read -r leaf; do
      [ -n "$leaf" ] || continue
      log_info "$(printf '%-28s %s' "$leaf" "$(brew_new_home "$leaf")")"
      n=$((n + 1))
    done <<<"$leaves"
    log_step_end
    log_info "$n leaf formula(e). Nothing was removed: uninstall brew yourself when you are ready,"
    log_info "  with  devenv --only brew --uninstall"
  fi

  # The PATH-ordering fix is the part that matters even if brew stays.
  log_info "config/bashrc.d/70-tools.sh emits 'brew shellenv' AFTER the system paths,"
  log_info "  so a brew python3 can no longer shadow the system one while pip3 does not."
  return 0
}

install_brew() {
  local libc=${OS_LIBC:-0}
  if have brew; then
    log_skip "homebrew is already installed ($(command -v brew))"
    return 0
  fi
  if ! version_ge "$libc" 2.39; then
    log_error "refusing to install homebrew: this box has glibc $libc, and Linuxbrew's"
    log_error "  bottles are built against 2.39 — EVERY formula would be built from source."
    log_error "  Every tool this repository needs has an apt or release-binary home instead;"
    log_error "  run 'devenv --only brew' with INSTALL_HOMEBREW unset to see the map."
    return 1
  fi
  if ! confirm_dangerous 'install homebrew (a second, source-building package manager)?' \
    INSTALL_HOMEBREW; then
    log_skip 'not installing homebrew'
    return 0
  fi
  sh_installer_run 'https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' \
    --reason 'homebrew publishes install.sh from a moving HEAD and no per-release digest' \
    --env NONINTERACTIVE=1 || {
    log_error 'the homebrew installer failed'
    return 1
  }
  changed 'homebrew'
  log_info "add it to your shell by re-running: devenv --only shell"
  return 0
}

uninstall_brew() {
  local prefix
  if ! prefix=$(brew_prefix); then
    log_skip 'homebrew is not installed here'
    return 0
  fi
  log_warn "this removes $prefix and everything installed into it."
  if ! confirm "uninstall homebrew from $prefix?"; then
    log_skip 'leaving homebrew alone'
    return 0
  fi
  sh_installer_run 'https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh' \
    --reason 'the vendor uninstaller is the only supported way to undo a brew install' \
    -- --force || {
    log_error 'the homebrew uninstaller failed'
    return 1
  }
  changed "removed homebrew from $prefix"
  return 0
}

module_main() {
  local a
  for a in "$@"; do
    case $a in
      --uninstall)
        uninstall_brew
        return 0
        ;;
      *) log_warn "brew: ignoring unknown argument '$a'" ;;
    esac
  done

  if [ "${INSTALL_HOMEBREW:-0}" = 1 ]; then
    install_brew
    return 0
  fi
  audit
  return 0
}

module_main "$@"
