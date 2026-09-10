#!/usr/bin/env bash
# meta: name=auth-sso
# meta: desc=browser shim plus sso/web-login helpers and templates (keycloak, azure, github, gitlab, argo cd, openbao)
# meta: profiles=devops,full
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=no
#
# SPEC-ADDENDUM §2 + §3. This module installs NO new binaries on the default path:
# every CLI the login flows use (kubectl, az, gh, glab, argocd, bao) is installed by
# another module. What it ships is config, shims and helpers.
#
# It NEVER runs an interactive login — an installer must not open a browser flow —
# and it NEVER touches ~/.kube/config. `sso-login` and `sso-kubeconfig-add` are the
# separate, explicit, confirming commands for that.
#
# Everything it writes goes through lib/fs.sh, so the manifest tracks it, a hand-edit
# is detected instead of clobbered, --dry-run is a true no-op, and `devenv uninstall`
# can take it all back out.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

BIN_DIR="${DEVENV_BIN_DIR:-$HOME/.local/bin}"
LIB_DIR="${DEVENV_SHIM_LIB_DIR:-$HOME/.local/lib/devops-env}"

# install_payload SRC_REL DEST [MODE]
#   Installs a shipped payload from the checkout with write_managed.
install_payload() {
  local src="$DEVENV_HOME/$1" dest=$2 mode=${3:-0644}
  if [ ! -r "$src" ]; then
    log_error "missing payload: $src"
    return 1
  fi
  write_managed "$dest" "$mode" <"$src"
}

# link_shim TARGET LINK
#   Symlink LINK -> TARGET, tolerating the dry-run case where TARGET has not been
#   written yet (it would have been, earlier in this same run).
link_shim() {
  local target=$1 link=$2
  if [ ! -e "$target" ]; then
    if is_dry_run; then
      log_info "would link ${link##*/} -> ${target##*/}"
      return 0
    fi
    log_warn "cannot link $link: $target is missing"
    return 1
  fi
  symlink_file "$target" "$link" || return 1
  manifest_record "$link"
  return 0
}

install_shims() {
  ensure_dir "$BIN_DIR" 0755
  ensure_dir "$LIB_DIR" 0755

  # The runtime detection library the three shims source. Deliberately NOT lib/os.sh:
  # this one runs in the user's shell and inside processes spawned by kubectl.
  install_payload config/lib/detect.sh "$LIB_DIR/detect.sh" 0644

  install_payload config/bin/open-url "$BIN_DIR/open-url" 0755
  install_payload config/bin/clip "$BIN_DIR/clip" 0755
  install_payload config/bin/clip-paste "$BIN_DIR/clip-paste" 0755
  install_payload config/bin/sso-login "$BIN_DIR/sso-login" 0755
  install_payload config/bin/sso-kubeconfig-add "$BIN_DIR/sso-kubeconfig-add" 0755
  install_payload config/bin/web "$BIN_DIR/web" 0755

  # Four browser names, not one: kubectl oidc-login and bao go through
  # github.com/pkg/browser (xdg-open -> x-www-browser -> www-browser) and argocd
  # through skratchdot/open-golang (xdg-open) — none of them reads $BROWSER.
  # Shadowing www-browser is also what stops the www-browser alternative (lynx on
  # this box) from seizing the TTY in the middle of a kubectl call.
  local n
  for n in xdg-open x-www-browser www-browser sensible-browser; do
    link_shim "$BIN_DIR/open-url" "$BIN_DIR/$n" || true
  done
  link_shim "$BIN_DIR/clip" "$BIN_DIR/pbcopy" || true
  link_shim "$BIN_DIR/clip-paste" "$BIN_DIR/pbpaste" || true
}

install_fragment() {
  bashrc_dropin 55-sso.sh <"$DEVENV_HOME/config/bashrc.d/55-sso.sh"
}

# The per-host settings file. Seeded ONCE from the example and never overwritten:
# it is the only file on the box that carries a real issuer URL.
seed_settings() {
  ensure_dir "$DEVENV_CONFIG" 0700
  ensure_dir "$DEVENV_CONFIG/kube" 0755
  ensure_dir "$DEVENV_CONFIG/tmux" 0755

  copy_if_absent "$DEVENV_HOME/config/sso/sso.env.example" "$DEVENV_CONFIG/sso.env" 0600
  copy_if_absent "$DEVENV_HOME/config/sso/bookmarks.example" "$DEVENV_CONFIG/bookmarks" 0600

  install_payload config/kube/oidc-user.template.yaml \
    "$DEVENV_CONFIG/kube/oidc-user.template.yaml" 0644
  install_payload config/tmux/devenv-clipboard.conf \
    "$DEVENV_CONFIG/tmux/devenv-clipboard.conf" 0644

  # A settings file holding an issuer URL must not be world-readable.
  local mode
  if [ -f "$DEVENV_CONFIG/sso.env" ]; then
    mode=$(stat -c '%a' -- "$DEVENV_CONFIG/sso.env" 2>/dev/null || printf '600')
    case $mode in
      600 | 400) ;;
      *)
        log_warn "$DEVENV_CONFIG/sso.env is mode $mode — tightening it to 600"
        run chmod 600 -- "$DEVENV_CONFIG/sso.env"
        ;;
    esac
  fi
}

# qrencode is the ONLY package this module may install, and only on request.
install_optional_qr() {
  [ "${DEVENV_BROWSER_QR:-0}" = 1 ] || return 0
  if have qrencode; then
    log_debug "qrencode already installed"
    return 0
  fi
  if ! have_root; then
    log_skip "DEVENV_BROWSER_QR=1 but qrencode needs root to install — skipping"
    return 0
  fi
  pkg_install_optional qrencode
}

# Everything below only LOOKS and REPORTS.
report_environment() {
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      log_warn "$BIN_DIR is not on PATH in this process."
      log_warn "  ~/.bashrc.d/10-path.sh prepends it; open a new shell (exec bash -l)."
      ;;
  esac

  local resolved
  resolved=$(command -v xdg-open 2>/dev/null || true)
  if [ -n "$resolved" ] && [ "$resolved" != "$BIN_DIR/xdg-open" ]; then
    log_warn "xdg-open currently resolves to $resolved, not $BIN_DIR/xdg-open."
    log_warn "  $BIN_DIR must come BEFORE /usr/bin on PATH or the Go CLIs miss the shim."
  fi

  if have kubectl; then
    # Checked on disk, never by running the plugin: `kubectl oidc-login version`
    # creates ~/.kube/cache/oidc-login and a lock file, and this module has no
    # business writing there.
    if [ ! -x "${KREW_ROOT:-$HOME/.krew}/bin/kubectl-oidc_login" ] && ! have kubectl-oidc_login; then
      log_skip "kubectl oidc-login (krew 'oidc-login') is not installed — Keycloak logins need it"
      log_info "  install it with:  devenv --only k8s-plugins    (or: kubectl krew install oidc-login)"
    fi
  else
    log_skip "kubectl is not installed — the Keycloak flow is unavailable on this box"
  fi

  # Two unrelated projects ship a binary called `kubelogin`. krew is safe (it
  # installs int128's as kubectl-oidc_login, outside PATH); `go install
  # github.com/int128/kubelogin` is not — it silently overwrites Azure's.
  if have kubelogin && ! kubelogin convert-kubeconfig --help >/dev/null 2>&1; then
    log_warn "the 'kubelogin' on PATH is int128/kubelogin, not Azure/kubelogin — AKS conversion will fail."
    log_warn "  fix:  go install github.com/Azure/kubelogin/cmd/kubelogin@latest"
    log_warn "  int128's belongs in krew only. Never 'go install' it, and never alias around this:"
    log_warn "  an alias does not affect an 'exec' entry in a kubeconfig."
  fi

  if have tmux && [ -f "$HOME/.tmux.conf" ]; then
    if ! grep -Fq 'devops-env/tmux/devenv-clipboard.conf' "$HOME/.tmux.conf"; then
      log_info "tmux: this repo never edits ~/.tmux.conf. Add this line yourself to get"
      log_info "  portable copy/paste:"
      log_info "  source-file ~/.config/devops-env/tmux/devenv-clipboard.conf"
    fi
    if grep -qE '^[[:space:]]*set-environment[[:space:]]+-g[[:space:]]+DISPLAY' "$HOME/.tmux.conf"; then
      log_warn "tmux: ~/.tmux.conf sets DISPLAY unconditionally — inside tmux a headless box then"
      log_warn "  looks graphical to every browser-opening tool. Delete that line upstream."
    fi
  fi

  if [ ! -s "$DEVENV_CONFIG/sso.env" ]; then
    log_info "fill in $DEVENV_CONFIG/sso.env before the first login (placeholders only today)"
  fi
}

print_next_steps() {
  log_info ''
  log_info "browser mode on this host: $(
    "$BIN_DIR/open-url" --mode 2>/dev/null || printf 'unknown (run open-url --mode in a new shell)'
  )"
  log_info 'next steps — this module never logs in for you:'
  log_info "  1. edit  $DEVENV_CONFIG/sso.env      (issuer, client id, contexts)"
  log_info '  2. sso-kubeconfig-add --context <ctx>   (add --headless with no tunnel)'
  log_info '  3. sso-login k8s        then  sso-login --status'
  log_info '  the full runbook, including the ssh -L tunnel table, is docs/sso.md'
}

module_main() {
  install_shims
  install_fragment
  seed_settings
  install_optional_qr
  report_environment
  print_next_steps
}

module_main "$@"
