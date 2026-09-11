#!/usr/bin/env bash
# meta: name=lang-rust
# meta: desc=the rust toolchain via rustup
# meta: profiles=devops,full
# meta: os=any
# meta: needs=
# meta: root=no
#
# SPEC §5.5 / §7.4: Rust is kept as a LANGUAGE, not as a package manager.
# `cargo install` compiles from source on the user's machine — minutes of CPU, a
# multi-hundred-MB ~/.cargo/registry, and a binary nothing can then version-check.
# The two crates the old scripts/tools.sh installed that way have moved:
#     eza     -> modules/10-shell.sh, pinned release tarball (K19)
#     tldr    -> modules/05-base-packages.sh, apt tealdeer or the pinned binary (K18)
# Nothing in this repository calls cargo_install. rustup is here so that `cargo`
# works for the user's own projects, and so that -sys crates can build (05
# installs pkg-config, libssl-dev and cmake for exactly that).
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"

# rustup_present — rustup is installed AND its shim directory is populated.
rustup_present() {
  [ -x "$CARGO_HOME_DIR/bin/rustup" ] || have rustup
}

install_rustup() {
  if rustup_present; then
    local v
    v=$(bin_version "$CARGO_HOME_DIR/bin/rustup" --version 2>/dev/null) || v=''
    log_skip "rustup is already installed${v:+ ($v)}"
    return 0
  fi

  # --no-modify-path is mandatory: rustup would otherwise APPEND a source line to
  # ~/.bashrc, ~/.profile and ~/.zshenv. ~/.bashrc.d/20-lang.sh sources
  # ~/.cargo/env exactly once (the pre-repo ~/.bashrc sourced it twice, once
  # spelled `.` and once `source`, which is why matching on text never works).
  # --profile minimal: rustc + cargo + rust-std. rust-docs alone is ~200 MB and
  # nothing on a devops box reads it from disk.
  #
  # No TMPDIR is set here on purpose. sh_installer_run already runs the script
  # from devenv_execdir with TMPDIR pointed at it, which is what makes this work
  # on a host with /tmp noexec: install.sh puts rustup-init in `mktemp -d` and
  # execs it, and without that it dies with
  #     error: Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
  #     (likely because of mounting /tmp as noexec)
  # Do not add a TMPDIR --env here; it would override the one that fixes it.
  sh_installer_run "https://sh.rustup.rs" \
    --reason 'rust-lang publishes rustup-init through this redirector and signs the release artefacts it fetches, not the shell wrapper; there is no stable per-release digest to pin' \
    --env "RUSTUP_HOME=$RUSTUP_HOME_DIR" --env "CARGO_HOME=$CARGO_HOME_DIR" \
    -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN:-stable}" \
    || {
      log_error "rustup could not be installed"
      return 1
    }
  changed "rustup ${RUST_TOOLCHAIN:-stable}"
  return 0
}

# report_cargo_leftovers
#   The live box has eza and tldr under ~/.cargo/bin from the old scripts. They
#   still work; they are simply no longer this repo's install path, and a
#   cargo-built binary will shadow the packaged one because 10-path.sh puts
#   ~/.cargo/bin ahead of /usr/local/bin. Reported, never removed (MUST-FIX S9).
report_cargo_leftovers() {
  local b moved=()
  for b in eza tldr; do
    [ -x "$CARGO_HOME_DIR/bin/$b" ] && moved+=("$b")
  done
  [ ${#moved[@]} -gt 0 ] || return 0
  log_warn "these are still installed from cargo: ${moved[*]}"
  log_warn "  This repo now installs them from apt or a pinned release instead, and"
  log_warn "  ~/.cargo/bin comes first on PATH, so the cargo build is what you run."
  log_warn "  To switch over:  cargo uninstall ${moved[*]}"
  return 0
}

module_main() {
  log_step "rust"

  install_rustup || {
    log_step_end
    return 1
  }

  # `rustup update` is a network operation that can pull a whole new toolchain;
  # "install my tools" must not do that silently. --upgrade asks for it.
  if [ "${DEVENV_UPGRADE:-0}" = 1 ] && rustup_present; then
    run "$CARGO_HOME_DIR/bin/rustup" update "${RUST_TOOLCHAIN:-stable}" \
      || log_warn "rustup update failed"
  fi

  report_cargo_leftovers

  if [ ! -s "$CARGO_HOME_DIR/env" ] && ! is_dry_run; then
    log_warn "$CARGO_HOME_DIR/env is missing — ~/.bashrc.d/20-lang.sh will not add cargo to PATH"
  fi

  log_step_end
  return 0
}

module_main "$@"
