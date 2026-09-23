# shellcheck shell=bash
# config/external-repos.sh — the external config repositories this repository ships.
#
# THE list. Nothing else in this repository knows a config-repo URL, a ref, where a
# checkout's symlink goes or how that checkout finishes installing itself;
# modules/50-editors.sh and modules/10-shell.sh each call `extrepo_sync_module
# <name>` and read what is below.
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
#
# ---------------------------------------------------------------------------
# WHY EACH ENTRY HAS A post= AND WHAT CHANGED
#
# These three are the whole point of
#
#     curl -fsSL https://raw.githubusercontent.com/Ujstor/linux-devops-tools/main/install.sh | bash
#
# and for two of them the symlink was never the whole install:
#
#   tmux-config  ~/.tmux.conf on its own is INERT. Every `set -g @plugin` line in
#                it is a no-op without ~/.tmux/plugins/tpm, so there was no
#                catppuccin theme, no tmux-resurrect and — the one people actually
#                notice — no tmux-yank, which is what binds `y` in copy mode. The
#                config even prints a yellow "TPM is not installed" bar in the
#                status line to say so. `bind q` / `bind a` also call ~/tmux.sh,
#                which nothing here installed either.
#   mybash       cloned but never activated, so its .bashrc, starship prompt and
#                fastfetch config sat in ~/linuxtoolbox/mybash doing nothing.
#
# Both repositories already ship an idempotent installer that backs up whatever it
# replaces — tmux-config's leaves a symlink it did not make alone, mybash's backs
# that up too and records every backup for its uninstall — so the post= step runs
# THAT, rather than this repository growing a second, drifting copy of their
# install logic. One source of truth per repository.
#
# Turn every post= step off for a run with DEVENV_EXTREPO_POST=0; you keep the
# checkouts and the symlinks and get nothing else.
# ---------------------------------------------------------------------------

# nvim-config — init.lua is at the repository ROOT, so the thing ~/.config/nvim must
# point at is the checkout directory itself (no link_src).
#
# No post=, deliberately. Its install.sh installs a PINNED neovim into /usr/local
# and bootstraps rustup to build the tree-sitter CLI; modules/50-editors.sh already
# installs both — neovim from upstream, the tree-sitter CLI at the same pin
# (TREE_SITTER_VERSION) — and lazy.nvim bootstraps its own plugins on the first
# launch. The symlink really is the whole install for this one.
extrepo nvim-config \
  url=https://github.com/Ujstor/nvim-config.git \
  ref="${NVIM_CONFIG_REF:-master}" \
  link="${XDG_CONFIG_HOME:-$HOME/.config}/nvim" \
  module=editors \
  desc='neovim configuration (lua)'

# tmux-config — the file at the repository root is .tmux.conf, so the symlink target
# is that FILE inside the checkout, not the directory.
#
# post= installs TPM, clones every plugin the config lists, and puts ~/tmux.sh in
# place. --keep-config: ~/.tmux.conf is this list's business — the symlink
# above, or a file of yours that it reports and leaves alone. A plain install.sh
# replaced such a file with a copy (backed up, but no longer following the
# checkout) straight after this repository had promised not to touch it.
extrepo tmux-config \
  url=https://github.com/Ujstor/tmux-config.git \
  ref="${TMUX_CONFIG_REF:-master}" \
  link="$HOME/.tmux.conf" \
  link_src=.tmux.conf \
  post='./install.sh --keep-config' \
  module=editors \
  desc='tmux configuration, TPM and its plugins'

# mybash — ON by default since 2026-09-15, which reverses the older MUST-FIX P8
# decision. That decision was made because "mybash owns ~/.bashrc and its setup.sh
# symlinks that file; running it on a box that already has a ~/.bashrc is a
# data-loss event". That is no longer true of mybash: its link_file() backs a real
# file up to ~/.bashrc.bak first, never overwrites an existing backup, and is a
# no-op when the link is already right.
#
# It declares no link= of its own — setup.sh links all THREE of its dotfiles
# (~/.bashrc, ~/.config/starship.toml, ~/.config/fastfetch/config.jsonc) and this
# list would only ever manage the first.
#
# post= is `setup.sh --config-only`: link the dotfiles, install nothing. A plain
# setup.sh also installs its tools, and here that is wrong twice over — it runs
# from the shell module, BEFORE this repository installs starship, zoxide, fzf and
# eza (pinned, checksum-verified) and before modules/50-editors.sh installs
# neovim, so it put unpinned copies from curl-piped vendor scripts into
# ~/.local/bin — ahead of ours on PATH, which then also satisfied our version
# gates — and pulled the distro neovim in next to the upstream one.
#
# Every ~/.bashrc.d fragment this repository ships still works with mybash and
# without it, so nothing here depends on the entry being on. Turn it off with
# DEVENV_EXTREPO_MYBASH=0 (or DEVENV_INSTALL_MYBASH=0, the older spelling).
extrepo mybash \
  url=https://github.com/Ujstor/mybash.git \
  ref="${MYBASH_REF:-main}" \
  dest="$HOME/linuxtoolbox/mybash" \
  post='./setup.sh --config-only' \
  module=shell \
  enabled="${DEVENV_INSTALL_MYBASH:-1}" \
  desc='bash prompt and dotfiles'
