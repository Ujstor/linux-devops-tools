# shellcheck shell=bash
# ~/.bashrc.d/40-shellui.sh — devops-env-config :: fzf, starship, zoxide.
#
# The only startup-time completion work in the whole set. Everything else is
# lazy-loaded by bash-completion from the generated cache.

# --- fzf -------------------------------------------------------------------
# A real, verified Debian/Ubuntu divergence:
#   bookworm 0.38.0 / noble 0.44.1  -> NO `fzf --bash`, ship example scripts
#   trixie 0.60.3 / questing 0.60.3 -> HAS `fzf --bash`
# One fork either way: capture the generator's output and decide on the result.
if command -v fzf >/dev/null 2>&1; then
  _devenv_fzf=$(fzf --bash 2>/dev/null) || _devenv_fzf=''
  if [ -n "$_devenv_fzf" ]; then
    eval "$_devenv_fzf"
  else
    # NOT _devenv_f: that is 00-init.bash's own loop variable, and unsetting it
    # here would blank the fragment name in the DEVENV_DEBUG timing line.
    for _devenv_fzf_src in /usr/share/doc/fzf/examples/key-bindings.bash \
      /usr/share/fzf/key-bindings.bash \
      /usr/share/bash-completion/completions/fzf; do
      if [ -r "$_devenv_fzf_src" ]; then
        # shellcheck source=/dev/null
        . "$_devenv_fzf_src"
        break
      fi
    done
  fi
  unset _devenv_fzf _devenv_fzf_src

  export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:---height=40% --layout=reverse --border --info=inline}"
  # Debian and Ubuntu both rename the binary to `fdfind`; a ~/.local/bin/fd
  # symlink is installed by the shell module, so prefer the real name first.
  if [ -z "${FZF_DEFAULT_COMMAND:-}" ]; then
    if command -v fd >/dev/null 2>&1; then
      export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
    elif command -v fdfind >/dev/null 2>&1; then
      export FZF_DEFAULT_COMMAND='fdfind --type f --hidden --exclude .git'
    fi
  fi
fi

# --- prompt and jump -------------------------------------------------------
# mybash already runs both of these. Double-initialising starship duplicates
# PROMPT_COMMAND entries, so init only when nothing else did.
if ! declare -F starship_precmd >/dev/null 2>&1 && command -v starship >/dev/null 2>&1; then
  eval "$(starship init bash)"
fi
if ! declare -F __zoxide_z >/dev/null 2>&1 && command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi
