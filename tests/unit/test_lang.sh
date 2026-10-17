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

t_section 'uv_tool_install: a pip --user entry point is retired, then the install retried'

# The stub behaves like uv 0.12 where it matters: an entry point whose name a
# file it does not own already holds is refused, naming every such file, and the
# whole tool is rolled back. Entry points are links into the tool directory, and
# `ansible` without --with-executables-from ansible-core gets ansible-community
# only — the real metapackage's behaviour.
unset UV_TOOL_DIR UV_TOOL_BIN_DIR XDG_BIN_HOME XDG_DATA_HOME
UVBIN="$HOME/.local/bin"
UVTOOLS="$HOME/.local/share/uv/tools"
UVLIST="$stub/uv-list"
export UVBIN UVTOOLS UVLIST
mkdir -p "$UVBIN" "$UVTOOLS"
: >"$UVLIST"
cat >"$stub/bin/uv" <<'UV'
#!/usr/bin/env bash
case "$1 $2" in
  'tool list')
    if [ -s "$UVLIST" ]; then cat "$UVLIST"; fi
    exit 0
    ;;
  'tool install') ;;
  *) exit 0 ;;
esac
tool=$3
shift 3
own=$tool extra=''
if [ "$tool" = ansible ]; then own=ansible-community; fi
while [ $# -gt 0 ]; do
  if [ "$1" = --with-executables-from ] && [ "$2" = ansible-core ]; then
    extra='ansible ansible-playbook'
  fi
  shift
done
bins="$own $extra"
# Like uv: the --with-executables-from package's conflicts are reported first,
# the tool's own only on the next attempt.
for group in "$extra" "$own"; do
  clash=()
  for b in $group; do
    f=$UVBIN/$b
    if [ -e "$f" ] && [ "$(readlink -f "$f")" != "$UVTOOLS/$tool/bin/$b" ]; then clash+=("$b"); fi
  done
  if [ ${#clash[@]} -eq 1 ]; then
    echo "error: Executable already exists: ${clash[0]} (use \`--force\` to overwrite)" >&2
    exit 2
  elif [ ${#clash[@]} -gt 1 ]; then
    list=$(printf '%s, ' "${clash[@]}")
    echo "error: Executables already exist: ${list%, } (use \`--force\` to overwrite)" >&2
    exit 2
  fi
done
mkdir -p "$UVTOOLS/$tool/bin"
awk -v t="$tool" '/^[^ -]/ { skip = ($1 == t) } !skip' "$UVLIST" >"$UVLIST.new"
{
  cat "$UVLIST.new"
  echo "$tool v1.0.0"
  for b in $bins; do echo "- $b"; done
} >"$UVLIST"
for b in $bins; do
  printf '#!/bin/sh\necho uv-%s\n' "$b" >"$UVTOOLS/$tool/bin/$b"
  chmod 0755 "$UVTOOLS/$tool/bin/$b"
  ln -sfn "$UVTOOLS/$tool/bin/$b" "$UVBIN/$b"
done
echo "Installed executables: $bins"
UV
chmod 0755 "$stub/bin/uv"
pip_script() { printf '#!/usr/bin/python3\nimport sys\nsys.exit(0)\n' >"$UVBIN/$1" && chmod 0755 "$UVBIN/$1"; }
retired="$DEVENV_STATE/retired-bin/.local_bin"

pip_script checkov
pip_script checkov.cmd
uv_tool_install checkov >/dev/null 2>&1
assert_eq 'uv-checkov' "$("$UVBIN/checkov")" 'checkov is now the uv entry point'
assert_file "$retired/checkov" 'the pip script is kept under retired-bin, not deleted'
assert_no_file "$retired/checkov.cmd" 'a name uv does not install is left alone'

uv_tool_install ansible >/dev/null 2>&1
assert_eq 'uv-ansible-community' "$("$UVBIN/ansible-community")" 'the metapackage alone gives ansible-community'
assert_no_file "$UVBIN/ansible-playbook" 'and no ansible-playbook'

pip_script ansible-playbook
uv_tool_install ansible --expect-bin ansible-playbook --with-executables-from ansible-core >/dev/null 2>&1
assert_eq 'uv-ansible-playbook' "$("$UVBIN/ansible-playbook")" \
  'a tool without its expected entry point is installed again, the pip copy retired'
assert_file "$retired/ansible-playbook" 'that pip copy is kept under retired-bin'

# The live box: pip owned BOTH groups, so uv refused ansible-core's entry points,
# then — once those were gone — ansible-community.
: >"$UVLIST"
rm -f "$UVBIN"/ansible*
pip_script ansible-community
pip_script ansible
rc=0
uv_tool_install ansible --expect-bin ansible-playbook --with-executables-from ansible-core >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'conflicts uv reports one package at a time are all cleared'
assert_eq 'uv-ansible-community' "$("$UVBIN/ansible-community")" 'ansible-community is the uv entry point'
assert_eq 'uv-ansible' "$("$UVBIN/ansible")" 'and so is ansible'

DEVENV_CHANGED_LAST=0
uv_tool_install ansible --expect-bin ansible-playbook --with-executables-from ansible-core >/dev/null 2>&1
assert_eq '0' "$DEVENV_CHANGED_LAST" 'a second run changes nothing'

pip_script yamllint
rc=0
DEVENV_KEEP_SHADOWS=1 uv_tool_install yamllint >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'DEVENV_KEEP_SHADOWS=1 keeps the pip script, and the install fails as uv said'
assert_no_file "$retired/yamllint" 'nothing was moved'

t_summary
