#!/usr/bin/env bash
#
# tests/policy/rules.sh — the rules shellcheck cannot express.
#
# A linter proves a script is well-formed bash. These rules prove it is a
# well-formed *module of this repository*: that every mutation goes through the
# one gate (which is what makes --dry-run a true no-op), that nothing is pinned
# outside versions.env, that nothing reaches around lib/ to a package manager,
# curl or sed, and that the meta headers `devenv list` depends on are actually
# there.
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
# lib/family/*.sh are sourced too, but they are DATA: one FAM_* assignment per
# line, the same key set in every family (spec 002 plan D3). They are not on
# lib_files' glob, so every rule that should see them names them explicitly.
family_files() { (cd "$ROOT" && files_in 'lib/family/*.sh'); }
exec_files() {
  (cd "$ROOT" && files_in 'install.sh' 'bin/*' 'modules/[0-9][0-9]-*.sh' \
    'tools/*.sh' 'tests/*.sh' 'tests/*/*.sh' 'tests/*/*/*.sh')
}

# The lists the rules work on, resolved once per run. Arrays, not strings: a
# quoted expansion is what keeps the file names intact.
MODULES=()
LIBS=()
FAMILY=()
BINS=()
CORE=()

load_file_lists() {
  mapfile -t MODULES < <(module_files)
  mapfile -t LIBS < <(lib_files)
  mapfile -t FAMILY < <(family_files)
  mapfile -t BINS < <(cd "$ROOT" && files_in 'install.sh' 'bin/*')
  CORE=(${MODULES[0]+"${MODULES[@]}"} ${LIBS[0]+"${LIBS[@]}"} ${BINS[0]+"${BINS[@]}"})

  # EVERY rule below only ever looks at the files in these four lists, and every
  # list comes from a glob. A glob that matches nothing expands to nothing and
  # tells no one: the rules then run to completion over zero files and the script
  # prints "clean". That is not a hypothetical failure mode — it is exactly how
  # old-name passed on this branch for its whole life while CI found nine
  # violations in the same tree. An empty list is a broken run, not a clean one.
  local empty=''
  [ "${#MODULES[@]}" -gt 0 ] || empty="$empty modules/[0-9][0-9]-*.sh"
  [ "${#LIBS[@]}" -gt 0 ] || empty="$empty lib/*.sh"
  [ "${#FAMILY[@]}" -gt 0 ] || empty="$empty lib/family/*.sh"
  [ "${#BINS[@]}" -gt 0 ] || empty="$empty install.sh|bin/*"
  if [ -n "$empty" ]; then
    printf '%s: these globs matched nothing under %s:%s\n' "$PROG" "$ROOT" "$empty" >&2
    printf 'The rules that read them would examine no file and report "clean".\n' >&2
    printf 'Refusing to report success on a checkout the rules cannot see.\n' >&2
    exit 1
  fi

  # Printed on every run, including --rule: "clean" means nothing without it.
  printf '%s: %d module(s), %d lib(s), %d family file(s), %d executable(s)\n' \
    "$PROG" "${#MODULES[@]}" "${#LIBS[@]}" "${#FAMILY[@]}" "${#BINS[@]}"
  return 0
}

# grep_rule RULE PATTERN FILE… — report every matching line that does not carry
# this rule's escape hatch.
grep_rule() {
  local rule=$1
  shift
  grep_rule_why "$rule" '' "$@"
}

# grep_rule_why RULE WHY PATTERN FILE… — as grep_rule, with WHY in front of the
# offending text. For a rule that is several detectors under one name: the
# self-test asserts each WHY separately, so one detector cannot rot while
# another keeps the rule in $FIRED.
grep_rule_why() {
  local rule=$1 why=$2 pat=$3
  shift 3
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
    fail "$rule" "$file:$line" "${why:+$why: }$text"
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

# The same idea, wider, for the commands that may never appear outside their one
# owner (a package manager, setenforce). Such a call hides behind more than a
# `sudo`: `run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install` is the
# shape 35-kubernetes.sh actually wrote, and the narrow form never saw it. So the
# command may sit behind any run of the words that execute a command for someone
# else, the shell's own keywords, `VAR=value` assignments and options — or inside
# `$(`. A `(` is a position only at the start of a line, for the reason above.
# An assignment whose value opens a quote is NOT a prefix: `hint="sudo apt-get
# install …"` is a message, not a command.
EXEC_POS='(^[[:space:]]*[({]?|[;&|]|&&|\|\||\$\()[[:space:]]*'
EXEC_PREFIX='((sudo|run|run_sudo|run_quiet|as_root|command|exec|env|time|nice|then|else|do|if|elif|while|until|!)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]"'\'']*[[:space:]]+|-[A-Za-z-]+[[:space:]]+)*'

# ---------------------------------------------------------------------------
# The rules
# ---------------------------------------------------------------------------

RULES='strict-mode lib-shape meta-header common-entrypoint no-bare-sudo no-bare-apt
no-bare-download no-sed-i no-append-dotfile no-rm-rf-unquoted no-os-release-source
no-hardcoded-arch-url release-checksum pin-defined old-name exec-bit noexec-scratch
no-selinux-relax'

RULES_DOC='
  strict-mode        every executable starts with #!/usr/bin/env bash and sets
                     -euo pipefail
  lib-shape          lib/*.sh are sourced fragments: no shebang, no set -e, and a
                     shell=bash lint directive. lib/family/*.sh are the same and
                     DATA as well: nothing but FAM_* assignments and comments
  meta-header        every module has meta name= and desc=, valid os=/root= values,
                     a family= that is a comma list of debian|redhat|suse|arch (or
                     no family= at all, meaning every family), and a name no
                     other module uses
  common-entrypoint  a module sources lib/common.sh and never an individual lib
                     file — a package backend and a family file included
  no-bare-sudo       every privileged command goes through run_sudo/as_root, so
                     --dry-run stays a no-op
  no-bare-apt        one package policy (the name predates the other families):
                     pkg_* only. apt-get/apt/apt-mark/aptitude/nala, dpkg -i,
                     dnf/yum/microdnf/zypper/pacman and rpm -i/-U/-e/--import
                     appear in lib/pkg_*.sh (the backends) and lib/repo.sh (rpm
                     keys) and nowhere else — not in a module, not in bin/, not
                     in lib/pkg.sh itself
  no-bare-download   every download goes through lib/net.sh, which verifies it
  no-sed-i           in-place edits are what severed a symlinked ~/.bashrc
  no-append-dotfile  no >> into a dotfile: use ensure_block_in_file / bashrc_dropin
  no-rm-rf-unquoted  rm -rf with an unquoted variable
  no-os-release-source
                     never source /etc/os-release (it leaks NAME/ID into the
                     caller) and never call lsb_release (absent on minimal Debian)
  no-hardcoded-arch-url
                     no architecture or distro codename baked into a URL literal
  release-checksum   every gh_release_install and pkg_release_install carries a checksum option or an
                     explicit --no-verify with a reason. A wrapper that forwards
                     its arguments is accepted — the option then belongs at the call site
  pin-defined        every *_VERSION / *_REF a module reads is defined in
                     versions.env, unless the module assigns it itself — no
                     undefined and no invented pins
  old-name           NEITHER former repository name (wsl2-config,
                     devops-env-config) may appear outside the migration
                     documents, and never inside a URL or a checkout path
  exec-bit           modules and bin/ are executable; lib/ and lib/family/ are not
  noexec-scratch     nothing under the run scratch dir (devenv_tmpdir,
                     devenv_tmpfile) is ever executed or chmod +x-ed: /tmp is
                     mounted noexec on every hardened host. A download that has
                     to RUN belongs in devenv_execdir
  no-selinux-relax   mandatory access control stays enforcing (spec 002 FR-011):
                     no setenforce, no write to /etc/selinux/config, no
                     SELINUX=permissive|disabled, no selinux=0/enforcing=0 kernel
                     argument, no semanage permissive. Installed files get
                     restorecon instead
'

# Every name this repository has had and shed. `Ujstor/devops-env-config` is not
# merely out of date: it 404s, so a stale install one-liner is a broken one, and
# `~/.local/share/devops-env-config` is a state directory nothing writes any more.
# Both are caught by the same rule and on the same terms — see rule_old_name.
OLD_NAMES='wsl2-config devops-env-config'

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
  done < <(
    lib_files
    family_files
  )

  # A family file is the bash form of the sibling playbooks' vars/<family>.yml:
  # names, never mechanisms (plan D3). It is sourced once per detection and
  # several times in one shell by tests/unit/test_family.sh, which compares the
  # key sets of all four — so it carries no include guard (a guard would hand
  # that test the first family four times), no function, no command and no
  # `readonly`. One `FAM_*=` assignment per line, `export` allowed, and comments.
  # Anything else is a mechanism that belongs in lib/, behind a function.
  local n line stripped
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      stripped=${line#"${line%%[![:space:]]*}"}
      case $stripped in '' | '#'*) continue ;; esac
      case $line in *"# policy-allow: lib-shape"*) continue ;; esac
      [[ $stripped =~ ^(export[[:space:]]+)?FAM_[A-Z0-9_]+= ]] && continue
      if [ ${#stripped} -gt 100 ]; then stripped="${stripped:0:97}..."; fi
      fail lib-shape "$f:$n" "a family file is data — only FAM_* assignments and comments: $stripped"
    done <"$ROOT/$f"
  done < <(family_files)
  return 0
}

# The families a module may declare itself applicable to (plan D8). Absent means
# every family; there is deliberately no `all` spelling — one way to say it.
FAMILIES='debian redhat suse arch'

rule_meta_header() {
  local f name desc os root family fam seen names=''
  local -a fams=()
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
    # family= is gated before os= (lib/registry.sh:module_gate). A value the
    # gate cannot parse is a module that is "not applicable" everywhere, which
    # reads as a skip in every summary and fails nothing — so it is caught here.
    if sed -n '1,40p' "$ROOT/$f" | grep -qE '^# meta:[[:space:]]*family[[:space:]]*='; then
      family=$(sed -n '1,40{s/^# meta:[[:space:]]*family[[:space:]]*=//p;}' "$ROOT/$f" | head -n1)
      family=${family%"${family##*[![:space:]]}"}
      case $family in
        '') fail meta-header "$f:1" 'family= is empty — leave the key out to mean every family' ;;
        *[[:space:]]* | ,* | *, | *,,*)
          fail meta-header "$f:1" "family= is a comma list with no spaces and no empty item, found: $family"
          ;;
        *)
          seen=''
          IFS=, read -r -a fams <<<"$family"
          for fam in "${fams[@]}"; do
            case " $FAMILIES " in
              *" $fam "*) ;;
              *) fail meta-header "$f:1" "unknown family= value: $fam (one of: $FAMILIES)" ;;
            esac
            case " $seen " in
              *" $fam "*) fail meta-header "$f:1" "family= names $fam twice" ;;
            esac
            seen="$seen $fam"
          done
          ;;
      esac
    fi
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
  # A package backend (pkg_<mgr>.sh) is chosen by lib/pkg.sh at run time and a
  # family file by lib/os.sh after detection; a module that sources one itself
  # has hard-coded the family it runs on.
  # shellcheck disable=SC2016  # a literal pattern, not an expansion
  grep_rule common-entrypoint \
    'source[[:space:]]+"?\$\{?DEVENV_HOME[^"]*/lib/(log|os|run|fs|net|pkg|pkg_[a-z0-9]+|repo|extrepo|shell|lang|wsl|registry|family/[a-z0-9_-]+)\.sh' \
    ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

rule_no_bare_sudo() {
  grep_rule no-bare-sudo "${CMD_POS}sudo[[:space:]]" ${MODULES[0]+"${MODULES[@]}"}
  return 0
}

# --- no-bare-apt: one package policy, four package managers ------------------
#
# lib/pkg.sh is the API every module calls; lib/pkg_<mgr>.sh are the only files
# that know how apt, dnf, zypper or pacman spell an operation (plan D4), and
# lib/repo.sh imports rpm signing keys next to the .repo files it writes (D6).
# Everything else — modules, bin/, the rest of lib/, lib/pkg.sh's own dispatch —
# reaches a package manager only through pkg_*. A direct call is a second
# package policy: it skips the name map (D5), the add-on-repository report (D4),
# the rolling-release upgrade rule (FR-012) and, on every family but the one its
# author was sitting on, it is simply the wrong command.
#
# What counts. apt-get/apt/apt-mark/aptitude/nala and dnf/dnf5/yum/microdnf/
# zypper/pacman in any form; dpkg and rpm only in a mode that changes the
# package set or the keyring. `dpkg --print-architecture`, `dpkg-query` and
# `rpm -q` are questions, and lib/os.sh asks them. A case label (`apt | dnf)`)
# is not a call, hence the `[^|)]` after the name.
PKG_TOOLS='apt-get|apt|apt-mark|aptitude|nala|dnf|dnf5|yum|microdnf|zypper|pacman'

# pkg_policy_files — CORE and the family data, minus the files that own the
# package managers.
pkg_policy_files() {
  local f
  for f in ${CORE[0]+"${CORE[@]}"} ${FAMILY[0]+"${FAMILY[@]}"}; do
    case $f in
      lib/pkg_*.sh | lib/repo.sh) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

rule_no_bare_apt() {
  local -a files=()
  mapfile -t files < <(pkg_policy_files)
  grep_rule no-bare-apt "${EXEC_POS}${EXEC_PREFIX}(${PKG_TOOLS})[[:space:]]+[^|)[:space:]]" \
    ${files[0]+"${files[@]}"}
  grep_rule no-bare-apt \
    "${EXEC_POS}${EXEC_PREFIX}dpkg[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(-i|--install|-r|--remove|-P|--purge)([[:space:]]|$)" \
    ${files[0]+"${files[@]}"}
  grep_rule no-bare-apt \
    "${EXEC_POS}${EXEC_PREFIX}rpm[[:space:]]+([^;&|]*[[:space:]])?(-[iUFe][A-Za-z]*|--(install|upgrade|freshen|erase|reinstall|import))([[:space:]]|=|$)" \
    ${files[0]+"${files[@]}"}
  grep_rule no-bare-apt "${EXEC_POS}${EXEC_PREFIX}rpmkeys[[:space:]]+([^;&|]*[[:space:]])?--import([[:space:]]|$)" \
    ${files[0]+"${files[@]}"}
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
    ${MODULES[0]+"${MODULES[@]}"} ${LIBS[0]+"${LIBS[@]}"} ${FAMILY[0]+"${FAMILY[@]}"}
  return 0
}

rule_release_checksum() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      fail release-checksum "${hit%%|*}" "release install without a checksum option: ${hit#*|}"
    done < <(awk -v file="$f" '
      {
        line = $0
        sub(/[[:space:]]*#.*$/, "", line)
        if (cont) { logical = logical " " line } else { logical = line; start = FNR }
        if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", logical); cont = 1; next }
        cont = 0
        if (logical ~ /(^|[^_a-zA-Z])(gh|pkg)_release_install[[:space:]]/ &&
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

# old_name_scan OLD — every `file:line:text` in this checkout that mentions OLD.
# Always in a subshell: it has to `cd` to $ROOT to get git's path shape, and the
# caller's working directory is not its to change.
old_name_scan() (
  local old=$1
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

rule_old_name() {
  # Files whose SUBJECT is a former repository name. Naming one there is the
  # point, so they are exempt outright — including in a URL, which is the whole
  # content of a migration instruction. ONE list serves BOTH names in
  # $OLD_NAMES, because it is the same handful of files that carry both
  # migrations. Anything not on it may mention a former name only in a comment,
  # and never in a URL or a checkout path.
  #   README.md             carries the migration notes
  #   docs/migration.md     is the migration guide: it must show the OLD commands
  #   docs/modules.md       documents the migrate module, in table cells that
  #                         cannot be shell comments
  #   modules/92-migrate.sh IS the migrate module — it looks for the old checkouts
  #   tests/policy/rules.sh this rule's own patterns, and its self-test fixtures
  local allow='^(README\.md|docs/migration\.md|docs/modules\.md|modules/92-migrate\.sh|tests/policy/rules\.sh)$'
  local old hit file rest line text
  # Both names, on identical terms. A rule that guarded only the first one would
  # have waved through the very URL that broke the install one-liner.
  for old in $OLD_NAMES; do
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      file=${hit%%:*}
      rest=${hit#*:}
      line=${rest%%:*}
      text=${rest#*:}
      case $text in
        *"# policy-allow: old-name"*) continue ;;
      esac
      # The allow-list is checked FIRST. It used to sit after the URL branch,
      # which made the exemption useless for exactly the files that need it:
      # docs/migration.md exists to print the old install URLs, and got flagged
      # for it.
      printf '%s' "$file" | grep -qE "$allow" && continue
      # In a URL, a clone target or a checkout path it is always wrong — that is
      # a pipeline pointing at a repository this one has left behind, and for
      # `devops-env-config` the URL does not merely redirect, it 404s.
      if printf '%s' "$text" | grep -qE "(github(usercontent)?\.com[:/][^\"' ]*|/)${old}(\.git|/|\"|'|$)"; then
        fail old-name "$file:$line" \
          "'$old' in a URL or a checkout path: ${text#"${text%%[![:space:]]*}"}"
        continue
      fi
      # Elsewhere it may only appear in a comment explaining the migration.
      case ${text#"${text%%[![:space:]]*}"} in
        '#'* | '*'* | '//'*) continue ;;
      esac
      fail old-name "$file:$line" \
        "'$old' outside the migration documents and outside a comment"
    done < <(old_name_scan "$old")
  done
  return 0
}

# --- noexec-scratch --------------------------------------------------------
#
# $DEVENV_RUNDIR lives under $TMPDIR, which on a hardened host is /tmp, which is
# mounted `noexec` — the fleet's own vm-hardening role makes exactly that change.
# A file downloaded there can be read, copied, unpacked and installed, but it can
# never be exec()'d, and the failure is one line of "Permission denied" a long way
# from its cause. It cost a whole kubectl plugin roster and the rust toolchain on
# one install:
#
#     .../krew-linux_amd64: Permission denied      -> krew self-install failed
#     Cannot execute /tmp/tmp.XXXXXXXXXX/rustup-init
#       (likely because of mounting /tmp as noexec) -> rustup could not be installed
#
# So: run it out of `devenv_execdir`, which probes for a filesystem that executes.
# This rule holds that line. It is deliberately NOT "no chmod, no run anywhere" —
# `install`, `tar`, `cp`, `awk -f` and `bash SCRIPT` all work fine on noexec, and
# only a genuine execve() of a scratch path is a violation.
#
# LIMIT, stated so nobody trusts it further than it goes: the scan is per file and
# follows one hop of assignment (`work=$(devenv_tmpdir)`, then `s="$work/x"`),
# resetting at each top-level function. A path laundered through a third variable,
# an array or a command substitution is not caught. It catches every shape this
# repository actually writes.

# The words a real execution may hide behind. `env` is one (`env "$x/bin"` runs
# it). `bash` and `sh` are deliberately NOT: `bash "$script"` hands the file to an
# interpreter, which noexec does not block, and which is therefore allowed.
NOEXEC_GATE='run|run_sudo|run_quiet|as_root|exec|sudo|env|time|command'

# noexec_scan_file FILE — report every execution of a $DEVENV_RUNDIR scratch path.
noexec_scan_file() {
  local f=$1
  local base='DEVENV_RUNDIR' vars line stripped text pat known lineno=0
  vars=$base
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case $line in *"# policy-allow: noexec-scratch"*) continue ;; esac
    stripped=${line#"${line%%[![:space:]]*}"}
    case $stripped in '#'* | '') continue ;; esac

    # Scratch variables are function-local in every file here, so the set resets
    # at each top-level definition. Without this, `work=$(devenv_tmpdir)` in
    # gh_release_install would still be "tracked" 250 lines later inside
    # sh_installer_run, whose own `work` is an exec dir — a false positive on the
    # very function this rule exists to keep correct.
    if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{? ]]; then
      vars=$base
    fi

    # Learn: assigned straight from a scratch helper, or derived from one.
    if [[ $line =~ ([A-Za-z_][A-Za-z0-9_]*)=\$\(devenv_tmp(dir|file)\) ]]; then
      vars="$vars ${BASH_REMATCH[1]}"
    fi
    known=${vars// /|}
    if [[ $line =~ ([A-Za-z_][A-Za-z0-9_]*)=\"?\$\{?($known)\}?/ ]]; then
      vars="$vars ${BASH_REMATCH[1]}"
      known=${vars// /|}
    fi

    text=$stripped
    if [ ${#text} -gt 140 ]; then text="${text:0:137}..."; fi

    # Flag 1: a scratch path in COMMAND position.
    pat='(^|[;&|]|&&|\|\|)[[:space:]]*(('"$NOEXEC_GATE"')[[:space:]]+)*"?\$\{?('"$known"')\}?([/"[:space:]]|$)'
    if [[ $line =~ $pat ]]; then
      fail noexec-scratch "$f:$lineno" \
        "executed out of \$DEVENV_RUNDIR (noexec on a hardened host) — use devenv_execdir: $text"
      continue
    fi
    # Flag 2: chmod +x on one. Making it executable IS the statement of intent,
    # wherever the exec then happens.
    pat='chmod[[:space:]][^;|&]*\$\{?('"$known"')\}?([/"[:space:]]|$)'
    if [[ $line =~ $pat ]]; then
      fail noexec-scratch "$f:$lineno" \
        "chmod +x on a \$DEVENV_RUNDIR path — if it must run, use devenv_execdir: $text"
      continue
    fi
    # Flag 3: `cd` into one. Flags 1 and 2 both match on the scratch VARIABLE, so
    # neither can see the shape that broke the tmux source build:
    #     ( cd "$src" || exit 1; run ./configure ... )
    # After the cd the command is a bare `./configure` with no variable in it at
    # all. `(` counts as a command position here — unlike $CMD_POS — because what
    # follows must be `cd` and then a scratch path, which no prose does.
    pat='(^|[;&|(]|&&|\|\|)[[:space:]]*(run[[:space:]]+)?(cd|pushd)[[:space:]]+(--[[:space:]]+)?"?\$\{?('"$known"')\}?([/"[:space:]]|$)'
    if [[ $line =~ $pat ]]; then
      fail noexec-scratch "$f:$lineno" \
        "cd into a \$DEVENV_RUNDIR path — a ./relative command there hits noexec; use devenv_execdir: $text"
    fi
  done <"$ROOT/$f"
  return 0
}

rule_noexec_scratch() {
  local -a files=()
  mapfile -t files < <(
    printf '%s\n' ${MODULES[0]+"${MODULES[@]}"} ${LIBS[0]+"${LIBS[@]}"} \
      ${BINS[0]+"${BINS[@]}"}
  )
  local f
  for f in ${files[0]+"${files[@]}"}; do
    [ -n "$f" ] || continue
    [ -f "$ROOT/$f" ] || continue
    noexec_scan_file "$f"
  done
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
  done < <(
    lib_files
    family_files
  )
  return 0
}

# --- no-selinux-relax ------------------------------------------------------
#
# Spec 002 FR-011: on the RedHat and SUSE families SELinux is enforcing, it
# stays enforcing, and everything this repository installs has to work under it.
# The tempting fix for a denial — `setenforce 0`, or SELINUX=permissive in
# /etc/selinux/config — "works" on the operator's box and silently disables the
# host's access control for everything else on it. The repository's answer is
# restorecon on what it installs (lib/fs.sh, plan D9), never relaxation, so
# every spelling of relaxation is a violation wherever it is written, including
# shipped shell code under config/.
#
# Five detectors under one name, each with its own WHY, asserted one by one in
# the self-test.
selinux_files() {
  printf '%s\n' ${CORE[0]+"${CORE[@]}"} ${FAMILY[0]+"${FAMILY[@]}"}
  (cd "$ROOT" && files_in 'config/*.sh' 'config/bin/*' 'config/lib/*.sh' \
    'config/bashrc.d/*.sh' 'config/bashrc.d/*.bash' 'tools/*.sh')
}

# Every command or library writer that can put bytes into a file. sed and perl
# only count with -i: `sed -n 's/^SELINUX=//p' /etc/selinux/config` is a read,
# and a doctor is allowed to report the mode.
SELINUX_WRITERS='tee|cp|mv|install|ln|dd|truncate|rm|write_if_changed|write_once|write_managed|ensure_block_in_file|ensure_line_in_file|symlink_file|yaml_map_merge'

rule_no_selinux_relax() {
  local -a files=()
  mapfile -t files < <(selinux_files)
  [ "${#files[@]}" -gt 0 ] || return 0
  grep_rule_why no-selinux-relax 'setenforce switches SELinux off' \
    "${EXEC_POS}${EXEC_PREFIX}setenforce([[:space:]]|$)" "${files[@]}"
  grep_rule_why no-selinux-relax 'writes /etc/selinux/config' \
    "(>[>|]?[[:space:]]*\"?/etc/selinux/config|(^|[[:space:]])(${SELINUX_WRITERS})[[:space:]][^#]*/etc/selinux/config|(^|[[:space:]])(sed|perl)[[:space:]][^#]*-[A-Za-z]*i[^#]*/etc/selinux/config)" \
    "${files[@]}"
  grep_rule_why no-selinux-relax 'sets SELinux permissive or disabled' \
    'SELINUX=["'\'']?(permissive|disabled)' "${files[@]}"
  grep_rule_why no-selinux-relax 'turns SELinux off on the kernel command line' \
    '(^|[[:space:]"'\''=])(selinux|enforcing)=0([[:space:]"'\'']|$)' "${files[@]}"
  grep_rule_why no-selinux-relax 'makes an SELinux domain permissive' \
    'semanage[[:space:]]+permissive' "${files[@]}"
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
  if selected noexec-scratch; then rule_noexec_scratch; fi
  if selected no-selinux-relax; then rule_no_selinux_relax; fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test — plant one synthetic violation per rule in a throwaway tree and
# assert every rule fires. A rule that stops firing is worse than no rule.
# ---------------------------------------------------------------------------

# The former names the self-test HOLDS old-name to. A literal, NOT a read of
# $OLD_NAMES: an assertion that takes its expectation from the thing it is
# checking cannot notice a name being dropped from that list — it would simply
# check one name fewer and still print ok. Shedding a name is a decision; make it
# here, in the fixture, and in $OLD_NAMES, all three.
SELFTEST_OLD_NAMES='wsl2-config devops-env-config'

# selftest_shapes RULE FINDINGS — every line on stdin must appear in one of
# RULE's findings (its location line or the message under it). Returns 1 when
# any shape went uncaught. For a rule that is several detectors under one name:
# a single firing detector puts the rule in $FIRED, so "the rule fires" cannot
# tell a whole rule from one that has quietly lost half its detectors.
selftest_shapes() {
  local rule=$1 findings=$2 shape rc=0
  while IFS= read -r shape; do
    [ -n "$shape" ] || continue
    if grep -A1 -e "POLICY \[$rule\]" "$findings" | grep -qF -e "$shape"; then
      printf '  ok    %s catches "%s"\n' "$rule" "$shape"
    else
      printf '  FAIL  %s did not catch "%s"\n' "$rule" "$shape"
      rc=1
    fi
  done
  return "$rc"
}

self_test() {
  local dir findings rc=0 rule
  dir=$(mktemp -d "${TMPDIR:-/tmp}/policy-selftest.XXXXXXXX")
  # The findings are kept, not discarded, so the assertions below can read what
  # each rule actually said — `old-name` guards two names now, and "the rule
  # fired" no longer proves both are guarded.
  #
  # OUTSIDE the synthetic tree, deliberately: this file quotes both former
  # repository names, and old-name walks $dir recursively. A findings file inside
  # it would be a violation of the very rule it exists to check, reported as a
  # false positive by the compliant-tree phase below.
  findings=$(mktemp "${TMPDIR:-/tmp}/policy-selftest-findings.XXXXXXXX")
  # shellcheck disable=SC2064  # expand now: fresh mktemp paths
  trap "rm -rf -- '$dir' '$findings'" EXIT
  mkdir -p "$dir/modules" "$dir/lib/family" "$dir/bin"

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

  # The files that OWN the package managers, and a family data file. All three
  # are compliant, and all three are the reason no-bare-apt has an allow-list:
  # the compliant phase below fails if a backend, the rpm key import in repo.sh
  # or a FAM_* value that merely NAMES a package tool is ever reported.
  cat >"$dir/lib/pkg_dnf.sh" <<'EOF'
# shellcheck shell=bash
# a package backend: the one place dnf may be called

_pkg_dnf_install() { run_sudo dnf -y install --setopt=install_weak_deps=False "$@"; }
_pkg_dnf_local() { run_sudo rpm -Uvh "$1"; }
EOF
  cat >"$dir/lib/repo.sh" <<'EOF'
# shellcheck shell=bash
# vendor sources: imports the signing key next to the .repo file it writes

repo_rpm_key() { run_sudo rpm --import "$1"; }
EOF
  cat >"$dir/lib/family/good.sh" <<'EOF'
# shellcheck shell=bash
# a family data file that breaks no rule
# shellcheck disable=SC2034  # read by the library that sources this

FAM_ADMIN_GROUP=wheel
FAM_PKG_QUERY=rpm
FAM_PKG_FINGERPRINT="rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n'"
FAM_PKG_FINGERPRINT_ARCH='pacman -Q'
export FAM_CA_REFRESH='update-ca-trust'
EOF
  chmod 0644 "$dir/lib/pkg_dnf.sh" "$dir/lib/repo.sh" "$dir/lib/family/good.sh"

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
# meta: family=debian,gentoo
sudo apt-get install -y thing
run_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y --only-upgrade thing
run_sudo dnf -y install thing
if ! zypper --non-interactive install thing; then :; fi
cur=$(pacman -S --needed --noconfirm thing)
run_sudo rpm --import "$key_file"
run_sudo rpm -Uvh thing.rpm
run_sudo dpkg -i thing.deb
source "${DEVENV_HOME:?}/lib/pkg_dnf.sh"
source "${DEVENV_HOME:?}/lib/family/redhat.sh"
run_sudo setenforce 0
run_sudo tee /etc/selinux/config <"$conf" >/dev/null
line='SELINUX=disabled'
run_sudo grubby --update-kernel=ALL --args=selinux=0
run_sudo semanage permissive -a httpd_t
curl -fsSL https://example.com/x | sh
sed -i 's/a/b/' "$HOME/.bashrc"
echo x >> "$HOME/.bashrc"
rm -rf $dir
. /etc/os-release
lsb_release -cs
url=https://example.com/dl/tool-linux-amd64.tar.gz
gh_release_install owner/repo 'tool-{version}.tar.gz' tool "$MISSING_VERSION"
pkg_release_install owner/repo tool "$MISSING_VERSION" --deb 'tool_{version}_linux_{arch_dpkg}.deb'
source "${DEVENV_HOME}/lib/net.sh"
work=$(devenv_tmpdir)
installer="$work/vendor-init"
run chmod 0755 -- "$installer"
run "$work/vendor-init" --yes
cd "$work/src" || exit 1
stale_url_1=https://raw.githubusercontent.com/Owner/wsl2-config/main/install.sh
stale_url_2=https://raw.githubusercontent.com/Owner/devops-env-config/main/install.sh
stale_home=$HOME/.local/share/devops-env-config
EOF
  chmod 0644 "$dir/modules/50-bad.sh"

  cat >"$dir/modules/51-dup.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=bad
# meta: desc=a duplicate name and a trailing period.
# meta: family=debian, arch
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"
EOF
  chmod 0755 "$dir/modules/51-dup.sh"

  # A lib file outside the backends calls a package manager: no-bare-apt covers
  # all of lib/ now, not only modules/.
  cat >"$dir/lib/bogus.sh" <<'EOF'
#!/usr/bin/env bash
set -e
bogus() { :; }
yum install -y thing
EOF
  chmod 0755 "$dir/lib/bogus.sh"

  # A family file that has grown a mechanism: a function, a command, and the
  # exec bit.
  cat >"$dir/lib/family/bad.sh" <<'EOF'
# shellcheck shell=bash
FAM_ADMIN_GROUP=wheel
fam_helper() { :; }
microdnf install -y fam-thing
EOF
  chmod 0755 "$dir/lib/family/bad.sh"

  ROOT=$dir
  ONLY=''
  FAILED=0
  FIRED=''
  printf '%s: self-test — the findings below are SYNTHETIC and expected\n' "$PROG" >&2
  run_rules 2>"$findings"

  for rule in $RULES; do
    case " $FIRED " in
      *" $rule "*) printf '  ok    %s fires\n' "$rule" ;;
      *)
        printf '  FAIL  %s did not fire on a synthetic violation\n' "$rule"
        rc=1
        ;;
    esac
  done

  # old-name guards two names, and ONE finding is enough to put the rule in
  # $FIRED. That is exactly how a second old name could go unguarded while the
  # self-test still printed `ok  old-name fires` — so assert each name by itself.
  # `-A1` reaches the message line: fail() prints the location first and the
  # offending text on the line under it.
  local name
  for name in $SELFTEST_OLD_NAMES; do
    if grep -A1 -e 'POLICY \[old-name\]' "$findings" | grep -qF -e "$name"; then
      printf '  ok    old-name catches %s\n' "$name"
    else
      printf '  FAIL  old-name did not catch %s\n' "$name"
      rc=1
    fi
  done

  # Same reasoning, same shape: noexec-scratch is THREE independent detectors
  # under one name (execute it / chmod +x it / cd into it), and any ONE of them
  # firing puts the rule in $FIRED. Assert each detector separately, or two of
  # them could rot while the self-test still printed `ok  noexec-scratch fires`.
  selftest_shapes noexec-scratch "$findings" <<'SHAPES' || rc=1
executed out of $DEVENV_RUNDIR
chmod +x on a $DEVENV_RUNDIR path
cd into a $DEVENV_RUNDIR path
SHAPES

  # no-bare-apt is one detector per package-manager family and per place a call
  # hides: behind run_sudo env VAR=…, after `if !`, inside $(…), in a lib file
  # that is not a backend, in a family data file.
  selftest_shapes no-bare-apt "$findings" <<'SHAPES' || rc=1
sudo apt-get install -y thing
env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install
run_sudo dnf -y install thing
zypper --non-interactive install thing
$(pacman -S --needed --noconfirm thing)
rpm --import
rpm -Uvh thing.rpm
dpkg -i thing.deb
yum install -y thing
microdnf install -y fam-thing
SHAPES

  # The new names a module must not source, the family= key, and the family
  # file's data shape and exec bit.
  selftest_shapes common-entrypoint "$findings" <<'SHAPES' || rc=1
lib/net.sh
lib/pkg_dnf.sh
lib/family/redhat.sh
SHAPES
  selftest_shapes meta-header "$findings" <<'SHAPES' || rc=1
unknown family= value: gentoo
family= is a comma list with no spaces
SHAPES
  selftest_shapes lib-shape "$findings" <<'SHAPES' || rc=1
a family file is data — only FAM_* assignments and comments: fam_helper
a family file is data — only FAM_* assignments and comments: microdnf
SHAPES
  selftest_shapes exec-bit "$findings" <<'SHAPES' || rc=1
lib/family/bad.sh
SHAPES

  # FR-011: five spellings of "switch SELinux off", five detectors.
  selftest_shapes no-selinux-relax "$findings" <<'SHAPES' || rc=1
setenforce switches SELinux off
writes /etc/selinux/config
sets SELinux permissive or disabled
turns SELinux off on the kernel command line
makes an SELinux domain permissive
SHAPES

  # A well-formed module must produce nothing at all.
  rm -f "$dir/modules/49-nopins.sh" "$dir/modules/50-bad.sh" "$dir/modules/51-dup.sh" \
    "$dir/lib/bogus.sh" "$dir/lib/family/bad.sh"
  cat >"$dir/modules/52-good.sh" <<'EOF'
#!/usr/bin/env bash
# meta: name=good
# meta: desc=a module that breaks no rule
# meta: os=any
# meta: root=no
# meta: family=debian,redhat
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

module_main() {
  local work payload
  pkg_install ripgrep
  # The compliant halves of no-bare-apt and no-selinux-relax: a package NAME
  # that is also a tool, a case label, an rpm query, restorecon, a read of the
  # SELinux mode, and the escape hatch.
  pkg_install nala
  case ${OS_PKG_MGR:-} in
    apt | dnf) : ;;
  esac
  if rpm -q ripgrep >/dev/null 2>&1; then :; fi
  run_sudo restorecon -F /usr/local/bin/tool
  sed -n 's/^SELINUX=//p' /etc/selinux/config
  run_sudo apt-get autoremove --purge -y # policy-allow: no-bare-apt
  gh_release_install owner/repo 'tool_{version}_linux_{arch}.tar.gz' tool "$GOOD_VERSION" \
    --checksum-asset 'checksums.txt'
  run_sudo install -m 0755 /dev/null /usr/local/bin/tool
  # The compliant halves of noexec-scratch, both of which must stay silent:
  # a scratch dir that is only WRITTEN to, and an exec dir that is RUN from.
  payload=$(devenv_tmpfile)
  run install -m 0644 -- "$payload" /etc/tool.conf
  work=$(devenv_execdir)
  run chmod 0755 -- "$work/vendor-init"
  run "$work/vendor-init" --yes
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
