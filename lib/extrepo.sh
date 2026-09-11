# shellcheck shell=bash
# lib/extrepo.sh — the external config repositories, as ONE declarative list.
#
# linux-devops-tools :: shared library. Sourced by lib/common.sh only.
#
# WHY THIS EXISTS. Three external checkouts used to be hardcoded in two modules:
# modules/50-editors.sh cloned nvim-config and tmux-config and knew where each
# symlink went, modules/10-shell.sh knew about mybash, and versions.env pinned all
# three refs with nothing tying the pin to the clone. Adding a fourth meant editing
# a module — which is exactly the thing a user of this repository must never have to
# do to add a checkout of their own.
#
# So the list is DATA, in two files, both of them plain sourced bash:
#
#     $DEVENV_HOME/config/external-repos.sh    the three this repository ships
#     $DEVENV_CONFIG/external-repos.sh         yours; never overwritten, never
#                                              committed, sourced second
#
# Each file is a sequence of `extrepo` calls and nothing else. Sourcing them second
# means an entry of yours REPLACES a shipped one of the same name in place — that is
# how you point `nvim-config` at your own fork without touching the checkout.
#
# WHAT AN ENTRY IS
#
#     extrepo NAME url=… [ref=…] [dest=…] [link=…] [link_src=…]
#                         [module=…] [enabled=0|1] [desc=…]
#
#     name      the entry's id. Also the default directory name, and the suffix of
#               its DEVENV_EXTREPO_<NAME> switch (upper-cased, non-alphanumerics
#               become `_`).
#     url       required. https://, git@, ssh://, file:// or an absolute path.
#     ref       branch or tag. Empty means the remote's default branch.
#     dest      where the checkout goes, ABSOLUTE. Default $EXTREPO_ROOT/<name>.
#     link      absolute path of a symlink to create. Empty means none — mybash is
#               a checkout with no symlink, which is the whole point of it.
#     link_src  what inside the checkout `link` points at, relative to dest.
#               Empty means the checkout directory itself (nvim-config: init.lua is
#               at the repository root, so ~/.config/nvim is the directory).
#     module    which module syncs it. Default `editors`; mybash is `shell`.
#     enabled   1 or 0. Default 1. mybash ships as 0 — this repository deliberately
#               does not require it, and the list is how it becomes opt-in instead
#               of special-cased in a module.
#     desc      one line, for the log.
#
# ENABLING AND DISABLING. Per entry, two ways, the environment always winning:
#
#     DEVENV_EXTREPO_MYBASH=1      devenv --only shell     turn one on
#     DEVENV_EXTREPO_NVIM_CONFIG=0 devenv --only editors   turn one off
#     enabled=0 in your own external-repos.sh              change the default
#
# GUARANTEES, all of them inherited from lib/fs.sh and none of them weakened here:
#   * devenv_sync_repo REFUSES to update a dirty worktree — your local edits in a
#     checkout are never destroyed, the run says so and carries on.
#   * a symlink is only ever placed over nothing, over another symlink, or over an
#     EMPTY directory. A real file or a non-empty directory of yours is reported
#     and left exactly as it is (SPEC §8 / C10: ~/.tmux.conf is never edited in
#     place and never overwritten).
#   * every write goes through lib/run.sh, so --dry-run changes nothing.
#   * a missing, unreachable or broken entry WARNS and returns 0. Nothing in here
#     may abort the module that called it: a GitHub outage must not stop neovim
#     from being installed.

[ -n "${_DEVENV_EXTREPO:-}" ] && return 0
_DEVENV_EXTREPO=1

# Where checkouts go by default. Overridable for a test or a box that keeps its
# clones elsewhere; the shipped entries all inherit it.
EXTREPO_ROOT=${EXTREPO_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/devops-env/repos}

# The registry. EXTREPO_NAMES holds declaration order (the order entries are
# synced in); the maps hold the fields. Private on purpose — modules go through
# extrepo_get, so the storage can change without touching a module.
EXTREPO_NAMES=()
declare -A _EXTREPO_URL
declare -A _EXTREPO_REF
declare -A _EXTREPO_DEST
declare -A _EXTREPO_LINK
declare -A _EXTREPO_LINKSRC
declare -A _EXTREPO_MODULE
declare -A _EXTREPO_ON
declare -A _EXTREPO_DESC

# extrepo NAME KEY=VALUE…
#   Declares one external config repository. Called only from the two
#   external-repos.sh files. Invalid entries are reported and SKIPPED, never fatal:
#   a typo in your own list must cost you that one entry, not the whole run.
#   Re-declaring a name replaces its fields and keeps its position.
#   Always returns 0.
extrepo() {
  local name=${1-}
  case $name in
    '' | *[!A-Za-z0-9._-]*)
      log_warn "external-repos: ignoring an entry whose name is empty or not [A-Za-z0-9._-]: '$name'"
      return 0
      ;;
  esac
  shift

  local url='' ref='' dest='' link='' link_src='' module='editors' enabled=1 desc=''
  local kv key val
  for kv in "$@"; do
    key=${kv%%=*}
    val=${kv#*=}
    case $key in
      url) url=$val ;;
      ref) ref=$val ;;
      dest) dest=$val ;;
      link) link=$val ;;
      link_src) link_src=$val ;;
      module) module=$val ;;
      enabled) enabled=$val ;;
      desc) desc=$val ;;
      *) log_warn "external-repos: $name: unknown field '$key=' — ignored" ;;
    esac
  done

  # A URL is the one thing an entry cannot do without, and a wrong one is worth
  # naming: `github.com/x/y` (no scheme) is the mistake people actually make, and
  # git would take it as a local path and fail much later with a worse message.
  case $url in
    https://?* | http://?* | git@?* | ssh://?* | git://?* | file://?* | /?*) ;;
    *)
      log_warn "external-repos: $name: url= must be a git URL or an absolute path, got '$url' — entry ignored"
      return 0
      ;;
  esac

  # dest= and link= are used verbatim by ensure_dir, git clone and symlink_file.
  # A relative one would resolve against whatever directory the run happens to be
  # in — which for `curl | bash` is wherever the user was standing. Refuse it here,
  # where the message can name the entry, rather than create a checkout in $PWD.
  case ${dest:-/} in
    /*) ;;
    *)
      log_warn "external-repos: $name: dest= must be an absolute path, got '$dest' — entry ignored"
      return 0
      ;;
  esac
  case ${link:-/} in
    /*) ;;
    *)
      log_warn "external-repos: $name: link= must be an absolute path, got '$link' — entry ignored"
      return 0
      ;;
  esac

  case $enabled in
    1 | yes | true | on) enabled=1 ;;
    0 | no | false | off | '') enabled=0 ;;
    *)
      log_warn "external-repos: $name: enabled='$enabled' is not a boolean — treating it as off"
      enabled=0
      ;;
  esac

  [ -n "$dest" ] || dest="$EXTREPO_ROOT/$name"
  [ -n "$module" ] || module=editors

  if [ -z "${_EXTREPO_URL[$name]:-}" ]; then
    EXTREPO_NAMES+=("$name")
  fi
  _EXTREPO_URL[$name]=$url
  _EXTREPO_REF[$name]=$ref
  _EXTREPO_DEST[$name]=$dest
  _EXTREPO_LINK[$name]=$link
  _EXTREPO_LINKSRC[$name]=$link_src
  _EXTREPO_MODULE[$name]=$module
  _EXTREPO_ON[$name]=$enabled
  _EXTREPO_DESC[$name]=$desc
  return 0
}

# extrepo_load
#   Sources the shipped list, then yours. Idempotent — the second call is free, so
#   every module may call it without coordinating. A file that fails to parse costs
#   the entries below the error and nothing else. Always returns 0.
extrepo_load() {
  if [ "${_EXTREPO_LOADED:-0}" = 1 ]; then
    return 0
  fi
  _EXTREPO_LOADED=1
  local f rc
  for f in "${DEVENV_HOME:?}/config/external-repos.sh" \
    "${DEVENV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/devops-env}/external-repos.sh"; do
    [ -r "$f" ] || continue
    rc=0
    # shellcheck disable=SC1090  # a runtime path: the shipped list and the user's
    . "$f" || rc=$?
    if [ "$rc" -ne 0 ]; then
      log_warn "external-repos: $f did not load cleanly (exit $rc)"
      log_warn "  entries after the error in it were not declared — check it with: bash -n '$f'"
    fi
  done
  if [ "${#EXTREPO_NAMES[@]}" -eq 0 ]; then
    log_warn "external-repos: not one entry was declared. Expected at least the shipped list at"
    log_warn "  $DEVENV_HOME/config/external-repos.sh — is the checkout complete?"
  else
    log_debug "external-repos: ${#EXTREPO_NAMES[@]} entry(ies) declared"
  fi
  return 0
}

# extrepo_reset — drop every declaration and let extrepo_load run again.
#   For the unit tests, which build a list of their own. Always returns 0.
extrepo_reset() {
  EXTREPO_NAMES=()
  _EXTREPO_URL=()
  _EXTREPO_REF=()
  _EXTREPO_DEST=()
  _EXTREPO_LINK=()
  _EXTREPO_LINKSRC=()
  _EXTREPO_MODULE=()
  _EXTREPO_ON=()
  _EXTREPO_DESC=()
  _EXTREPO_LOADED=0
  return 0
}

# extrepo_known NAME — predicate: is NAME a declared entry? Read-only.
extrepo_known() {
  local name=${1-}
  [ -n "$name" ] || return 1
  [ -n "${_EXTREPO_URL[$name]:-}" ]
}

# extrepo_names [MODULE]
#   Prints entry names in declaration order, all of them or only those a module
#   owns. Read-only; always returns 0 (an empty list is not an error).
extrepo_names() {
  local want=${1-} n
  for n in ${EXTREPO_NAMES[0]+"${EXTREPO_NAMES[@]}"}; do
    if [ -n "$want" ] && [ "${_EXTREPO_MODULE[$n]:-}" != "$want" ]; then
      continue
    fi
    printf '%s\n' "$n"
  done
  return 0
}

# extrepo_get NAME FIELD
#   Prints one field: url ref dest link link_src module enabled desc.
#   Returns 1 (printing nothing) for an unknown entry or an unknown field, so
#   `dir=$(extrepo_get mybash dest) || dir=$fallback` reads correctly.
extrepo_get() {
  local name=${1:?extrepo_get: NAME required} field=${2:?extrepo_get: FIELD required}
  extrepo_known "$name" || return 1
  case $field in
    url) printf '%s\n' "${_EXTREPO_URL[$name]}" ;;
    ref) printf '%s\n' "${_EXTREPO_REF[$name]}" ;;
    dest) printf '%s\n' "${_EXTREPO_DEST[$name]}" ;;
    link) printf '%s\n' "${_EXTREPO_LINK[$name]}" ;;
    link_src) printf '%s\n' "${_EXTREPO_LINKSRC[$name]}" ;;
    module) printf '%s\n' "${_EXTREPO_MODULE[$name]}" ;;
    enabled) printf '%s\n' "${_EXTREPO_ON[$name]}" ;;
    desc) printf '%s\n' "${_EXTREPO_DESC[$name]}" ;;
    *) return 1 ;;
  esac
  return 0
}

# extrepo_switch NAME — prints the environment switch that turns NAME on or off.
#   `nvim-config` -> DEVENV_EXTREPO_NVIM_CONFIG. Read-only.
extrepo_switch() {
  local s=${1-}
  s=${s//[^A-Za-z0-9]/_}
  printf 'DEVENV_EXTREPO_%s\n' "${s^^}"
}

# extrepo_enabled NAME
#   PREDICATE. The environment switch wins over the entry's own `enabled=`, in both
#   directions, so one run can turn a shipped entry off as easily as on.
#   Returns 1 for an unknown entry. Read-only — safe inside `if`.
extrepo_enabled() {
  local name=${1-} var val
  extrepo_known "$name" || return 1
  var=$(extrepo_switch "$name")
  val=${!var:-}
  case $val in
    1 | yes | true | on) return 0 ;;
    0 | no | false | off) return 1 ;;
  esac
  [ "${_EXTREPO_ON[$name]:-0}" = 1 ]
}

# extrepo_place_link NAME   (the symlink half, on its own)
#   Points the entry's `link` at `link_src` inside its checkout.
#
#   What is at the destination decides what happens, and only one of the four cases
#   replaces anything:
#       nothing            -> the link is created
#       a symlink          -> re-pointed (this is how a moved checkout is repaired)
#       an EMPTY directory -> removed, then linked (~/.config/nvim is exactly this
#                             on a fresh box)
#       anything else      -> LEFT ALONE and reported. A real ~/.tmux.conf is a file
#                             somebody hand-patched; a non-empty ~/.config/nvim is
#                             somebody's config. Neither is ours to move.
#   Honours --dry-run. Always returns 0.
extrepo_place_link() {
  local name=${1:?extrepo_place_link: NAME required}
  local dest link link_src src
  extrepo_known "$name" || return 0
  dest=${_EXTREPO_DEST[$name]}
  link=${_EXTREPO_LINK[$name]}
  link_src=${_EXTREPO_LINKSRC[$name]}
  [ -n "$link" ] || return 0

  if [ ! -d "$dest" ]; then
    log_skip "$name: no checkout at $dest — $link was not linked"
    return 0
  fi
  src=$dest
  if [ -n "$link_src" ]; then
    src="$dest/${link_src#/}"
  fi
  if [ ! -e "$src" ]; then
    log_warn "$name: $src is not in the checkout — $link was not linked"
    return 0
  fi

  # -L before -d: a symlink TO a directory answers yes to both, and re-pointing it
  # is right while rmdir'ing it is not.
  if [ -L "$link" ]; then
    symlink_file "$src" "$link" || log_warn "$name: could not update the symlink $link"
    return 0
  fi
  if [ -d "$link" ]; then
    if [ -n "$(ls -A "$link" 2>/dev/null)" ]; then
      log_warn "$link is a non-empty directory — leaving your own config in place"
      log_warn "  move it aside and re-run if you want $name's:  mv '$link' '$link.bak'"
      return 0
    fi
    if is_dry_run; then
      log_dryrun "rmdir empty $link, then link it to $src"
      return 0
    fi
    run rmdir -- "$link" || {
      log_warn "$name: could not remove the empty directory $link — not linking it"
      return 0
    }
  elif [ -e "$link" ]; then
    log_info "$link is a regular file of your own — not touched, not overwritten"
    log_info "  $name is checked out at $dest; link it yourself if you want it"
    return 0
  fi
  symlink_file "$src" "$link" || log_warn "$name: could not create the symlink $link"
  return 0
}

# extrepo_sync NAME
#   Clones or fast-forwards one entry and places its symlink. A disabled entry is
#   skipped with the switch that would turn it on. An unreachable repository warns
#   and the run continues — that is the contract every caller relies on.
#   Honours --dry-run. ALWAYS returns 0.
extrepo_sync() {
  local name=${1:?extrepo_sync: NAME required}
  local url ref dest desc
  if ! extrepo_known "$name"; then
    log_warn "external-repos: no entry named '$name' — nothing to sync"
    return 0
  fi
  if ! extrepo_enabled "$name"; then
    log_skip "$name is not enabled — turn it on with $(extrepo_switch "$name")=1"
    return 0
  fi
  url=${_EXTREPO_URL[$name]}
  ref=${_EXTREPO_REF[$name]}
  dest=${_EXTREPO_DEST[$name]}
  desc=${_EXTREPO_DESC[$name]}
  [ -z "$desc" ] || log_debug "$name: $desc"

  devenv_sync_repo "$url" "$dest" "$ref" \
    || log_warn "could not sync $name from $url — keeping whatever is at $dest"
  extrepo_place_link "$name"
  return 0
}

# extrepo_sync_module MODULE
#   Every enabled entry that MODULE owns, in declaration order. This is the ONE
#   call a module makes. Loads the list if nobody has yet. ALWAYS returns 0.
extrepo_sync_module() {
  local module=${1:?extrepo_sync_module: MODULE required} n seen=0
  extrepo_load
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    seen=$((seen + 1))
    extrepo_sync "$n"
  done < <(extrepo_names "$module")
  if [ "$seen" -eq 0 ]; then
    log_debug "external-repos: no entry is owned by module '$module'"
  fi
  return 0
}

# extrepo_seed_user_list
#   Copies the shipped template to $DEVENV_CONFIG/external-repos.sh once, so the
#   file you extend is already there with its fields documented. NEVER overwrites
#   (copy_if_absent), honours --dry-run. Always returns 0.
extrepo_seed_user_list() {
  local src="${DEVENV_HOME:?}/config/external-repos.sh.example"
  local dir=${DEVENV_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/devops-env}
  [ -r "$src" ] || {
    log_debug "external-repos: no shipped template at $src"
    return 0
  }
  ensure_dir "$dir" || return 0
  copy_if_absent "$src" "$dir/external-repos.sh" 0644 \
    || log_warn "could not seed $dir/external-repos.sh"
  return 0
}
