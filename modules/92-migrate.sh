#!/usr/bin/env bash
# meta: name=migrate
# meta: desc=report and, with --apply, neutralise what the old wsl2-config left behind
# meta: profiles=
# meta: os=any
# meta: root=no
#
# NEVER in a profile. Run it explicitly:
#     devenv --only migrate                    # report only (the default)
#     DEVENV_MIGRATE_APPLY=1 devenv --only migrate
#     ./modules/92-migrate.sh --apply          # same thing, run directly
#
# MUST-FIX P10. A box provisioned by github.com/Ujstor/wsl2-config carries three
# kinds of residue; this module covers the first two and hands the third to
# `devenv --only purge-desktop`:
#
#   1. lines the old scripts APPENDED to ~/.bashrc with `>>`, several of them twice
#   2. ~/.use-nala, which redefines the `sudo` and `apt` SHELL FUNCTIONS
#   3. picom, brave and the rest of the desktop layer            -> purge-desktop
#
# The safety rules it never breaks (MUST-FIX S3/S9):
#   * nothing is deleted. Lines are COMMENTED OUT, prefixed so a later run skips
#     them, and ~/.bashrc is backed up first by write_if_changed.
#   * a line is only commented out when the drop-in that REPLACES it is already
#     installed. No fragment, no edit — you get a report instead.
#   * the rewritten ~/.bashrc is parsed with `bash -n` BEFORE it is installed. If
#     the transform produced anything that does not parse, nothing is written.
#   * a symlinked ~/.bashrc (mybash owns it) is written through, never replaced.
#   * every file the old repo created outside ~/.bashrc — ~/.use-nala included —
#     is reported, never removed. It is yours.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

APPLY=${DEVENV_MIGRATE_APPLY:-0}
RC="$HOME/.bashrc"
DROPIN="${DEVENV_DROPIN_DIR:-$HOME/.bashrc.d}"
MARK='# devops-env-config:migrated'
FINDINGS=0
ACTIONABLE=0

note() {
  FINDINGS=$((FINDINGS + 1))
  log_warn "$*"
}
detail() { log_info "     $*"; }

# rule PATTERN REASON REQUIRED_FRAGMENT [block]
#   Adds one comment-out rule when its replacement fragment is installed, and
#   reports it as "manual" when it is not. Rules are collected in $RULES.
RULES=''
rule() {
  local pat=$1 why=$2 frag=$3 kind=${4:-line} n
  n=$(grep -cE -- "$pat" "$RC" 2>/dev/null || true)
  n=${n:-0}
  [ "$n" -gt 0 ] || return 0
  if [ -n "$frag" ] && [ ! -f "$DROPIN/$frag" ]; then
    note "bashrc: $n line(s) of '$why' are still live, but $DROPIN/$frag is not installed"
    detail 'run "devenv --only shell" first; this module will not comment out a line'
    detail 'whose replacement is missing.'
    return 0
  fi
  note "bashrc: $n line(s) — $why"
  ACTIONABLE=$((ACTIONABLE + 1))
  RULES="$RULES$kind"$'\t'"$pat"$'\t'"$why"$'\n'
  return 0
}

collect_rules() {
  [ -f "$RC" ] || return 0

  # The `sudo`/`apt` shell-function shim from scripts/usenala.sh. This one is
  # actively harmful: it makes `sudo apt …` mean `sudo nala …` for every command
  # you type, including ones inside other people's scripts.
  rule '^if \[ -f .*\.use-nala' \
    'the ~/.use-nala sudo()/apt() shell-function shim' '' block
  rule '^[[:space:]]*\.[[:space:]]+.*\.use-nala' \
    'sourcing ~/.use-nala' '' line

  # The WSL clipboard aliases. They are already dead on this box: neither clip.exe
  # nor powershell.exe resolves by name, because the Windows PATH is not on this
  # shell's PATH. auth-sso replaces them with real executables in ~/.local/bin.
  rule '^if grep -qi microsoft /proc/version' \
    'the legacy WSL clipboard block (clip.exe / powershell.exe)' 55-sso.sh block
  rule '^[[:space:]]*# export BROWSER=chrome' \
    'the commented-out BROWSER=chrome line' 55-sso.sh line

  # Cargo, twice, in two different spellings — which is exactly why the block
  # writer matches on a marker and never on the text.
  rule '^[[:space:]]*([.]|source)[[:space:]]+"[$]HOME/[.]cargo/env"' \
    'sourcing ~/.cargo/env (20-lang.sh does it once, guarded)' 20-lang.sh line
  return 0
}

apply_rules() {
  local tmp prog rules out
  [ -n "$RULES" ] || return 0
  if [ "$APPLY" != 1 ]; then
    log_info ''
    log_info "$ACTIONABLE group(s) above can be commented out automatically, with a backup:"
    log_info '  DEVENV_MIGRATE_APPLY=1 devenv --only migrate'
    return 0
  fi
  if ! confirm "comment out $ACTIONABLE legacy group(s) in $RC (a backup is taken first)?"; then
    log_info 'nothing was changed'
    return 0
  fi

  tmp=$(devenv_tmpdir) || return 1
  rules="$tmp/rules"
  prog="$tmp/migrate.awk"
  out="$tmp/bashrc"
  printf '%s' "$RULES" >"$rules"

  cat >"$prog" <<'AWK'
# Comments out every line matching a rule, prefixing it so a second run is a no-op.
# A "block" rule swallows lines up to the matching `fi`, because an if/fi pair must
# be commented out as a whole or the file stops parsing.
BEGIN {
  k = 0
  while ((getline l < rules) > 0) {
    if (l == "") continue
    split(l, a, "\t")
    k++
    kind[k] = a[1]; pat[k] = a[2]; why[k] = a[3]
  }
  close(rules)
}
index($0, mark) == 1 { print; next }
inblock {
  printf "%s (%s): %s\n", mark, blockwhy, $0
  if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/) inblock = 0
  next
}
{
  for (i = 1; i <= k; i++) {
    if ($0 ~ pat[i]) {
      if (kind[i] == "block") { inblock = 1; blockwhy = why[i] }
      printf "%s (%s): %s\n", mark, why[i], $0
      next
    }
  }
  print
}
END {
  if (inblock) exit 3    # an unterminated block: refuse the whole transform
}
AWK

  if ! awk -v rules="$rules" -v mark="$MARK" -f "$prog" "$RC" >"$out"; then
    log_error 'the rewrite hit an unterminated if/fi block — nothing was changed.'
    log_error "comment the legacy lines out by hand; $RC is untouched."
    return 0
  fi

  # The safety net that makes this module safe to run at all.
  if ! bash -n "$out"; then
    log_error 'the rewritten ~/.bashrc does not parse — refusing to install it.'
    log_error 'nothing was changed. Please report this with the lines above.'
    return 0
  fi
  if cmp -s -- "$out" "$RC"; then
    log_debug 'nothing to comment out'
    return 0
  fi

  write_if_changed "$RC" "$(stat -c '0%a' -- "$RC" 2>/dev/null || printf '0644')" <"$out" || return 1
  log_success "commented out the legacy lines in $RC (see the backup next to it)"
  log_info 'open a new shell to pick up the change:  exec bash -l'
  return 0
}

# ---------------------------------------------------------------------------
# report-only findings
# ---------------------------------------------------------------------------

report_bashrc_extras() {
  [ -f "$RC" ] || return 0
  local n

  n=$(grep -cFx -- "$(block_begin_marker '')" "$RC" 2>/dev/null || true)
  if [ "${n:-0}" -gt 1 ]; then
    note "bashrc: $n devops-env-config blocks — the loader runs $n times"
    detail 'this is never fixed automatically: edit ~/.bashrc and delete the extras.'
  fi

  # PATH lines are reported, never rewritten: several of them also add paths no
  # fragment covers (flatpak, labctl, sst, pulumi, miniconda), and dropping one
  # would silently remove a tool from PATH.
  n=$(grep -cE '^[[:space:]]*export PATH=' "$RC" 2>/dev/null || true)
  if [ "${n:-0}" -gt 2 ]; then
    note "bashrc: $n 'export PATH=' lines"
    detail '10-path.sh already prepends ~/.local/bin, ~/.cargo/bin, ~/go/bin, ~/bin and'
    detail 'and ~/.krew/bin, deduplicated. The rest (flatpak, labctl, sst, pulumi, conda) are'
    detail 'yours — REPORT ONLY, because removing the wrong one hides a tool.'
    detail "  grep -n 'export PATH=' $RC"
  fi

  n=$(grep -cE '^export (GOROOT|GOPATH|GOCACHE)=' "$RC" 2>/dev/null || true)
  if [ "${n:-0}" -gt 0 ] && [ -f "$DROPIN/20-lang.sh" ]; then
    note "bashrc: the Go environment is exported directly on $n line(s)"
    detail '20-lang.sh sets GOROOT/GOPATH/GOCACHE already. REPORT ONLY, deliberately: the'
    detail 'legacy block is followed by an "export PATH=...:GOPATH/bin" line that'
    detail 'would expand to garbage if GOPATH were commented out and nothing else set it'
    detail 'yet. Remove the whole group by hand, PATH line included, or leave it alone.'
  fi

  n=$(grep -cE 'NVM_DIR|nvm\.sh' "$RC" 2>/dev/null || true)
  if [ "${n:-0}" -gt 0 ] && [ -f "$DROPIN/20-lang.sh" ]; then
    note "bashrc: nvm is loaded eagerly on $n line(s)"
    detail '20-lang.sh installs a lazy nvm/node/npm/npx shim instead — worth ~0.2 s per'
    detail 'shell. REPORT ONLY: comment the old lines out yourself once you trust it.'
  fi

  n=$(grep -cE '^[[:space:]]*(source|\.)[[:space:]]+<\(.*completion' "$RC" 2>/dev/null || true)
  if [ "${n:-0}" -gt 0 ]; then
    note "bashrc: $n completion script(s) are sourced at shell start"
    detail 'they cost a fork each, and the ones for tools that are not installed print an'
    detail 'error on every new shell. "devenv completions" caches them lazily instead.'
    detail 'REPORT ONLY.'
  fi
  return 0
}

report_use_nala() {
  [ -f "$HOME/.use-nala" ] || return 0
  note 'the file ~/.use-nala still exists'
  detail 'it defines sudo() and apt() as SHELL FUNCTIONS. This repo never redefines'
  detail 'sudo, and it calls apt-get directly. Once nothing sources the file you can'
  detail 'delete it — this module will not, because it is not ours to delete.'
  detail "  rm ~/.use-nala"
  if [ "${ENABLE_NALA_ALIAS:-0}" != 1 ]; then
    detail 'if you liked typing apt, set ENABLE_NALA_ALIAS=1 - 70-tools.sh then defines'
    detail 'an ALIAS (never a function, and never for sudo).'
  fi
  return 0
}

report_python_marker() {
  local f found=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    found=1
    note "the PEP 668 marker was renamed: $f"
    detail 'the old installer did that to force "pip install --user". It disables the'
    detail 'distro guard for every python3 on this box.'
    if [ "$APPLY" = 1 ] && confirm "restore ${f%.old} now (needs root)?"; then
      if run_sudo mv -n -- "$f" "${f%.old}"; then
        changed "restored ${f%.old}"
      fi
    else
      detail "  sudo mv '$f' '${f%.old}'"
    fi
  done < <(find /usr/lib/python3* -maxdepth 1 -name 'EXTERNALLY-MANAGED.old' 2>/dev/null)
  [ "$found" = 0 ] && log_debug 'PEP 668 marker is intact'
  return 0
}

report_leftovers() {
  local f

  # The desktop half. This module never touches it.
  local desktop=()
  for f in /usr/local/bin/picom /usr/local/bin/compton "$HOME/build/picom"; do
    if [ -e "$f" ]; then desktop+=("$f"); fi
  done
  if pkg_installed brave-browser; then desktop+=(brave-browser); fi
  if [ ${#desktop[@]} -gt 0 ]; then
    note "the old desktop layer is still installed: ${desktop[*]}"
    detail 'that is a different module, which reports before it removes anything:'
    detail '  devenv --only purge-desktop'
  fi

  # A hardcoded /mnt/c symlink from the old setup. The shim resolves the Windows
  # mount at runtime and never reads this.
  if [ -L "$HOME/.local/bin/chrome" ]; then
    note "the symlink ~/.local/bin/chrome points at $(readlink -- "$HOME/.local/bin/chrome")"
    detail 'nothing in this repo uses it, and a hardcoded /mnt/c breaks if [automount]'
    detail 'root ever changes. Set DEVENV_BROWSER_WIN_EXE in sso.env instead.'
  fi

  # nvm installed twice.
  if [ -d "$HOME/.nvm" ] && [ -d "$HOME/.config/nvm" ]; then
    note 'both ~/.nvm and ~/.config/nvm exist'
    detail 'the old scripts/nvm.sh installed to ~/.nvm while ~/.bashrc pointed NVM_DIR at'
    detail 'at ~/.config/nvm, so one of them has never been used. Move the versions you want'
    detail 'to keep by hand — node installs are big and this module will not guess.'
  fi

  # A safe.directory that no longer exists is a leftover of a moved checkout.
  if have git; then
    local sd
    while IFS= read -r sd; do
      [ -n "$sd" ] || continue
      [ -d "$sd" ] && continue
      note "git safe.directory points at a path that no longer exists: $sd"
      detail "  git config --global --unset-all safe.directory '$sd'"
    done < <(git config --global --get-all safe.directory 2>/dev/null || true)
  fi

  # The old checkout itself.
  for f in "$HOME/wsl2-config" "$HOME/code/wsl2-config"; do
    if [ -d "$f/.git" ]; then
      note "an old wsl2-config checkout is still at $f"
      detail 'nothing reads it any more; keep or delete it as you like.'
    fi
  done
  return 0
}

module_main() {
  local a
  for a in "$@"; do
    case $a in
      --apply) APPLY=1 ;;
      --report | --dry-run) APPLY=0 ;;
      *) log_warn "ignoring unknown argument '$a'" ;;
    esac
  done

  if [ ! -f "$RC" ]; then
    skip "no ~/.bashrc on this box — nothing to migrate"
  fi

  log_info "auditing this box for residue from the old wsl2-config repository"
  [ "$APPLY" = 1 ] || log_info 'report mode: nothing will be changed'

  collect_rules
  report_bashrc_extras
  report_use_nala
  report_leftovers
  report_python_marker
  apply_rules

  log_info ''
  if [ "$FINDINGS" = 0 ]; then
    log_success 'nothing from the old repository is left on this box'
  else
    log_info "$FINDINGS finding(s). Everything above that is not marked REPORT ONLY can be"
    log_info 'handled with:  DEVENV_MIGRATE_APPLY=1 devenv --only migrate'
  fi
  return 0
}

module_main "$@"
