# shellcheck shell=bash
# lib/registry.sh — module discovery, plan resolution, execution and the summary.
#
# devops-env-config :: shared library. Sourced by lib/common.sh only.
#
# D2: modules are executable CHILD PROCESSES, modules/NN-name.sh, described by
# `# meta:` comment headers. Order is numeric filename order; there is no dependency
# graph. Exit status: 0 = ok, 78 = skipped precondition, anything else = failure.
#
# MODULE CONTRACT — every modules/NN-name.sh starts with exactly this shape:
#
#     #!/usr/bin/env bash
#     # meta: name=k8s-plugins
#     # meta: desc=krew, kubectl plugins and helm plugins
#     # meta: profiles=devops,full
#     # meta: os=any                 # any | debian | ubuntu | wsl | !wsl | !container
#     # meta: arch=amd64,arm64
#     # meta: needs=kubectl          # missing => SKIP (78), never a failure
#     # meta: root=no                # yes => the module calls run_sudo
#     set -euo pipefail
#     source "${DEVENV_HOME:?}/lib/common.sh"
#     module_main() { … }
#     module_main "$@"
#
# Modules must be individually runnable:
#     DEVENV_HOME=$PWD ./modules/36-k8s-plugins.sh
#
# MUST-FIX S14 / idempotency F21: a `root=yes` module on a box with no usable sudo is
# SKIPPED with a clear message, not failed — and nothing asks for a password until
# such a module actually runs.

[ -n "${_DEVENV_REGISTRY:-}" ] && return 0
_DEVENV_REGISTRY=1

DEVENV_MODULE_DIR=${DEVENV_MODULE_DIR:-${DEVENV_HOME:-.}/modules}
DEVENV_PROFILE_DIR=${DEVENV_PROFILE_DIR:-${DEVENV_HOME:-.}/profiles}

# module_list
#   Prints every module file path, one per line, in numeric filename order.
#   NEVER executes a module. Always returns 0.
module_list() {
  local f
  for f in "$DEVENV_MODULE_DIR"/[0-9][0-9]-*.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# module_meta FILE KEY
#   Prints the value of `# meta: KEY=value` from FILE's header, or nothing.
#   Reads only the first 40 lines and never sources or runs the file.
#   Returns 1 when the key is absent.
module_meta() {
  local f=${1:?module_meta: FILE required} key=${2:?module_meta: KEY required} v
  [ -r "$f" ] || return 1
  v=$(sed -n "1,40{s/^# meta:[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p;}" "$f" \
    | head -n1 | sed 's/[[:space:]]*#.*$//;s/[[:space:]]*$//') || return 1
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# module_name FILE   — the module's short name (meta name=, else the filename stem).
module_name() {
  local f=$1 n
  n=$(module_meta "$f" name) || n=$(basename -- "$f" .sh)
  printf '%s\n' "$n"
}

# module_resolve NAME
#   Resolves a user-supplied module name to exactly one file path.
#   Matching order: exact `# meta: name`, exact filename stem, then unique suffix
#   (`k8s-plugins` == `36-k8s-plugins` == `36-k8s-plugins.sh`).
#   An AMBIGUOUS name is fatal: it prints the candidates and returns 1.
module_resolve() {
  local want=${1:?module_resolve: NAME required} f stem hits=() all=()
  want=${want%.sh}
  mapfile -t all < <(module_list)
  for f in "${all[@]}"; do
    [ -n "$f" ] || continue
    stem=$(basename -- "$f" .sh)
    if [ "$(module_name "$f")" = "$want" ] || [ "$stem" = "$want" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  for f in "${all[@]}"; do
    [ -n "$f" ] || continue
    stem=$(basename -- "$f" .sh)
    case $stem in *"-$want" | *"$want") hits+=("$f") ;; esac
  done
  case ${#hits[@]} in
    1)
      printf '%s\n' "${hits[0]}"
      return 0
      ;;
    0)
      log_error "no such module: $want"
      return 1
      ;;
    *)
      log_error "'$want' is ambiguous — it matches: ${hits[*]}"
      return 1
      ;;
  esac
}

# profile_modules PROFILE
#   Prints the module names listed in profiles/PROFILE.list (one per line),
#   ignoring blank lines and `#` comments. Returns 1 when the profile does not exist.
profile_modules() {
  local p=${1:?profile_modules: PROFILE required} f="$DEVENV_PROFILE_DIR/$1.list"
  [ -f "$f" ] || {
    log_error "no such profile: $p (looked for $f)"
    return 1
  }
  sed -e 's/#.*$//' -e 's/[[:space:]]//g' -e '/^$/d' "$f"
}

# resolve_plan
#   Prints the module FILES to run, in numeric filename order.
#   Inputs (all environment, set by bin/devenv):
#     DEVENV_ONLY     comma/space separated module names; REPLACES the profile
#     DEVENV_PROFILE  profile name (default: devops)
#     DEVENV_SKIP     comma/space separated module names to subtract
#   Returns 1 when a named module or profile does not resolve.
resolve_plan() {
  local names=() n f w match wanted=() all=() skip
  skip=" ${DEVENV_SKIP:-} "
  skip=${skip//,/ }
  if [ -n "${DEVENV_ONLY:-}" ]; then
    read -r -a names <<<"${DEVENV_ONLY//,/ }"
  else
    mapfile -t names < <(profile_modules "${DEVENV_PROFILE:-devops}") || return 1
  fi
  for n in "${names[@]}"; do
    [ -n "$n" ] || continue
    f=$(module_resolve "$n") || return 1
    wanted+=("$f")
  done
  [ ${#wanted[@]} -gt 0 ] || return 0
  mapfile -t all < <(module_list)
  for f in "${all[@]}"; do
    [ -n "$f" ] || continue
    match=0
    for w in "${wanted[@]}"; do
      if [ "$w" = "$f" ]; then match=1; fi
    done
    [ "$match" = 1 ] || continue
    n=$(module_name "$f")
    case $skip in
      *" $n "* | *" $(basename -- "$f" .sh) "*) continue ;;
    esac
    printf '%s\n' "$f"
  done
}

# module_gate FILE
#   Decides whether FILE may run on THIS machine, using only its `# meta:` header.
#   Prints nothing. Returns:
#     0  run it
#     78 skip it (the reason has already been logged)
#   Gates, in order: os=, arch=, needs=, root=.
module_gate() {
  local f=$1 v name
  name=$(module_name "$f")
  if v=$(module_meta "$f" os); then
    case $v in
      any) ;;
      debian) os_is_debian || {
        log_skip "$name: Debian only"
        return 78
      } ;;
      ubuntu) os_is_ubuntu || {
        log_skip "$name: Ubuntu only"
        return 78
      } ;;
      wsl) os_is_wsl || {
        log_skip "$name: WSL only"
        return 78
      } ;;
      '!wsl') ! os_is_wsl || {
        log_skip "$name: not applicable under WSL"
        return 78
      } ;;
      '!container') ! os_is_container || {
        log_skip "$name: not applicable in a container"
        return 78
      } ;;
      *) log_warn "$name: unknown 'os' gate '$v' — running it anyway" ;;
    esac
  fi
  if v=$(module_meta "$f" arch); then
    case ",$v," in
      *",${OS_ARCH_DPKG:-},"*) ;;
      *)
        log_skip "$name: architecture ${OS_ARCH_DPKG:-unknown} is not in '$v'"
        return 78
        ;;
    esac
  fi
  if v=$(module_meta "$f" needs); then
    local need
    for need in ${v//,/ }; do
      have "$need" || {
        log_skip "$name: needs '$need', which is not installed"
        return 78
      }
    done
  fi
  if v=$(module_meta "$f" root); then
    if [ "$v" = yes ] && ! have_root; then
      log_skip "$name: needs root privileges, which are not available here"
      return 78
    fi
  fi
  return 0
}

# print_plan
#   Machine-readable listing on STDOUT, one TAB-separated row per module:
#     name<TAB>file<TAB>profiles<TAB>os<TAB>arch<TAB>needs<TAB>root<TAB>desc
#   This is `devenv list`. Never executes a module. Always returns 0.
print_plan() {
  local f all=()
  mapfile -t all < <(module_list)
  for f in "${all[@]}"; do
    [ -n "$f" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(module_name "$f")" "$f" \
      "$(module_meta "$f" profiles || printf '-')" \
      "$(module_meta "$f" os || printf 'any')" \
      "$(module_meta "$f" arch || printf 'any')" \
      "$(module_meta "$f" needs || printf '-')" \
      "$(module_meta "$f" root || printf 'no')" \
      "$(module_meta "$f" desc || printf '-')"
  done
}

# run_module FILE
#   Runs one module as a CHILD PROCESS with the exported environment, after
#   module_gate. Records the outcome for summary_print.
#   Returns 0 (ok or skipped) or the module's exit status on failure. With
#   DEVENV_FAIL_FAST=1 the caller should stop on the first non-zero return.
run_module() {
  local f=${1:?run_module: FILE required} name rc=0
  name=$(module_name "$f")
  if ! module_gate "$f"; then
    summary_record "$name" SKIP "gated out"
    return 0
  fi
  log_step "$name — $(module_meta "$f" desc || printf 'no description')"
  DEVENV_MODULE=$name
  export DEVENV_MODULE
  if [ ! -x "$f" ]; then
    bash "$f" || rc=$?
  else
    "$f" || rc=$?
  fi
  unset DEVENV_MODULE
  log_step_end
  case $rc in
    0)
      summary_record "$name" OK
      return 0
      ;;
    78)
      summary_record "$name" SKIP "precondition missing"
      return 0
      ;;
    *)
      summary_record "$name" FAIL "exit $rc"
      log_error "$name failed (exit $rc)"
      return "$rc"
      ;;
  esac
}

# summary_record NAME STATUS [NOTE]
#   Appends one outcome row to $DEVENV_RUNDIR/summary. STATUS is OK|SKIP|FAIL.
#   Always returns 0.
summary_record() {
  local name=${1:?summary_record: NAME required} status=${2:?summary_record: STATUS required}
  local note=${3:-}
  [ -n "${DEVENV_RUNDIR:-}" ] && [ -d "$DEVENV_RUNDIR" ] || return 0
  printf '%s\t%s\t%s\n' "$name" "$status" "$note" >>"$DEVENV_RUNDIR/summary"
  return 0
}

# summary_print
#   Prints the per-module table, everything `changed` recorded, and the next steps.
#   Returns 0 when no module failed, 1 when at least one did — so bin/devenv can use
#   it as its own exit status.
summary_print() {
  local sfile="${DEVENV_RUNDIR:-}/summary" fails=0
  log_step "summary"
  if [ -s "$sfile" ]; then
    local name status note
    while IFS=$'\t' read -r name status note; do
      case $status in
        OK) log_success "$(printf '%-18s %s' "$name" "${note:-}")" ;;
        SKIP) log_skip "$(printf '%-18s %s' "$name" "${note:-}")" ;;
        FAIL)
          log_error "$(printf '%-18s %s' "$name" "${note:-}")"
          fails=$((fails + 1))
          ;;
      esac
    done <"$sfile"
  else
    log_info "no modules ran"
  fi

  if [ -s "${DEVENV_RUNDIR:-}/changed" ]; then
    log_step "what changed"
    local mod what
    while IFS=$'\t' read -r mod what; do
      log_info "$(printf '%-18s %s' "$mod" "$what")"
    done <"$DEVENV_RUNDIR/changed"
  else
    log_info "nothing changed — this machine was already up to date"
  fi

  log_step "next steps"
  log_info "start a new login shell so the new PATH and completions take effect:  exec bash -l"
  if os_is_wsl; then
    log_info "if /etc/wsl.conf changed, run 'wsl --shutdown' in Windows first"
  fi
  if have docker && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log_info "you are not in the 'docker' group yet — log out and back in after adding yourself"
  fi
  log_step_end
  [ "$fails" -eq 0 ]
}
