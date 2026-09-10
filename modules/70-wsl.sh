#!/usr/bin/env bash
# meta: name=wsl
# meta: desc=the WSL-only adjustments: systemd, wslu and the restart hint
# meta: profiles=minimal,devops,full
# meta: os=wsl
# meta: needs=
# meta: root=no
#
# `os=wsl` means `module_gate` skips this whole file with one line on a VM, a
# container or bare metal — which is why the profiles can list it unconditionally
# and there is no separate "wsl" profile.
#
# THE THINGS THIS MODULE MUST NOT DO, and why (VERIFIED-FACTS §1, SPEC §5.5, K27)
#
#   * It never writes `[interop]` or `[automount]`. `wslconf_set` refuses both
#     outright. The SPEC-ADDENDUM claimed the old repo's docker.sh had written
#     `appendWindowsPath=false`, which is why `clip.exe` and `powershell.exe` do
#     not resolve. That claim was CHECKED ON THE BOX AND IS FALSE: /etc/wsl.conf
#     has only `[boot] systemd=true` and `[user] default=…`, and the old docker.sh
#     writes wsl.conf only in its non-systemd branch, which never ran there.
#     The observed effect is real — the Windows PATH is simply not on this shell's
#     PATH — but nothing in this repository caused it and nothing here "repairs"
#     it. Removing a user's interop setting to fix a symptom you misdiagnosed is
#     how you break every Windows tool they have.
#
#   * It never adds `pkg.wslutiliti.es`. That host now serves an HTML parking
#     page, and an apt source pointing at it breaks `apt update` for everything.
#     `wslu` is taken from the distro archive when the distro has it (jammy and
#     noble universe do; Debian does not) and skipped with one line when it does
#     not.
#
#   * It never installs a clipboard bridge. `clip` / `clip-paste` are shipped by
#     10-shell as real executables that resolve the automount prefix at RUNTIME,
#     precisely so they keep working on a box where `clip.exe` is not on PATH.
#
# /etc/wsl.conf is system-wide, survives every reboot and changes how the whole
# distribution boots, so writing it is a `confirm_dangerous` step gated on
# DEVENV_ALLOW_WSL_CONF (MUST-FIX S5). `--yes` alone is not enough.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# ensure_systemd
#   Offers `[boot] systemd=true` when the key is absent. Already-set is a no-op
#   whatever its value: `wslconf_set` never overrides an existing choice.
#   Requires WSL 0.67.6+ (Windows 10 22H2 / 11 22H2 and later); older builds
#   ignore the key harmlessly, so there is nothing to version-gate on.
ensure_systemd() {
  local cur
  if cur=$(wslconf_get boot systemd 2>/dev/null); then
    log_skip "/etc/wsl.conf already sets [boot] systemd = $cur"
    return 0
  fi
  if os_has_systemd; then
    log_skip "systemd is already the init system here"
    return 0
  fi
  log_info "systemd is not running: docker, kubelet and any unit-managed service"
  log_info "  will need 'service <name> start' instead of 'systemctl'."
  if ! confirm_dangerous "enable systemd in /etc/wsl.conf (needs 'wsl --shutdown' to apply)?" \
    DEVENV_ALLOW_WSL_CONF; then
    log_skip "leaving /etc/wsl.conf alone"
    return 0
  fi
  wslconf_set boot systemd true || return 0
  changed "/etc/wsl.conf: [boot] systemd = true"
  wsl_restart_hint
  return 0
}

# ensure_sysv_boot_command
#   ONLY on a sysvinit box (INIT_SYSTEM=sysv), and only when docker is actually
#   installed: `[boot] command` is the one hook that starts a service on a distro
#   with no init system. On a systemd box it is both unnecessary and wrong.
ensure_sysv_boot_command() {
  [ "${INIT_SYSTEM:-unknown}" = sysv ] || return 0
  have docker || return 0
  local cur
  if cur=$(wslconf_get boot command 2>/dev/null); then
    log_skip "/etc/wsl.conf already sets [boot] command = $cur"
    return 0
  fi
  if ! confirm_dangerous "start the docker service at WSL boot via /etc/wsl.conf [boot] command?" \
    DEVENV_ALLOW_WSL_CONF; then
    log_skip "leaving /etc/wsl.conf alone"
    return 0
  fi
  wslconf_set boot command 'service docker start' || return 0
  changed '/etc/wsl.conf: [boot] command = service docker start'
  wsl_restart_hint
  return 0
}

# ensure_wslu
#   `wslview` is what makes every browser-based login flow work under WSL: it
#   hands the URL to the Windows default browser instead of falling through
#   /etc/alternatives/www-browser, which on this box is lynx and seizes the TTY
#   (VERIFIED-FACTS §3). config/bin/open-url prefers it when it exists.
#   Archive-only, on purpose — see the header.
ensure_wslu() {
  if have wslview; then
    log_skip "wslu is already installed ($(command -v wslview))"
    return 0
  fi
  if ! have_root; then
    log_skip "wslu needs root to install; open-url falls back to printing the URL"
    return 0
  fi
  if ! pkg_available wslu; then
    log_skip "wslu has no candidate on ${OS_ID:-this system} ${OS_CODENAME:-} — not adding a repository for it"
    log_info "  open-url will use the Windows default browser through an absolute"
    log_info "  \$(wsl_win_root)/Windows/System32 path, or print the URL to paste."
    return 0
  fi
  pkg_install_optional wslu || return 0
  have wslview && changed "wslu (wslview) installed"
  return 0
}

# report_interop
#   Reports, and only reports. A box where Windows executables do not resolve by
#   name still works — every helper this repo ships uses an absolute path — but
#   the user should know, because their OWN aliases (pbcopy='clip.exe') are dead.
report_interop() {
  if wsl_interop_ok; then
    log_debug "WSL interop is enabled"
  else
    log_warn "WSL interop (binfmt_misc) is not enabled — no Windows executable can run here"
    return 0
  fi
  if have clip.exe; then
    log_debug "Windows executables resolve by name"
    return 0
  fi
  log_info "Windows executables do not resolve by NAME on this PATH (interop itself is on)."
  log_info "  That is a PATH question, not a wsl.conf one, and this module does not change either."
  log_info "  Use the shipped 'clip' / 'clip-paste' / 'open-url', which resolve the"
  log_info "  automount prefix at runtime and work either way."
  return 0
}

module_main() {
  log_info "WSL${WSL_VERSION:+$WSL_VERSION} detected: init=${INIT_SYSTEM:-unknown} wslg=${HAS_WSLG:-0}"
  ensure_systemd
  ensure_sysv_boot_command
  ensure_wslu
  report_interop
  return 0
}

module_main "$@"
