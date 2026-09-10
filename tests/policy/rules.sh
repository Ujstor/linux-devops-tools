#!/usr/bin/env bash
#
# tests/policy/rules.sh — the rules shellcheck cannot express.
#
# A linter proves a script is well-formed bash. These rules prove it is a
# well-formed *module of this repository*: that every mutation goes through the
# one gate (which is what makes --dry-run a true no-op), that nothing is pinned
# outside versions.env, that no module reaches around lib/ to apt, curl or sed,
# and that the meta headers `devenv list` depends on are actually there.
#
# Usage:
#     bash tests/policy/rules.sh                # check the checkout
#     bash tests/policy/rules.sh --rule NAME    # one rule only
#     bash tests/policy/rules.sh --list         # what each rule checks
#     bash tests/policy/rules.sh --self-test    # prove the rules still fire
#
# ESCAPE HATCH. A line ending in `# policy-allow: <rule>` is exempt from that one
# rule. Use it for a genuine, commented exception — never to silence a class.

set -euo pipefail

PROG=${0##*/}

ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../.." && pwd)
ONLY=''
FAILED=0
FIRED=''

# ---------------------------------------------------------------------------
# Plumbing
# ---------------------------------------------------------------------------

fail() {
  local rule=$1 loc=$2 msg=$3
  printf 'POLICY [%s] %s\n    %s\n' "$rule" "$loc" "$msg" >&2
  FAILED=$((FAILED + 1))
  case " $FIRED " in
    *" $rule "*) ;;
    *) FIRED="$FIRED $rule" ;;
  esac
}

# selected RULE — true when this rule should run.
selected() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# files_in GLOB…  — prints the existing files matching the globs, relative paths.
files_in() {
  local g f
  for g in "$@"; do
    for f in $g; do
      [ -f "$ROOT/$f" ] && printf '%s\n' "$f"
    done
  done
  return 0
}

module_files() { (cd "$ROOT" && files_in 'modules/[0-9][0-9]-*.sh'); }
lib_files() { (cd "$ROOT" && files_in 'lib/*.sh'); }
exec_files() {
  (cd "$ROOT" && files_in 'install.sh' 'bin/*' 'modules/[0-9][0-9]-*.sh' \
    'tools/*.sh' 'tests/*.sh' 'tests/*/*.sh' 'tests/*/*/*.sh')
}

# The lists the rules work on, resolved once per run. Arrays, not strings: a
# quoted expansion is what keeps the file names intact.
MODULES=()
LIBS=()
BINS=()
CORE=()

load_file_lists() {
  mapfile -t MODULES < <(module_files)
  mapfile -t LIBS < <(lib_files)
  mapfile -t BINS < <(cd "$ROOT" && files_in 'install.sh' 'bin/*')
  CORE=(${MODULES[0]+"${MODULES[@]}"} ${LIBS[0]+"${LIBS[@]}"} ${BINS[0]+"${BINS[@]}"})

  # EVERY rule below only ever looks at the files in these three lists, and every
  # list comes from a glob. A glob that matches nothing expands to nothing and
  # tells no one: the rules then run to completion over zero files and the script
  # prints "clean". That is not a hypothetical failure mode — it is exactly how
  # old-name passed on this branch for its whole life while CI found nine
  # violations in the same tree. An empty list is a broken run, not a clean one.
  local empty=''
  [ "${#MODULES[@]}" -gt 0 ] || empty="$empty modules/[0-9][0-9]-*.sh"
  [ "${#LIBS[@]}" -gt 0 ] || empty="$empty lib/*.sh"
  [ "${#BINS[@]}" -gt 0 ] || empty="$empty install.sh|bin/*"
  if [ -n "$empty" ]; then
    printf '%s: these globs matched nothing under %s:%s\n' "$PROG" "$ROOT" "$empty" >&2
    printf 'The rules that read them would examine no file and report "clean".\n' >&2
    printf 'Refusing to report success on a checkout the rules cannot see.\n' >&2
    exit 1
  fi

  # Printed on every run, including --rule: "clean" means nothing without it.
  printf '%s: %d module(s), %d lib(s), %d executable(s)\n' \
    "$PROG" "${#MODULES[@]}" "${#LIBS[@]}" "${#BINS[@]}"
  return 0
}

# grep_rule RULE PATTERN FILE… — report every matching line that does not carry
# this rule's escape hatch.
grep_rule() {
  local rule=$1 pat=$2
  shift 2
  local hit file rest line text
  [ $# -gt 0 ] || return 0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file=${hit%%:*}
    rest=${hit#*:}
    line=${rest%%:*}
    text=${rest#*:}
    case $text in
      *"# policy-allow: $rule"*) continue ;;
    esac
    text=${text#"${text%%[![:space:]]*}"}
    # A whole-line comment is documentation — several modules describe the very
    # thing they promise not to do. Only real code is a violation.
    case $text in
      '#'*) continue ;;
    esac
    if [ ${#text} -gt 140 ]; then text="${text:0:137}..."; fi
    fail "$rule" "$file:$line" "$text"
    # An explicit subshell, not `cd && grep || true`: in that form a failed `cd`
    # falls through to `|| true` and the scan silently examines nothing
    # (shellcheck SC2015). Here a failed cd exits the subshell and the caller
    # reads an empty stream deliberately, not by accident.
  done < <(
    cd "$ROOT" || exit 0
    grep -nIHE -- "$pat" "$@" 2>/dev/null || true
  )
  return 0
}

# A command position: the start of a line, or just after ; & | && || then else do.
# `(` is deliberately NOT one: prose inside a quoted message ("... (sudo ninja
# install put them there)") is not a command, and a subshell is caught by the
# line-start branch anyway.
CMD_POS='(^|[[:space:]]*[;&|]|&&|\|\||^[[:space:]]*(then|else|do)[[:space:]]+)[[:space:]]*'

# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------

RULES='strict-mode lib-shape meta-header common-entrypoint no-bare-sudo no-bare-apt
no-bare-download no-sed-i no-append-dotfile no-rm-rf-unquoted no-os-release-source
no-hardcoded-arch-url release-checksum pin-defined old-name exec-bit'

RULES_DOC='
  strict-mode        every executable starts with #!/usr/bin/env bash and sets
                     -euo pipefail
  lib-shape          lib/*.sh are sourced fragments: no shebang, no set -e, and a
                     shell=bash lint directive
  meta-header        every module has meta name= and desc=, valid os=/root= values,
                     and a name no other module uses
  common-entrypoint  a module sources lib/common.sh and never an individual lib file
  no-bare-sudo       every privileged command goes through run_sudo/as_root, so
                     --dry-run stays a no-op
  no-bare-apt        one apt policy: pkg_* only, never apt-get/apt/nala/dpkg -i
  no-bare-download   every download goes through lib/net.sh, which verifies it
  no-sed-i           in-place edits are what severed a symlinked ~/.bashrc
  no-append-dotfile  no >> into a dotfile: use ensure_block_in_file / bashrc_dropin
  no-rm-rf-unquoted  rm -rf with an unquoted variable
  no-os-release-source
                     never source /etc/os-release (it leaks NAME/ID into the
                     caller) and never call lsb_release (absent on minimal Debian)
  no-hardcoded-arch-url
                     no architecture or distro codename baked into a URL literal
  release-checksum   every gh_release_install carries a checksum option or an
                     explicit --no-verify with a reason. A wrapper that forwards
                     its arguments is accepted — the option then belongs at the call site
  pin-defined        every *_VERSION / *_REF a module reads is defined in
                     versions.env, unless the module assigns it itself — no
                     undefined and no invented pins
  old-name           the previous repository name may appear only in the migration
                     documents, and never inside a URL
  exec-bit           modules and bin/ are executable; lib/ is not
'

rule_strict_mode() {
  local f first
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    first=$(head -n1 "$ROOT/$f")
    [ "$first" = '#!/usr/bin/env bash' ] \
      || fail strict-mode "$f:1" "first line must be '#!/usr/bin/env bash', found: $first"
    grep -qE '^set -euo pipefail$' "$ROOT/$f" \
      || fail strict-mode "$f:1" 'no "set -euo pipefail" anywhere in the file'
  done < <(exec_files)
  return 0
}

rule_lib_shape() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $(head -n1 "$ROOT/$f") in
      '#!'*) fail lib-shape "$f:1" 'a lib file is sourced, so it must have no shebang' ;;
    esac
    head -n 10 "$ROOT/$f" | grep -q 'shellcheck shell=bash' \
      || fail lib-shape "$f:1" 'missing the shell=bash lint directive'
    grep_rule lib-shape '^set -[eu]' "$f"
  done < <(lib_files)
  return 0
}

rule_meta_header() {
  local f name desc os root names=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(sed -n '1,40{s/^# meta:[[:space:]]*name[[:space:]]*=[[:space:]]*//p;}' "$ROOT/$f" | head -n1)
    desc=$(sed -n '1,40{s/^# meta:[[:space:]]*desc[[:space:]]*=[[:space:]]*//p;}' "$ROOT/$f" | head -n1)
    os=$(sed -n '1,40{s/^# meta:[[:space:]]*os[[:space:]]*=[[:space:]]*//p;}' "$ROOT/$f" | head -n1)
    root=$(sed -n '1,40{s/^# meta:[[:space:]]*root[[:space:]]*=[[:space:]]*//p;}' "$ROOT/$f" | head -n1)
    [ -n "$name" ] || fail meta-header "$f:2" 'missing "# meta: name="'
    [ -n "$desc" ] || fail meta-header "$f:3" 'missing "# meta: desc="'
    case $desc in
      *.) fail meta-header "$f:3" 'desc must not end in a period' ;;
    esac
    case ${os:-any} in
      any | debian | ubuntu | wsl | '!wsl' | '!container') ;;
      *) fail meta-header "$f:1" "unknown os= value: $os" ;;
    esac
    case ${root:-no} in
      yes | no) ;;
      *) fail meta-header "$f:1" "root= must be yes or no, found: $root" ;;
    esac
    if [ -n "$name" ]; then
      case " $names " in
        *" $name "*) fail meta-header "$f:2" "duplicate module name: $name" ;;
        *) names="$names $name" ;;
      esac
    fi
  done < <(module_files)
  return 0
}

rule_common_entrypoint() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -q 'lib/common\.sh' "$ROOT/$f" \
      || fail common-entrypoint "$f:1" "a module must source \"\${DEVENV_HOME:?}/lib/common.sh\""
  done < <(module_files)
  # shellcheck disable=SC2016  # a literal pattern, not an expansion
  grep_rule common-entrypoint \
    'source[[:space:]]+"?\$\{?DEVENV_HOME[^"]*/lib/(log|os|run|fs|net|pkg|repo|shell|lang|wsl|registry)\.sh' \
    ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_bare_sudo() {
  grep_rule no-bare-sudo "${CMD_POS}sudo[[:space:]]" ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_bare_apt() {
  grep_rule no-bare-apt "${CMD_POS}(sudo[[:space:]]+)?(apt-get|apt|aptitude|nala)[[:space:]]" \
    ${MODULES[0]+"${MODULES[@]}"}
  grep_rule no-bare-apt "${CMD_POS}(sudo[[:space:]]+)?dpkg[[:space:]]+-i[[:space:]]" \
    ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_bare_download() {
  grep_rule no-bare-download "${CMD_POS}(curl|wget)[[:space:]]" ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_sed_i() {
  grep_rule no-sed-i 'sed[[:space:]]+(-[a-zA-Z]*[[:space:]]+)*-i' ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_append_dotfile() {
  # shellcheck disable=SC2016  # $HOME here is a pattern to look for, not a value
  grep_rule no-append-dotfile '>>[[:space:]]*"?(\$HOME|\$\{HOME|~/|\.\./)' \
    ${MODULES[0]+"${MODULES[@]}"}
  grep_rule no-append-dotfile '>>[[:space:]]*"?[^ ]*(\.bashrc|\.profile|\.bash_profile|\.zshrc)' \
    ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_rm_rf_unquoted() {
  # shellcheck disable=SC2016  # ditto
  grep_rule no-rm-rf-unquoted \
    '(^|[;&|]|&&|\|\|)[[:space:]]*(run|run_sudo|run_quiet|sudo)?[[:space:]]*rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+[^"'\''|;]*\$[A-Za-z_{]' \
    ${MODULES[0]+"${MODULES[@]}"} ${BINS[0]+"${BINS[@]}"}
  return 0
}

rule_no_os_release_source() {
  grep_rule no-os-release-source \
    '(^|[[:space:]])(\.|source)[[:space:]]+"?/etc/os-release' ${CORE[0]+"${CORE[@]}"}
  grep_rule no-os-release-source "${CMD_POS}lsb_release[[:space:]]" ${CORE[0]+"${CORE[@]}"}
  return 0
}

rule_no_hardcoded_arch_url() {
  grep_rule no-hardcoded-arch-url \
    'https?://[^"'\''[:space:]]*(x86_64|amd64|aarch64|arm64|bookworm|trixie|jammy|noble|focal)' \
    ${MODULES[0]+"${MODULES[@]}"} ${LIBS[0]+"${LIBS[@]}"}
  return 0
}

rule_release_checksum() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail release-checksum "${hit%%|*}" "gh_release_install without a checksum option: ${hit#*|}"
    done < <(awk -v file="$f" '
      {
        line = $0
        sub(/[[:space:]]*#.*$/, "", line)
        if (cont) { logical = logical " " line } else { logical = line; start = FNR }
        if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", logical); cont = 1; next }
        cont = 0
        if (logical ~ /(^|[^_a-zA-Z])gh_release_install[[:space:]]/ &&
            logical !~ /--checksum-asset|--checksum-url|--sha256|--no-verify|"\$@"/) {
          gsub(/^[[:space:]]+/, "", logical)
          printf "%s:%d|%s\n", file, start, substr(logical, 1, 120)
        }
        logical = ""
      }' "$ROOT/$f")
  done < <(module_files)
  return 0
}

rule_pin_defined() {
  local f key line
  [ -f "$ROOT/versions.env" ] || {
    fail pin-defined 'versions.env:0' 'versions.env is missing'
    return 0
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f=${line%%:*}
    key=${line#*:}
    grep -qE "^${key}=" "$ROOT/versions.env" && continue
    # A variable the module assigns itself is not a pin: 15-git.sh's GIT_VERSION
    # holds the version of the git that is installed, not a version to install.
    grep -qE "^[[:space:]]*(local[[:space:]]+|export[[:space:]]+|declare[[:space:]]+)?${key}=" \
      "$ROOT/$f" && continue
    # Nor is a fact the library computes and exports for every module: lib/os.sh
    # sets WSL_VERSION to 1 or 2 from /proc/version. That is a property of the
    # box, not something this repository could pin. The assignment there is not
    # at the start of a line (`IS_WSL=0 WSL_VERSION='' …`), so this pattern takes
    # the name in any command or assignment position.
    grep -qE "(^|[[:space:]]|;)${key}=" "$ROOT"/lib/*.sh 2>/dev/null && continue
    fail pin-defined "$f:0" "\$$key is read here but neither set in this module nor defined in versions.env"
  done < <(
    cd "$ROOT" || exit 0
    local m
    for m in ${MODULES[0]+"${MODULES[@]}"}; do
      # `|| true` is load-bearing, not defensive noise: this subshell inherits
      # `set -e` AND `pipefail`, so a module with no pin at all (grep exits 1)
      # would abort the whole loop and the rule would silently examine nothing
      # from there on. modules/00-preflight.sh is exactly such a file and sorts
      # first, so without this the rule checked NOTHING.
      { grep -oE '\$\{?[A-Z][A-Z0-9_]*(_VERSION|_REF|_MINOR|_CHANNEL|_KEY_SHA256)\b' "$m" || true; } \
        | sed 's/^\${\?//' | sort -u | sed "s|^|$m:|"
    done
  )
  return 0
}

rule_old_name() {
  # Files whose SUBJECT is the old repository. Naming it there is the point, so
  # they are exempt outright — including in a URL, which is the whole content of
  # a migration instruction. Anything not on this list may mention the old name
  # only in a comment, and never in a URL.
  #   README.md             carries the migration note
  #   docs/migration.md     is the migration guide: it must show the OLD command
  #   docs/modules.md       documents the migrate module, in table cells that
  #                         cannot be shell comments
  #   modules/92-migrate.sh IS the migrate module — it looks for the old checkout
  #   tests/policy/rules.sh this rule's own pattern, and its self-test fixture
  local old='wsl2-config'
  local allow='^(README\.md|docs/migration\.md|docs/modules\.md|modules/92-migrate\.sh|tests/policy/rules\.sh)$'
  local hit file rest line text
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file=${hit%%:*}
    rest=${hit#*:}
    line=${rest%%:*}
    text=${rest#*:}
    case $text in
      *"# policy-allow: old-name"*) continue ;;
    esac
    # The allow-list is checked FIRST. It used to sit after the URL branch, which
    # made the exemption useless for exactly the files that need it: docs/
    # migration.md exists to print the old install URL, and got flagged for it.
    printf '%s' "$file" | grep -qE "$allow" && continue
    # In a URL or a clone target it is always wrong — that is a pipeline pointing
    # at the repository this one replaced.
    if printf '%s' "$text" | grep -qE "(github(usercontent)?\.com[:/][^\"' ]*|/)${old}(\.git|/|\"|'|$)"; then
      fail old-name "$file:$line" "the old repository name in a URL: ${text#"${text%%[![:space:]]*}"}"
      continue
    fi
    # Elsewhere it may only appear in a comment explaining the migration.
    case ${text#"${text%%[![:space:]]*}"} in
      '#'* | '*'* | '//'*) continue ;;
    esac
    fail old-name "$file:$line" \
      "the old repository name outside README.md / docs/migration.md and outside a comment"
  done < <(
    cd "$ROOT" || exit 0
    # `git rev-parse`, NOT `[ -d .git ]`: in a `git worktree` checkout .git is a
    # FILE, so -d is false and the rule quietly switches to the fallback below —
    # the branch nobody runs, which emits `./README.md` where git emits
    # `README.md`, so the anchored allow-list matches nothing and every exempt
    # file is reported. Measured in a worktree: 13 findings on a clean tree,
    # one of them against .git itself. A gate that cries wolf gets switched off,
    # which is the same outcome as a gate that cannot fire.
    if command -v git >/dev/null 2>&1 \
      && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      # --untracked is load-bearing. Plain `git grep` searches TRACKED files
      # only, so a working tree full of new-but-uncommitted files scans to
      # nothing and the rule reports "clean". That is not hypothetical: this
      # whole repository was written as untracked files, every local run passed,
      # and the rule only fired once CI checked out the commit. --untracked adds
      # the working tree while still honouring .gitignore.
      git grep --untracked -nIH -- "$old" -- . 2>/dev/null || true
    else
      # No git at all (a release tarball). Emit git's path shape — no leading
      # `./` — so the allow-list above judges the same strings either way, and
      # exclude .git whether it is a directory or a worktree's pointer file.
      grep -rnIH --exclude-dir=.git --exclude=.git -- "$old" . 2>/dev/null \
        | sed 's|^\./||' || true
    fi
  )
  return 0
}

rule_exec_bit() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -x "$ROOT/$f" ] || fail exec-bit "$f:0" 'must be executable (chmod 0755)'
  done < <(cd "$ROOT" && files_in 'install.sh' 'bin/*' 'modules/[0-9][0-9]-*.sh')
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -x "$ROOT/$f" ] && fail exec-bit "$f:0" 'a sourced lib file must not be executable (chmod 0644)'
  done < <(lib_files)
  return 0
}

run_rules() {
  load_file_lists
  if selected strict-mode; then rule_strict_mode; fi
  if selected lib-shape; then rule_lib_shape; fi
  if selected meta-header; then rule_meta_header; fi
  if selected common-entrypoint; then rule_common_entrypoint; fi
  if selected no-bare-sudo; then rule_no_bare_sudo; fi
  if selected no-bare-apt; then rule_no_bare_apt; fi
  if selected no-bare-download; then rule_no_bare_download; fi
  if selected no-sed-i; then rule_no_sed_i; fi
  if selected no-append-dotfile; then rule_no_append_dotfile; fi
  if selected no-rm-rf-unquoted; then rule_no_rm_rf_unquoted; fi
  if selected no-os-release-source; then rule_no_os_release_source; fi
  if selected no-hardcoded-arch-url; then rule_no_hardcoded_arch_url; fi
  if selected release-checksum; then rule_release_checksum; fi
  if selected pin-defined; then rule_pin_defined; fi
  if selected old-name; then rule_old_name; fi
  if selected exec-bit; then rule_exec_bit; fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — plant one synthetic violation per rule in a throwaway tree and
# assert every rule fires. A rule that stops firing is worse than no rule.
# ---------------------------------------------------------------------------

self_test() {
  local dir rc=0 rule
  dir=$(mktemp -d "${TMPDIR:-/tmp}/policy-selftest.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: a fresh mktemp path
  trap "rm -rf -- '$dir'" EXIT
  mkdir -p "$dir/modules" "$dir/lib" "$dir/bin"

  printf 'GOOD_VERSION=v1.0.0\n' >"$dir/versions.env"

  # A compliant lib fragment and a compliant executable, created once and kept
  # for BOTH phases. Without them lib/*.sh and bin/* are empty in one phase or
  # the other, which is the very condition load_file_lists now refuses — and,
  # before it refused, the condition under which lib-shape and exec-bit silently
  # checked nothing.
  cat >"$dir/lib/good.sh" <<'EOF'
# shellcheck shell=bash
# a sourced fragment that breaks no rule

good_helper() { printf 'ok\n'; }
EOF
  chmod 0644 "$dir/lib/good.sh"

  cat >"$dir/bin/tool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tool\n'
EOF
  chmod 0755 "$dir/bin/tool"

  # A compliant module that mentions no pin AT ALL, sorting before the bad one.
  # Its only job is to keep `pin-defined` honest: the rule scans the modules in
  # order, and a file with no match must not stop the scan (it did once — see
  # the `|| true` in rule_pin_defined).
  cat >"$dir/modules/49-nopins.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=nopins
# meta: desc=a compliant module that pins nothing
# meta: os=any
# meta: root=no
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

module_main() { pkg_install ripgrep; }
module_main "$@"
EOF
  chmod 0755 "$dir/modules/49-nopins.sh"

  cat >"$dir/modules/50-bad.sh" <<'EOF'
#!/bin/sh
# meta: name=bad
# meta: os=solaris
# meta: root=maybe
sudo apt-get install -y thing
curl -fsSL https://example.com/x | sh
sed -i 's/a/b/' "$HOME/.bashrc"
echo x >> "$HOME/.bashrc"
rm -rf $dir
. /etc/os-release
lsb_release -cs
url=https://example.com/dl/tool-linux-amd64.tar.gz
gh_release_install owner/repo 'tool-{version}.tar.gz' tool "$MISSING_VERSION"
source "${DEVENV_HOME}/lib/net.sh"
old=https://raw.githubusercontent.com/Owner/wsl2-config/main/install.sh
EOF
  chmod 0644 "$dir/modules/50-bad.sh"

  cat >"$dir/modules/51-dup.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=bad
# meta: desc=a duplicate name and a trailing period.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"
EOF
  chmod 0755 "$dir/modules/51-dup.sh"

  cat >"$dir/lib/bogus.sh" <<'EOF'
#!/usr/bin/env bash
set -e
bogus() { :; }
EOF
  chmod 0755 "$dir/lib/bogus.sh"

  ROOT=$dir
  ONLY=''
  FAILED=0
  FIRED=''
  printf '%s: self-test — the findings below are SYNTHETIC and expected\n' "$PROG" >&2
  run_rules 2>/dev/null

  for rule in $RULES; do
    case " $FIRED " in
      *" $rule "*) printf '  ok    %s fires\n' "$rule" ;;
      *)
        printf '  FAIL  %s did not fire on a synthetic violation\n' "$rule"
        rc=1
        ;;
    esac
  done

  # A well-formed module must produce nothing at all.
  rm -f "$dir/modules/49-nopins.sh" "$dir/modules/50-bad.sh" "$dir/modules/51-dup.sh" \
    "$dir/lib/bogus.sh"
  cat >"$dir/modules/52-good.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=good
# meta: desc=a module that breaks no rule
# meta: os=any
# meta: root=no
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

module_main() {
  pkg_install ripgrep
  gh_release_install owner/repo 'tool_{version}_linux_{arch}.tar.gz' tool "$GOOD_VERSION" \
    --checksum-asset 'checksums.txt'
  run_sudo install -m 0755 /dev/null /usr/local/bin/tool
}
module_main "$@"
EOF
  chmod 0755 "$dir/modules/52-good.sh"
  FAILED=0
  FIRED=''
  run_rules
  if [ "$FAILED" -eq 0 ]; then
    printf '  ok    a compliant module is accepted\n'
  else
    printf '  FAIL  %d false positive(s) on a compliant module\n' "$FAILED"
    rc=1
  fi

  [ "$rc" -eq 0 ] && printf '%s: self-test passed\n' "$PROG"
  return "$rc"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case $1 in
      --list)
        printf 'policy rules:\n%s\n' "$RULES_DOC"
        return 0
        ;;
      --self-test)
        self_test
        return
        ;;
      --rule)
        [ $# -ge 2 ] || {
          printf '%s: --rule needs a name\n' "$PROG" >&2
          return 64
        }
        ONLY=$2
        shift
        ;;
      --rule=*) ONLY=${1#*=} ;;
      *)
        printf 'usage: %s [--rule NAME|--list|--self-test]\n' "$PROG" >&2
        return 64
        ;;
    esac
    shift
  done

  if [ -n "$ONLY" ]; then
    case " $RULES " in
      *" $ONLY "*) ;;
      *)
        printf '%s: unknown rule: %s (try --list)\n' "$PROG" "$ONLY" >&2
        return 64
        ;;
    esac
  fi

  run_rules
  if [ "$FAILED" -gt 0 ]; then
    printf '\n%s: %d violation(s) in rules:%s\n' "$PROG" "$FAILED" "$FIRED" >&2
    printf 'Run "%s --list" for what each one means.\n' "$PROG" >&2
    return 1
  fi
  printf '%s: clean%s\n' "$PROG" "${ONLY:+ ($ONLY)}"
  return 0
}

main "$@"
