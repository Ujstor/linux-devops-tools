#!/usr/bin/env bash
#
# tests/unit/test_lang.sh — lib/lang.sh, the helm chart repository helpers.
#
# helm_repos_ensure is what module 36 runs over its 34-entry HELM_REPOS roster,
# so the properties worth pinning down are:
#
#   * a fresh box gets every repository, a second run adds nothing,
#   * a NAME the user already configured is never rewritten, even when it
#     points elsewhere — and a trailing slash is not "elsewhere",
#   * one repository that cannot be added costs that one and nothing else,
#   * --dry-run adds nothing, and `helm repo update` only runs when there is
#     something to update,
#   * the shipped roster is well-formed: NAME=URL, https, no duplicate NAME.
#
# No network: `helm` is a stub on PATH that keeps its repository list in the
# sandbox and fails `repo add` for any URL containing "unreachable".

set -euo pipefail
# shellcheck source=tests/unit/assert.bash
. "$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)/assert.bash"

stub="$T_SANDBOX/stub"
REPOS="$stub/repos"
CALLS="$stub/calls"
export REPOS CALLS
mkdir -p "$stub/bin"
: >"$REPOS"
: >"$CALLS"
cat >"$stub/bin/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$1 $2" in
  'repo list')
    if [ ! -s "$REPOS" ]; then
      echo 'Error: no repositories to show' >&2
      exit 1
    fi
    printf 'NAME\tURL\n'
    awk '{ printf "%s\t%s\n", $1, $2 }' "$REPOS"
    ;;
  'repo add')
    case $4 in *unreachable*)
      echo "Error: looks like \"$4\" is not a valid chart repository or cannot be reached" >&2
      exit 1
      ;;
    esac
    printf '%s %s\n' "$3" "$4" >>"$REPOS"
    echo "\"$3\" has been added to your repositories"
    ;;
  'repo update') echo 'Update Complete.' ;;
esac
EOF
chmod 0755 "$stub/bin/helm"
PATH="$stub/bin:$PATH"

# adds — the `repo add` lines the stub saw, nothing else.
adds() { grep -c '^repo add ' "$CALLS" || true; }

t_section 'a fresh box gets every repository'

helm_repos_ensure 'a=https://a.example/charts' 'b=https://b.example/charts/' 2>/dev/null
assert_eq 2 "$(adds)" 'both repositories are added'
assert_eq 'a https://a.example/charts
b https://b.example/charts/' "$(cat "$REPOS")" 'under exactly the given names and URLs'

t_section 'a second run adds nothing'

: >"$CALLS"
helm_repos_ensure 'a=https://a.example/charts' 'b=https://b.example/charts/' 2>/dev/null
assert_eq 0 "$(adds)" 'nothing is added again'

t_section 'a name already configured is never rewritten'

: >"$CALLS"
err=$(helm_repos_ensure 'a=https://elsewhere.example/charts' 2>&1 >/dev/null)
assert_eq 0 "$(adds)" 'a NAME pointing elsewhere is not re-added'
assert_contains "$err" "helm repo 'a' is https://a.example/charts here" 'and the difference is reported'
assert_contains "$(cat "$REPOS")" 'a https://a.example/charts' 'the user URL stays'

err=$(helm_repos_ensure 'a=https://a.example/charts/' 'b=https://b.example/charts' 2>&1 >/dev/null)
assert_eq '' "$err" 'a trailing slash alone is not a different URL'

t_section 'one repository that fails costs only that one'

: >"$CALLS"
rc=0
err=$(helm_repos_ensure 'dead=https://unreachable.example' 'c=https://c.example' 2>&1 >/dev/null) || rc=$?
assert_eq 0 "$rc" 'the helper still returns 0'
assert_contains "$(cat "$REPOS")" 'c https://c.example' 'the next repository is still added'
assert_contains "$err" 'could not be added: dead' 'the failure is named'

# A run that only retried a failure added nothing — which must not read as "all
# configured". DEVENV_QUIET hides that skip line, so it is lifted for this call.
err=$(DEVENV_QUIET=0 helm_repos_ensure 'dead=https://unreachable.example' 2>&1 >/dev/null)
assert_eq 0 "$(printf '%s\n' "$err" | grep -c 'already configured' || true)" \
  'a failed retry is not reported as every repository being configured'

: >"$CALLS"
rc=0
helm_repos_ensure 'no-equals-sign' '=https://x.example' 'd=' 2>/dev/null || rc=$?
assert_eq 0 "$rc" 'a malformed entry is skipped, not fatal'
assert_eq 0 "$(adds)" 'and nothing is added for it'

t_section '--dry-run changes nothing'

: >"$CALLS"
DEVENV_DRY_RUN=1 helm_repos_ensure 'e=https://e.example' 2>/dev/null
assert_eq 0 "$(adds)" 'no repo add under --dry-run'

t_section 'helm repo update'

: >"$CALLS"
helm_repo_update >/dev/null 2>&1
assert_eq 1 "$(grep -c '^repo update$' "$CALLS")" 'runs once when repositories exist'

: >"$REPOS"
: >"$CALLS"
helm_repo_update >/dev/null 2>&1
assert_eq 0 "$(grep -c '^repo update$' "$CALLS" || true)" 'and not at all on a box with none'

t_section 'the shipped roster'

roster=$(sed -n '/^HELM_REPOS=(/,/^)/p' "$DEVENV_HOME/modules/36-k8s-plugins.sh" \
  | grep -o '^  "[^"]*"' | tr -d ' "')
assert_eq 34 "$(printf '%s\n' "$roster" | grep -c .)" 'HELM_REPOS has 34 entries'
assert_eq 34 "$(printf '%s\n' "$roster" | grep -cE '^[a-z0-9-]+=https://[^ ]+$')" \
  'every entry is NAME=https://…'
assert_eq '' "$(printf '%s\n' "$roster" | cut -d= -f1 | sort | uniq -d)" 'no NAME appears twice'

t_summary
