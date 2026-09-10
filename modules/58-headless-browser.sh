#!/usr/bin/env bash
# meta: name=headless-browser
# meta: desc=system dependencies for headless browser automation (playwright, chrome for testing)
# meta: profiles=
# meta: os=!container
# meta: arch=amd64,arm64
# meta: needs=npx
# meta: root=yes
#
# NEVER in a profile. Run it explicitly:  devenv --only headless-browser
#
# SPEC-ADDENDUM §5.3. The package list is DELEGATED TO THE VENDOR and never
# hand-maintained here: Playwright keys its dependency set by distro inside
# nativeDeps.ts (ubuntu24.04-x64, debian12-x64 and debian13-x64 genuinely differ —
# libasound2t64 on noble vs libasound2 on bookworm), and `install-deps` reads
# /etc/os-release and picks the right list itself. Copying that list into a shell
# script guarantees drift the first time this repo runs on Debian.
#
# This module owns xvfb, the fonts-* set, libnss3/libatk*/libgbm1/libcups2t64/
# libasound2t64, libgtk-3-0t64, libgtk-4-1, libgles2, libepoxy0 and gstreamer1.0-*.
# They are NOT x11/desktop residue — they are Playwright's own runtime deps —
# which is why 91-purge-desktop `apt-mark manual`s them before it autoremoves.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# `latest` is the vendor's own default. Set PLAYWRIGHT_VERSION to pin it.
PW_SPEC="playwright@${PLAYWRIGHT_VERSION:-latest}"
PW_BROWSERS=${PLAYWRIGHT_BROWSERS:-chromium firefox webkit}

module_main() {
  local npx
  npx=$(command -v npx) || skip "npx is not on PATH"

  log_info "delegating the dependency list to $PW_SPEC (never hand-maintained here)"

  # `sudo npx` alone loses an nvm-provided node: sudo resets PATH and npx's
  # shebang is `#!/usr/bin/env node`. Hand the child the caller's PATH.
  if ! run_sudo env "PATH=$PATH" "$npx" --yes "$PW_SPEC" install-deps; then
    log_error "playwright install-deps failed."
    log_error "  On a distro Playwright does not know yet, install its deps by hand:"
    log_error "  npx $PW_SPEC install-deps --dry-run   prints the exact apt line."
    return 1
  fi
  changed "playwright system dependencies"

  # Browser builds land in ~/.cache/ms-playwright and are skipped when present,
  # so a second run downloads nothing.
  # shellcheck disable=SC2086  # PW_BROWSERS is a deliberate word list
  if ! run "$npx" --yes "$PW_SPEC" install $PW_BROWSERS; then
    log_warn "browser download failed — the system deps are installed; retry with:"
    log_warn "  npx $PW_SPEC install $PW_BROWSERS"
    return 0
  fi
  changed "playwright browsers: $PW_BROWSERS"

  log_info "Chrome for Testing, if that is what you actually want, is a one-liner and"
  log_info "  needs no extra packages beyond the set above:"
  log_info "  npx @puppeteer/browsers install chrome@stable"
  return 0
}

module_main "$@"
