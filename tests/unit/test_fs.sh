#!/usr/bin/env bash
#
# tests/unit/test_fs.sh — lib/fs.sh: the writers, the managed block and --dry-run.
#
# These are the three properties the whole repository rests on:
#   * a second write with identical bytes does nothing at all,
#   * --dry-run writes nothing at all,
#   * a symlinked dotfile is written THROUGH, never replaced (MUST-FIX S4).

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

sandbox=$T_SANDBOX

t_section 'write_if_changed'

f="$sandbox/config.txt"
printf 'one\n' | write_if_changed "$f" 0644
assert_file "$f" 'write_if_changed creates the file'
assert_eq 'one' "$(cat "$f")" 'with the payload from stdin'
assert_eq '644' "$(stat -c '%a' "$f")" 'and the requested mode'

# Idempotency, the way the container test measures it: identical bytes must not
# produce a new file, a new mtime or a backup.
before=$(stat -c '%Y %s %a' "$f")
printf 'one\n' | write_if_changed "$f" 0644
assert_eq "$before" "$(stat -c '%Y %s %a' "$f")" 'an identical payload does not rewrite the file'
assert_eq '0' "$(find "$sandbox" -maxdepth 1 -name 'config.txt.devenv.*.bak' | wc -l)" \
  'and takes no backup'

# The documented contract of every lib/fs.sh writer (lib/fs.sh:19). Fed by
# REDIRECTION, not a pipe: the right-hand side of a pipeline runs in a subshell,
# so a writer there cannot report anything back to its caller. copy_if_absent
# calls write_if_changed exactly this way, and 35-kubernetes.sh reads the flag
# afterwards.
printf 'one\n' >"$sandbox/payload"
DEVENV_CHANGED_LAST=x
write_if_changed "$f" 0644 <"$sandbox/payload"
assert_eq '0' "${DEVENV_CHANGED_LAST}" 'DEVENV_CHANGED_LAST is 0 when nothing changed'

printf 'two\n' >"$sandbox/payload"
DEVENV_CHANGED_LAST=x
write_if_changed "$f" 0644 <"$sandbox/payload"
assert_eq 'two' "$(cat "$f")" 'a different payload is written'
assert_eq '1' "$(find "$sandbox" -maxdepth 1 -name 'config.txt.devenv.*.bak' | wc -l)" \
  'and the previous content is backed up first'
assert_eq '1' "${DEVENV_CHANGED_LAST}" 'DEVENV_CHANGED_LAST is 1 when the file changed'

t_section 'file_content_differs'

# shellcheck disable=SC2016  # $1 is the child shell's argument, deliberately not expanded here
assert_fail 'file_content_differs is false for identical bytes' \
  bash -c '. "$DEVENV_HOME/lib/common.sh"; printf "two\n" | file_content_differs "$1"' _ "$f"

t_section 'ensure_block_in_file'

rc="$sandbox/rc"
printf 'first line\n' >"$rc"
printf 'PAYLOAD\n' | ensure_block_in_file "$rc" ''
assert_contains "$(cat "$rc")" 'first line' 'the original content survives'
assert_contains "$(cat "$rc")" 'PAYLOAD' 'the payload is inside the block'
assert_eq '1' "$(grep -c '^# >>> linux-devops-tools >>>$' "$rc")" 'exactly one opening fence'
assert_ok 'has_block_in_file finds it' has_block_in_file "$rc" ''

before=$(stat -c '%Y %s' "$rc")
printf 'PAYLOAD\n' | ensure_block_in_file "$rc" ''
assert_eq "$before" "$(stat -c '%Y %s' "$rc")" 'a second identical block is a no-op'

printf 'REPLACED\n' | ensure_block_in_file "$rc" ''
assert_eq '1' "$(grep -c '^# >>> linux-devops-tools >>>$' "$rc")" \
  'a changed payload replaces the block in place, it does not append a second one'
assert_contains "$(cat "$rc")" 'REPLACED' 'with the new payload'
assert_eq '0' "$(grep -c 'PAYLOAD' "$rc")" 'and the old payload is gone'

remove_block_from_file "$rc" ''
assert_eq 'first line' "$(cat "$rc")" 'remove_block_from_file leaves the rest untouched'

t_section 'a block written under the pre-rename tag is upgraded, not duplicated'

# The repository was renamed devops-env-config -> linux-devops-tools. Every box
# installed before that carries the old fences in ~/.bashrc. If the writer only
# matched the new fence it would append a second block beside the old one and the
# loader would run twice; if the remover only matched the new fence, `devenv
# uninstall` would leave the machine sourcing a loader it had just deleted.
# The two fences are spelled out ONCE, as literals, because that is the contract:
# this exact text is in ~/.bashrc on every box installed before the rename, and a
# fixture built from legacy_block_begin_marker would still pass if DEVENV_TAG_LEGACY
# were wrong. Everything below derives from these two.
old_begin='# >>> devops-env-config >>>' # policy-allow: old-name
old_end='# <<< devops-env-config <<<'   # policy-allow: old-name
assert_eq "$old_begin" "$(legacy_block_begin_marker '')" \
  'legacy_block_begin_marker still spells the pre-rename opening fence'
assert_eq "$old_end" "$(legacy_block_end_marker '')" \
  'and legacy_block_end_marker the closing one'

legacy="$sandbox/legacy-rc"
printf '%s\n' 'first line' "$old_begin" 'OLD PAYLOAD' "$old_end" 'last line' >"$legacy"

assert_ok 'has_block_in_file finds a pre-rename block' has_block_in_file "$legacy" ''
assert_eq '1' "$(count_blocks_in_file "$legacy" '')" 'and it is counted as one block'

printf 'NEW PAYLOAD\n' | ensure_block_in_file "$legacy" ''
assert_eq '1' "$(grep -c '^# >>> linux-devops-tools >>>$' "$legacy")" \
  'the block is re-fenced under the new tag'
assert_eq '0' "$(grep -cF "$DEVENV_TAG_LEGACY" "$legacy")" 'no old fence is left behind'
assert_eq '0' "$(grep -c 'OLD PAYLOAD' "$legacy")" 'and the old payload is replaced'
assert_contains "$(cat "$legacy")" 'NEW PAYLOAD' 'with the new one'
assert_eq '1' "$(grep -c 'first line' "$legacy")" 'the content before the block survives'
assert_contains "$(cat "$legacy")" 'last line' 'and so does the content after it'

# The removal path, from the old fences directly: this is `devenv uninstall` on a
# box that has not re-run the installer since the rename.
printf '%s\n' 'first line' "$old_begin" 'OLD' "$old_end" >"$legacy"
remove_block_from_file "$legacy" ''
assert_eq 'first line' "$(cat "$legacy")" 'remove_block_from_file deletes a pre-rename block'

t_section 'ensure_block_in_file refuses an unterminated fence (never swallows the tail)'

broken="$sandbox/broken"
{
  printf '# >>> linux-devops-tools >>>\n'
  printf 'half a block, no closing fence\n'
  printf 'important user content\n'
} >"$broken"
# shellcheck disable=SC2016  # ditto
assert_fail 'an unterminated block is refused' \
  bash -c '. "$DEVENV_HOME/lib/common.sh"; printf "x\n" | ensure_block_in_file "$1" ""' _ "$broken"
assert_contains "$(cat "$broken")" 'important user content' \
  'and nothing after the fence is lost'

t_section 'a symlinked ~/.bashrc is written through (MUST-FIX S4)'

real="$sandbox/mybash/.bashrc"
link="$sandbox/.bashrc"
mkdir -p "$sandbox/mybash"
printf 'upstream content\n' >"$real"
ln -sfn "$real" "$link"

printf 'HOOK LINE\n' | ensure_block_in_file "$link" ''
assert_symlink "$link" 'the link is not replaced by a regular file'
assert_eq "$real" "$(readlink "$link")" 'and it still points at the same target'
assert_contains "$(cat "$real")" 'HOOK LINE' 'the block landed in the target file'
assert_contains "$(cat "$real")" 'upstream content' 'the target keeps its own content'

remove_block_from_file "$link" ''
assert_symlink "$link" 'removing the block also preserves the link'
assert_eq 'upstream content' "$(cat "$real")" 'and restores the target exactly'

t_section 'ensure_line_in_file'

lines="$sandbox/lines"
printf 'a\n' >"$lines"
ensure_line_in_file "$lines" 'export DEVENV_X=1' 'unit'
ensure_line_in_file "$lines" 'export DEVENV_X=1' 'unit'
assert_eq '2' "$(grep -c . "$lines")" 'the line is added exactly once'
ensure_line_in_file "$lines" 'export DEVENV_X=2' 'unit'
assert_eq '2' "$(grep -c . "$lines")" 'and updated in place when the value changes'
assert_contains "$(cat "$lines")" 'DEVENV_X=2' 'to the new value'

t_section 'symlink_file'

target="$sandbox/target.conf"
printf 'target\n' >"$target"
symlink_file "$target" "$sandbox/link.conf"
assert_symlink "$sandbox/link.conf" 'symlink_file creates the link'
DEVENV_CHANGED_LAST=x
symlink_file "$target" "$sandbox/link.conf"
assert_eq '0' "$DEVENV_CHANGED_LAST" 'and is a silent no-op when it is already correct'

t_section '--dry-run writes nothing at all (MUST-FIX S6)'

(
  export DEVENV_DRY_RUN=1
  printf 'x\n' | write_if_changed "$sandbox/dry-write" 0644
  printf 'x\n' | ensure_block_in_file "$sandbox/dry-block" ''
  ensure_dir "$sandbox/dry-dir"
  symlink_file "$target" "$sandbox/dry-link"
  run touch "$sandbox/dry-run-touched"
  run mkdir "$sandbox/dry-run-dir"
) >/dev/null 2>&1

assert_no_file "$sandbox/dry-write" 'write_if_changed created nothing'
assert_no_file "$sandbox/dry-block" 'ensure_block_in_file created nothing'
assert_no_file "$sandbox/dry-dir" 'ensure_dir created nothing'
assert_no_file "$sandbox/dry-link" 'symlink_file created nothing'
assert_no_file "$sandbox/dry-run-touched" 'run executed nothing'
assert_no_file "$sandbox/dry-run-dir" 'run executed nothing (mkdir)'

t_section 'backup_file'

b="$sandbox/backed"
printf 'v1\n' >"$b"
bak=$(backup_file "$b")
assert_file "$bak" 'backup_file returns the path it wrote'
assert_eq 'v1' "$(cat "$bak")" 'with the original content'
assert_eq '' "$(backup_file "$sandbox/does-not-exist")" \
  'and is a silent no-op for a file that does not exist'

t_summary
