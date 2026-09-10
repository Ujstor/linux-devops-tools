#!/usr/bin/env bash
# meta: name=summary
# meta: desc=what ran, what changed and the exact next steps
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=no
#
# The last module in every profile, and the only one whose entire job is output.
#
# It works because `lib/run.sh`'s `changed` and `lib/registry.sh`'s
# `summary_record` both append to files under $DEVENV_RUNDIR, and $DEVENV_RUNDIR
# is exported into every child module. This module is a child like any other, so
# it sees every row its siblings wrote.
#
# Two consequences, both deliberate:
#
#   * its OWN row is not in the table it prints — bin/devenv records that after
#     this process exits. There is nothing to say about a module that only
#     prints, so nothing is lost.
#   * it ALWAYS exits 0, even when a sibling failed. The run's exit status is
#     bin/devenv's job (it returns the last failing module's status); a summary
#     that failed because it had bad news to report would add a second, wrong
#     failure to the very table it just printed.
#
# When `summary` is not in the plan, bin/devenv calls summary_print itself, so
# the output is identical either way and never appears twice.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

module_main() {
  # Returns 1 when a sibling module failed; that is bin/devenv's business, not
  # this module's exit status. See the header.
  summary_print || true
  return 0
}

module_main "$@"
