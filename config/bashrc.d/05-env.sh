# shellcheck shell=bash
# ~/.bashrc.d/05-env.sh — linux-devops-tools :: environment defaults.
#
# Everything here is SET-IF-UNSET, so an earlier ~/.bashrc (mybash, or your own)
# always wins. Exactly one fork happens in this file: the `tty` call gpg needs,
# and only in a shell that actually has a terminal.

# Per-host shell settings, if you made them. ~/.bashrc.d/90-local.sh loads LAST,
# which is too late for the toggles the later fragments read at load time
# (ENABLE_NALA_ALIAS, DEVENV_KEEP_GREP_ALIAS, DEVENV_NODE_MANAGER,
# DEVENV_KUBE_GUARD, KUBE_PROD_PATTERN, DEVENV_CLIP_BACKEND, …). This is not.
# The file is yours: this repo creates it never and overwrites it never.
if [ -r "${DEVENV_CONF:-$HOME/.config/devops-env}/shell.env" ]; then
  # shellcheck source=/dev/null
  . "${DEVENV_CONF:-$HOME/.config/devops-env}/shell.env"
fi

# --- XDG base directories --------------------------------------------------
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_DATA_HOME:=$HOME/.local/share}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
export XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME

# --- editor ----------------------------------------------------------------
# `command -v` is a builtin, so this costs nothing.
if [ -z "${EDITOR:-}" ]; then
  if command -v nvim >/dev/null 2>&1; then
    EDITOR=nvim
  elif command -v vim >/dev/null 2>&1; then
    EDITOR=vim
  else
    EDITOR='vi'
  fi
  export EDITOR
fi
: "${VISUAL:=$EDITOR}"
export VISUAL

# --- pager -----------------------------------------------------------------
# -R keeps colour escapes. Without it `git log`, kubecolor and delta render
# their colours as literal escape sequences.
: "${LESS:=-R}"
: "${LESSHISTFILE:=${XDG_STATE_HOME:-$HOME/.local/state}/less_history}"
export LESS LESSHISTFILE

# --- gpg -------------------------------------------------------------------
# gpg has to know which terminal to prompt on, or a signed commit dies with
# "Inappropriate ioctl for device". This box signs every commit by default.
if [ -z "${GPG_TTY:-}" ] && [ -t 0 ]; then
  GPG_TTY=$(tty 2>/dev/null) && export GPG_TTY
fi

# --- history ---------------------------------------------------------------
# ignoreboth = ignorespace + ignoredups; erasedups also drops older duplicates.
# histappend is what stops two terminals from truncating each other's history.
HISTCONTROL=ignoreboth:erasedups
HISTSIZE=100000
HISTFILESIZE=200000
HISTTIMEFORMAT='%F %T '
HISTIGNORE='ls:ll:la:cd:pwd:exit:clear:c:history'
shopt -s histappend cmdhist checkwinsize

# --- libvirt ---------------------------------------------------------------
# Only when virsh is genuinely installed. Exporting it unconditionally makes
# every unrelated tool that reads LIBVIRT_DEFAULT_URI believe a hypervisor is
# configured here.
if [ -z "${LIBVIRT_DEFAULT_URI:-}" ] && command -v virsh >/dev/null 2>&1; then
  export LIBVIRT_DEFAULT_URI='qemu:///system'
fi
