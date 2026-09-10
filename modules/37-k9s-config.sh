#!/usr/bin/env bash
# meta: name=k9s-config
# meta: desc=the k9s plugins, hotkeys, aliases, skins and settings
# meta: profiles=devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=no
#
# The headline module. Everything it installs lives under $HOME, so it needs no
# privilege and runs on a box with no sudo at all.
#
# `needs=` IS DELIBERATELY EMPTY (SPEC §5.5 calls it "needs=k9s (soft)"). A hard
# `needs=k9s` would skip the module on a box where k9s is installed later, or
# installed from something other than PATH, and the payload is only YAML: writing
# it before k9s exists is harmless and means the first `k9s` is already
# configured. The k9s binary is only required for the two live steps at the end,
# and each checks for itself.
#
# THE FOUR WRITE STRATEGIES, one per kind of file, because k9s treats them
# differently:
#
#   plugins/*.yaml, skins/*.yaml   write_managed 0600
#       Files this repository OWNS. `write_managed` refreshes them when they are
#       ours or absent, and backs up + warns when they were hand-edited (unless
#       DEVENV_KEEP_LOCAL=1). 0600 because a plugin definition is a command line
#       that runs against your clusters.
#       plugins.yaml — the SINGULAR file, k9s's own — is NEVER touched: it is
#       where the user's own plugins live, and k9s reads plugins/*.yaml as well.
#
#   config.yaml                    awk merge  (MUST-FIX C4)
#       k9s rewrites this file in full every time it EXITS, so on any box that
#       has ever run k9s it already exists with every key at its default. A
#       create-if-absent install would land nothing; a whole-file overwrite would
#       discard the keys a newer k9s added. lib/awk/k9s-config-merge.awk forces
#       every leaf this repo ships onto the existing file and preserves the rest.
#
#   aliases.yaml, hotkeys.yaml     yaml_map_merge  (additive)
#       Purely additive: the user's own aliases and hotkeys survive, and only the
#       keys they do not already have are appended. Merging twice writes nothing.
#
# MUST-FIX C1/C2 (no duplicate or layout-dependent keys) are properties of the
# PAYLOAD in config/k9s/, and tests/k9s-keys.sh is what proves them. This module
# does not re-check what the test already owns.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

SRC_DIR="$DEVENV_HOME/config/k9s"

# k9s_config_dir
#   Prints the directory k9s actually reads. K9S_CONFIG_DIR wins, as it does for
#   k9s itself; otherwise $XDG_CONFIG_HOME/k9s. Always returns 0.
k9s_config_dir() {
  printf '%s\n' "${K9S_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/k9s}"
}

# install_dir_payload SUBDIR
#   write_managed every *.yaml from $SRC_DIR/SUBDIR into $cfg/SUBDIR at 0600.
#   Returns 0; a file that cannot be written is a warning, not a failure — one
#   bad skin must not cost you the other eleven plugins.
install_dir_payload() {
  local sub=$1 f dest n=0
  [ -d "$SRC_DIR/$sub" ] || {
    log_warn "$SRC_DIR/$sub is missing from this checkout"
    return 0
  }
  ensure_dir "$(k9s_config_dir)/$sub" 0755 || return 0
  for f in "$SRC_DIR/$sub"/*.yaml; do
    [ -f "$f" ] || continue
    dest="$(k9s_config_dir)/$sub/${f##*/}"
    write_managed "$dest" 0600 <"$f" || log_warn "could not write $dest"
    n=$((n + 1))
  done
  log_info "$sub: $n file(s) in $(k9s_config_dir)/$sub"
  return 0
}

# install_config_yaml
#   The C4 merge. Absent -> written verbatim, comments and all. Present -> the
#   awk merge, and the result is only written when it differs, so a second run
#   takes no backup and prints nothing.
install_config_yaml() {
  local src="$SRC_DIR/config.yaml" dest merged
  dest="$(k9s_config_dir)/config.yaml"
  [ -f "$src" ] || {
    log_warn "$src is missing from this checkout"
    return 0
  }

  if [ ! -f "$dest" ]; then
    write_if_changed "$dest" 0644 <"$src" || log_warn "could not write $dest"
    return 0
  fi

  if [ "${K9S_KEEP_LOCAL:-${DEVENV_KEEP_LOCAL:-0}}" = 1 ]; then
    log_skip "K9S_KEEP_LOCAL=1 — leaving $dest exactly as it is"
    return 0
  fi

  merged=$(devenv_tmpfile) || return 0
  if ! awk -f "$DEVENV_HOME/lib/awk/k9s-config-merge.awk" "$src" "$dest" >"$merged"; then
    log_warn "could not merge the k9s settings into $dest — leaving it alone"
    return 0
  fi
  # A merge that produced nothing, or lost the root key, is a bug in the awk
  # program, not a licence to truncate the user's config.
  if [ ! -s "$merged" ] || ! grep -q '^k9s:' "$merged"; then
    log_warn "the k9s config merge produced an unusable file — leaving $dest alone"
    return 0
  fi
  if cmp -s -- "$merged" "$dest"; then
    log_debug "$dest already carries every setting this repo owns"
    return 0
  fi
  write_if_changed "$dest" 0644 <"$merged" || log_warn "could not write $dest"
  return 0
}

# merge_map FILE ROOT_KEY
#   The additive merge for aliases.yaml (root `aliases`) and hotkeys.yaml
#   (root `hotKeys`).
merge_map() {
  local name=$1 root=$2 src="$SRC_DIR/$1" dest
  dest="$(k9s_config_dir)/$name"
  [ -f "$src" ] || {
    log_warn "$src is missing from this checkout"
    return 0
  }
  yaml_map_merge "$dest" "$root" 0644 <"$src" || log_warn "could not merge $dest"
  return 0
}

# apply_skin
#   Points the per-context k9s config at the right skin for the cluster you are
#   on — green for dev, amber for uat, red-and-read-only for prod. That decision
#   needs a live kubeconfig, so it is guarded three ways and never fails the
#   module.
#
#   bin/k9s-skin is a separate deliverable. Until it exists this prints the one
#   line that tells you the skins ARE installed and how the global default is
#   set, instead of pretending the feature is missing.
apply_skin() {
  local skinner="$DEVENV_HOME/bin/k9s-skin"
  if [ ! -x "$skinner" ]; then
    log_debug "bin/k9s-skin is not in this checkout — the global skin from config.yaml applies"
    return 0
  fi
  if ! have kubectl; then
    log_skip "no kubectl — cannot tell which cluster you are on, keeping the global skin"
    return 0
  fi
  if ! kubectl config current-context >/dev/null 2>&1; then
    log_skip "no current kubeconfig context — keeping the global skin"
    return 0
  fi
  run "$skinner" --auto || log_warn "k9s-skin --auto failed — the global skin still applies"
  return 0
}

# reload_hint
#   `ui.reactive: true` makes k9s re-read skins, aliases, plugins and hotkeys
#   without a restart, so a running instance picks all of this up live. Worth one
#   line, and only when there is something to say.
reload_hint() {
  have pgrep || return 0
  pgrep -x k9s >/dev/null 2>&1 || return 0
  log_info "k9s is running: 'ui.reactive: true' means it picks this up live — no restart needed."
  return 0
}

module_main() {
  local cfg
  cfg=$(k9s_config_dir)
  log_info "k9s configuration in $cfg"
  ensure_dir "$cfg" 0755 || die "cannot create $cfg"

  install_config_yaml
  merge_map aliases.yaml aliases
  merge_map hotkeys.yaml hotKeys
  install_dir_payload plugins
  install_dir_payload skins

  if ! have k9s; then
    log_info "k9s itself is not installed yet (modules/35-kubernetes.sh installs it);"
    log_info "  the configuration above is already in place for when it is."
  fi

  apply_skin
  reload_hint
  return 0
}

module_main "$@"
