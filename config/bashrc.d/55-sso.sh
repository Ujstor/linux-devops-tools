# ~/.bashrc.d/55-sso.sh — devops-env-config :: SSO / web-login environment.
# shellcheck shell=bash
# Loads after 50-platform.sh, which owns $BROWSER and $DEVENV_BROWSER_MODE.
# The number 55 is shared with modules/55-media.sh — different namespace, no
# collision. Do not "fix" it by renumbering: it must load after 50-platform.sh
# and before 60-aliases.sh.

# Per-host, gitignored, mode 0600. The ONLY place a real hostname is written.
# shellcheck source=/dev/null
[ -r "$HOME/.config/devops-env/sso.env" ] && . "$HOME/.config/devops-env/sso.env"

# az reads $BROWSER through python webbrowser. can_launch_browser() returns True
# as soon as webbrowser.get() succeeds, which SUPPRESSES az's own device-code
# fallback and starts an authcode flow on a random loopback port that nothing
# can tunnel. On a print-mode host, put the fallback back.
# Resolved at CALL time, not at shell start: zero startup cost, and correct when
# the same ~/.bashrc is used in a WSL pane and an SSH pane.
if command -v az >/dev/null 2>&1; then
  az() {
    if [ "${1:-}" = login ] && [ "$(open-url --mode 2>/dev/null)" = print ]; then
      case " $* " in
        *" --use-device-code "* | *" --service-principal "* | *" --identity "* | *" --federated-token "*)
          command az "$@"
          ;;
        *)
          printf 'devenv: no local browser on this host - adding --use-device-code\n' >&2
          command az "$@" --use-device-code
          ;;
      esac
    else
      command az "$@"
    fi
  }
fi
