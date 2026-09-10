# shellcheck shell=bash
# lib/shell.sh — ~/.bashrc integration and the lazy bash-completion cache.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# D4: shell integration is ONE marker-fenced block in ~/.bashrc that sources
# ~/.bashrc.d/00-init.bash. All real content lives in whole-file drop-ins under
# ~/.bashrc.d/. Nothing here ever appends a bare line and nothing here ever runs
# `sed -i` on a dotfile — that is what severed the mybash symlink on the live box.
#
# MUST-FIX S4: ~/.bashrc may be a SYMLINK into another git worktree (mybash). The
# hook is written THROUGH the link by lib/fs.sh, so the link survives and mybash
# keeps working. `--adopt-bashrc` (bashrc_adopt) severs it deliberately, after a backup.
#
# MUST-FIX S3: bashrc_dropin_prune NEVER deletes a file the user wrote. It is opt-in
# (DEVENV_PRUNE=1) and only unlinks files that carry this repo's own header marker.
#
# MUST-FIX S13 / idempotency F20: the completion cache lives in the SHARED XDG user
# completions directory. Only files this repo generated (they carry a first-line
# marker) are ever removed or overwritten.
#
# INVARIANT for the shell track: every file shipped in config/bashrc.d/ MUST contain
# the literal string `linux-devops-tools` within its first 5 lines. bashrc_dropin
# warns when it does not, because that marker is the only thing that lets the pruner
# tell our files from the user's.

[ -n "${_DEVENV_SHELL:-}" ] && return 0
_DEVENV_SHELL=1

DEVENV_BASHRC=${DEVENV_BASHRC:-$HOME/.bashrc}
DEVENV_DROPIN_DIR=${DEVENV_DROPIN_DIR:-$HOME/.bashrc.d}
# The hook block carries NO marker suffix, so it renders exactly SPEC 6.2's literal
# "# >>> linux-devops-tools >>>". One definition, one detector, one uninstaller.
DEVENV_BASHRC_MARKER=''

# dropin_is_ours FILE
#   Returns 0 when FILE's first five lines carry this repo's header marker. It is
#   the ONLY thing that licenses the pruner and the uninstaller to unlink a file in
#   ~/.bashrc.d, so it accepts the pre-rename tag as well: a fragment shipped before
#   the rename is still ours, and refusing to recognise it would strand it in every
#   interactive shell for ever. Read-only.
dropin_is_ours() {
  local f=${1:?dropin_is_ours: FILE required}
  [ -f "$f" ] || return 1
  head -n5 "$f" | grep -qF -e "$DEVENV_TAG" -e "$DEVENV_TAG_LEGACY"
}

# bashrc_hook_payload
#   Prints the exact three lines that go inside the managed block. Kept here so the
#   writer, the doctor and the uninstaller can never disagree about the content.
bashrc_hook_payload() {
  # shellcheck disable=SC2016  # literal shell for ~/.bashrc: $HOME must NOT expand here
  printf '%s\n' \
    '# Managed block — edit ~/.bashrc.d/ instead. Remove with: devenv shell uninstall' \
    '[ -f "$HOME/.bashrc.d/00-init.bash" ] && . "$HOME/.bashrc.d/00-init.bash"'
}

# bashrc_ensure_hook
#   Makes ~/.bashrc contain exactly one managed block sourcing the drop-in loader.
#   Symlink-aware: a symlinked ~/.bashrc is written THROUGH, never replaced (S4).
#   Byte-identical on a second run: no backup, no write, no log line.
#   Honours --dry-run. Returns non-zero only when the file could not be written.
bashrc_ensure_hook() {
  local target=$DEVENV_BASHRC
  if [ -L "$target" ]; then
    local real
    real=$(readlink -f -- "$target" 2>/dev/null) || real=''
    log_info "$DEVENV_BASHRC is a symlink -> ${real:-unresolvable}; the managed block is written through it"
    if [ -n "$real" ] && git -C "$(dirname -- "$real")" rev-parse --git-dir >/dev/null 2>&1; then
      log_warn "that target is inside a git worktree — commit or upstream the one-line block there."
    fi
  fi
  bashrc_hook_payload | ensure_block_in_file "$target" "$DEVENV_BASHRC_MARKER"
}

# bashrc_remove_hook
#   Deletes the managed block from ~/.bashrc, preserving a symlink.
#   No-op when the block is absent. Honours --dry-run. Returns 0.
bashrc_remove_hook() {
  remove_block_from_file "$DEVENV_BASHRC" "$DEVENV_BASHRC_MARKER"
}

# bashrc_adopt
#   `--adopt-bashrc`: replaces a symlinked ~/.bashrc with a REAL file holding the
#   same content, after a backup. Only for users who want to stop tracking mybash.
#   No-op when ~/.bashrc is already a real file. Honours --dry-run. Returns 0.
bashrc_adopt() {
  local target=$DEVENV_BASHRC real
  [ -L "$target" ] || {
    log_debug "$DEVENV_BASHRC is already a regular file"
    return 0
  }
  real=$(readlink -f -- "$target") || return 1
  log_warn "severing ~/.bashrc -> $real (mybash will no longer manage it)"
  backup_file "$target" >/dev/null
  if is_dry_run; then
    log_dryrun "replace the symlink $target with a copy of $real"
    return 0
  fi
  run rm -f -- "$target" || return 1
  write_if_changed "$target" 0644 <"$real"
}

# bashrc_dropin NAME
#   Content on stdin -> ~/.bashrc.d/NAME, via write_if_changed (so a second run is a
#   no-op and an existing file is backed up before any change).
#   Warns when the payload lacks the `linux-devops-tools` marker, because the pruner
#   relies on it. Honours --dry-run. Returns non-zero on a write failure.
bashrc_dropin() {
  local name=${1:?bashrc_dropin: NAME required} tmp
  ensure_dir "$DEVENV_DROPIN_DIR" || return 1
  tmp=$(devenv_tmpfile) || return 1
  cat >"$tmp"
  if ! head -n5 "$tmp" | grep -q "$DEVENV_TAG"; then
    log_warn "config/bashrc.d/$name has no '$DEVENV_TAG' marker in its first 5 lines;"
    log_warn "  bashrc_dropin_prune will not be able to recognise it as ours."
  fi
  write_if_changed "$DEVENV_DROPIN_DIR/$name" 0644 <"$tmp" || return 1
  manifest_record "$DEVENV_DROPIN_DIR/$name"
  return 0
}

# bashrc_dropin_remove NAME
#   Removes ~/.bashrc.d/NAME, but ONLY when it carries this repo's marker (S3).
#   Honours --dry-run. Always returns 0.
bashrc_dropin_remove() {
  local name=${1:?bashrc_dropin_remove: NAME required} f="$DEVENV_DROPIN_DIR/$1"
  [ -f "$f" ] || return 0
  if ! dropin_is_ours "$f"; then
    log_warn "not removing $f — it does not carry the $DEVENV_TAG marker, so it is not ours"
    return 0
  fi
  backup_file "$f" >/dev/null
  run rm -f -- "$f" || return 0
  manifest_forget "$f"
  changed "removed $f"
  return 0
}

# bashrc_dropin_prune KEEP…
#   Removes ~/.bashrc.d/NN-*.sh files that are no longer shipped.
#   MUST-FIX S3: OPT-IN — it does nothing unless DEVENV_PRUNE=1. It never touches
#   90-local.sh (the user's escape hatch), and it only unlinks files carrying this
#   repo's marker. A user-authored fragment is reported, never deleted.
#   Args: the basenames that should survive. Honours --dry-run. Always returns 0.
bashrc_dropin_prune() {
  local keep=" $* " f base
  [ -d "$DEVENV_DROPIN_DIR" ] || return 0
  if [ "${DEVENV_PRUNE:-0}" != 1 ]; then
    log_debug "prune not requested (DEVENV_PRUNE=1)"
    return 0
  fi
  for f in "$DEVENV_DROPIN_DIR"/[0-9][0-9]-*.sh "$DEVENV_DROPIN_DIR"/00-init.bash; do
    [ -f "$f" ] || continue
    base=${f##*/}
    [ "$base" = "90-local.sh" ] && continue
    case $keep in *" $base "*) continue ;; esac
    if ! dropin_is_ours "$f"; then
      log_warn "leaving $f alone — it has no $DEVENV_TAG marker, so you wrote it"
      continue
    fi
    log_info "pruning the no-longer-shipped $f"
    backup_file "$f" >/dev/null
    run rm -f -- "$f" || continue
    manifest_forget "$f"
    changed "pruned $f"
  done
  return 0
}

# bashrc_ensure_local
#   Creates an empty ~/.bashrc.d/90-local.sh exactly once and never touches it again.
#   It is the user's own fragment: nothing in this repo may write to it.
#   Honours --dry-run. Returns 0.
bashrc_ensure_local() {
  local f="$DEVENV_DROPIN_DIR/90-local.sh"
  [ -e "$f" ] && return 0
  ensure_dir "$DEVENV_DROPIN_DIR" || return 1
  printf '%s\n' \
    '# ~/.bashrc.d/90-local.sh — yours. linux-devops-tools creates this file once' \
    '# and never writes to it again. Put machine-local settings here.' \
    | write_if_changed "$f" 0644
}

# ---------------------------------------------------------------------------
# Lazy bash-completion cache
# ---------------------------------------------------------------------------
#
# D9: completions are GENERATED ONCE at install time into the user's XDG completion
# directory and lazy-loaded by bash-completion's __load_completion() on the first TAB
# for that command. Startup cost goes to zero, not merely "cheaper" — the nine
# `source <(x completion bash)` lines measured 0.23 s per shell.
#
# `bash-completion` is a HARD dependency of this design; 05-base-packages installs it.

# The first line of every file this repo generates. Nothing else is ever removed.
DEVENV_COMP_MARKER="# ${DEVENV_TAG} generated — do not edit; regenerate with: devenv completions"

# comp_dir
#   Prints the user completions directory:
#     ${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}/completions
comp_dir() {
  printf '%s/completions\n' \
    "${BASH_COMPLETION_USER_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion}"
}

# comp_is_ours FILE
#   Returns 0 when FILE was generated by this repo (first line is the marker),
#   under the current tag or the pre-rename one. A cache written before the rename
#   is still ours: were it not recognised, comp_cache would refuse to refresh it
#   (F24h) and `devenv completions --clear` would leave it behind for ever.
comp_is_ours() {
  [ -f "$1" ] || return 1
  head -n1 -- "$1" | grep -Fq -e "$DEVENV_TAG generated" -e "$DEVENV_TAG_LEGACY generated"
}

# comp_cache CMD GEN_CMD…
#   Generates the completion for CMD by running GEN_CMD… and caching its stdout.
#   correctness C3: output that is EMPTY or that fails is DISCARDED, never cached —
#   `bao` and `kubeconform` have no completion sub-command at all, and caching their
#   error text would break TAB for those commands. Nothing is written in that case.
#   Regenerates only when the cache is missing, empty, or older than the RESOLVED
#   binary (readlink -f), so a re-run is free.
#   Skips silently when CMD is not installed.
#   idempotency F24h: refuses to overwrite a file that exists and is NOT ours.
#   Honours --dry-run. Always returns 0 — a missing completion never fails a module.
comp_cache() {
  local cmd=${1:?comp_cache: CMD required}
  shift
  [ $# -gt 0 ] || set -- "$cmd" completion bash
  have "$cmd" || {
    log_debug "no completion for $cmd (not installed)"
    return 0
  }
  local dir out bin tmp
  dir=$(comp_dir)
  out="$dir/$cmd"
  bin=$(command -v "$cmd")
  bin=$(readlink -f -- "$bin" 2>/dev/null || printf '%s\n' "$bin")
  if [ -f "$out" ] && ! comp_is_ours "$out"; then
    log_warn "$out exists and was not generated by linux-devops-tools — leaving it alone"
    return 0
  fi
  if [ -s "$out" ] && [ "$out" -nt "$bin" ]; then
    log_debug "completion cache is current: $out"
    return 0
  fi
  if is_dry_run; then
    log_dryrun "generate the bash completion for $cmd -> $out"
    return 0
  fi
  tmp=$(devenv_tmpfile) || return 0
  if ! "$@" >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    log_debug "$cmd produced no completion output — not caching anything"
    return 0
  fi
  ensure_dir "$dir" || return 0
  {
    printf '%s\n' "$DEVENV_COMP_MARKER"
    cat "$tmp"
  } | write_if_changed "$out" 0644
  manifest_record "$out"
  return 0
}

# comp_shim NAME SOURCE_CMD
#   Writes a small completion file for an ALIAS (`k`, `kubecolor`) that loads
#   SOURCE_CMD's completion and then registers itself.
#   K8: a standalone shim file, not an append to the generated kubectl completion —
#   an append is lost every time that file is regenerated.
#   `-o default` is required, or filename completion breaks for the alias.
#   Honours --dry-run. Always returns 0.
comp_shim() {
  local name=${1:?comp_shim: NAME required} src=${2:?comp_shim: SOURCE_CMD required}
  local dir out fn
  dir=$(comp_dir)
  out="$dir/$name"
  fn="__start_${src//-/_}"
  if [ -f "$out" ] && ! comp_is_ours "$out"; then
    log_warn "$out exists and was not generated by linux-devops-tools — leaving it alone"
    return 0
  fi
  ensure_dir "$dir" || return 0
  {
    printf '%s\n' "$DEVENV_COMP_MARKER"
    printf '%s\n' \
      "if ! declare -F $fn >/dev/null 2>&1; then" \
      "  if [ -r \"\${BASH_SOURCE[0]%/*}/$src\" ]; then" \
      "    . \"\${BASH_SOURCE[0]%/*}/$src\"" \
      "  elif command -v $src >/dev/null 2>&1; then" \
      "    . <($src completion bash)" \
      "  fi" \
      "fi" \
      "declare -F $fn >/dev/null 2>&1 && complete -o default -F $fn \"\${BASH_SOURCE[0]##*/}\""
  } | write_if_changed "$out" 0644
  manifest_record "$out"
  return 0
}

# comp_complete_c NAME… BIN
#   Writes a `complete -C <resolved bin> NAME…` file. terraform's completion is a
#   BINDING, not generated output, so it cannot go through comp_cache.
#   The LAST argument is the binary: either a command name (resolved here with
#   `command -v`) or an already-resolved path — SPEC 6.5's call form
#       comp_complete_c terraform tf t "$(command -v terraform)"
#   works unchanged. It is never hardcoded to /usr/bin/terraform, which is the bug
#   in the live ~/.bashrc.
#   The file is named after the FIRST name, and every name is bound in it.
#   Skips when the binary cannot be resolved. Honours --dry-run. Always returns 0.
comp_complete_c() {
  [ $# -ge 2 ] || {
    log_error "comp_complete_c: need at least one NAME and a BIN"
    return 0
  }
  local bin=${*: -1}
  local names=("${@:1:$#-1}")
  local path=''
  case $bin in
    */*) [ -x "$bin" ] && path=$bin ;;
    *) path=$(command -v "$bin" 2>/dev/null) || path='' ;;
  esac
  [ -n "$path" ] || {
    log_debug "no complete -C binding for $bin (not installed)"
    return 0
  }
  local dir out
  dir=$(comp_dir)
  out="$dir/${names[0]}"
  if [ -f "$out" ] && ! comp_is_ours "$out"; then
    log_warn "$out exists and was not generated by linux-devops-tools — leaving it alone"
    return 0
  fi
  ensure_dir "$dir" || return 0
  {
    printf '%s\n' "$DEVENV_COMP_MARKER"
    printf 'complete -C %q %s\n' "$path" "${names[*]}"
  } | write_if_changed "$out" 0644
  manifest_record "$out"
  return 0
}

# comp_prune
#   MUST-FIX S13 / idempotency F20: `--refresh` must NOT `rm -rf` the shared XDG
#   completions directory — hand-written completions and other installers' files
#   live there. This removes ONLY files whose first line is our marker.
#   Honours --dry-run. Always returns 0.
comp_prune() {
  local dir f
  dir=$(comp_dir)
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    comp_is_ours "$f" || continue
    run rm -f -- "$f" || continue
    manifest_forget "$f"
  done
  log_info "cleared the linux-devops-tools completion cache in $dir"
  return 0
}
