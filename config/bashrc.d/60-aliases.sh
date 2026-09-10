# shellcheck shell=bash
# ~/.bashrc.d/60-aliases.sh — linux-devops-tools :: aliases and small helpers.
# Loads after mybash, so an `unalias` here wins.

# --- grep: ripgrep is NOT a drop-in grep (K30) -----------------------------
# mybash sets `alias grep='rg'` unconditionally. Measured on this box, the same
# command in the same directory: `grep -r needle .` found 3 matches, `rg needle`
# found 1 — rg skips hidden files and honours .gitignore, and it exits 0 either
# way. `-E` in rg is `--encoding`, not "extended regex". There are no
# backreferences and no look-around without --pcre2. Silent wrong answers in a
# command the user copies out of runbooks is the wrong footgun to ship.
if [ "${DEVENV_KEEP_GREP_ALIAS:-0}" != 1 ]; then
  unalias grep 2>/dev/null
fi
if command -v rg >/dev/null 2>&1; then
  alias rgh='rg --hidden --no-ignore' # the "act like grep -r" ripgrep
fi
alias grepr='grep -rn --color=auto'

# --- eza: absent from Debian 12, and mybash aliases ls to it unguarded ------
# Without this, every `ls` on a bookworm VM fails with "command not found".
if ! command -v eza >/dev/null 2>&1; then
  unalias ls la ll lt 2>/dev/null
fi

# --- terraform -------------------------------------------------------------
# The pre-repo ~/.bashrc hardcoded `complete -C /usr/bin/terraform t`, which is
# correct only while terraform comes from the apt package. Resolve the path.
if command -v terraform >/dev/null 2>&1; then
  _devenv_tf=$(command -v terraform)
  alias tf='terraform'
  alias t='terraform'
  complete -C "$_devenv_tf" terraform tf t
  unset _devenv_tf
fi

# --- misc ------------------------------------------------------------------
alias c='clear'
# Deliberately NOT `--volumes`: that deletes data, and this alias is one keypress.
alias docker-clean='docker system prune -f'

# --- nvme temperatures -----------------------------------------------------
# Debian-family only; the yum/pacman branches of the original are dead weight
# here, and nvme-cli is reported rather than installed behind the user's back.
check_nvme_temps() {
  if ! command -v nvme >/dev/null 2>&1; then
    printf 'nvme-cli is not installed. Install it with:\n' >&2
    printf '  sudo apt-get install -y nvme-cli\n' >&2
    return 1
  fi
  local dev found=0
  for dev in /dev/nvme[0-9]*n[0-9]*; do
    [ -e "$dev" ] || continue
    found=1
    printf '== %s ==\n' "$dev"
    sudo nvme smart-log "$dev" 2>/dev/null | grep -iE 'temperature|critical_comp|warning' || true
  done
  if [ "$found" = 0 ]; then
    printf 'no NVMe namespaces found under /dev\n' >&2
    return 1
  fi
}
alias nvmetemp='check_nvme_temps'

# --- run a command in every immediate subdirectory --------------------------
run_in_all_dirs() {
  if [ $# -eq 0 ]; then
    printf 'usage: run_in_all_dirs <command> [args...]\n' >&2
    return 2
  fi
  local d
  for d in */; do
    [ -d "$d" ] || continue
    printf '\n== %s ==\n' "${d%/}"
    (cd "$d" && "$@")
  done
}
