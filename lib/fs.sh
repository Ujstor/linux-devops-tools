# shellcheck shell=bash
# lib/fs.sh — every filesystem mutation in this repository.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# MUST-FIX S6: EVERY writer here routes through lib/run.sh. Under --dry-run nothing
# on disk changes: the function prints "[dry ] write <path> (would change)" and
# returns 0. That is what makes the "fingerprint $HOME and /etc before and after a
# dry run" acceptance test honest.
#
# MUST-FIX S4 / idempotency F4: a SYMLINKED target (mybash symlinks ~/.bashrc) is
# written THROUGH the link — never replaced by `mv`, which would sever it. That bug
# is the reason this repository exists.
#
# Convention: functions that take a payload read it from STDIN. They are no-ops
# (returning 0, writing nothing, taking no backup) when the payload is already the
# file's exact content — that is the whole idempotency story.
#
# Every writer sets DEVENV_CHANGED_LAST to 1 when it changed (or would change) the
# file and 0 when it did not, so callers such as repo_add can react without relying
# on a non-zero return (which `set -e` would turn into a module failure).

[ -n "${_DEVENV_FS:-}" ] && return 0
_DEVENV_FS=1

# The one marker tag. Everything that fences a managed region in someone else's
# file derives from it, so a marker can never drift between the writer, the
# detector and the uninstaller (idempotency F4).
DEVENV_TAG='linux-devops-tools'

# The tag this project used before it was renamed. A box provisioned by any earlier
# version carries it in ~/.bashrc, in ~/.bashrc.d/* and in the completion cache, so
# every REMOVER and every "is this ours?" test below accepts it as well. Nothing
# ever WRITES it: an old block is replaced by a new one, never re-emitted, which is
# what keeps `devenv --only shell` from leaving two loaders behind.
DEVENV_TAG_LEGACY='devops-env-config' # policy-allow: old-name

# Set to 1 by every writer below when it changed (or would change) the file, and to 0
# when it did not. Read by callers such as repo_add's NEED_APT_UPDATE logic; exported
# so a child module sees a defined value.
DEVENV_CHANGED_LAST=${DEVENV_CHANGED_LAST:-0}
export DEVENV_CHANGED_LAST

# block_begin_marker [MARKER] / block_end_marker [MARKER]
#   Print the fence lines for a managed block. MARKER may be empty, which yields
#   exactly SPEC 6.2's literal "# >>> linux-devops-tools >>>".
block_begin_marker() { printf '# >>> %s%s >>>\n' "$DEVENV_TAG" "${1:+:$1}"; }
block_end_marker() { printf '# <<< %s%s <<<\n' "$DEVENV_TAG" "${1:+:$1}"; }

# legacy_block_begin_marker [MARKER] / legacy_block_end_marker [MARKER]
#   The same fences under the pre-rename tag. READ-ONLY: they exist so a block
#   written before the rename can still be found, replaced and deleted. Never
#   print them into a file.
legacy_block_begin_marker() { printf '# >>> %s%s >>>\n' "$DEVENV_TAG_LEGACY" "${1:+:$1}"; }
legacy_block_end_marker() { printf '# <<< %s%s <<<\n' "$DEVENV_TAG_LEGACY" "${1:+:$1}"; }

# sha256_of FILE
#   Prints the file's sha256 hex digest on stdout. Returns 1 when the file cannot
#   be read or no sha256 tool exists. Read-only: runs under --dry-run too.
sha256_of() {
  local f=${1:?sha256_of: FILE required}
  [ -r "$f" ] || return 1
  if have sha256sum; then
    sha256sum -- "$f" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 -- "$f" | awk '{print $1}'
  elif have openssl; then
    openssl dgst -sha256 -- "$f" | awk '{print $NF}'
  else
    return 1
  fi
}

# fs_needs_root PATH
#   Returns 0 when writing PATH would require root (its nearest existing ancestor
#   is not writable by this user), 1 when the current user can write it.
#   Read-only; safe inside `if`.
fs_needs_root() {
  local p=${1:?fs_needs_root: PATH required} d
  if [ -e "$p" ]; then
    [ -w "$p" ] && return 1
    return 0
  fi
  d=$(dirname -- "$p")
  while [ ! -e "$d" ] && [ "$d" != / ]; do d=$(dirname -- "$d"); done
  [ -w "$d" ] && return 1
  return 0
}

# _fs_run_for PATH CMD…   (private) — run CMD through the right privilege gate.
_fs_run_for() {
  local target=$1
  shift
  if fs_needs_root "$target"; then
    run_sudo "$@"
  else
    run "$@"
  fi
}

# ensure_dir PATH [MODE]
#   Creates PATH and any missing parents. MODE defaults to 0755.
#   No-op (silent, no dry-run line) when the directory already exists.
#   Uses run/run_sudo, so --dry-run creates nothing. Returns 0, or non-zero when
#   the directory could not be created.
ensure_dir() {
  local d=${1:?ensure_dir: PATH required} mode=${2:-0755}
  [ -d "$d" ] && return 0
  _fs_run_for "$d" install -d -m "$mode" -- "$d" || return 1
  changed "created directory $d"
  return 0
}

# backup_file PATH
#   Copies PATH to PATH.devenv.<UTC>.bak, preserving mode and owner, and prints the
#   backup path on stdout. At most one backup per file per run. Older backups are
#   pruned to the newest DEVENV_BACKUP_KEEP (default 5) — idempotency F24a.
#   Returns 0 and prints nothing when PATH does not exist.
#   Only call this when you are ABOUT TO CHANGE the file; the writers below already do.
#   Under --dry-run it prints the intended path and copies nothing.
backup_file() {
  local f=${1:?backup_file: PATH required} stamp bak
  [ -e "$f" ] || return 0
  local key="${DEVENV_RUNDIR:-}/backedup"
  if [ -n "${DEVENV_RUNDIR:-}" ] && [ -f "$key" ] && grep -Fxq -- "$f" "$key"; then
    return 0
  fi
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  bak="${f}.devenv.${stamp}.bak"
  if is_dry_run; then
    log_dryrun "backup $f -> $bak"
    printf '%s\n' "$bak"
    return 0
  fi
  _fs_run_for "$bak" cp -p -- "$f" "$bak" || return 1
  [ -n "${DEVENV_RUNDIR:-}" ] && printf '%s\n' "$f" >>"$key"
  log_info "backed up $f -> $bak"
  _fs_prune_backups "$f"
  printf '%s\n' "$bak"
  return 0
}

# _fs_prune_backups PATH   (private) — keep only the newest N of our own backups.
_fs_prune_backups() {
  local f=$1 keep=${DEVENV_BACKUP_KEEP:-5} old
  local dir base
  dir=$(dirname -- "$f")
  base=$(basename -- "$f")
  while IFS= read -r old; do
    [ -n "$old" ] || continue
    _fs_run_for "$old" rm -f -- "$old"
  done < <(find "$dir" -maxdepth 1 -type f -name "${base}.devenv.*.bak" 2>/dev/null \
    | sort | head -n "-${keep}")
  return 0
}

# file_content_differs PATH
#   Payload on stdin. Returns 0 when PATH is missing or its bytes differ from the
#   payload, 1 when they are identical. PREDICATE — use it inside `if`, never as the
#   last statement of a function under `set -e`.
#   Consumes stdin, so read the payload once into a temp file if you need it twice.
file_content_differs() {
  local f=${1:?file_content_differs: PATH required} tmp
  tmp=$(devenv_tmpfile) || {
    cat >/dev/null
    return 0
  }
  cat >"$tmp"
  [ -f "$f" ] || return 0
  cmp -s -- "$tmp" "$f" && return 1
  return 0
}

# _fs_place TMP DEST MODE   (private)
#   Installs the already-rendered TMP at DEST.
#   * DEST is a SYMLINK  -> `cp` writes THROUGH the link, preserving it (S4/F4).
#   * otherwise          -> same-directory temp + `mv` (atomic rename).
#   Both forms are argv-only, so they pass through run/run_sudo unchanged.
_fs_place() {
  local tmp=$1 dest=$2 mode=$3 dir stage rc=0
  if [ -L "$dest" ]; then
    _fs_run_for "$dest" cp -- "$tmp" "$dest" || return 1
    return 0
  fi
  dir=$(dirname -- "$dest")
  ensure_dir "$dir" || return 1
  if fs_needs_root "$dest"; then
    run_sudo install -m "$mode" -- "$tmp" "$dest" || return 1
    return 0
  fi
  stage="$dir/.$(basename -- "$dest").devenv.$$"
  run install -m "$mode" -- "$tmp" "$stage" || return 1
  run mv -f -- "$stage" "$dest" || rc=$?
  if [ "$rc" -ne 0 ]; then
    run rm -f -- "$stage"
    return "$rc"
  fi
  return 0
}

# write_file_atomic PATH MODE
#   Payload on stdin. Writes it unconditionally (no content comparison) and records
#   a change. Prefer write_if_changed — this one exists for callers that have already
#   decided the content differs. Honours --dry-run. Returns non-zero on failure.
write_file_atomic() {
  local dest=${1:?write_file_atomic: PATH required} mode=${2:-0644} tmp
  tmp=$(devenv_tmpfile) || return 1
  cat >"$tmp"
  if is_dry_run; then
    log_dryrun "write $dest (mode $mode)"
    changed "write $dest"
    return 0
  fi
  _fs_place "$tmp" "$dest" "$mode" || return 1
  changed "write $dest"
  return 0
}

# write_if_changed PATH MODE
#   THE default writer. Payload on stdin.
#   * bytes identical  -> no write, no backup, no log noise; DEVENV_CHANGED_LAST=0.
#   * different/absent -> backup_file (only if PATH existed), then write; sets
#                         DEVENV_CHANGED_LAST=1 and records a `changed` entry.
#   Symlink-safe (S4). Honours --dry-run (S6). Returns 0 on success.
write_if_changed() {
  local dest=${1:?write_if_changed: PATH required} mode=${2:-0644} tmp
  tmp=$(devenv_tmpfile) || return 1
  cat >"$tmp"
  DEVENV_CHANGED_LAST=0
  if [ -f "$dest" ] && cmp -s -- "$tmp" "$dest"; then
    log_debug "unchanged: $dest"
    return 0
  fi
  [ -e "$dest" ] && backup_file "$dest" >/dev/null
  if is_dry_run; then
    log_dryrun "write $dest (would change)"
    changed "write $dest"
    return 0
  fi
  _fs_place "$tmp" "$dest" "$mode" || return 1
  log_success "wrote $dest"
  changed "write $dest"
  return 0
}

# write_once PATH MODE
#   Payload on stdin. Creates PATH when it is absent. When PATH already exists the
#   file is LEFT ALONE; if the shipped payload differs, it is written to PATH.new and
#   a one-line diff hint is logged. Use for files a tool rewrites itself
#   (k9s config.yaml, kubecolor color.yaml). Returns 0.
write_once() {
  local dest=${1:?write_once: PATH required} mode=${2:-0644} tmp
  tmp=$(devenv_tmpfile) || return 1
  cat >"$tmp"
  if [ ! -e "$dest" ]; then
    write_if_changed "$dest" "$mode" <"$tmp"
    return
  fi
  if cmp -s -- "$tmp" "$dest"; then
    log_debug "unchanged: $dest"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  write_if_changed "$dest.new" "$mode" <"$tmp" || return 1
  log_warn "$dest exists and differs — shipped version written to $dest.new"
  log_warn "  compare with:  diff -u '$dest' '$dest.new'"
  return 0
}

# has_block_in_file FILE MARKER
#   Returns 0 when FILE contains the managed block fenced by MARKER, under either
#   the current tag or the pre-rename one — a legacy block is still a live block:
#   it sources the same loader, and `devenv shell status` must not call it absent.
#   Read-only predicate; MARKER may be empty for the top-level hook block.
has_block_in_file() {
  local f=${1:?has_block_in_file: FILE required} marker=${2-}
  [ -f "$f" ] || return 1
  grep -Fxq -e "$(block_begin_marker "$marker")" \
    -e "$(legacy_block_begin_marker "$marker")" -- "$f"
}

# count_blocks_in_file FILE [MARKER]
#   Prints how many opening fences FILE carries, current tag and pre-rename tag
#   together, so the doctor's "the loader runs N times" count cannot miss one.
#   Prints 0 when FILE does not exist. Read-only; always returns 0.
count_blocks_in_file() {
  local f=${1:?count_blocks_in_file: FILE required} marker=${2-} n
  n=$(grep -cFx -e "$(block_begin_marker "$marker")" \
    -e "$(legacy_block_begin_marker "$marker")" -- "$f" 2>/dev/null) || n=0
  printf '%s\n' "${n:-0}"
}

# ensure_block_in_file FILE MARKER
#   Payload on stdin. Renders
#       # >>> linux-devops-tools[:MARKER] >>>
#       <payload>
#       # <<< linux-devops-tools[:MARKER] <<<
#   and makes FILE contain exactly that block: replacing an existing one in place,
#   or appending it when absent. Byte-identical on a second run (no backup, no write).
#   MUST-FIX S4: when FILE is a symlink the block is written THROUGH the link, so
#   ~/.bashrc -> ~/linuxtoolbox/mybash/.bashrc keeps working and the link survives.
#   Refuses (returns 1) when FILE has an opening fence and no closing fence, rather
#   than swallow everything after it.
#   RENAME: a block left by the pre-rename tag is UPGRADED IN PLACE — consumed where
#   it sits and re-emitted under the new fences. Matching only the new fence would
#   append a second block beside the old one and the loader would run twice, which
#   is the exact failure `devenv doctor` reports and refuses to fix automatically.
#   Honours --dry-run. Returns 0 on success.
ensure_block_in_file() {
  local f=${1:?ensure_block_in_file: FILE required} marker=${2-}
  local body begin end lbegin lend out
  begin=$(block_begin_marker "$marker")
  end=$(block_end_marker "$marker")
  lbegin=$(legacy_block_begin_marker "$marker")
  lend=$(legacy_block_end_marker "$marker")
  body=$(devenv_tmpfile) || return 1
  cat >"$body"

  if [ -f "$f" ]; then
    if grep -Fxq -- "$begin" "$f" && ! grep -Fxq -- "$end" "$f"; then
      log_error "$f has an unterminated '$begin' block — refusing to edit it."
      log_error "Add the matching '$end' line by hand, then re-run."
      return 1
    fi
    if grep -Fxq -- "$lbegin" "$f" && ! grep -Fxq -- "$lend" "$f"; then
      log_error "$f has an unterminated '$lbegin' block — refusing to edit it."
      log_error "Add the matching '$lend' line by hand, then re-run."
      return 1
    fi
  fi

  local src=/dev/null mode=0644
  if [ -f "$f" ]; then
    src=$f
    mode=$(_fs_mode_of "$f")
  fi
  out=$(devenv_tmpfile) || return 1
  awk -v b="$begin" -v e="$end" -v lb="$lbegin" -v le="$lend" -v body="$body" '
    BEGIN { while ((getline l < body) > 0) blk = blk l "\n"; close(body) }
    $0 == b  { inblk = 1; fence = e;  seen = 1; printf "%s\n%s%s\n", b, blk, e; next }
    $0 == lb { inblk = 1; fence = le; seen = 1; printf "%s\n%s%s\n", b, blk, e; next }
    inblk    { if ($0 == fence) inblk = 0; next }
             { print }
    END      { if (!seen) printf "%s\n%s%s\n", b, blk, e }
  ' "$src" >"$out" || return 1

  write_if_changed "$f" "$mode" <"$out"
}

# remove_block_from_file FILE MARKER
#   Deletes the managed block fenced by MARKER. Symlink-safe (writes through the
#   link, never `mv`). No-op when the block is absent. Honours --dry-run. Returns 0.
#   RENAME: removes a block under the pre-rename tag too. `devenv uninstall` on a
#   box installed before the rename would otherwise leave its ~/.bashrc sourcing a
#   loader from a directory it has just deleted — every new shell an error.
remove_block_from_file() {
  local f=${1:?remove_block_from_file: FILE required} marker=${2-}
  local begin end lbegin lend out
  [ -f "$f" ] || return 0
  begin=$(block_begin_marker "$marker")
  end=$(block_end_marker "$marker")
  lbegin=$(legacy_block_begin_marker "$marker")
  lend=$(legacy_block_end_marker "$marker")
  grep -Fxq -e "$begin" -e "$lbegin" -- "$f" || return 0
  out=$(devenv_tmpfile) || return 1
  awk -v b="$begin" -v e="$end" -v lb="$lbegin" -v le="$lend" '
    $0 == b  { inblk = 1; fence = e;  next }
    $0 == lb { inblk = 1; fence = le; next }
    inblk    { if ($0 == fence) inblk = 0; next }
             { print }
  ' "$f" >"$out" || return 1
  write_if_changed "$f" "$(_fs_mode_of "$f")" <"$out"
}

# _fs_mode_of PATH  (private) — octal mode of PATH, or 0644.
_fs_mode_of() {
  local m
  m=$(stat -c '%a' -- "$1" 2>/dev/null) || m=''
  case $m in '' | *[!0-7]*) m=644 ;; esac
  printf '0%s\n' "${m#0}"
}

# ensure_line_in_file FILE LINE MARKER
#   Ensures FILE contains exactly one line
#       LINE # linux-devops-tools:MARKER
#   Matching is on the MARKER SUFFIX, never on the text — that is why the live
#   ~/.bashrc ended up with both `. cargo/env` and `source cargo/env`.
#   Replaces a drifted line in place, appends when absent, no-op when identical.
#   RENAME: a line carrying the pre-rename suffix is the same line, and is replaced
#   rather than left behind with a second copy appended under the new suffix.
#   Symlink-safe; honours --dry-run. Returns 0.
ensure_line_in_file() {
  local f=${1:?ensure_line_in_file: FILE required}
  local line=${2:?ensure_line_in_file: LINE required}
  local marker=${3:?ensure_line_in_file: MARKER required}
  local tagged suffix lsuffix out
  suffix="# ${DEVENV_TAG}:${marker}"
  lsuffix="# ${DEVENV_TAG_LEGACY}:${marker}"
  tagged="$line $suffix"
  out=$(devenv_tmpfile) || return 1
  if [ -f "$f" ]; then
    awk -v suf="$suffix" -v lsuf="$lsuffix" -v want="$tagged" '
      function ends_with(s) {
        return index($0, s) && substr($0, length($0) - length(s) + 1) == s
      }
      ends_with(suf) || ends_with(lsuf) {
        if (!done) { print want; done = 1 }
        next
      }
      { print }
      END { if (!done) print want }
    ' "$f" >"$out" || return 1
  else
    printf '%s\n' "$tagged" >"$out"
  fi
  write_if_changed "$f" "$(_fs_mode_of "$f")" <"$out"
}

# symlink_file SRC DST
#   Points DST at the resolved absolute SRC. No-op when the link already resolves
#   there. A real file at DST is backed up first, then replaced by the link.
#   Honours --dry-run. Returns non-zero when SRC does not exist.
symlink_file() {
  local src=${1:?symlink_file: SRC required} dst=${2:?symlink_file: DST required} abs
  [ -e "$src" ] || {
    log_warn "symlink source does not exist: $src"
    return 1
  }
  abs=$(readlink -f -- "$src") || abs=$src
  if [ -L "$dst" ] && [ "$(readlink -f -- "$dst" 2>/dev/null)" = "$abs" ]; then
    log_debug "symlink already correct: $dst -> $abs"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  ensure_dir "$(dirname -- "$dst")" || return 1
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    backup_file "$dst" >/dev/null
    _fs_run_for "$dst" rm -f -- "$dst" || return 1
  fi
  _fs_run_for "$dst" ln -sfn -- "$abs" "$dst" || return 1
  DEVENV_CHANGED_LAST=1
  changed "symlink $dst -> $abs"
  return 0
}

# copy_if_absent SRC DST [MODE]
#   Copies SRC to DST only when DST does not exist. NEVER overwrites — this is how
#   ~/.config/devops-env/sso.env (0600, holds the only real hostname on the box) is
#   seeded exactly once. Honours --dry-run. Returns 0.
copy_if_absent() {
  local src=${1:?copy_if_absent: SRC required} dst=${2:?copy_if_absent: DST required}
  local mode=${3:-0644}
  if [ -e "$dst" ]; then
    log_debug "exists, not overwritten: $dst"
    DEVENV_CHANGED_LAST=0
    return 0
  fi
  [ -r "$src" ] || {
    log_warn "copy_if_absent: cannot read $src"
    return 1
  }
  write_if_changed "$dst" "$mode" <"$src"
}

# ---------------------------------------------------------------------------
# Manifest — what this repo owns on the machine
# ---------------------------------------------------------------------------

# manifest_path  — prints $DEVENV_STATE/manifest.
manifest_path() { printf '%s\n' "${DEVENV_STATE:?DEVENV_STATE unset}/manifest"; }

# manifest_get PATH   — prints the recorded sha256 for PATH, or nothing. Always 0.
manifest_get() {
  local p=${1:?manifest_get: PATH required} mf
  mf=$(manifest_path)
  [ -f "$mf" ] || return 0
  awk -F'\t' -v p="$p" '$2 == p { print $1; exit }' "$mf"
}

# manifest_record PATH
#   Records PATH's current sha256 in the manifest (replacing any earlier entry).
#   Honours --dry-run. Always returns 0.
manifest_record() {
  local p=${1:?manifest_record: PATH required} mf sum tmp
  mf=$(manifest_path)
  if is_dry_run; then
    log_dryrun "record $p in $mf"
    return 0
  fi
  sum=$(sha256_of "$p") || return 0
  if [ "$(manifest_get "$p")" = "$sum" ]; then
    return 0
  fi
  ensure_dir "$(dirname -- "$mf")" || return 0
  tmp=$(devenv_tmpfile) || return 0
  if [ -f "$mf" ]; then
    awk -F'\t' -v p="$p" '$2 != p' "$mf" >"$tmp"
  fi
  printf '%s\t%s\n' "$sum" "$p" >>"$tmp"
  LC_ALL=C sort -k2 -t"$(printf '\t')" -o "$tmp" "$tmp" 2>/dev/null || true
  run install -m 0644 -- "$tmp" "$mf" || return 0
  return 0
}

# manifest_forget PATH   — drops PATH's entry. Honours --dry-run. Always 0.
manifest_forget() {
  local p=${1:?manifest_forget: PATH required} mf tmp
  mf=$(manifest_path)
  [ -f "$mf" ] || return 0
  if is_dry_run; then
    log_dryrun "forget $p from $mf"
    return 0
  fi
  tmp=$(devenv_tmpfile) || return 0
  awk -F'\t' -v p="$p" '$2 != p' "$mf" >"$tmp"
  run install -m 0644 -- "$tmp" "$mf" || return 0
  return 0
}

# manifest_owns PATH
#   Returns 0 when PATH is byte-identical to what this repo last wrote there.
#   Used by pruners so they can never delete a file the user authored.
manifest_owns() {
  local p=${1:?manifest_owns: PATH required} rec cur
  rec=$(manifest_get "$p")
  [ -n "$rec" ] || return 1
  cur=$(sha256_of "$p") || return 1
  [ "$rec" = "$cur" ]
}

# write_managed PATH MODE
#   Payload on stdin, for files this repo OWNS (k9s plugins and skins, ~/.local/bin
#   shims, the SSO templates).
#     * bytes identical               -> no-op, manifest refreshed, returns 0
#     * absent, or ours and unmodified -> overwritten, manifest updated
#     * present but HAND-EDITED       -> backup + overwrite + warning, unless
#                                        DEVENV_KEEP_LOCAL=1 (alias K9S_KEEP_LOCAL=1),
#                                        in which case the local file is kept
#   Honours --dry-run. Returns 0.
write_managed() {
  local dest=${1:?write_managed: PATH required} mode=${2:-0644} tmp cur rec
  tmp=$(devenv_tmpfile) || return 1
  cat >"$tmp"
  DEVENV_CHANGED_LAST=0

  if [ -f "$dest" ]; then
    if cmp -s -- "$tmp" "$dest"; then
      manifest_record "$dest"
      log_debug "unchanged: $dest"
      return 0
    fi
    cur=$(sha256_of "$dest" || printf '\n')
    rec=$(manifest_get "$dest")
    if [ -z "$rec" ] || [ "$cur" != "$rec" ]; then
      if [ "${DEVENV_KEEP_LOCAL:-${K9S_KEEP_LOCAL:-0}}" = 1 ]; then
        log_warn "keeping your edited $dest (DEVENV_KEEP_LOCAL=1) — shipped version not installed"
        return 0
      fi
      log_warn "$dest was edited outside linux-devops-tools; backing it up before overwriting"
    fi
  fi

  write_if_changed "$dest" "$mode" <"$tmp" || return 1
  manifest_record "$dest"
  return 0
}

# ---------------------------------------------------------------------------
# YAML map merge — additive, never destructive
# ---------------------------------------------------------------------------

# yaml_map_merge FILE ROOT_KEY [MODE]
#   Payload on stdin: a YAML document whose single root key is ROOT_KEY with
#   two-space-indented children. Appends ONLY the child keys FILE does not already
#   have, at the end of FILE's ROOT_KEY block, preserving every existing value and
#   comment. Comments immediately above a child key travel with it.
#   No-op (no backup, no write) when nothing is missing.
#   Creates FILE when absent. Honours --dry-run. Returns 0.
#   This is how ~/.config/k9s/aliases.yaml gains 56 entries without losing the 8 the
#   user already has, and how hotkeys.yaml is merged under `hotKeys`.
yaml_map_merge() {
  local f=${1:?yaml_map_merge: FILE required} root=${2:?yaml_map_merge: ROOT_KEY required}
  local mode=${3:-} payload out
  payload=$(devenv_tmpfile) || return 1
  cat >"$payload"
  out=$(devenv_tmpfile) || return 1
  local src=/dev/null
  if [ -f "$f" ]; then src=$f; fi
  awk -v root="$root" '
    function flushmissing(   i, k) {
      for (i = 1; i <= nkeys; i++) {
        k = order[i]
        if (!(k in have)) printf "%s", blk[k]
      }
    }
    NR == FNR {
      if (!pseen && $0 ~ "^" root ":") { pseen = 1; pin = 1; next }
      if (pin && $0 ~ /^[^[:space:]#]/) { pin = 0 }
      if (!pin) next
      if ($0 ~ /^  [^[:space:]#][^:]*:/) {
        k = $0; sub(/^  /, "", k); sub(/:.*$/, "", k)
        cur = k; order[++nkeys] = k; blk[k] = pend $0 "\n"; pend = ""
        next
      }
      if (cur == "") { pend = pend $0 "\n" } else { blk[cur] = blk[cur] $0 "\n" }
      next
    }
    {
      line[++nl] = $0
      if (!tseen && $0 ~ "^" root ":") { tseen = 1; tin = 1; tstart = nl; next }
      if (tin) {
        if ($0 ~ /^[^[:space:]#]/) { tin = 0 }
        else {
          if ($0 ~ /^[[:space:]]/) tlast = nl
          if ($0 ~ /^  [^[:space:]#][^:]*:/) {
            k = $0; sub(/^  /, "", k); sub(/:.*$/, "", k); have[k] = 1
          }
        }
      }
    }
    END {
      ins = tlast ? tlast : tstart
      for (i = 1; i <= nl; i++) {
        print line[i]
        if (ins && i == ins) flushmissing()
      }
      if (!tseen) {
        if (nl > 0) print ""
        print root ":"
        flushmissing()
      }
    }
  ' "$payload" "$src" >"$out" || return 1
  if [ -z "$mode" ]; then
    mode=0644
    if [ -f "$f" ]; then mode=$(_fs_mode_of "$f"); fi
  fi
  write_if_changed "$f" "$mode" <"$out"
}

# ---------------------------------------------------------------------------
# External git checkouts
# ---------------------------------------------------------------------------

# devenv_sync_repo URL DIR [REF]
#   Clones URL into DIR, or fast-forwards an existing clone to REF (default: the
#   remote's default branch). REFUSES to touch a dirty worktree — it warns and
#   returns 0, so a user's local edits in Ujstor/nvim-config are never destroyed.
#   Honours --dry-run. Returns non-zero only when the clone itself fails.
devenv_sync_repo() {
  local url=${1:?devenv_sync_repo: URL required} dir=${2:?devenv_sync_repo: DIR required}
  local ref=${3:-}
  have git || {
    log_skip "git is not installed — cannot sync $url"
    return 0
  }
  if [ ! -d "$dir/.git" ]; then
    if [ -e "$dir" ]; then
      log_warn "$dir exists and is not a git checkout — leaving it alone"
      return 0
    fi
    ensure_dir "$(dirname -- "$dir")" || return 1
    if [ -n "$ref" ]; then
      run git clone --depth=1 --branch "$ref" -- "$url" "$dir" || return 1
    else
      run git clone --depth=1 -- "$url" "$dir" || return 1
    fi
    changed "cloned $url -> $dir"
    return 0
  fi
  if ! is_dry_run && [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    log_warn "$dir has uncommitted changes — not updating it"
    return 0
  fi
  # `git fetch --depth=1` REWRITES .git/shallow on every call, even when it
  # brings nothing new. In a shallow checkout that is a file change on every
  # single run, which is exactly what the "install twice, change nothing" test
  # in tests/docker/ is there to catch — and it caught it the moment an entry in
  # the external-repo list became enabled by default.
  #
  # So ask the remote what the ref points at before touching anything local:
  # ls-remote writes nothing into the checkout. Skipped under --dry-run, which
  # must neither reach the network nor change the plan it prints.
  if ! is_dry_run; then
    local want head
    want=$(git -C "$dir" ls-remote --quiet origin "${ref:-HEAD}" 2>/dev/null | awk 'NR==1 {print $1}')
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf '')
    if [ -n "$want" ] && [ "$want" = "$head" ]; then
      log_debug "$dir is already at ${want:0:12} — nothing to fetch"
      return 0
    fi
  fi
  run git -C "$dir" fetch --depth=1 --quiet origin "${ref:-HEAD}" || {
    log_warn "could not fetch $url — keeping the existing checkout"
    return 0
  }
  local before after
  before=$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf '\n')
  run git -C "$dir" checkout --quiet --detach FETCH_HEAD || {
    log_warn "could not update $dir"
    return 0
  }
  after=$(git -C "$dir" rev-parse HEAD 2>/dev/null || printf '\n')
  [ "$before" != "$after" ] && changed "updated $dir to ${after:0:12}"
  return 0
}
