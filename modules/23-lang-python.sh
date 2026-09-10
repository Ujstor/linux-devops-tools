#!/usr/bin/env bash
# meta: name=lang-python
# meta: desc=uv, and every python cli in its own venv
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=no
#
# D7/K17/MUST-FIX S12. uv is the ONLY Python installer here. pip --user, pipx and
# --break-system-packages are gone, and NOTHING in this repository moves, renames
# or deletes /usr/lib/python3.*/EXTERNALLY-MANAGED.
#
# Why that marker matters: the old install.sh renamed it to EXTERNALLY-MANAGED.old
# in every python3.* directory so that `pip3 install --user ansible` would work.
# That disables PEP 668 system-wide, for one package — and it is not even durable:
# the file is owned by libpython3.12-stdlib, so the next routine upgrade of that
# package RESTORES it and leaves the stray .old behind. Verified on this box.
# uv sidesteps the whole question: it brings its own CPython, so Debian 12's
# system 3.11 stops mattering, and every tool lands in its own venv under
# ~/.local/share/uv/tools with a shim in ~/.local/bin.
#
# K34 is the single highest-risk detail of the migration: `uv tool install
# ansible` alone is NOT equivalent to `pip3 install --user ansible`. Ansible
# COLLECTIONS import third-party modules from the same interpreter —
# kubernetes.core needs `kubernetes`, ansible.utils needs `netaddr`, and half the
# fleet's playbooks use the `json_query` filter, which needs `jmespath`. A shared
# --user prefix satisfied that by accident. A per-tool venv does not, so each one
# is named explicitly with --with.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

LOCAL_BIN="$HOME/.local/bin"
UV_TOOL_ROOT="${UV_TOOL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/uv/tools}"

# ---------------------------------------------------------------------------
# MUST-FIX S12 — report, never touch
# ---------------------------------------------------------------------------

# report_externally_managed
#   Reports both halves of the old hack: a marker this repo would never remove,
#   and the stray .old the upgrade left behind. modules/90-doctor.sh --fix is the
#   only thing that restores it; a language module must not make that decision.
report_externally_managed() {
  local d marker old stray=()
  for d in /usr/lib/python3.*/; do
    [ -d "$d" ] || continue
    marker="${d}EXTERNALLY-MANAGED"
    old="${d}EXTERNALLY-MANAGED.old"
    if [ -e "$old" ]; then
      stray+=("$old")
      if [ ! -e "$marker" ]; then
        log_warn "PEP 668 is DISABLED for ${d%/}: EXTERNALLY-MANAGED was renamed to .old"
      fi
    fi
  done
  [ ${#stray[@]} -gt 0 ] || return 0
  log_warn "left over from the old installer: ${stray[*]}"
  log_warn "  This repo never moves or deletes EXTERNALLY-MANAGED. Nothing here needs it gone."
  log_warn "  Restore it with:  devenv doctor --fix"
  return 0
}

# ---------------------------------------------------------------------------
# idempotency F9 — the pip --user entrypoint collision
# ---------------------------------------------------------------------------
#
# The live box has ansible, ansible-lint, checkov, yamllint, black,
# detect-secrets, mkdocs and friends in ~/.local/bin from `pip3 install --user`.
# `uv tool install` writes its shim to the SAME directory and refuses when a file
# it does not own is already there ("Executable already exists"). That refusal is
# correct — silently overwriting a working entrypoint is exactly the class of
# damage MUST-FIX S9 exists to prevent — but it must not abort this module.
#
# So: collisions are detected up front and REPORTED with the two ways out, each
# tool is attempted independently, and a failure is a warning rather than a
# module failure. DEVENV_UV_FORCE=1 is the explicit opt-in that lets uv take the
# entrypoints over.

# uv_owns_entrypoint NAME — 0 when ~/.local/bin/NAME is a uv shim.
uv_owns_entrypoint() {
  local f="$LOCAL_BIN/$1" target
  [ -e "$f" ] || return 1
  target=$(readlink -f -- "$f" 2>/dev/null) || target=''
  case $target in
    "$UV_TOOL_ROOT"/*) return 0 ;;
  esac
  grep -qs -- "$UV_TOOL_ROOT" "$f" && return 0
  return 1
}

# report_pip_user_collisions ENTRYPOINT…
report_pip_user_collisions() {
  local n clash=()
  for n in "$@"; do
    [ -e "$LOCAL_BIN/$n" ] || continue
    uv_owns_entrypoint "$n" && continue
    clash+=("$n")
  done
  [ ${#clash[@]} -gt 0 ] || return 0
  log_warn "these commands in $LOCAL_BIN were not installed by uv (a 'pip3 install --user' from the old setup):"
  log_warn "  ${clash[*]}"
  log_warn "  uv will refuse to overwrite them, and this module will report each refusal and move on."
  log_warn "  To hand them over to uv, pick one:"
  log_warn "    python3 -m pip uninstall --break-system-packages -y <package>   # then re-run"
  log_warn "    DEVENV_UV_FORCE=1 devenv --only lang-python                     # let uv replace the shims"
  return 0
}

# py_tool SPEC [--with PKG]…
#   uv_tool_install, with the F9 handling: a failure is warned about and the loop
#   continues. DEVENV_UV_FORCE=1 adds --force.
py_tool() {
  local spec=$1
  shift
  local extra=()
  [ "${DEVENV_UV_FORCE:-0}" = 1 ] && extra=(--force)
  uv_tool_install "$spec" ${extra[@]+"${extra[@]}"} "$@" || {
    log_warn "uv tool install $spec did not succeed — continuing"
    log_warn "  if it says the executable already exists, see the pip3 note above"
    return 0
  }
  return 0
}

# ---------------------------------------------------------------------------
# The roster (SPEC §7.4)
# ---------------------------------------------------------------------------

install_python_tools() {
  # K34. Do not drop a --with: the collections import these from the SAME venv.
  py_tool ansible --with kubernetes --with netaddr --with jmespath
  py_tool ansible-lint
  py_tool checkov
  py_tool yamllint
  py_tool detect-secrets

  # mike is an MkDocs PLUGIN: it has to live in mkdocs' own venv or `mike deploy`
  # cannot import mkdocs, and `mkdocs serve` cannot find the plugin.
  py_tool mkdocs-material --with mike

  # GitHub Spec Kit. There is no PyPI release, so it comes from git at a pinned
  # ref. The PACKAGE name is given first and the source second with --from: that
  # is what makes `uv tool list` report `specify-cli`, which is in turn what makes
  # the "already installed" short-circuit work on the second run.
  if [ -n "${SPEC_KIT_REF:-}" ]; then
    py_tool specify-cli --from "git+https://github.com/github/spec-kit.git@${SPEC_KIT_REF}"
  fi

  if [ "${INSTALL_EXTRAS:-0}" = 1 ]; then
    py_tool black
  fi

  # Deliberately NOT installed, and this list is the documentation:
  #   pytest                     a global pytest tests nothing reproducibly;
  #                              `uv add --dev pytest` per project instead
  #   pipx                       uv covers every case (K17)
  #   cloudsplaining,            AWS-only, and there is no AWS in this estate
  #   policy_sentry
  #   pre-commit                 modules/28-repo-dev.sh — it is CI tooling for
  #                              repositories, not a system-wide Python CLI
  return 0
}

module_main() {
  log_step "python"

  # This MUST come before uv_install. uv installs itself into $LOCAL_BIN, and
  # uv_install short-circuits on `bin_version uv --version` — which can only find
  # uv if $LOCAL_BIN is on PATH. With the PATH fix after the install call, a second
  # run on a box where ~/.local/bin is not already on PATH fails to see the uv it
  # installed a moment ago, re-runs astral's installer, and rewrites
  # ~/.config/uv/uv-receipt.json. That is a real idempotency break: it showed up as
  # "the second run changed nothing" failing on ubuntu 24.04 and 26.04, whose
  # default profile does not put ~/.local/bin on PATH for a non-login shell the way
  # the debian images do.
  #
  # uv writes its own PATH helper; ~/.bashrc.d/20-lang.sh sources it. This module
  # runs before any of that took effect in the current process.
  case ":$PATH:" in
    *":$LOCAL_BIN:"*) ;;
    *)
      PATH="$LOCAL_BIN:$PATH"
      export PATH
      ;;
  esac

  uv_install || {
    log_error "uv could not be installed — no Python CLI can be installed without it"
    log_step_end
    return 1
  }

  report_externally_managed
  report_pip_user_collisions \
    ansible ansible-playbook ansible-lint checkov yamllint detect-secrets \
    mkdocs mike black specify

  install_python_tools

  # MUST-FIX P5: the tool layer must be refreshable, not inert after day one.
  # No arguments = every installed tool.
  if [ "${DEVENV_UPGRADE:-0}" = 1 ]; then
    # shellcheck disable=SC2119  # deliberate: upgrade ALL uv tools
    uv_tool_upgrade
  fi

  log_step_end
  return 0
}

module_main "$@"
