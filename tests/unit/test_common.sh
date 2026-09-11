#!/usr/bin/env bash
#
# tests/unit/test_common.sh — lib/common.sh's two scratch areas, and the one
# property that separates them: whether a file written there can be RUN.
#
# This exists because /tmp is mounted `noexec` on every hardened host in the
# fleet, and $DEVENV_RUNDIR lives under /tmp. Anything that downloaded a binary
# and executed it therefore died with one line of "Permission denied" a long way
# from its cause — a whole kubectl plugin roster, and the rust toolchain, on one
# real install. devenv_execdir is the answer and this is what holds it honest:
#
#   * the probe really executes something, and really refuses a directory it
#     cannot use (that is the entire mechanism — `mount` and /proc/mounts are
#     not consulted, because bind mounts and overlays make them liars)
#   * an unusable first candidate is SKIPPED, not fatal
#   * the directory handed out actually runs a file
#   * ONE root per run, even though every caller says `x=$(devenv_execdir)` and
#     that runs in a subshell whose exports die with it
#   * the run's exec scratch is cleaned up when the run's owner exits
#
# No network, no root, nothing written outside the sandbox $HOME.

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

# Keep every exec root this file makes inside the sandbox, so nothing is left in
# /tmp when the harness tears $HOME down. $DEVENV_RUNDIR was already created (at
# source time) and is unaffected.
mkdir -p "$T_SANDBOX/tmp"
export TMPDIR="$T_SANDBOX/tmp"

t_section 'devenv_tmpdir / devenv_tmpfile still live under the run dir'

d=$(devenv_tmpdir)
assert_ok 'devenv_tmpdir makes a directory' test -d "$d"
case $d in
  "$DEVENV_RUNDIR"/*) t_ok 'devenv_tmpdir is under the run dir' ;;
  *) t_not_ok "devenv_tmpdir escaped \$DEVENV_RUNDIR: $d" ;;
esac
f=$(devenv_tmpfile)
assert_file "$f" 'devenv_tmpfile makes a file'

t_section '_devenv_exec_probe'

probe_dir=$(devenv_tmpdir)
assert_ok 'a writable directory passes the probe' _devenv_exec_probe "$probe_dir"
assert_fail 'a directory that does not exist fails the probe' \
  _devenv_exec_probe "$probe_dir/nope"
assert_fail 'an empty argument fails the probe' _devenv_exec_probe ''

# The probe must leave nothing behind, whether it passed or not.
assert_eq '' "$(find "$probe_dir" -mindepth 1 -print 2>/dev/null)" \
  'the probe removes its own throwaway script'

# A directory that cannot be written to is the shape every rejected candidate
# has: on a noexec mount the write succeeds and the exec fails, here the write
# fails — either way the answer is "not this one, try the next".
#
# ROOT CANNOT EXPRESS "unwritable". DAC_OVERRIDE means mode 0500 is still
# writable for uid 0, so the probe correctly SUCCEEDS and the assertion below is
# simply not a valid statement about a root run. It is skipped rather than
# inverted: a pass that only means "we are root" is not worth counting.
# (Found by the GitLab runner, which runs jobs as root; the GitHub matrix creates
# an unprivileged user and never hit it.)
if [ "$(id -u)" -eq 0 ]; then
  t_skip 'an unwritable directory fails the probe (root ignores write bits)'
else
  ro_dir=$(devenv_tmpdir)
  chmod 0500 "$ro_dir"
  assert_fail 'an unwritable directory fails the probe' _devenv_exec_probe "$ro_dir"
fi

t_section 'devenv_execdir'

x=$(devenv_execdir)
assert_ok 'devenv_execdir makes a directory' test -d "$x"
x2=$(devenv_execdir)
assert_ne "$x" "$x2" 'two calls return two different directories'

# The point of the whole exercise: a file put there RUNS.
printf '#!/bin/sh\nprintf ran\n' >"$x/hello"
chmod 0755 "$x/hello"
assert_eq 'ran' "$("$x/hello" 2>/dev/null || printf 'DID-NOT-RUN')" \
  'a script in the exec dir is actually executed'

# It is a SEPARATE area, not a corner of $DEVENV_RUNDIR: lib/common.sh keeps the
# run dir out of $HOME on purpose and that must not change.
case $x in
  "$DEVENV_RUNDIR"/*) t_not_ok "the exec dir is inside \$DEVENV_RUNDIR: $x" ;;
  *) t_ok 'the exec dir is a separate scratch area' ;;
esac

t_section 'one exec root per run, across subshells'

# Every real caller writes `work=$(devenv_execdir)`, which runs the chooser in a
# command substitution. A memo held only in an exported variable would be lost
# with that subshell, so each call would probe again and strand another root with
# nothing able to remove it. The run directory is what carries the answer.
assert_file "$DEVENV_RUNDIR/execroot" 'the chosen root is recorded in the run dir'
recorded=$(cat "$DEVENV_RUNDIR/execroot")
assert_eq "$recorded" "${x%/*}" 'the recorded root is the one the dirs came from'
assert_eq "${x%/*}" "${x2%/*}" 'a second call reuses the same root'
assert_eq 1 "$(find "${TMPDIR:?}" -maxdepth 1 -name 'devenv-exec.*' | wc -l)" \
  'exactly one exec root exists for this run'

t_section 'the candidate walk skips what it cannot use'

# Point TMPDIR — the FIRST candidate — at a directory nothing can be written to.
# devenv_execdir must fall through to the next candidate rather than fail, and
# must not have used the unusable one.
saved_tmpdir=$TMPDIR
bad_tmp="$T_SANDBOX/unwritable-tmp"
mkdir -p "$bad_tmp"
# As above: mode 0500 does not stop uid 0, so under root this candidate is
# perfectly usable and "skips what it cannot use" has nothing to skip. Point the
# first candidate at a path that is unusable for EVERYONE instead — a plain file
# where a directory is required — so the walk is still exercised as root.
if [ "$(id -u)" -eq 0 ]; then
  bad_tmp="$T_SANDBOX/unwritable-tmp-file"
  rm -rf "$T_SANDBOX/unwritable-tmp"
  : >"$bad_tmp"
else
  chmod 0500 "$bad_tmp"
fi
rm -f "$DEVENV_RUNDIR/execroot"
unset DEVENV_EXECROOT
export TMPDIR="$bad_tmp"
y=$(devenv_execdir) || y=''
assert_ne '' "$y" 'an unusable first candidate is skipped, not fatal'
case ${y:-none} in
  "$bad_tmp"/*) t_not_ok "the unwritable candidate was used anyway: $y" ;;
  *) t_ok 'the unwritable candidate was not used' ;;
esac
if [ -n "$y" ]; then
  printf '#!/bin/sh\nprintf fallback\n' >"$y/hello"
  chmod 0755 "$y/hello"
  assert_eq 'fallback' "$("$y/hello" 2>/dev/null || printf 'DID-NOT-RUN')" \
    'the fallback directory executes too'
  rm -rf -- "${y%/*}"
fi
export TMPDIR="$saved_tmpdir"
rm -f "$DEVENV_RUNDIR/execroot"
unset DEVENV_EXECROOT

t_section 'the exec scratch is cleaned up by the run that made it'

# A real child with the traps installed, owning its own run directory, so this
# measures the EXIT trap and not a re-implementation of it.
# shellcheck disable=SC2016  # the child's script expands these, not this shell
child=$(env -u DEVENV_RUNDIR -u DEVENV_RUNDIR_OWNER -u DEVENV_EXECROOT \
  DEVENV_NO_TRAPS=0 TMPDIR="$TMPDIR" \
  bash -c '
    set -euo pipefail
    . "$DEVENV_HOME/lib/common.sh"
    devenv_execdir
  ' 2>/dev/null) || child=''
assert_ne '' "$child" 'the child made an exec dir'
assert_no_file "$child" 'the child removed its exec dir on exit'
if [ -n "$child" ]; then
  assert_no_file "${child%/*}" 'the child removed its exec ROOT on exit'
fi

# This file's own roots, which have no trap to remove them (DEVENV_NO_TRAPS=1).
rm -rf -- "${x%/*}"

t_summary
