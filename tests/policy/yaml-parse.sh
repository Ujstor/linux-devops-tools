#!/usr/bin/env bash
#
# tests/policy/yaml-parse.sh — every shipped YAML file must parse.
#
# A k9s plugin file that does not parse is not one broken plugin: k9s's decoder
# rejects the WHOLE file, so one stray tab silently removes every plugin in it.
# The same goes for config.yaml, hotkeys.yaml, the skins and this repository's
# own workflow.
#
# This check used to exist only inline in .github/workflows/ci.yml, which made it
# the one gate nobody could run before pushing. It is a make target now:
#
#     bash tests/policy/yaml-parse.sh              # parse the checkout
#     bash tests/policy/yaml-parse.sh --self-test  # prove it still fires
#     make lint-yaml
#
# THE FILE LIST INCLUDES UNTRACKED FILES, deliberately. `git ls-files` on its own
# sees only what is committed, so a working tree of new files scans to nothing
# and the gate prints "clean" having read zero bytes. That is not hypothetical —
# it is exactly how the old-name policy rule passed locally while CI found nine
# violations. `--others --exclude-standard` adds the working tree and still
# honours .gitignore.
#
# A run that parsed NOTHING is a failure, not a pass, for the same reason.

set -euo pipefail

PROG=${0##*/}
ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)

die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

# collect ROOT — every *.yaml / *.yml worth parsing, as paths relative to ROOT.
collect() {
  local root=$1 f
  {
    # `git rev-parse`, NOT `[ -d .git ]`: in a `git worktree` checkout .git is a
    # FILE, the -d test is false, and this drops into the find fallback — a
    # different enumerator over a different set of files, in the branch nobody
    # runs. Ask git whether this is a work tree instead.
    if command -v git >/dev/null 2>&1 \
      && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$root" ls-files --cached --others --exclude-standard
    else
      (cd "$root" && find . -type f -printf '%P\n')
    fi
  } | {
    while IFS= read -r f; do
      case $f in
        .git/* | */.git/* | node_modules/* | */node_modules/*) continue ;;
        *.yaml | *.yml) ;;
        *) continue ;;
      esac
      [ -f "$root/$f" ] || continue
      if [ -L "$root/$f" ]; then continue; fi
      printf '%s\n' "$f"
    done
  } | LC_ALL=C sort
}

parse_all() {
  local root=$1
  shift
  (
    cd "$root" || exit 1
    python3 - "$@" <<'PY'
import pathlib
import sys

import yaml

names = sys.argv[1:]
bad = 0
for name in names:
    try:
        list(yaml.safe_load_all(pathlib.Path(name).read_text(encoding='utf-8')))
    except Exception as exc:                            # noqa: BLE001
        print(f'INVALID {name}: {exc}', file=sys.stderr)
        bad += 1
print(f'{len(names)} YAML file(s) parsed, {bad} invalid')
sys.exit(1 if bad else 0)
PY
  )
}

require_parser() {
  command -v python3 >/dev/null 2>&1 \
    || die 'python3 is needed to parse YAML. Install it, or run this gate in CI.'
  python3 -c 'import yaml' >/dev/null 2>&1 || die \
    'python3 is here but PyYAML is not. Install it with one of:
    python3 -m pip install --user PyYAML
    sudo apt-get install -y python3-yaml
A missing parser is a failure, never a skip: a gate that cannot run has not passed.'
}

# ---------------------------------------------------------------------------
# Self-test — plant a file that does not parse and prove it is reported, then
# prove the empty-scan tripwire fires. A gate that only ever sees valid input has
# never demonstrated that it can fail.
# ---------------------------------------------------------------------------

self_test() {
  local dir rc=0 prc out
  dir=$(mktemp -d "${TMPDIR:-/tmp}/yaml-selftest.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: a fresh mktemp path
  trap "rm -rf -- '$dir'" EXIT
  mkdir -p "$dir/config/k9s/plugins" "$dir/empty"

  printf 'plugins:\n  demo:\n    shortCut: Shift-D\n' >"$dir/config/k9s/plugins/ok.yaml"
  # A tab where YAML forbids one — the exact shape that takes a k9s plugin file
  # (and every plugin in it) out of service.
  printf 'plugins:\n  demo:\n\tshortCut: Shift-D\n' >"$dir/config/k9s/plugins/broken.yaml"
  printf 'a: [1, 2\n' >"$dir/unterminated.yml"

  printf '%s: self-test — the findings below are SYNTHETIC and expected\n' "$PROG" >&2
  local -a files=()
  mapfile -t files < <(collect "$dir")
  if [ "${#files[@]}" -eq 3 ]; then
    printf '  ok    all three YAML files were collected\n'
  else
    printf '  FAIL  collected %d file(s), expected 3\n' "${#files[@]}"
    rc=1
  fi

  prc=0
  out=$(parse_all "$dir" ${files[0]+"${files[@]}"} 2>&1) || prc=$?
  if [ "$prc" -eq 0 ]; then
    printf '  FAIL  a file that does not parse was accepted\n'
    rc=1
  fi
  case $out in
    *'INVALID config/k9s/plugins/broken.yaml'*) printf '  ok    a tab-indented plugin file is reported\n' ;;
    *)
      printf '  FAIL  the tab-indented plugin file was not reported\n'
      rc=1
      ;;
  esac
  case $out in
    *'INVALID unterminated.yml'*) printf '  ok    an unterminated flow sequence is reported\n' ;;
    *)
      printf '  FAIL  the unterminated flow sequence was not reported\n'
      rc=1
      ;;
  esac
  case $out in
    *'INVALID config/k9s/plugins/ok.yaml'*)
      printf '  FAIL  false positive on a valid plugin file\n'
      rc=1
      ;;
    *) printf '  ok    a valid plugin file is accepted\n' ;;
  esac

  # The tripwire this gate exists to keep: no files scanned is a failure.
  if (scan_dir "$dir/empty") >/dev/null 2>&1; then
    printf '  FAIL  a directory with no YAML in it reported success\n'
    rc=1
  else
    printf '  ok    scanning nothing fails instead of passing\n'
  fi

  [ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
  return "$rc"
}

# scan_dir ROOT — the real check, factored out so the self-test can aim it at a
# throwaway tree.
scan_dir() {
  local root=$1
  local -a files=()
  mapfile -t files < <(collect "$root")
  if [ "${#files[@]}" -eq 0 ]; then
    printf '%s: no YAML file was found under %s at all.\n' "$PROG" "$root" >&2
    printf 'That is a broken walk, not a clean tree: this repository ships k9s config,\n' >&2
    printf 'k9s plugins, skins and its own workflow. Refusing to report success.\n' >&2
    return 1
  fi
  parse_all "$root" "${files[@]}"
}

main() {
  case ${1:-} in
    --self-test)
      require_parser
      self_test
      return
      ;;
    '') ;;
    *)
      printf 'usage: %s [--self-test]\n' "$PROG" >&2
      return 64
      ;;
  esac

  require_parser
  scan_dir "$ROOT" || return 1
  printf '%s: clean\n' "$PROG"
  return 0
}

main "$@"
