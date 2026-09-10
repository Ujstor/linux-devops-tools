#!/usr/bin/env bash
# meta: name=repo-dev
# meta: desc=the toolchain this repository's own CI runs: shellcheck, shfmt and pre-commit
# meta: profiles=full
# meta: os=any
# meta: needs=
# meta: root=no
#
# SPEC §5.5. Everything `make lint` and .github/workflows/ci.yml need, so that a
# contributor can reproduce CI locally with one command.
#
# It is NOT in `ci.list`. The container matrix installs a profile in order to
# TEST it; it does not lint from inside the container (the workflow lints on the
# runner, with the pinned shellcheck and shfmt container images). Putting the
# linters into the profile under test would only slow every image down.
#
# Nothing here needs root: shfmt goes through `go install`, pre-commit through
# `uv tool`, and shellcheck is the one apt package — installed when the archive
# has it and skipped with one line when it does not, exactly like nala.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# install_shellcheck
#   apt, optional. Every target archive has it; a box that does not gets a line
#   pointing at the container image the CI workflow uses, not a source build.
install_shellcheck() {
  if have shellcheck; then
    log_skip "shellcheck is already installed ($(command -v shellcheck))"
    return 0
  fi
  if ! have_root; then
    log_skip "shellcheck needs root to install from apt"
    return 0
  fi
  if ! pkg_available shellcheck; then
    log_skip "shellcheck has no candidate on ${OS_ID:-this system} ${OS_CODENAME:-}"
    log_info "  CI uses the container image instead: docker run --rm -v \"\$PWD:/mnt\" koalaman/shellcheck:stable"
    return 0
  fi
  pkg_install_optional shellcheck
}

# install_shfmt
#   `go install`, version-gated by lib/lang.sh against $DEVENV_STATE/go-tools.
#   The Debian/Ubuntu `shfmt` package is years behind and does not understand the
#   `-bn` style this repository formats with, so the pinned upstream build is the
#   only one that agrees with CI.
install_shfmt() {
  # go_ensure_path, not `have go`: modules/20-lang-go.sh may have installed
  # /usr/local/go earlier in this same run, after our PATH was inherited.
  if ! go_ensure_path; then
    log_skip "no go toolchain — shfmt comes from 'go install' (run --only lang-go first)"
    return 0
  fi
  go_install "mvdan.cc/sh/v3/cmd/shfmt@${GO_TOOL_SHFMT:?}" shfmt \
    || log_warn "could not install shfmt ${GO_TOOL_SHFMT}"
  return 0
}

# install_pre_commit
#   uv tool, like every other Python CLI in this repository (D7/K17): never pip,
#   never --user, never a touch of EXTERNALLY-MANAGED (MUST-FIX S12).
install_pre_commit() {
  if ! have uv; then
    log_skip "no uv — pre-commit comes from 'uv tool install' (run --only lang-python first)"
    return 0
  fi
  uv_tool_install pre-commit || log_warn "could not install pre-commit"
  return 0
}

module_main() {
  install_shellcheck
  install_shfmt
  install_pre_commit

  log_info "reproduce this repository's CI locally with:  make lint && make test"
  return 0
}

module_main "$@"
