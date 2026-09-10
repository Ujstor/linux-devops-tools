# shellcheck shell=bash
# lib/wsl.sh — /etc/wsl.conf and WSL helpers.
#
# devops-env-config :: shared library. Sourced by lib/common.sh only.
#
# K27, and it is a hard rule: /etc/wsl.conf is edited by ADDITIVE KEY MERGE only.
# The old scripts/docker.sh wrote the whole file, which would erase
# `[user] default=<name>` and move /mnt/c. This repository sets AT MOST
# `[boot] systemd` (opt-in and confirmed) and, only in the sysv branch,
# `[boot] command`.
#
# `[automount]` and `[interop]` are NEVER written. wslconf_set REFUSES those two
# sections outright.
#
# VERIFIED FACT (checked on the live box): the current /etc/wsl.conf contains only
#   [boot] systemd=true      [user] default=<name>
# There is no `[interop] appendWindowsPath = false` and no `[automount]` stanza —
# so the claim that docker.sh disabled appendWindowsPath is FALSE and must not be
# repeated anywhere. What IS true and verified is that the Windows PATH is not on
# this shell's PATH, so clip.exe / powershell.exe / cmd.exe / explorer.exe do not
# resolve by name while interop itself is enabled. The conclusion stands: never
# invoke a Windows executable by bare name, resolve the mount prefix at runtime, and
# prefer wslview. NO MODULE MAY "REPAIR" appendWindowsPath.

[ -n "${_DEVENV_WSL:-}" ] && return 0
_DEVENV_WSL=1

DEVENV_WSLCONF=${DEVENV_WSLCONF:-/etc/wsl.conf}

# wslconf_get SECTION KEY
#   Prints the value of KEY in SECTION of /etc/wsl.conf, trimmed.
#   Returns 1 when the file, the section or the key is absent. Read-only.
wslconf_get() {
  local section=${1:?wslconf_get: SECTION required} key=${2:?wslconf_get: KEY required}
  [ -r "$DEVENV_WSLCONF" ] || return 1
  awk -v sec="[$section]" -v k="$key" '
    /^[[:space:]]*\[/ { in_sec = ($0 ~ "^[[:space:]]*\\" sec "[[:space:]]*$"); next }
    !in_sec { next }
    {
      line = $0
      sub(/[;#].*$/, "", line)
      n = index(line, "=")
      if (!n) next
      name = substr(line, 1, n - 1); val = substr(line, n + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (name == k) { print val; found = 1; exit }
    }
    END { if (!found) exit 1 }
  ' "$DEVENV_WSLCONF"
}

# wslconf_set SECTION KEY VALUE
#   Additive INI merge into /etc/wsl.conf. Creates the section when missing.
#   NO-OP when the key already has ANY value, unless WSLCONF_FORCE=1 — the user's
#   existing choice always wins. Backs the file up once before the first change.
#   NEVER writes the whole file, and REFUSES `[automount]` and `[interop]` (K27).
#
#   MUST-FIX S5, BACKSTOP. /etc/wsl.conf is system-wide, root-owned, changes how
#   the whole distribution boots, and only takes effect after `wsl --shutdown`, so
#   `--yes` must never be enough to write it. Every CALLER is required to ask first
#   with `confirm_dangerous … DEVENV_ALLOW_WSL_CONF` (modules/70-wsl.sh does), and
#   this function independently REFUSES the unattended case — `--yes`, or no
#   controlling terminal — unless DEVENV_ALLOW_WSL_CONF=1. The check here is
#   deliberately silent-on-success and does not prompt: a second prompt with the
#   same wording as the caller's would read as a bug and get "fixed" away. It
#   guarantees that no future caller can turn `--yes` into a wsl.conf write by
#   forgetting the gate.
#
#   Honours --dry-run. Returns 1 when the section is refused; returns 0 in every
#   other case, INCLUDING a refused unattended write — a caller that is told "no"
#   has nothing to fail about, and the way to allow it has just been printed.
wslconf_set() {
  local section=${1:?wslconf_set: SECTION required} key=${2:?wslconf_set: KEY required}
  local value=${3:?wslconf_set: VALUE required}
  case $section in
    automount | interop)
      log_error "refusing to write [$section] in $DEVENV_WSLCONF."
      log_error "  This repository never touches [automount] or [interop] (K27): changing them"
      log_error "  moves /mnt/c or removes the Windows PATH, breaking tools it does not own."
      return 1
      ;;
  esac
  local cur out
  if cur=$(wslconf_get "$section" "$key"); then
    if [ "$cur" = "$value" ]; then
      log_debug "$DEVENV_WSLCONF already has [$section] $key = $value"
      return 0
    fi
    if [ "${WSLCONF_FORCE:-0}" != 1 ]; then
      log_warn "$DEVENV_WSLCONF already sets [$section] $key = $cur — leaving it alone"
      log_warn "  (set WSLCONF_FORCE=1 to change it to '$value')"
      return 0
    fi
  fi
  # Nothing above this line has touched the file: the value really is about to
  # change, so this is the last point at which the S5 backstop still applies.
  if [ "${DEVENV_ALLOW_WSL_CONF:-0}" != 1 ] \
    && { [ "${DEVENV_ASSUME_YES:-0}" = 1 ] || ! have_tty; }; then
    log_warn "not writing $DEVENV_WSLCONF unattended: [$section] $key = $value"
    log_warn "  --yes does not cover a system-wide boot setting. Re-run with"
    log_warn "  --allow-wsl-conf (or DEVENV_ALLOW_WSL_CONF=1) to allow it."
    return 0
  fi
  out=$(devenv_tmpfile) || return 1
  if [ -f "$DEVENV_WSLCONF" ]; then
    awk -v sec="[$section]" -v k="$key" -v v="$value" '
      function emit() { if (!written) { print k " = " v; written = 1 } }
      /^[[:space:]]*\[/ {
        if (in_sec) emit()
        in_sec = ($0 ~ "^[[:space:]]*\\" sec "[[:space:]]*$")
        if (in_sec) seen = 1
        print; next
      }
      in_sec {
        line = $0; sub(/[;#].*$/, "", line)
        n = index(line, "=")
        if (n) {
          name = substr(line, 1, n - 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
          if (name == k) { emit(); next }
        }
        print; next
      }
      { print }
      END {
        if (in_sec) emit()
        if (!seen) { print ""; print sec; print k " = " v }
      }
    ' "$DEVENV_WSLCONF" >"$out" || return 1
  else
    printf '[%s]\n%s = %s\n' "$section" "$key" "$value" >"$out"
  fi
  if [ -f "$DEVENV_WSLCONF" ] && cmp -s -- "$out" "$DEVENV_WSLCONF"; then
    log_debug "$DEVENV_WSLCONF unchanged"
    return 0
  fi
  write_if_changed "$DEVENV_WSLCONF" 0644 <"$out" || return 1
  log_warn "$DEVENV_WSLCONF changed — run 'wsl --shutdown' from Windows for it to take effect"
  return 0
}

# wsl_interop_ok
#   Returns 0 when the WSL binfmt_misc interop handler is registered and enabled.
#   NOTE: interop being enabled says nothing about whether Windows executables
#   resolve BY NAME — that is $PATH, and on this box they do not. Always use an
#   absolute /mnt/c/... path.
wsl_interop_ok() {
  grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null \
    || grep -q enabled /proc/sys/fs/binfmt_misc/WSLInterop-late 2>/dev/null
}

# wsl_win_root
#   Prints the mount prefix of the Windows system drive, honouring `[automount] root`
#   so it keeps working on a box where C: is at /c. NEVER hardcode /mnt/c.
#   Returns 1 when the drive cannot be found (not WSL, or automount disabled).
wsl_win_root() {
  local root
  root=$(wslconf_get automount root 2>/dev/null) || root=/mnt/
  case $root in */) ;; *) root="$root/" ;; esac
  [ -d "${root}c" ] || return 1
  printf '%sc\n' "$root"
}

# wsl_restart_hint
#   Prints the exact instruction the user needs after a /etc/wsl.conf change.
#   Always returns 0.
wsl_restart_hint() {
  os_is_wsl || return 0
  log_info "to apply WSL configuration changes, run this in Windows (PowerShell or cmd):"
  log_info "    wsl --shutdown"
  log_info "then start your distribution again."
  return 0
}
