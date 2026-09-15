#!/usr/bin/env bash
# meta: name=root-configs
# meta: desc=give root the same nvim, tmux and bash configuration as your user
# meta: profiles=devops,full
# meta: os=any
# meta: needs=git
# meta: root=yes
#
# `sudo -i`, `sudo su -` and a root login shell read ROOT's dotfiles, not yours.
# On a box configured only for the invoking user that means root gets a bare bash
# prompt, a tmux with no prefix and none of its plugins, and a vi that is not
# neovim — which is exactly the moment you are doing something delicate and want
# your own tools. This module closes that gap: the same entries from
# config/external-repos.sh, cloned into root's home and linked from root's
# dotfiles, so the two accounts genuinely match.
#
# root=yes in the meta, so lib/registry.sh skips the whole module (with a line
# saying why) on a box where the user is not a sudoer. There is nothing useful
# this module can do without root, so unlike 50-editors.sh there is no half of it
# worth running unprivileged.
#
# WHICH repositories is not written here either. The list is read from
# lib/extrepo.sh and piped to config/root-configs.sh, so adding a fourth checkout
# still means editing one data file and nothing else.
#
# SWITCH: DEVENV_ROOT_CONFIGS=0 skips it entirely.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

ROOT_HELPER="$DEVENV_HOME/config/root-configs.sh"

# root_config_entries
#   The list, as 0x1f-separated rows for config/root-configs.sh — NOT tabs; see
#   the header of that script for why an empty field must not collapse. Only ENABLED
#   entries are mirrored, so DEVENV_EXTREPO_MYBASH=0 turns mybash off for root in
#   the same breath as for the user — one switch, both accounts.
#
#   `dest` is deliberately NOT passed through. The user's mybash entry points at
#   $HOME/linuxtoolbox/mybash; mirroring that verbatim would put root's checkout
#   inside the USER's home, where a non-root user could edit what root's login
#   shell sources. config/root-configs.sh always derives dest under root's own
#   HOME instead. `link` is passed as written and is expanded there for the same
#   reason — see the loop below.
root_config_entries() {
  local n url ref link link_src post
  extrepo_load
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    extrepo_enabled "$n" || continue
    url=$(extrepo_get "$n" url) || continue
    ref=$(extrepo_get "$n" ref) || ref=''
    link=$(extrepo_get "$n" link) || link=''
    link_src=$(extrepo_get "$n" link_src) || link_src=''
    post=$(extrepo_get "$n" post) || post=''

    # The link was computed against the USER's $HOME when the list was sourced,
    # so re-anchor it on root's home. A link that was NOT under $HOME — an
    # XDG_CONFIG_HOME pointing somewhere else, an /etc path — is DROPPED rather
    # than passed through: mirroring it verbatim would point root's dotfile at a
    # path outside root's home, which is the one thing the helper exists to
    # prevent. The checkout is still made; only the symlink is left to you.
    case $link in
      '') ;;
      "$HOME"/*) link="/root/${link#"$HOME"/}" ;;
      *)
        log_warn "root-configs: $n's link ($link) is not under \$HOME — not mirrored for root"
        log_warn "  root gets the checkout; link it yourself if that is what you want"
        link=''
        ;;
    esac

    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$n" "$url" "$ref" "$link" "$link_src" "$post"
  done < <(extrepo_names)
  return 0
}

module_main() {
  log_step "root-configs"

  case ${DEVENV_ROOT_CONFIGS:-1} in
    0 | no | false | off)
      log_skip "DEVENV_ROOT_CONFIGS=0 — root's dotfiles were not touched"
      log_step_end
      return 0
      ;;
  esac

  if [ ! -r "$ROOT_HELPER" ]; then
    log_warn "config/root-configs.sh is missing from the checkout — root was not configured"
    log_step_end
    return 0
  fi

  if ! have_root; then
    log_skip "no usable sudo — root's dotfiles were not touched"
    log_step_end
    return 0
  fi

  local entries
  entries=$(root_config_entries)
  if [ -z "$entries" ]; then
    log_skip "no enabled external-repo entries — nothing to mirror into root's home"
    log_step_end
    return 0
  fi

  log_info "mirroring $(printf '%s\n' "$entries" | wc -l | tr -d ' ') config repo(s) into /root"
  log_info "  turn this off with DEVENV_ROOT_CONFIGS=0"

  # -H is the whole point: it sets HOME=/root, which is what the helper and every
  # post script anchor on. Without it sudo keeps the caller's HOME and mybash's
  # setup.sh would relink the USER's ~/.bashrc a second time.
  #
  # DEVENV_DRY_RUN and DEVENV_EXTREPO_POST are forwarded by hand: the helper
  # honours both, and a --dry-run that silently became a real run for root is the
  # one failure mode here that would actually hurt.
  #
  # The three -u are not belt-and-braces. Run this from inside tmux — which is
  # how anyone actually runs it — and your environment carries TMUX and
  # TMUX_PLUGIN_MANAGER_PATH. sudo's env_reset normally drops them, but a sudoers
  # with a generous env_keep does not, and then the tmux server root's TPM talks
  # to is YOURS: `install_plugins` reports "Already installed" for every plugin,
  # having checked /home/<you>/.tmux/plugins, and root ends up with TPM and no
  # plugins at all. Seen exactly that way while testing this module.
  if printf '%s\n' "$entries" | run_sudo -H env \
    -u TMUX -u TMUX_PLUGIN_MANAGER_PATH -u TMUX_TMPDIR \
    DEVENV_DRY_RUN="${DEVENV_DRY_RUN:-0}" \
    DEVENV_EXTREPO_POST="${DEVENV_EXTREPO_POST:-1}" \
    bash "$ROOT_HELPER"; then
    is_dry_run || changed "root dotfiles"
  else
    log_warn "mirroring the config repos into /root did not finish cleanly"
    log_warn "  your own configuration is unaffected; re-run with --only root-configs"
  fi

  log_step_end
  return 0
}

module_main "$@"
