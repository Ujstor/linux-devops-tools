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
#   gh          GitHub CLI, vendor apt repository, suite literally `stable`; the
#               vendor's rpm repository on redhat and suse, Arch's `github-cli`
#   glab        GitLab CLI. Released on GITLAB.COM, not GitHub: the GitHub
#               releases feed for gitlab-org/cli is empty, so the tag comes from
#               GitLab's own API and pkg_release_install downloads from the
#               release's /downloads (--base-url): .deb, .rpm, or the archive.
#   az          azure-cli from packages.microsoft.com, with the K12 suite map and
#               a `uv tool install azure-cli` fallback when Microsoft publishes
#               nothing usable for this release — which is Fedora, Leap and Arch
#               (plan D6); EL 9/10 take Microsoft's rhel/<major>/prod repository.
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
#   78 off the Debian family is arch, where no vendor repository exists:
#   pkg_install gh then takes the distribution's package (packages.map spells it
#   github-cli there).
#   Always returns 0.
_cloud_gh() {
  local rc=0
  if have gh && pkg_installed gh; then
    log_skip "gh is already installed"
    return 0
  fi
  if have gh; then
    log_warn "gh is on PATH at $(command -v gh) but no ${OS_PKG_MGR:-apt} package owns it —"
    log_warn "  leaving it alone rather than installing a second copy."
    return 0
  fi
  repo_ensure_github_cli || rc=$?
  if [ "$rc" = 78 ] && [ "${OS_FAMILY:-debian}" != debian ]; then
    : # no vendor repository here: pkg_install below takes the distribution's gh
  elif [ "$rc" != 0 ]; then
    log_warn "the github-cli ${OS_PKG_MGR:-apt} repository could not be configured — skipping gh"
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
#   Installs glab from gitlab.com through pkg_release_install: the .deb on apt,
#   the .rpm on dnf and zypper, the archive's bin/glab into /usr/local/bin on
#   pacman. All three are verified against the release's own checksums.txt, which
#   lists them (checked for v1.120.0). Version-gated on `glab --version` first, so
#   a converged box does no network at all. Honours --dry-run. Always returns 0.
_cloud_glab() {
  local tag ver arch cur rc=0
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

  # The tag is already resolved, so pkg_release_install never asks GitHub for
  # one; gitlab-org/cli only labels its messages.
  pkg_release_install gitlab-org/cli glab "$tag" \
    --base-url "$CLOUD_GLAB_RELEASES/{tag}/downloads" \
    --deb "glab_{version}_linux_${arch}.deb" --rpm "glab_{version}_linux_${arch}.rpm" \
    --tarball "glab_{version}_linux_${arch}.tar.gz" --archive-path bin/glab \
    --checksum-asset checksums.txt || rc=$?
  case $rc in
    0) ;;
    78)
      log_skip "glab $ver: nothing in the $tag release installs here"
      return 0
      ;;
    *)
      _cloud_fail "glab $ver could not be installed"
      return 0
      ;;
  esac
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
#   Off the Debian family an azure-cli PACKAGE that is already there (Fedora and
#   Arch both ship one) is left as it is, rather than shadowed by a uv copy.
#   Always returns 0.
_cloud_azure_cli() {
  local rc=0 cur=''
  cur=$(installed_pkg_version azure-cli) || cur=''
  if [ -z "$cur" ] && have az; then
    log_skip "az is on PATH at $(command -v az) but no ${OS_PKG_MGR:-apt} package owns it — leaving it alone"
    return 0
  fi

  repo_ensure_azure_cli || rc=$?
  if [ "$rc" = 78 ] && [ -n "$cur" ] && [ "${OS_FAMILY:-debian}" != debian ]; then
    log_skip "azure-cli $cur is already installed as a ${OS_DISTRO:-distribution} package — leaving it alone"
    return 0
  fi
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
    log_warn "the azure-cli ${OS_PKG_MGR:-apt} repository could not be configured — skipping azure-cli"
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
      case ${OS_PKG_MGR:-apt} in
        dnf) log_warn "    sudo dnf upgrade azure-cli" ;;
        *) log_warn "    sudo apt-get install --only-upgrade azure-cli" ;;
      esac
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
