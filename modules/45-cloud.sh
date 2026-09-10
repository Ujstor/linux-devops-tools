#!/usr/bin/env bash
# meta: name=cloud
# meta: desc=cloud and forge clis plus the remote-operations diagnostics
# meta: profiles=devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=yes
#
# modules/45-cloud.sh — the CLIs that talk to somebody else's machines.
#
#   gh          GitHub CLI, vendor apt repository, suite literally `stable`
#   glab        GitLab CLI. Released on GITLAB.COM, not GitHub: the GitHub
#               releases feed for gitlab-org/cli is empty, which is why this
#               module has its own downloader instead of deb_release_install.
#   az          azure-cli from packages.microsoft.com, with the K12 suite map and
#               a `uv tool install azure-cli` fallback when Microsoft publishes
#               nothing usable for this release.
#   hcloud      Hetzner Cloud CLI (go install — half the fleet is Hetzner)
#   crane       go-containerregistry's registry CLI (go install)
#   diagnostics dig, mtr, traceroute, nmap, tcpdump, ping, htpasswd, wireguard
#               tools and sshpass
#
# Ownership notes:
#   * `gh` is named by SPEC 5.5 for both `git` (module 15) and this one. It is
#     installed here only when it is missing, so exactly one module ever acts.
#   * `crane` is SPEC 7.4's module-45 row, while versions.env files GO_TOOL_CRANE
#     under `# owner: lang-go`. go_install short-circuits on its own state file,
#     so whichever module runs first installs it and the other costs nothing —
#     and crane cannot become an orphan if either module drops the row.
#   * The diagnostics packages are SPEC 7.1 rows filed under `base-packages`.
#     pkg_install skips every name that is already installed, so naming them here
#     as well cannot produce a second apt run; it only guarantees that the box
#     that actually operates remote infrastructure has them.

set -euo pipefail
# shellcheck source=lib/common.sh
source "${DEVENV_HOME:?}/lib/common.sh"

# The GitLab CLI is published to the project's own release downloads endpoint.
# Both are the public gitlab.com project, not any private instance.
CLOUD_GLAB_RELEASES="https://gitlab.com/gitlab-org/cli/-/releases"
CLOUD_GLAB_API="https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases"

# SPEC 7.1's `dev` networking rows. wireguard-tools, never `wireguard`: the
# metapackage pulls the kernel module, which does not exist under WSL.
CLOUD_NET_PKGS=(
  bind9-dnsutils mtr-tiny traceroute nmap tcpdump iputils-ping
  apache2-utils wireguard-tools sshpass
)

# apt_run CMD [ARGS…]
#   Runs ONE lib/pkg.sh helper with `pipefail` switched off, and restores it.
#
#   WHY THIS EXISTS. lib/pkg.sh's pkg_candidate_version is
#       v=$(apt-cache policy "$1" | awk '/Candidate:/ {print $2; exit}') || return 1
#   The awk `exit` closes the pipe while apt-cache is still writing, apt-cache
#   dies of SIGPIPE, and under `set -o pipefail` — which EVERY module sets — the
#   command substitution's status is 141. pkg_candidate_version therefore returns
#   1, pkg_available says "no candidate", and pkg_install silently DROPS a package
#   that is perfectly installable. Verified on ubuntu 24.04: mtr-tiny, traceroute,
#   tcpdump and sshpass were each dropped with "no installation candidate", while
#   `apt-cache policy` lists a candidate for all four.
#
#   THE ROOT CAUSE IS NOW FIXED IN lib/pkg.sh: pkg_candidate_version reads the
#   whole apt-cache stream and prints in END, so it can no longer SIGPIPE. This
#   wrapper is therefore belt-and-braces — it is still correct, it still costs
#   nothing, and it protects any OTHER lib helper that grows the same shape — but
#   it is no longer load-bearing and may be deleted with its call sites.
#   Returns the wrapped command's exit status.
apt_run() {
  local rc=0
  set +o pipefail
  "$@" || rc=$?
  set -o pipefail
  return "$rc"
}

CLOUD_FAILURES=()

# _cloud_fail MSG   (private) — record a real failure and keep going.
_cloud_fail() {
  CLOUD_FAILURES+=("$1")
  log_error "$1"
  return 0
}

# _path_prepend DIR   (private)
#   Puts DIR at the front of PATH once. Modules run as child processes with the
#   invoking shell's PATH, and a box that has never had ~/.local/bin or ~/go/bin
#   does not list them yet — which would make `comp_cache` skip a tool this
#   module has just installed.
_path_prepend() {
  local dir=${1:-}
  [ -n "$dir" ] || return 0
  [ -d "$dir" ] || return 0
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  PATH="$dir:$PATH"
  export PATH
  return 0
}

# _cloud_gh
#   GitHub CLI. `repo_ensure_github_cli` also drops the /usr/share/keyrings copy
#   the vendor's own instructions create, so there is one trusted key, not two.
#   Always returns 0.
_cloud_gh() {
  local rc=0
  if have gh && pkg_installed gh; then
    log_skip "gh is already installed"
    return 0
  fi
  if have gh; then
    log_warn "gh is on PATH at $(command -v gh) but is not an apt package —"
    log_warn "  leaving it alone rather than installing a second copy."
    return 0
  fi
  repo_ensure_github_cli || rc=$?
  if [ "$rc" != 0 ]; then
    log_warn "the github-cli apt repository could not be configured — skipping gh"
    return 0
  fi
  # The index must be refreshed before availability is checked — see the note
  # in modules/40-iac.sh's _iac_hashicorp.
  pkg_update
  if ! apt_run pkg_install gh; then
    _cloud_fail "gh could not be installed"
    return 0
  fi
  # MUST-FIX C3: gh's subcommand is `completion -s bash`, not `completion bash`.
  comp_cache gh gh completion -s bash
  return 0
}

# _cloud_glab_tag   (private)
#   Prints the glab release tag to install. GLAB_VERSION is the pin; the sentinel
#   `latest` resolves through GitLab's own permalink, since gh_latest_tag only
#   understands github.com. Returns 1 when it cannot be resolved.
_cloud_glab_tag() {
  local want=${GLAB_VERSION:-latest} tag
  case $want in
    latest) ;;
    *)
      printf '%s\n' "$want"
      return 0
      ;;
  esac
  # Every stage here reads its input to EOF. `set -o pipefail` is on in every
  # module, so a `head -n1` that exits early would SIGPIPE the stage above it and
  # turn a good answer into an empty one.
  tag=$(http_body "$CLOUD_GLAB_API/permalink/latest" \
    | grep -oE '"tag_name":"[^"]+"' | sed 's/.*:"//;s/"$//' | sed -n '1p') || tag=''
  [ -n "$tag" ] || return 1
  printf '%s\n' "$tag"
}

# _cloud_glab_arch   (private)
#   Prints the architecture token glab's release assets use, which is GOARCH with
#   armhf spelled armv6. Returns 1 when this architecture has no build.
_cloud_glab_arch() {
  case ${OS_ARCH_DPKG:-} in
    amd64) printf 'amd64\n' ;;
    arm64) printf 'arm64\n' ;;
    i386) printf '386\n' ;;
    armhf) printf 'armv6\n' ;;
    ppc64el) printf 'ppc64le\n' ;;
    s390x) printf 's390x\n' ;;
    *) return 1 ;;
  esac
}

# _cloud_glab
#   Installs glab from gitlab.com: the .deb when dpkg is available, else the
#   tarball into /usr/local/bin. Both are verified against the release's own
#   checksums.txt. Version-gated on `glab --version`, so a converged box does no
#   network at all. Honours --dry-run. Always returns 0.
_cloud_glab() {
  local tag ver arch cur asset url dl ar cfile expected work
  tag=$(_cloud_glab_tag) || {
    log_warn "could not resolve a glab release tag — skipping glab"
    return 0
  }
  ver=${tag#v}
  arch=$(_cloud_glab_arch) || {
    log_skip "glab publishes no build for ${OS_ARCH_DPKG:-this architecture}"
    return 0
  }

  if cur=$(bin_version glab --version); then
    if [ "${cur#v}" = "$ver" ]; then
      log_skip "glab is already $ver"
      return 0
    fi
    log_info "glab $cur -> $ver"
  fi

  if have dpkg; then
    asset="glab_${ver}_linux_${arch}.deb"
  else
    asset="glab_${ver}_linux_${arch}.tar.gz"
  fi
  url="$CLOUD_GLAB_RELEASES/$tag/downloads/$asset"

  if is_dry_run; then
    log_dryrun "install glab $ver from $url"
    changed "glab $ver"
    return 0
  fi

  if ! http_ok "$url"; then
    log_warn "no asset '$asset' in the glab $tag release — skipping glab"
    log_warn "  looked at: $url"
    return 0
  fi

  dl="${DEVENV_CACHE:?}/dl"
  ensure_dir "$dl" || return 0
  ar="$dl/$asset"
  if [ ! -f "$ar" ]; then
    if ! download "$url" "$ar"; then
      _cloud_fail "could not download $url"
      return 0
    fi
  fi

  # The checksum file's name carries no version, so cache it under one that does.
  cfile="$dl/glab_${ver}_checksums.txt"
  if ! download "$CLOUD_GLAB_RELEASES/$tag/downloads/checksums.txt" "$cfile"; then
    _cloud_fail "could not fetch the glab $tag checksums — refusing to install it unverified"
    return 0
  fi
  if ! expected=$(checksum_lookup "$cfile" "$asset"); then
    _cloud_fail "$asset is not listed in the glab $tag checksums"
    return 0
  fi
  if ! verify_sha256 "$ar" "$expected"; then
    _cloud_fail "the downloaded $asset does not match its published sha256"
    return 0
  fi

  case $asset in
    *.deb)
      if ! pkg_install_local "$ar"; then
        _cloud_fail "glab $ver could not be installed"
        return 0
      fi
      ;;
    *)
      work=$(devenv_tmpdir) || return 0
      if ! run tar -xzf "$ar" -C "$work"; then
        _cloud_fail "could not unpack $asset"
        return 0
      fi
      ensure_dir /usr/local/bin || return 0
      if ! run_sudo install -m 0755 -- "$work/bin/glab" /usr/local/bin/glab; then
        _cloud_fail "could not install glab into /usr/local/bin"
        return 0
      fi
      ;;
  esac
  log_success "installed glab $ver"
  changed "glab $ver"
  # MUST-FIX C3: glab's form is `completion -s bash`.
  comp_cache glab glab completion -s bash
  return 0
}

# _cloud_azure_cli
#   azure-cli. The suite logic (K12: trixie/forky/plucky/questing -> noble, never
#   bookworm, because trixie ships libssl3t64 and the bookworm build needs
#   libssl3) lives in lib/repo.sh. 78 from it means Microsoft publishes nothing
#   for this release, and the documented fallback is a uv tool venv.
#   An azure-cli that is already installed is never upgraded or removed here
#   (MUST-FIX S9); the exact command to do it yourself is printed instead.
#   Always returns 0.
_cloud_azure_cli() {
  local rc=0 cur=''
  if have dpkg-query; then
    cur=$(dpkg-query -W -f='${Version}' azure-cli 2>/dev/null) || cur=''
  fi
  if [ -z "$cur" ] && have az; then
    log_skip "az is on PATH at $(command -v az) but is not an apt package — leaving it alone"
    return 0
  fi

  repo_ensure_azure_cli || rc=$?
  if [ "$rc" = 78 ]; then
    log_warn "packages.microsoft.com publishes no azure-cli suite for this release."
    if have uv; then
      log_info "installing azure-cli into a uv tool venv instead"
      if ! uv_tool_install azure-cli; then
        _cloud_fail "uv tool install azure-cli failed"
      fi
    else
      log_skip "uv is not installed either — run 'devenv --only lang-python', then this module"
    fi
    return 0
  fi
  if [ "$rc" != 0 ]; then
    log_warn "the azure-cli apt repository could not be configured — skipping azure-cli"
    return 0
  fi

  if [ -n "$cur" ]; then
    if version_ge "$cur" 2.30.0; then
      log_skip "azure-cli $cur is already installed"
    else
      log_warn "azure-cli $cur is the distribution's own build and is too old:"
      log_warn "  below 2.30 it has no 'az login --use-device-code' worth relying on"
      log_warn "  and no support for the current Entra ID endpoints."
      log_warn "  The Microsoft repository is configured now. Upgrade it yourself:"
      log_warn "    sudo apt-get install --only-upgrade azure-cli"
      log_warn "  (this repository never upgrades or removes a package you installed)"
    fi
    return 0
  fi

  pkg_update
  if ! apt_run pkg_install azure-cli; then
    _cloud_fail "azure-cli could not be installed"
  fi
  return 0
}

# _cloud_go_tools
#   hcloud and crane. go_install is a no-op when the recorded version already
#   matches, and it logs a skip (never a failure) when Go itself is missing.
#   Always returns 0.
_cloud_go_tools() {
  # go_ensure_path, not `have go`: this module runs as a child process with the
  # invoking shell's PATH, which on a fresh box does not yet contain the
  # /usr/local/go that modules/20-lang-go.sh installed EARLIER IN THIS SAME RUN.
  # Without it, hcloud and crane were skipped on every run of a fresh box.
  if ! go_ensure_path; then
    log_skip "go is not installed — hcloud and crane need it (run 'devenv --only lang-go')"
    return 0
  fi
  if ! go_install "github.com/hetznercloud/cli/cmd/hcloud@${GO_TOOL_HCLOUD:?GO_TOOL_HCLOUD is not set}" hcloud; then
    _cloud_fail "hcloud could not be built"
  fi
  if ! go_install "github.com/google/go-containerregistry/cmd/crane@${GO_TOOL_CRANE:?GO_TOOL_CRANE is not set}" crane; then
    _cloud_fail "crane could not be built"
  fi
  # Both are cobra binaries with a real `completion bash` subcommand (C3).
  comp_cache hcloud hcloud completion bash
  comp_cache crane crane completion bash
  return 0
}

# _cloud_diagnostics
#   The remote-operations toolkit. Optional by construction: a name with no
#   candidate on this distribution is dropped with one warning, never a failure.
#   Always returns 0.
_cloud_diagnostics() {
  apt_run pkg_install_optional "${CLOUD_NET_PKGS[@]}"
  return 0
}

module_main() {
  _path_prepend "$HOME/.local/bin"
  if have go; then _path_prepend "$(go env GOPATH 2>/dev/null)/bin"; fi

  _cloud_gh
  _cloud_glab
  _cloud_azure_cli
  _cloud_go_tools
  _cloud_diagnostics

  log_info "none of these CLIs is logged in by this module — that is 'sso-login'"
  log_info "  (gh auth login, glab auth login, az login), which never runs unattended."

  if [ ${#CLOUD_FAILURES[@]} -gt 0 ]; then
    log_error "${#CLOUD_FAILURES[@]} step(s) in this module failed:"
    printf '  - %s\n' "${CLOUD_FAILURES[@]}" >&2
    # A deliberate failure exit: clear the ERR trap first, or lib/common.sh's
    # trap prints two more "failed (exit 1) … command: return 1" lines after the
    # list above and buries the real reason.
    trap - ERR
    exit 1
  fi
  return 0
}

module_main "$@"
