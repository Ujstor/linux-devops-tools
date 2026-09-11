# shellcheck shell=bash
# config/external-repos.sh — the external config repositories this repository ships.
#
# THE list. Nothing else in this repository knows a config-repo URL, a ref or where
# a checkout's symlink goes; modules/50-editors.sh and modules/10-shell.sh each call
# `extrepo_sync_module <name>` and read what is below.
#
# Sourced by lib/extrepo.sh, which documents every field and every guarantee. Do not
# edit this file to add a repository of your own — put it in
#
#     ~/.config/devops-env/external-repos.sh
#
# which is sourced straight after this one, is never overwritten and is never
# committed. Declaring the same name there replaces the entry here in place, so that
# is also how you point one of these at your own fork.
#
# Refs are pinned in versions.env, as every version in this repository is. The
# `${…:-default}` fallbacks below are what keeps a checkout that predates a pin
# working rather than cloning the wrong branch.

# nvim-config — init.lua is at the repository ROOT, so the thing ~/.config/nvim must
# point at is the checkout directory itself (no link_src).
extrepo nvim-config \
  url=https://github.com/Ujstor/nvim-config.git \
  ref="${NVIM_CONFIG_REF:-master}" \
  link="${XDG_CONFIG_HOME:-$HOME/.config}/nvim" \
  module=editors \
  desc='neovim configuration (lua)'

# tmux-config — the file at the repository root is .tmux.conf, so the symlink target
# is that FILE inside the checkout, not the directory.
extrepo tmux-config \
  url=https://github.com/Ujstor/tmux-config.git \
  ref="${TMUX_CONFIG_REF:-master}" \
  link="$HOME/.tmux.conf" \
  link_src=.tmux.conf \
  module=editors \
  desc='tmux configuration'

# mybash — OFF by default, and that is a decision, not an oversight (MUST-FIX P8).
# mybash owns ~/.bashrc on a box that has it and its setup.sh symlinks that file;
# running it on a box that already has a ~/.bashrc is a data-loss event. Every
# ~/.bashrc.d fragment this repository ships works with it and without it, so
# nothing here needs it.
#
# enabled=1 CLONES IT AND NOTHING ELSE: no setup.sh, no symlink (link= is empty),
# no ~/.bashrc touched. modules/10-shell.sh prints the two commands that would adopt
# it, for you to run yourself.
#
#     DEVENV_EXTREPO_MYBASH=1 devenv --only shell
#     DEVENV_INSTALL_MYBASH=1 devenv --only shell     # the older spelling, still honoured
extrepo mybash \
  url=https://github.com/Ujstor/mybash.git \
  ref="${MYBASH_REF:-main}" \
  dest="$HOME/linuxtoolbox/mybash" \
  module=shell \
  enabled="${DEVENV_INSTALL_MYBASH:-0}" \
  desc='bash prompt and dotfiles — cloned only, never activated'
