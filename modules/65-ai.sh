#!/usr/bin/env bash
# meta: name=ai
# meta: desc=claude code and opencode as base installs, plus the opt-in crush
# meta: profiles=devops,full,ai
# meta: os=any
# meta: needs=
# meta: root=no
#
# USER REQUIREMENT #5 and MUST-FIX P4, verified on the live box:
#
#   ~/.local/bin/claude -> ~/.local/share/claude/versions/2.1.267
#   ~/.local/share/claude/versions/ holds 2.1.259 .260 .263 .266 .267
#   `npm ls -g @anthropic-ai/claude-code` -> EMPTY
#
# Claude Code is installed here by its NATIVE installer and it is part of the
# DEFAULT profile, not an opt-in. The old scripts/tools.sh installed it with
# `npm install -g @anthropic-ai/claude-code` (and fell back to `sudo npm -g`,
# which drops root-owned files into a system prefix with no uninstall story) —
# that is the wrong path and it is gone.
#
# This module INSTALLS IF ABSENT and then leaves it alone. Claude Code updates
# itself: the five versions in versions/ are its own doing. Nothing here ever
# runs `claude update`, and nothing here ever wraps the installer in sudo — the
# installer itself refuses that, because under sudo everything would land in
# root's home and the `claude` command would not work from the user's shell.
#
# opencode is a BASE install on exactly the same terms: its vendor installer,
# install if absent, never upgraded or sudo-wrapped here. It was opt-in until it
# joined the default profile beside Claude Code. crush is still opt-in: it needs
# INSTALL_AI_AGENTS=1, which `--profile ai` sets.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

LOCAL_BIN="$HOME/.local/bin"
OPENCODE_BIN="$HOME/.opencode/bin"

# ---------------------------------------------------------------------------
# Claude Code — base
# ---------------------------------------------------------------------------

claude_present() {
  have claude && return 0
  [ -x "$LOCAL_BIN/claude" ]
}

install_claude() {
  if claude_present; then
    local v=''
    v=$(bin_version "${LOCAL_BIN}/claude" --version 2>/dev/null) || v=''
    log_skip "claude is already installed${v:+ ($v)} — it self-updates, so this repo leaves it alone"
    return 0
  fi

  # The installer takes ONE optional positional argument: stable | latest | X.Y.Z.
  # CLAUDE_CODE_CHANNEL in versions.env is that argument.
  sh_installer_run "https://claude.ai/install.sh" \
    --reason 'Anthropic serves this installer from a rolling URL and it verifies the sha256 of the binary it downloads against a signed manifest; there is no stable per-release digest of the wrapper to pin' \
    -- "${CLAUDE_CODE_CHANNEL:-stable}" \
    || {
      log_error "the Claude Code installer failed"
      return 1
    }
  changed "claude code (${CLAUDE_CODE_CHANNEL:-stable})"
  return 0
}

# report_npm_claude
#   If a previous run of the OLD repo left the npm package behind, both are on
#   PATH and it is not obvious which one runs. Reported, never removed (S9).
report_npm_claude() {
  have npm || return 0
  # Captured into a variable rather than piped into `grep -q`: grep would exit on
  # the first match, npm would die of SIGPIPE, and `set -o pipefail` would turn a
  # genuine hit into a miss.
  local globals=''
  globals=$(npm ls -g --depth=0 --parseable 2>/dev/null) || globals=''
  case $globals in
    *'/@anthropic-ai/claude-code'*) ;;
    *) return 0 ;;
  esac
  log_warn "@anthropic-ai/claude-code is ALSO installed as a global npm package."
  log_warn "  That is the old scripts/tools.sh path. The native install in ~/.local/bin is"
  log_warn "  the supported one and the only one that self-updates."
  log_warn "  To remove the npm copy:  npm uninstall -g @anthropic-ai/claude-code"
  return 0
}

# ---------------------------------------------------------------------------
# opencode — base
# ---------------------------------------------------------------------------

# install_opencode
#   Claude Code's terms exactly: the vendor installer when opencode is absent,
#   nothing at all once it is present — `opencode upgrade` moves it on, this
#   repository never does. Returns 1 when the installer fails, which fails the
#   module the same way a failed Claude Code install does.
install_opencode() {
  if have opencode || [ -x "$OPENCODE_BIN/opencode" ]; then
    local v=''
    v=$(bin_version "$OPENCODE_BIN/opencode" --version 2>/dev/null) || v=''
    log_skip "opencode is already installed${v:+ ($v)} — 'opencode upgrade' moves it, so this repo leaves it alone"
    return 0
  fi
  local args=(--no-modify-path)
  case ${OPENCODE_VERSION:-latest} in
    latest | '') ;;
    *) args+=(--version "${OPENCODE_VERSION#v}") ;;
  esac
  # --no-modify-path: the installer would otherwise append its PATH line to
  # ~/.bashrc and ~/.zshrc. ~/.bashrc.d/70-tools.sh already adds
  # ~/.opencode/bin, [ -d ]-guarded (D4: nothing appends to a dotfile).
  # The vendor URL redirects to the current upstream repository; it is
  # deliberately not resolved to a github.com/<owner>/<repo> here, because that
  # owner has already changed once.
  sh_installer_run "https://opencode.ai/install" \
    --reason 'opencode publishes only this installer URL, with no per-release digest of it, and the installer does not checksum the archive it downloads' \
    -- "${args[@]}" \
    || {
      log_error "the opencode installer failed"
      return 1
    }
  changed "opencode ${OPENCODE_VERSION:-latest}"
  return 0
}

# ---------------------------------------------------------------------------
# The opt-in agents
# ---------------------------------------------------------------------------

install_crush() {
  if have crush; then
    log_skip "crush is already installed ($(command -v crush))"
    return 0
  fi
  # go_ensure_path, not `have go`: /usr/local/go may have been installed earlier in
  # this same run, after the shell that launched us computed its PATH.
  if ! go_ensure_path; then
    log_skip "crush is built with 'go install' and go is not on PATH — run --only lang-go first"
    return 0
  fi
  go_install "github.com/charmbracelet/crush@${CRUSH_VERSION:?}" crush \
    || log_warn "could not install crush"
  return 0
}

install_agents() {
  if [ "${INSTALL_AI_AGENTS:-0}" != 1 ]; then
    log_skip "crush is opt-in: use --profile ai, or INSTALL_AI_AGENTS=1"
    return 0
  fi
  install_crush
  return 0
}

module_main() {
  log_step "ai agents"

  # Both base installs are attempted even when the first one fails: one vendor's
  # installer being down is no reason to go without the other agent.
  local failed=()
  install_claude || failed+=("Claude Code")
  report_npm_claude
  install_opencode || failed+=(opencode)
  install_agents

  # Both native installers put their binary somewhere the PATH this process
  # inherited may not reach yet — ~/.local/bin, which ~/.bashrc.d/10-path.sh
  # prepends, and ~/.opencode/bin, which 70-tools.sh does. Say so, because that is
  # the one confusing failure mode.
  if ! have claude && [ -x "$LOCAL_BIN/claude" ]; then
    log_info "claude is at $LOCAL_BIN/claude; open a new shell (or 'exec bash -l') to pick it up"
  fi
  if ! have opencode && [ -x "$OPENCODE_BIN/opencode" ]; then
    log_info "opencode is at $OPENCODE_BIN/opencode; open a new shell (or 'exec bash -l') to pick it up"
  fi

  log_step_end
  if [ ${#failed[@]} -gt 0 ]; then
    log_error "base install(s) failed: ${failed[*]}"
    # A deliberate failure exit: clear the ERR trap first, or lib/common.sh's trap
    # prints two more "failed (exit 1) … command: return 1" lines after the one
    # above and buries the real reason.
    trap - ERR
    exit 1
  fi
  return 0
}

module_main "$@"
