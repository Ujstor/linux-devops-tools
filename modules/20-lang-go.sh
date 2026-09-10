#!/usr/bin/env bash
# meta: name=lang-go
# meta: desc=the go toolchain from the upstream tarball, plus the pinned go tools
# meta: profiles=minimal,devops,full,ci
# meta: os=any
# meta: needs=
# meta: root=yes
#
# SPEC §5.5. Go comes from the upstream tarball into /usr/local/go, because the
# distro packages lag badly (bookworm ships 1.19) and because `go install` of a
# module that requires a newer toolchain then fails in a way that looks like a
# network error.
#
# Four things the old scripts/tools.sh did that are NOT done here (SPEC §8):
#   * `sed -i` on ~/.bashrc to delete `export GOPATH` lines. That command, run
#     against an 802-line hand-tuned file with no backup, is what REPLACED the
#     mybash symlink with a regular file. The Go environment lives in
#     ~/.bashrc.d/20-lang.sh, written whole, every time.
#   * `go clean -modcache` on every run — deleting a multi-GB cache and forcing a
#     full re-download of every dependency of every project, to install one tool.
#   * a hello-world compile as a "test". `go env GOVERSION` answers the same
#     question without a temp directory.
#   * `sudo chown -R $USER:$USER /home/$USER`, which rewrites ~/go/pkg/mod (which
#     is deliberately read-only), ~/.krew, and every mounted Windows path.
set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

GOROOT_DIR=/usr/local/go

# The pinned Go tools, `module@version  binary` per line. versions.env owns every
# pin; nothing here may hardcode one.
#   goimports      golang.org/x/tools — no release tags worth pinning, floats
#   crane          the OCI registry client this estate uses. versions.env files
#                  GO_TOOL_CRANE under this module while SPEC §7.4 lists crane as
#                  a module-45 row, so BOTH install it on purpose: go_install
#                  records module@version and is a no-op the second time, and the
#                  pin cannot become an orphan if either module drops the row
#   gdu            installed by modules/10-shell.sh, apt first — NOT here
#   golangci-lint  installed by THIS module as a release binary (GOLANGCI_LINT_VERSION),
#                  not via go_install: upstream ships binaries and a `go install`
#                  build reports the wrong version
#   shfmt          modules/28-repo-dev.sh (GO_TOOL_SHFMT)
#   hcloud         modules/45-cloud.sh   (GO_TOOL_HCLOUD)
#   kubelogin      modules/45-cloud.sh — AZURE's kubelogin. Never `go install`
#                  int128/kubelogin: it writes the same $GOPATH/bin/kubelogin and
#                  silently breaks `kubelogin convert-kubeconfig` for AKS
go_tools() {
  cat <<TOOLS
golang.org/x/tools/cmd/goimports@${GO_TOOL_GOIMPORTS:-latest} goimports
github.com/swaggo/swag/cmd/swag@${GO_TOOL_SWAG:?} swag
github.com/a-h/templ/cmd/templ@${GO_TOOL_TEMPL:?} templ
github.com/Melkeydev/go-blueprint@${GO_TOOL_GO_BLUEPRINT:?} go-blueprint
github.com/google/go-containerregistry/cmd/crane@${GO_TOOL_CRANE:?} crane
TOOLS
}

# installed_go_version — prints e.g. 1.27.1, or nothing.
#   The tarball ships a plain-text VERSION file at the root of GOROOT, so the
#   version is READ rather than asked for. That matters for --dry-run: running
#   `go env` makes the toolchain create and update its own telemetry counters
#   under ~/.config/go/telemetry, which would show up in the "a dry run changes
#   nothing" fingerprint even though this module wrote nothing.
installed_go_version() {
  local v='' line
  if [ -r "$GOROOT_DIR/VERSION" ]; then
    read -r line <"$GOROOT_DIR/VERSION" || line=''
    v=${line%% *}
  elif [ -x "$GOROOT_DIR/bin/go" ]; then
    v=$("$GOROOT_DIR/bin/go" env GOVERSION 2>/dev/null) || v=''
  elif have go; then
    v=$(go env GOVERSION 2>/dev/null) || v=''
  fi
  [ -n "$v" ] || return 1
  printf '%s\n' "${v#go}"
}

# install_go_toolchain
#   Downloads go<version>.linux-<arch>.tar.gz and its published .sha256 (a bare
#   digest, one line) and unpacks it over /usr/local/go. The checksum is
#   MANDATORY: this is a compiler, installed as root, from a tarball.
install_go_toolchain() {
  local want=${GO_VERSION:?} cur url sha_url work sum
  if cur=$(installed_go_version); then
    if [ "$cur" = "$want" ]; then
      log_skip "go is already $cur"
      return 0
    fi
    log_info "go $cur -> $want"
  fi

  case ${OS_ARCH_GO:-} in
    '')
      log_warn "unknown architecture — cannot pick a Go tarball"
      return 78
      ;;
  esac

  url="https://dl.google.com/go/go${want}.linux-${OS_ARCH_GO}.tar.gz"
  sha_url="$url.sha256"

  if is_dry_run; then
    log_dryrun "install go $want from $url -> $GOROOT_DIR"
    changed "go $want"
    return 0
  fi

  if ! have_root; then
    log_skip "installing Go into $GOROOT_DIR needs root"
    return 0
  fi
  if ! http_ok "$url"; then
    log_warn "go $want has no linux-${OS_ARCH_GO} build at $url"
    return 78
  fi

  work=$(devenv_tmpdir) || return 1
  local dl="${DEVENV_CACHE:?}/dl" ar
  ensure_dir "$dl" || return 1
  ar="$dl/go${want}.linux-${OS_ARCH_GO}.tar.gz"
  [ -f "$ar" ] || download "$url" "$ar" || return 1
  download "$sha_url" "$work/go.sha256" || {
    log_error "go $want publishes no checksum at $sha_url — refusing to install a compiler unverified"
    return 1
  }
  sum=$(awk '{print $1; exit}' "$work/go.sha256")
  verify_sha256 "$ar" "$sum" || return 1

  # Unpack beside the target first, then swap. `tar -C /usr/local -xzf` over a
  # live tree leaves the previous release's files behind, and a half-extracted
  # /usr/local/go is a broken toolchain.
  run_sudo rm -rf -- "$GOROOT_DIR.new" || return 1
  run_sudo install -d -m 0755 -- "$GOROOT_DIR.new" || return 1
  run_sudo tar -C "$GOROOT_DIR.new" --strip-components=1 -xzf "$ar" || {
    run_sudo rm -rf -- "$GOROOT_DIR.new"
    return 1
  }
  if [ -d "$GOROOT_DIR" ]; then
    run_sudo rm -rf -- "$GOROOT_DIR.old" || return 1
    run_sudo mv -- "$GOROOT_DIR" "$GOROOT_DIR.old" || return 1
  fi
  run_sudo mv -- "$GOROOT_DIR.new" "$GOROOT_DIR" || return 1
  run_sudo rm -rf -- "$GOROOT_DIR.old" || true

  log_success "installed go $want -> $GOROOT_DIR"
  changed "go $want"
  return 0
}

install_go_tools() {
  local line spec bin
  if ! have go && [ ! -x "$GOROOT_DIR/bin/go" ]; then
    log_skip "go is not on PATH — no Go tools installed"
    return 0
  fi
  # This module runs as a child process whose PATH may predate the toolchain it
  # just installed, and a distro `go` may be earlier on it. Build the tools with
  # the toolchain THIS module manages. ~/.bashrc.d/10-path.sh decides the order
  # in the user's own shells.
  if [ -x "$GOROOT_DIR/bin/go" ]; then
    PATH="$GOROOT_DIR/bin:$PATH"
    export PATH
  fi

  while read -r spec bin; do
    [ -n "$spec" ] || continue
    go_install "$spec" "$bin" || log_warn "could not install $bin"
  done < <(go_tools)
  return 0
}

# install_golangci_lint
#   The linter ships release binaries and upstream explicitly recommends them over
#   `go install`, which builds it against your Go version and produces a binary
#   that reports the wrong version. So it is a release install, not a go_tools row.
#   It lives here rather than in 28-repo-dev.sh because that module is this
#   REPOSITORY's own CI toolchain (shellcheck, shfmt, pre-commit) and there is no
#   Go in this repo — golangci-lint is a Go-developer tool and belongs with Go.
install_golangci_lint() {
  have go || {
    log_skip "go is not on PATH — golangci-lint not installed"
    return 0
  }
  gh_release_install golangci/golangci-lint \
    'golangci-lint-{version}-{os}-{arch_go}.tar.gz' \
    golangci-lint "${GOLANGCI_LINT_VERSION:?}" \
    --archive-path 'golangci-lint-{version}-{os}-{arch_go}/golangci-lint' \
    --checksum-asset 'golangci-lint-{version}-checksums.txt' \
    --version-cmd '--version'
  case $? in
    0 | 78) return 0 ;;
    *)
      log_warn "could not install golangci-lint"
      return 0
      ;;
  esac
}

module_main() {
  log_step "go"

  local rc=0
  install_go_toolchain || rc=$?
  case $rc in
    0) ;;
    78) skip "no Go toolchain is available for ${OS_ARCH_GO:-this architecture}" ;;
    *) log_error "the Go toolchain could not be installed" ;;
  esac

  install_go_tools
  install_golangci_lint

  # Reported, never removed: two Go toolchains on one box is a real source of
  # "it works in my shell" confusion, and the apt one may be a dependency.
  pkg_conflicts_report \
    "a distro Go is installed alongside $GOROOT_DIR — check 'command -v go' if a build picks the wrong toolchain" \
    golang-go gccgo || true

  log_step_end
  return 0
}

module_main "$@"
