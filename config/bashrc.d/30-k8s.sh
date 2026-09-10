# shellcheck shell=bash
# ~/.bashrc.d/30-k8s.sh — linux-devops-tools :: kubernetes shell ergonomics.
#
# KUBECONFIG is deliberately NOT merged. With ~40 files in ~/.kube, "the first
# file to set a value wins", `current-context` comes from whichever file sorted
# first, and `kubectl config use-context` / `kubens` write back into that same
# file. One kubeconfig per cluster in ~/.kube/clusters, selected per shell with
# `kc`, is the fleet-operator's actual working mode.
#
# No tool completions are registered here — they live in the lazy completion
# cache under ~/.local/share/bash-completion/completions. The one exception is
# `kc`, which is our own function and runs its `find` at TAB time, not at start.

export KREW_ROOT="${KREW_ROOT:-$HOME/.krew}"
export KUBE_CLUSTER_DIR="${KUBE_CLUSTER_DIR:-$HOME/.kube/clusters}"
export KUBECACHEDIR="${KUBECACHEDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/kube}"

# --- kc: pick a cluster for THIS shell -------------------------------------
#   kc            fzf picker over ~/.kube/clusters
#   kc <name>     select directly
#   kc -          unset KUBECONFIG (back to ~/.kube/config)
kc() {
  local pick f
  case "${1:-}" in
    -)
      unset KUBECONFIG
      printf 'KUBECONFIG unset (-> ~/.kube/config)\n'
      return 0
      ;;
    '')
      command -v fzf >/dev/null 2>&1 || {
        printf 'kc: fzf is not installed; pass a cluster name.\n' >&2
        _devenv_kc_names
        return 2
      }
      pick=$(_devenv_kc_names | fzf --prompt='cluster> ' --preview \
        "kubectl --kubeconfig=$KUBE_CLUSTER_DIR/{}.yaml config get-contexts 2>/dev/null") || return 1
      ;;
    *) pick=$1 ;;
  esac
  [ -n "$pick" ] || return 1
  for f in "$KUBE_CLUSTER_DIR/$pick.yaml" "$KUBE_CLUSTER_DIR/$pick.yml"; do
    if [ -r "$f" ]; then
      export KUBECONFIG="$f"
      kubectl config current-context 2>/dev/null
      return 0
    fi
  done
  printf 'kc: no such cluster: %s (looked in %s)\n' "$pick" "$KUBE_CLUSTER_DIR" >&2
  return 1
}

_devenv_kc_names() {
  find "$KUBE_CLUSTER_DIR" -maxdepth 1 -type f \
    \( -name '*.yaml' -o -name '*.yml' \) -printf '%f\n' 2>/dev/null \
    | sed -e 's/\.ya\?ml$//' | sort
}

_devenv_kc_complete() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  local names
  names=$(_devenv_kc_names)
  mapfile -t COMPREPLY < <(compgen -W "$names -" -- "$cur")
}
complete -F _devenv_kc_complete kc

# --- kubectl / kubecolor / k ----------------------------------------------
DEVENV_KUBE_BIN=kubectl
if command -v kubecolor >/dev/null 2>&1; then
  DEVENV_KUBE_BIN=kubecolor
  export KUBECOLOR_PRESET="${KUBECOLOR_PRESET:-dark}"
  # `watch` gives kubecolor a pipe, so colour has to be forced.
  alias kwatch='KUBECOLOR_FORCE_COLORS=auto watch --color '
fi

# The prod guard is opt-in and replaces the alias, because an alias would be
# expanded before a function of the same name is ever consulted.
if [ "${DEVENV_KUBE_GUARD:-0}" = 1 ]; then
  export KUBE_PROD_PATTERN="${KUBE_PROD_PATTERN:-prod}"
  unalias kubectl 2>/dev/null
  kubectl() {
    local ctx answer
    case "${1:-}" in
      delete | drain | cordon | uncordon | taint | scale | apply | replace | patch | edit | rollout)
        ctx=$(command kubectl config current-context 2>/dev/null) || ctx=''
        if [ -n "$ctx" ] && printf '%s' "$ctx" | grep -qiE "$KUBE_PROD_PATTERN"; then
          printf 'devenv: context "%s" matches KUBE_PROD_PATTERN.\n' "$ctx" >&2
          # shellcheck disable=SC2016  # backticks are prose in the prompt text
          printf 'devenv: retype the context name to run `kubectl %s`: ' "$1" >&2
          read -r answer
          if [ "$answer" != "$ctx" ]; then
            printf 'devenv: aborted.\n' >&2
            return 1
          fi
        fi
        ;;
    esac
    command "$DEVENV_KUBE_BIN" "$@"
  }
elif [ "$DEVENV_KUBE_BIN" != kubectl ]; then
  alias kubectl='kubecolor'
fi
alias k='kubectl'

# --- kubectx / kubens ------------------------------------------------------
# Functions, not aliases: `bind -x` runs a command string in which aliases are
# not expanded, and functions compose in pipes.
if command -v kubectx >/dev/null 2>&1; then
  kx() { command kubectx "$@"; }
  kn() { command kubens "$@"; }
elif command -v kubectl >/dev/null 2>&1; then
  kx() { command kubectl ctx "$@"; } # krew fallback
  kn() { command kubectl ns "$@"; }
fi

# Ctrl-o -> cluster picker. Ctrl-x n -> namespace picker.
# NOT Ctrl-n: that is readline's `next-history` and rebinding it costs more than
# the picker saves. Bind it yourself in 90-local.sh if you disagree.
if [ -n "${PS1:-}" ]; then
  bind -x '"\C-o": kc' 2>/dev/null
  bind -x '"\C-x n": kn' 2>/dev/null
fi
