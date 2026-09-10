#!/usr/bin/env bash
# meta: name=git
# meta: desc=git defaults (opt-in, set-if-absent), the shared ignore file, git-delta and the github cli
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=git
# meta: root=no
#
# YOUR GIT IDENTITY IS YOURS. This module is deliberately the most conservative one
# in the repository:
#
#   * it NEVER writes a key that already has a value — it prints the difference and
#     keeps yours;
#   * it writes nothing at all unless you opt in with DEVENV_GIT_APPLY=1 (or run the
#     module directly with --apply). The default is a plan;
#   * it never touches user.name, user.email, user.signingkey, commit.gpgsign, any
#     credential.* helper, or an includeIf work-identity scheme. Those are set up by
#     hand, per person, and an installer has no business rewriting them;
#   * it NEVER sets http.sslVerify. If yours is false it says so, loudly, once, and
#     prints the scoped replacement — but changing it is your call, not a script's
#     (VERIFIED-FACTS §6).
#
# `git config --global --list` before and after a default run is byte-identical.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

APPLY=${DEVENV_GIT_APPLY:-0}
GIT_VERSION=''
N_SET=0
N_PLAN=0
N_KEPT=0

# git_set KEY VALUE [MIN_GIT_VERSION]
#   Sets KEY only when it has no value at all. A different existing value is
#   reported and kept. Honours --dry-run through `run`, and DEVENV_GIT_APPLY.
git_set() {
  local key=$1 val=$2 min=${3:-} cur
  if [ -n "$min" ] && ! version_ge "$GIT_VERSION" "$min"; then
    log_debug "$key: needs git >= $min, this box has $GIT_VERSION"
    return 0
  fi
  cur=$(git config --global --get "$key" 2>/dev/null || true)
  if [ -n "$cur" ]; then
    if [ "$cur" != "$val" ]; then
      log_info "keeping your $key = $cur   (this repo suggests $val)"
      N_KEPT=$((N_KEPT + 1))
    fi
    return 0
  fi
  if [ "$APPLY" != 1 ]; then
    log_plan "git config --global $key '$val'"
    N_PLAN=$((N_PLAN + 1))
    return 0
  fi
  run git config --global "$key" "$val" || return 0
  N_SET=$((N_SET + 1))
  changed "git config --global $key $val"
  return 0
}

apply_defaults() {
  # Workflow. Every one of these is a preference, not a requirement.
  git_set init.defaultBranch main 2.28
  git_set pull.rebase true
  git_set rebase.autoStash true
  git_set rebase.autoSquash true
  git_set rebase.updateRefs true 2.38
  git_set push.autoSetupRemote true 2.37
  git_set push.default simple
  git_set push.followTags true
  git_set fetch.prune true

  # Diffs and merges.
  git_set merge.conflictStyle zdiff3 2.35
  git_set diff.algorithm histogram
  git_set diff.colorMoved zebra 2.15
  git_set diff.mnemonicPrefix true
  git_set rerere.enabled true
  git_set rerere.autoUpdate true

  # Listing and typing.
  git_set branch.sort -committerdate
  git_set tag.sort version:refname
  git_set column.ui auto
  git_set help.autocorrect prompt 2.30

  # WSL2 over 9p: the filesystem monitor costs more than it saves and misfires.
  git_set core.fsmonitor false

  if have delta; then
    git_set core.pager delta
    git_set interactive.diffFilter 'delta --color-only'
    git_set delta.navigate true
    git_set delta.dark true
    git_set delta.line-numbers true
    git_set delta.hyperlinks true
  else
    log_debug 'delta is not installed — its pager keys are not set'
  fi

  if have nvim; then
    git_set diff.tool nvimdiff
    git_set merge.tool nvimdiff
    git_set difftool.prompt false
    git_set mergetool.prompt false
    git_set mergetool.keepBackup false
  fi
  return 0
}

ship_ignore() {
  local dest="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
  ensure_dir "$(dirname -- "$dest")" 0755
  # write_once, not write_managed: if you already have a global ignore file it is
  # yours, and the shipped one lands next to it as .ignore.new for you to compare.
  write_once "$dest" 0644 <"$DEVENV_HOME/config/git/ignore"
  log_info "global gitignore: $dest"
  log_info '  git reads that path by default, so no core.excludesFile key is set.'
  return 0
}

# install_delta — git-delta, the pager the delta.* keys above configure.
#   K19's runtime probe rather than a distro matrix, and the archive really is
#   split four ways (checked, not assumed): trixie 0.18.2 and noble 0.16.5 have a
#   candidate >= 0.16.0, while bookworm and jammy have no git-delta AT ALL — so
#   half the target matrix takes the pinned release tarball.
#   The apt package is `git-delta`; the BINARY is `delta`, which is why both
#   names are passed. Never a failure: without delta the pager keys stay unset.
install_delta() {
  local rc=0
  local pattern='delta-{version}-{arch_rust}-unknown-linux-gnu.tar.gz'
  local why='dandavison/delta ships no checksum file with its release assets (verified for 0.18.2)'
  if have delta; then
    log_debug "delta $(delta --version 2>/dev/null | awk '{print $2}') is installed"
    return 0
  fi
  if ! have_root; then
    gh_release_install dandavison/delta "$pattern" delta "${DELTA_VERSION:?}" \
      --no-verify --no-verify-reason "$why" --dest "$HOME/.local/bin" || rc=$?
  else
    apt_or_release git-delta delta 0.16.0 dandavison/delta "$pattern" \
      --release-version "${DELTA_VERSION:?}" \
      --no-verify --no-verify-reason "$why" || rc=$?
  fi
  [ "$rc" = 78 ] && log_skip "no delta release asset for ${OS_ARCH_RUST:-?}"
  return 0
}

install_gh() {
  if have gh; then
    log_debug "gh $(gh --version 2>/dev/null | head -n1 | awk '{print $3}') is installed"
    return 0
  fi
  if ! have_root; then
    log_skip 'gh (GitHub CLI) needs root to install — skipping, everything else still runs'
    return 0
  fi
  repo_ensure_github_cli || {
    log_warn 'could not configure the GitHub CLI apt repository'
    return 0
  }
  pkg_update
  pkg_install gh || log_warn 'gh did not install - try again after an apt-get update'
  return 0
}

# ---------------------------------------------------------------------------
# Report-only findings. None of these is ever changed by this module.
# ---------------------------------------------------------------------------

report_tls() {
  local v
  v=$(git config --global --get http.sslVerify 2>/dev/null || true)
  case "$v" in
    false | 0 | off) ;;
    *)
      log_debug 'http.sslVerify is not disabled'
      return 0
      ;;
  esac
  log_warn 'git http.sslVerify is FALSE, GLOBALLY — every host, github.com included,'
  log_warn 'is fetched without verifying its TLS certificate.'
  log_warn 'REPORT ONLY: this module will never change it. When you want to fix it:'
  log_warn '  1. install the CA that made you disable it:'
  log_warn '       sudo cp your-ca.crt /usr/local/share/ca-certificates/'
  log_warn '       sudo update-ca-certificates'
  log_warn '  2. drop the global switch:'
  log_warn '       git config --global --unset http.sslVerify'
  log_warn '  3. if one host still needs a private CA, scope it to that host only:'
  log_warn '       git config --global http."https://<your-host>/".sslCAInfo /path/to/ca.crt'
  return 0
}

report_signing() {
  local gpgsign inc file
  gpgsign=$(git config --global --get commit.gpgsign 2>/dev/null || true)
  [ "$gpgsign" = true ] || return 0
  while IFS= read -r inc; do
    [ -n "$inc" ] || continue
    file=${inc#* }
    file=${file/#\~/$HOME}
    [ -f "$file" ] || continue
    if grep -qiE '^[[:space:]]*signingkey[[:space:]]*=' "$file"; then
      log_debug "$file has its own signing key"
      continue
    fi
    log_warn "commit.gpgsign is on globally, but $file sets no signingkey of its own."
    log_warn 'Every commit made under that identity is signed with your PERSONAL key'
    log_warn 'while claiming the other address. REPORT ONLY — the fix is yours:'
    log_warn '  git config --global user.useConfigOnly true'
    log_warn "  then give $file its own [user] signingkey and [commit] gpgsign"
    break
  done < <(git config --global --get-regexp '^includeif\.' 2>/dev/null || true)
  return 0
}

report_identity() {
  local n e
  n=$(git config --global --get user.name 2>/dev/null || true)
  e=$(git config --global --get user.email 2>/dev/null || true)
  if [ -z "$n" ] || [ -z "$e" ]; then
    log_warn 'git has no global user.name / user.email. This module will not invent one:'
    log_warn '  git config --global user.name  "Your Name"'
    log_warn '  git config --global user.email "you@example.com"'
    return 0
  fi
  log_debug "identity: $n"
  if git config --global --get-regexp '^includeif\.' >/dev/null 2>&1; then
    log_info 'an includeIf work-identity split is configured — left exactly as it is'
  fi
  return 0
}

module_main() {
  local a
  for a in "$@"; do
    case $a in
      --apply) APPLY=1 ;;
      --plan | --dry-run) APPLY=0 ;;
      *) log_warn "ignoring unknown argument '$a'" ;;
    esac
  done

  GIT_VERSION=$(git --version 2>/dev/null | awk '{print $3}')
  log_info "git $GIT_VERSION"

  # delta first: apply_defaults only sets the delta.* pager keys when the binary
  # is actually on PATH, so installing it afterwards would postpone them a run.
  install_delta
  apply_defaults
  ship_ignore
  install_gh
  report_identity
  report_tls
  report_signing

  if [ "$APPLY" = 1 ]; then
    log_success "git: set $N_SET key(s), kept $N_KEPT of your own"
  elif [ "$N_PLAN" -gt 0 ]; then
    log_info ''
    log_info "git: $N_PLAN default(s) are NOT applied — this module is opt-in."
    log_info '  review the plan above, then:  DEVENV_GIT_APPLY=1 devenv --only git'
    log_info "  it will still never overwrite a key you have already set ($N_KEPT of those)."
  else
    log_success 'git: every default this repo suggests is already configured your way'
  fi
  return 0
}

module_main "$@"
