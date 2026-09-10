#!/usr/bin/env bash
# meta: name=private
# meta: desc=optional internal tooling from a private git host, entirely env-driven
# meta: profiles=private
# meta: os=any
# meta: arch=
# meta: needs=
# meta: root=no
#
# modules/80-private.sh — internal tooling that a PUBLIC repository must never
# describe.
#
# THE RULE THIS FILE EXISTS TO KEEP (MUST-FIX S2 / VERIFIED-FACTS 9):
#   Not one internal hostname, group path, project name, port, IP, realm or
#   credential appears anywhere in this file, in its example config, or in
#   anything it writes into the repository. Everything comes from the operator's
#   environment, with EMPTY defaults, and an unconfigured box does nothing at all
#   and still exits 0. Every example here uses RFC 2606 reserved names.
#
# THE ENVIRONMENT CONTRACT (all empty by default; set them in
# $DEVENV_CONFIG/private.env, which is mode 0600 and gitignored):
#
#   DEVENV_PRIVATE_HOST            host[:port] of the private git host.
#                                  EMPTY => this module does nothing.
#   DEVENV_PRIVATE_PORT            TCP port for the reachability probe (443).
#   DEVENV_PRIVATE_PROBE_TIMEOUT   seconds to wait for that probe (3).
#   DEVENV_PRIVATE_TOOLS           space-separated `<module-path>@<version>`,
#                                  installed with `go install` under GOPRIVATE.
#   DEVENV_PRIVATE_RELEASE_TOOLS   space-separated
#                                  `<project-path>@<tag>:<asset>:<command>`,
#                                  downloaded with `glab release download` for
#                                  tools that are not `go get`-able.
#
# AUTHENTICATION is never invented here. `go install` and `glab` use whatever the
# user already has: an ssh-agent key, ~/.netrc, a `glab auth login` token, or
# $GITLAB_TOKEN. This module writes no credential, no ~/.netrc entry and no git
# `insteadOf` rewrite, and it never asks for a token.
#
# WHY THE VARIABLES ARE NAMED DEVENV_PRIVATE_* and not after any organisation:
# a variable name is text in a public repository like any other. A neutral name
# leaks nothing and makes the module reusable by anyone with a private forge.

set -euo pipefail
# shellcheck source=lib/common.sh
source "${DEVENV_HOME:?}/lib/common.sh"

PRIVATE_FAILURES=()

# _path_prepend DIR   (private)
#   Puts DIR at the front of PATH once. Modules run as child processes with the
#   invoking shell's PATH, and a box that has never had ~/.local/bin or ~/go/bin
#   does not list them yet — which would make `comp_cache` skip a tool this
#   module has just installed.
_path_prepend() {
  local dir=${1:-}
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  PATH="$dir:$PATH"
  export PATH
  return 0
}

# _private_fail MSG   (private) — record a real failure and keep going.
_private_fail() {
  PRIVATE_FAILURES+=("$1")
  log_error "$1"
  return 0
}

# _private_seed_config
#   Seeds $DEVENV_CONFIG/private.env from the shipped example, once, mode 0600,
#   and never overwrites it. Prints where it is. Honours --dry-run. Always 0.
_private_seed_config() {
  local cfg=$1 example="$DEVENV_HOME/config/private/private.env.example"
  [ -r "$example" ] || {
    log_debug "no example config at $example"
    return 0
  }
  ensure_dir "$(dirname -- "$cfg")" 0700 || return 0
  copy_if_absent "$example" "$cfg" 0600
  return 0
}

# _private_load_config FILE
#   Sources FILE, then puts back any DEVENV_PRIVATE_* value that was already set
#   in the environment: the environment wins, the file is the default.
#   Sourcing is safe here in the way sourcing any of the user's own config is —
#   it is their file, mode 0600, and this module never fetches it from anywhere.
#   Always returns 0.
_private_load_config() {
  local file=$1
  local e_host=${DEVENV_PRIVATE_HOST:-} e_port=${DEVENV_PRIVATE_PORT:-}
  local e_tools=${DEVENV_PRIVATE_TOOLS:-} e_rel=${DEVENV_PRIVATE_RELEASE_TOOLS:-}
  local e_timeout=${DEVENV_PRIVATE_PROBE_TIMEOUT:-}
  if [ -r "$file" ]; then
    log_debug "reading $file"
    # shellcheck source=/dev/null
    . "$file"
  fi
  if [ -n "$e_host" ]; then DEVENV_PRIVATE_HOST=$e_host; fi
  if [ -n "$e_port" ]; then DEVENV_PRIVATE_PORT=$e_port; fi
  if [ -n "$e_tools" ]; then DEVENV_PRIVATE_TOOLS=$e_tools; fi
  if [ -n "$e_rel" ]; then DEVENV_PRIVATE_RELEASE_TOOLS=$e_rel; fi
  if [ -n "$e_timeout" ]; then DEVENV_PRIVATE_PROBE_TIMEOUT=$e_timeout; fi
  return 0
}

# _private_parse_host
#   Normalises DEVENV_PRIVATE_HOST into PRIVATE_HOST and PRIVATE_PORT: a scheme
#   and any path are stripped, and an embedded :port wins over
#   DEVENV_PRIVATE_PORT. Rejects anything that is not a bare hostname, because a
#   value from the environment must never reach a command line unvalidated.
#   Returns 1 when the value is unusable (the caller then skips).
_private_parse_host() {
  local raw=${DEVENV_PRIVATE_HOST:-}
  raw=${raw#https://}
  raw=${raw#http://}
  raw=${raw#ssh://}
  raw=${raw%%/*}
  PRIVATE_PORT=${DEVENV_PRIVATE_PORT:-443}
  case $raw in
    *:*:*)
      log_warn "DEVENV_PRIVATE_HOST looks like an IPv6 literal, which this module does not handle"
      return 1
      ;;
    *:*)
      PRIVATE_PORT=${raw##*:}
      raw=${raw%%:*}
      ;;
  esac
  case $raw in
    '' | *[!A-Za-z0-9.-]* | -* | .*)
      log_warn "DEVENV_PRIVATE_HOST is not a plain hostname — refusing to use it"
      return 1
      ;;
  esac
  case $PRIVATE_PORT in
    '' | *[!0-9]*)
      log_warn "DEVENV_PRIVATE_PORT must be a number, got '$PRIVATE_PORT'"
      return 1
      ;;
  esac
  PRIVATE_HOST=$raw
  return 0
}

# _private_reachable HOST PORT TIMEOUT
#   TCP connect test, no DNS assumptions, no external dependency: bash's own
#   /dev/tcp, wrapped in `timeout` so a black-holed route cannot hang the run.
#   Read-only, so it runs under --dry-run too. Returns 1 when the host does not
#   answer — a laptop on a café network, a fresh public VM or a CI runner must
#   complete the whole install with this module doing nothing.
_private_reachable() {
  local host=$1 port=$2 timeout=$3
  case $timeout in '' | *[!0-9]*) timeout=3 ;; esac
  if have timeout; then
    # shellcheck disable=SC2016  # deliberate: the INNER bash expands $1 and $2,
    # so the host never reaches a command line this shell has already expanded.
    timeout "$timeout" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null
    return
  fi
  (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null
}

# _private_go_tools
#   `go install` for every entry in DEVENV_PRIVATE_TOOLS, under GOPRIVATE so the
#   module is fetched straight from the host instead of proxy.golang.org (which
#   cannot reach it) and is not looked up in the public checksum database (which
#   would leak the module path).
#   Each entry must start with the configured host: a public path here would mean
#   GOPRIVATE was pointed at something it should not cover.
#   One failing tool is reported and the rest continue (the krew rule, K24).
#   Always returns 0.
_private_go_tools() {
  local specs=${DEVENV_PRIVATE_TOOLS:-} spec bin bins=() failed=() list=()
  [ -n "$specs" ] || {
    log_debug "DEVENV_PRIVATE_TOOLS is empty — no go tools to install"
    return 0
  }
  if ! have go; then
    log_skip "go is not installed — run 'devenv --only lang-go' first"
    return 0
  fi
  export GOPRIVATE="$PRIVATE_HOST"
  log_info "GOPRIVATE=$GOPRIVATE for the tools below (no module proxy, no sumdb lookup)"
  # read -a splits on whitespace WITHOUT globbing, which a bare `for x in $var`
  # would do.
  read -r -a list <<<"$specs" || true
  for spec in "${list[@]}"; do
    case $spec in
      "$PRIVATE_HOST"/*@*) ;;
      *@*)
        log_warn "ignoring '$spec': it is not a module path under $PRIVATE_HOST"
        continue
        ;;
      *)
        log_warn "ignoring '$spec': DEVENV_PRIVATE_TOOLS entries are <module-path>@<version>"
        continue
        ;;
    esac
    bin=${spec%@*}
    bin=${bin##*/}
    if go_install "$spec" "$bin"; then
      bins+=("$bin")
    else
      failed+=("$spec")
    fi
  done
  if [ ${#failed[@]} -gt 0 ]; then
    log_warn "these private tools could not be built: ${failed[*]}"
    log_warn "  The usual cause is credentials: go fetches over HTTPS and uses"
    log_warn "  ~/.netrc, or over SSH when git has an insteadOf rewrite for the"
    log_warn "  host. This module never writes either of those for you."
  fi
  _private_completions "${bins[@]}"
  return 0
}

# _private_state_file BIN   (private) — where the release-tool pin is recorded.
_private_state_file() { printf '%s/private/%s\n' "${DEVENV_STATE:?}" "$1"; }

# _private_release_tools
#   The fallback for tools that are not `go get`-able: download a named asset
#   from a release with `glab release download` and install it.
#   Entry format: <project-path>@<tag>:<asset>:<command>
#   Idempotent through a one-line state file per command, because a private
#   binary's `--version` output is not something this repository can assume.
#   Always returns 0.
_private_release_tools() {
  local specs=${DEVENV_PRIVATE_RELEASE_TOOLS:-}
  local entry project tag asset cmd rest norm state bins=() list=()
  [ -n "$specs" ] || {
    log_debug "DEVENV_PRIVATE_RELEASE_TOOLS is empty — nothing to download"
    return 0
  }
  if ! have glab; then
    log_skip "glab is not installed — run 'devenv --only cloud' first"
    return 0
  fi
  read -r -a list <<<"$specs" || true
  for entry in "${list[@]}"; do
    case $entry in
      *@*:*:*) ;;
      *)
        log_warn "ignoring '$entry': the form is <project-path>@<tag>:<asset>:<command>"
        continue
        ;;
    esac
    project=${entry%%@*}
    rest=${entry#*@}
    tag=${rest%%:*}
    rest=${rest#*:}
    asset=${rest%%:*}
    cmd=${rest##*:}
    if [ -z "$project" ] || [ -z "$tag" ] || [ -z "$asset" ] || [ -z "$cmd" ]; then
      log_warn "ignoring '$entry': the form is <project-path>@<tag>:<asset>:<command>"
      continue
    fi
    case $cmd in
      */*)
        log_warn "ignoring '$entry': the command must be a bare name"
        continue
        ;;
    esac
    norm="$project@$tag:$asset:$cmd"
    state=$(_private_state_file "$cmd")
    if have "$cmd" && [ -r "$state" ] && [ "$(cat "$state")" = "$norm" ]; then
      log_skip "$cmd is already at $tag"
      continue
    fi
    if _private_release_one "$project" "$tag" "$asset" "$cmd" "$state"; then
      bins+=("$cmd")
    fi
  done
  _private_completions "${bins[@]}"
  return 0
}

# _private_release_one PROJECT TAG ASSET CMD STATE   (private)
#   Downloads one release asset into a temp dir and installs it: a .deb through
#   apt, a tarball by extracting CMD out of it, anything else as the binary
#   itself. Honours --dry-run. Returns 1 when the tool was not installed.
_private_release_one() {
  local project=$1 tag=$2 asset=$3 cmd=$4 state=$5
  local work found n dest="$HOME/.local/bin"
  if is_dry_run; then
    log_dryrun "glab release download $tag from $PRIVATE_HOST/$project ($asset) -> $dest/$cmd"
    changed "$cmd $tag"
    return 0
  fi
  work=$(devenv_tmpdir) || return 1
  if ! run glab release download "$tag" \
    --repo "https://$PRIVATE_HOST/$project" --asset-name "$asset" --dir "$work"; then
    _private_fail "could not download $asset from $project $tag"
    return 1
  fi
  n=$(find "$work" -maxdepth 1 -type f | wc -l | tr -d ' ')
  if [ "$n" != 1 ]; then
    _private_fail "'$asset' matched $n files in $project $tag — name exactly one"
    return 1
  fi
  found=$(find "$work" -maxdepth 1 -type f -print -quit)
  case $found in
    *.deb)
      pkg_install_local "$found" || {
        _private_fail "$cmd: apt refused $found"
        return 1
      }
      ;;
    *.tar.gz | *.tgz)
      run tar -xzf "$found" -C "$work" || {
        _private_fail "$cmd: could not unpack $found"
        return 1
      }
      found=$(find "$work" -type f -name "$cmd" -print -quit) || found=''
      [ -n "$found" ] || {
        _private_fail "$cmd: '$cmd' is not inside $asset"
        return 1
      }
      ensure_dir "$dest" || return 1
      run install -m 0755 -- "$found" "$dest/$cmd" || {
        _private_fail "$cmd: could not install into $dest"
        return 1
      }
      ;;
    *)
      ensure_dir "$dest" || return 1
      run install -m 0755 -- "$found" "$dest/$cmd" || {
        _private_fail "$cmd: could not install into $dest"
        return 1
      }
      ;;
  esac
  ensure_dir "$(dirname -- "$state")" || return 1
  printf '%s\n' "$project@$tag:$asset:$cmd" | write_if_changed "$state" 0644
  log_success "installed $cmd $tag"
  changed "$cmd $tag"
  return 0
}

# _private_completions BIN…
#   Caches a bash completion for each private tool that actually has one.
#   comp_cache throws away empty or failed output (MUST-FIX C3), which is exactly
#   what makes this safe: the live ~/.bashrc sources four templater completions
#   unconditionally today and errors on every shell start of a box that does not
#   have them. Always returns 0.
_private_completions() {
  local b
  [ $# -gt 0 ] || return 0
  for b in "$@"; do
    [ -n "$b" ] || continue
    comp_cache "$b" "$b" completion bash
  done
  return 0
}

module_main() {
  local cfg="${DEVENV_CONFIG:?}/private.env"

  _path_prepend "$HOME/.local/bin"
  if have go; then _path_prepend "$(go env GOPATH 2>/dev/null)/bin"; fi

  _private_seed_config "$cfg"
  _private_load_config "$cfg"

  if [ -z "${DEVENV_PRIVATE_HOST:-}" ]; then
    log_skip "private tooling is not configured — nothing to do"
    log_info "  Set DEVENV_PRIVATE_HOST and DEVENV_PRIVATE_TOOLS in $cfg"
    log_info "  (that file is mode 0600 and is never committed) to enable this."
    return 0
  fi

  PRIVATE_HOST='' PRIVATE_PORT=''
  if ! _private_parse_host; then
    log_skip "private tooling: DEVENV_PRIVATE_HOST is unusable — doing nothing"
    return 0
  fi

  if ! _private_reachable "$PRIVATE_HOST" "$PRIVATE_PORT" "${DEVENV_PRIVATE_PROBE_TIMEOUT:-3}"; then
    log_skip "private tooling: the configured host does not answer on port $PRIVATE_PORT — doing nothing"
    log_info "  This is the normal outcome away from that network. The rest of the"
    log_info "  install is unaffected and this module still succeeds."
    return 0
  fi

  _private_go_tools
  _private_release_tools

  if [ ${#PRIVATE_FAILURES[@]} -gt 0 ]; then
    log_error "${#PRIVATE_FAILURES[@]} step(s) in this module failed:"
    printf '  - %s\n' "${PRIVATE_FAILURES[@]}" >&2
    # A deliberate failure exit: clear the ERR trap first, or lib/common.sh's
    # trap prints two more "failed (exit 1) … command: return 1" lines after the
    # list above and buries the real reason.
    trap - ERR
    exit 1
  fi
  return 0
}

module_main "$@"
