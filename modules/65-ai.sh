#!/usr/bin/env bash
# meta: name=ai
# meta: desc=claude code as a base install, plus the opt-in ai agent clis
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
# opencode and crush are NOT base (they were found installed by hand, not by any
# script). They need INSTALL_AI_AGENTS=1, which `--profile ai` sets.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

LOCAL_BIN="$HOME/.local/bin"

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
# The opt-in agents
# ---------------------------------------------------------------------------

install_opencode() {
  if have opencode || [ -x "$HOME/.opencode/bin/opencode" ]; then
    log_skip "opencode is already installed"
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
    --reason 'opencode publishes only this installer URL; it resolves the release and verifies its own download, and there is no stable per-release digest of the wrapper' \
    -- "${args[@]}" \
    || {
      log_warn "the opencode installer failed"
      return 0
    }
  changed "opencode ${OPENCODE_VERSION:-latest}"
  return 0
}

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
    log_skip "opencode and crush are opt-in: use --profile ai, or INSTALL_AI_AGENTS=1"
    return 0
  fi
  install_opencode
  install_crush
  return 0
}

module_main() {
  log_step "ai agents"

  install_claude || {
    log_step_end
    return 1
  }
  report_npm_claude
  install_agents

  # The native installer puts everything in ~/.local/bin, which
  # ~/.bashrc.d/10-path.sh prepends. Say so when the current process cannot see
  # it, because that is the one confusing failure mode.
  if ! have claude && [ -x "$LOCAL_BIN/claude" ]; then
    log_info "claude is at $LOCAL_BIN/claude; open a new shell (or 'exec bash -l') to pick it up"
  fi

  log_step_end
  return 0
}

module_main "$@"
