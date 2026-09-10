#!/usr/bin/env bash
# meta: name=personal
# meta: desc=the owner's own side-project clis, entirely env-driven and off by default
# meta: profiles=personal
# meta: os=any
# meta: needs=
# meta: root=no
#
# SPEC §5.5: "superseedr (cargo), shellbeats. No-ops when unreachable."
#
# NOTHING IS HARDCODED HERE, for the same reason as 80-private.sh: this
# repository is public, and a source URL is a fact about the author's estate. The
# two tools are named — they are the author's own public-facing side projects and
# the name alone leaks nothing — but WHERE they come from is a value the operator
# supplies:
#
#     DEVENV_PERSONAL_CARGO   space-separated crates for `cargo install`
#                             (a crates.io name, or "--git <url> <name>")
#     DEVENV_PERSONAL_GO      space-separated module@version specs for `go install`
#     DEVENV_PERSONAL_SH      space-separated https:// installer scripts
#
# Put them in $DEVENV_CONFIG/personal.env, which is gitignored, exactly like
# private.env. With nothing set the module prints one line and returns 0, so
# `devenv --profile personal` on a fresh clone does nothing at all rather than
# failing.
#
# `personal.list` is the ONLY profile that contains this module: it is never
# implied by devops or full.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

PERSONAL_ENV="$DEVENV_CONFIG/personal.env"

# load_personal_env
#   Sources $DEVENV_CONFIG/personal.env when it exists, so the three variables can
#   live in a file instead of the caller's environment. Read-only; it never writes
#   the file (a template belongs in config/, not in a module).
load_personal_env() {
  [ -r "$PERSONAL_ENV" ] || return 0
  log_info "reading $PERSONAL_ENV"
  set -a
  # shellcheck disable=SC1090  # a user-supplied path, validated above
  . "$PERSONAL_ENV"
  set +a
  return 0
}

# install_cargo_tools
#   `cargo install` for every entry in DEVENV_PERSONAL_CARGO. cargo_install is
#   idempotent through `cargo install --list`.
install_cargo_tools() {
  local spec
  [ -n "${DEVENV_PERSONAL_CARGO:-}" ] || return 0
  if ! have cargo; then
    log_skip "no cargo toolchain — run 'devenv --only lang-rust' first"
    return 0
  fi
  for spec in ${DEVENV_PERSONAL_CARGO}; do
    cargo_install "$spec" || log_warn "could not install $spec"
  done
  return 0
}

# install_go_tools
install_go_tools() {
  local spec
  [ -n "${DEVENV_PERSONAL_GO:-}" ] || return 0
  if ! have go; then
    log_skip "no go toolchain — run 'devenv --only lang-go' first"
    return 0
  fi
  for spec in ${DEVENV_PERSONAL_GO}; do
    go_install "$spec" || log_warn "could not install $spec"
  done
  return 0
}

# install_sh_installers
#   A vendor install script, run through lib/net.sh's sh_installer_run so it is
#   downloaded to a file, shown to be non-empty and executed with `bash <file>` —
#   never `curl | bash`, which is what the repository this one replaces did and
#   which pipes a 404 page into a shell.
install_sh_installers() {
  local url
  [ -n "${DEVENV_PERSONAL_SH:-}" ] || return 0
  for url in ${DEVENV_PERSONAL_SH}; do
    case $url in
      https://*) ;;
      *)
        log_warn "refusing a non-https installer: $url"
        continue
        ;;
    esac
    sh_installer_run "$url" \
      --reason 'a personal side project publishes no stable per-release digest' \
      || log_warn "the installer at $url failed"
  done
  return 0
}

module_main() {
  load_personal_env

  if [ -z "${DEVENV_PERSONAL_CARGO:-}${DEVENV_PERSONAL_GO:-}${DEVENV_PERSONAL_SH:-}" ]; then
    log_skip "nothing configured — set DEVENV_PERSONAL_CARGO / _GO / _SH, or write $PERSONAL_ENV"
    log_info "  e.g.  DEVENV_PERSONAL_CARGO='superseedr'  devenv --profile personal"
    return 0
  fi

  install_cargo_tools
  install_go_tools
  install_sh_installers
  return 0
}

module_main "$@"
