#!/usr/bin/env bash
# meta: name=kubernetes
# meta: desc=kubectl from a configurable minor stream, helm, k9s and the kubernetes cli set
# meta: profiles=devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=yes
#
# =============================================================================
# modules/35-kubernetes.sh — KUBERNETES CORE.
#
# Everything a workstation needs to talk to the fleet, and nothing that belongs
# to a cluster. Plugins (krew, kubectl-*, helm plugins) are module 36; the k9s
# configuration is module 37. This module only installs BINARIES and the one
# create-if-absent kubecolor config.
#
# THE HEADLINE FIX. The old repo hard-wired the apt source to
#     https://pkgs.k8s.io/core:/stable:/v1.29/deb/
# and never moved it, so the live box still had a v1.29 client against a much
# newer fleet. Here the minor is DATA: `K8S_MINOR` in versions.env, with the
# sentinel `auto` enabling lib/repo.sh's three-tier probe (current cluster ->
# dl.k8s.io/release/stable.txt -> cached answer). Changing one line in
# versions.env now moves every box. lib/repo.sh refuses a silent DOWNGRADE, and
# k8s_apt_upgrade_to_candidate() below makes sure the already-installed client
# actually follows the stream instead of staying on the EOL minor.
#
# HOW EACH TOOL IS INSTALLED, and why the method differs:
#   apt (vendor repo)   kubectl (pkgs.k8s.io, flat repo -> no distro branch),
#                       trivy (suite `generic` -> one identical line on both
#                       distributions). Security updates then arrive with apt.
#   release .deb        k9s, kubecolor, dive, grpcurl (+ kube-bench when
#                       INSTALL_K8S_OPT=1). dpkg-query gives a free, exact
#                       idempotency gate and apt resolves the dependencies.
#   release binary      everything else, pinned in versions.env, checksum
#                       verified, installed into $K8S_BIN_DIR.
#   get.helm.sh         helm — the only tool here that does not live on GitHub.
#                       `get-helm-3` is deliberately NOT used: it resolves
#                       "latest" at run time and Helm 4 exists, so a bootstrap
#                       script must not be allowed to jump a major (K1).
#
# CHECKSUMS (MUST-FIX F14/D14). Every download above is verified against a
# digest the vendor publishes. Three projects publish none, and each one says so
# at the call site with --no-verify-reason: kubevirt (virtctl), CrunchyData
# (kubectl-pgo) and stackrox (kube-linter, sigstore bundles only). mikefarah/yq
# publishes a multi-hash TABLE rather than a `<sum>  <file>` list, so this module
# reads the SHA-256 column out of it itself — see k8s_yq_sha256().
#
# IDEMPOTENCY. Every install is gated on the version of the file this module
# would write ($K8S_BIN_DIR/<bin>), NOT on whatever `command -v <bin>` resolves
# to. That distinction is load-bearing on the live box: ~/go/bin comes before
# /usr/local/bin on its PATH and holds older go-installed copies of k9s,
# kubecolor and kubelogin, so a `command -v` gate would reinstall on every run,
# for ever. Where such a shadow exists it is REPORTED (k8s_warn_shadow) and
# never removed — that is the user's file.
#
# arm64. Every asset pattern here is arch-derived and was checked against the
# pinned release: amd64 and arm64 both resolve. A project that ships no asset
# for this architecture makes gh_release_install return 78, which is recorded as
# a skip with the reason, never as a silent no-op (C4) and never as a failure.
#
# NOTHING PRIVATE. No cluster, context, hostname or kubeconfig content appears
# here or is read by this module. ~/.kube/config is never touched; the only file
# written under ~/.kube is color.yaml, and only when it does not exist.
# =============================================================================

set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# Where release binaries land. /usr/local/bin (not ~/.local/bin) so that a
# kubectl plugin such as kubectl-pgo is on the PATH of every shell — including
# `sudo kubectl`, cron and a systemd unit.
K8S_BIN_DIR=${K8S_BIN_DIR:-/usr/local/bin}

# Outcome buckets, printed at the end. A tool that failed does not stop the
# other twenty from installing; the module reports the failures and exits 1.
K8S_OK=()
K8S_SKIPPED=()
K8S_FAILED=()

# GoReleaser's default name template renders amd64 as `x86_64` while leaving
# arm64 alone, and stackrox omits the arch entirely for amd64. One {token}
# cannot express either, so the exact strings those projects use are computed
# once, here.
K8S_ARCH_X=''
K8S_ARCH_LINTER=''

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# k8s_arch_init
#   Fills K8S_ARCH_X (x86_64 / arm64) and K8S_ARCH_LINTER ('' / _arm64).
k8s_arch_init() {
  case ${OS_ARCH_DPKG:-amd64} in
    amd64)
      K8S_ARCH_X=x86_64
      K8S_ARCH_LINTER=''
      ;;
    arm64)
      K8S_ARCH_X=arm64
      K8S_ARCH_LINTER=_arm64
      ;;
    *)
      K8S_ARCH_X=${OS_ARCH_GO:-amd64}
      K8S_ARCH_LINTER="_${OS_ARCH_GO:-amd64}"
      ;;
  esac
}

# k8s_bin_at PATH WANT [VERSION_ARGS] [REGEX]
#   Returns 0 when the executable at PATH already reports version WANT.
#   Deliberately takes a PATH and not a command name: see the IDEMPOTENCY note
#   in the header. Read-only, safe under --dry-run, never dies.
k8s_bin_at() {
  local p=${1:?k8s_bin_at: PATH required} want=${2:?k8s_bin_at: WANT required}
  local vargs=${3:---version} re=${4:-} out v
  [ -x "$p" ] || return 1
  [ -n "$re" ] || re='v?[0-9]+\.[0-9]+(\.[0-9]+)?'
  # shellcheck disable=SC2086  # deliberate word-splitting: VERSION_ARGS is a string
  out=$("$p" $vargs 2>&1) || out=${out:-}
  v=$(printf '%s\n' "$out" | grep -oE "$re" | head -n1) || v=''
  [ -n "$v" ] || return 1
  [ "${v#v}" = "${want#v}" ]
}

# k8s_warn_shadow BIN
#   Reports — never repairs — a copy of BIN inside $HOME that takes precedence
#   over the one this module installed. On the live box ~/go/bin precedes
#   /usr/local/bin, and it holds go-installed k9s, kubecolor, kubelogin and
#   helm-docs. Removing them is the user's decision (`devenv doctor` lists
#   duplicate binaries); silently shadowing them is not. Always returns 0.
k8s_warn_shadow() {
  local bin=${1:?k8s_warn_shadow: BIN required} found sys
  have "$bin" || return 0
  found=$(command -v "$bin") || return 0
  case $found in
    "$HOME"/*) ;;
    *) return 0 ;;
  esac
  for sys in "$K8S_BIN_DIR/$bin" "/usr/bin/$bin"; do
    [ -x "$sys" ] || continue
    log_warn "$bin on PATH is $found (yours), while this module installed $sys"
    log_warn "  the earlier PATH entry wins. Remove your copy or reorder PATH;"
    log_warn "  'devenv doctor' lists every duplicate binary it can see."
    return 0
  done
  return 0
}

# k8s_record LABEL RC
#   Files one tool's outcome. 78 is "upstream publishes nothing usable here" and
#   is a skip, not a failure. Always returns 0.
k8s_record() {
  local label=${1:?k8s_record: LABEL required} rc=${2:-0}
  case $rc in
    0) K8S_OK+=("$label") ;;
    78) K8S_SKIPPED+=("$label") ;;
    *)
      K8S_FAILED+=("$label")
      log_warn "$label: install failed (exit $rc) — continuing with the rest"
      ;;
  esac
  return 0
}

# k8s_release BIN VERSION VERSION_CMD REPO ASSET_PATTERN [OPTS…]
#   One pinned release binary into $K8S_BIN_DIR. OPTS go to gh_release_install
#   unchanged (checksum options above all). Records the outcome and always
#   returns 0 — the caller inspects K8S_FAILED at the end.
k8s_release() {
  local bin=${1:?k8s_release: BIN required} version=${2:?k8s_release: VERSION required}
  local vcmd=${3:?k8s_release: VERSION_CMD required} repo=${4:?k8s_release: REPO required}
  local asset=${5:?k8s_release: ASSET required}
  shift 5
  local want rc=0
  want=$(tag_to_version "$version")
  if k8s_bin_at "$K8S_BIN_DIR/$bin" "$want" "$vcmd"; then
    log_skip "$bin is already $want"
    K8S_OK+=("$bin $want")
    k8s_warn_shadow "$bin"
    return 0
  fi
  gh_release_install "$repo" "$asset" "$bin" "$version" \
    --dest "$K8S_BIN_DIR" --version-cmd "$vcmd" "$@" || rc=$?
  k8s_record "$bin $want" "$rc"
  if [ "$rc" = 0 ]; then k8s_warn_shadow "$bin"; fi
  return 0
}

# k8s_deb PKG VERSION REPO ASSET_PATTERN [OPTS…]
#   One release .deb. `--bin NAME` when the command differs from the package.
#   Records the outcome and always returns 0.
k8s_deb() {
  local pkg=${1:?k8s_deb: PKG required} version=${2:?k8s_deb: VERSION required}
  local repo=${3:?k8s_deb: REPO required} asset=${4:?k8s_deb: ASSET required}
  shift 4
  local want rc=0 bin=$pkg i=0
  local opts=("$@")
  want=$(tag_to_version "$version")
  while [ $i -lt ${#opts[@]} ]; do
    if [ "${opts[i]}" = --bin ]; then bin=${opts[i + 1]}; fi
    i=$((i + 1))
  done
  deb_release_install "$repo" "$asset" "$pkg" "$version" "$@" || rc=$?
  k8s_record "$pkg $want" "$rc"
  if [ "$rc" = 0 ]; then k8s_warn_shadow "$bin"; fi
  return 0
}

# k8s_apt_upgrade_to_candidate PKG
#   Upgrades exactly ONE package to the candidate of the repositories that are
#   configured right now. It is neither pkg_install (which never touches an
#   installed package) nor pkg_upgrade (the whole system, and gated behind
#   --upgrade). It exists because pointing the kubernetes source at $K8S_MINOR
#   is pointless while the v1.29 client from the old repo stays installed —
#   which is exactly the state this module was written to fix.
#   Idempotent: nothing happens once the installed version is >= the candidate.
#   Honours --dry-run through run_sudo. Always returns 0.
k8s_apt_upgrade_to_candidate() {
  local pkg=${1:?k8s_apt_upgrade_to_candidate: PKG required} cur cand
  have dpkg-query || return 0
  pkg_installed "$pkg" || return 0
  pkg_update
  cur=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null) || return 0
  cand=$(pkg_candidate_version "$pkg") || return 0
  if version_ge "$cur" "$cand"; then
    log_debug "$pkg $cur is already at or above the candidate $cand"
    return 0
  fi
  log_info "$pkg $cur -> $cand (following the configured stream)"
  # `env DEBIAN_FRONTEND=…` is attached to the command, not merely exported: sudo's
  # env_reset drops it otherwise and an unattended upgrade can stop on a debconf
  # prompt. Same reasoning, and same fix, as lib/pkg.sh's _apt_get.
  # `--only-upgrade` is the one apt operation lib/pkg.sh does not express: it moves
  # an ALREADY-INSTALLED package along its configured stream and installs nothing
  # new, which is exactly what following a kubernetes minor means.
  run_sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y \
    -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef \
    --only-upgrade -- "$pkg" || { # policy-allow: no-bare-apt
    log_warn "could not upgrade $pkg to $cand — leaving $cur in place"
    return 0
  }
  changed "apt upgrade $pkg $cand"
  return 0
}

# ---------------------------------------------------------------------------
# kubectl — the one tool that comes from an apt repository
# ---------------------------------------------------------------------------

# k8s_kubectl
#   Configures pkgs.k8s.io for the resolved minor, installs kubectl and pulls an
#   already-installed client up to that stream. Always returns 0.
k8s_kubectl() {
  local stream rc=0
  stream=$(k8s_detect_stream)
  log_info "kubernetes package stream: $stream (K8S_MINOR=${K8S_MINOR:-unset})"
  repo_ensure_kubernetes "$stream" || rc=$?
  case $rc in
    0) ;;
    78)
      log_warn "no usable kubernetes apt repository for this box — skipping kubectl"
      K8S_SKIPPED+=("kubectl ($stream)")
      return 0
      ;;
    *)
      K8S_FAILED+=("kubernetes apt repository")
      return 0
      ;;
  esac
  # repo_ensure_kubernetes refreshes the index itself when it CHANGED the
  # source; this covers the other case (an unchanged source plus an index that
  # a container image wiped), because pkg_install looks for a candidate before
  # it refreshes anything.
  pkg_update
  if ! pkg_install kubectl; then
    K8S_FAILED+=("kubectl")
    return 0
  fi
  k8s_apt_upgrade_to_candidate kubectl
  if have kubectl; then
    K8S_OK+=("kubectl $(bin_version kubectl 'version --client' || printf 'installed\n')")
    log_info "kubectl supports +/-1 minor against the API server; keep K8S_MINOR within one"
    log_info "  minor of the fleet's k3s release rather than chasing upstream stable."
  else
    K8S_SKIPPED+=("kubectl")
  fi
  return 0
}

# ---------------------------------------------------------------------------
# helm — get.helm.sh, pinned, checksum-verified
# ---------------------------------------------------------------------------

# k8s_helm
#   Installs $HELM_VERSION from get.helm.sh and verifies the published
#   .sha256sum. Never runs get-helm-3 (it resolves `latest` and Helm 4 exists).
#   Always returns 0; the outcome is recorded.
k8s_helm() {
  local want=${HELM_VERSION:?HELM_VERSION unset} ver arch asset url dl work cur sum
  ver=$(tag_to_version "$want")
  arch=${OS_ARCH_GO:-amd64}
  if k8s_bin_at "$K8S_BIN_DIR/helm" "$ver" 'version --short'; then
    log_skip "helm is already $ver"
    K8S_OK+=("helm $ver")
    k8s_warn_shadow helm
    return 0
  fi
  if cur=$(bin_version helm 'version --short'); then
    log_info "helm $cur -> $want"
  fi
  asset="helm-${want}-linux-${arch}.tar.gz"
  url="https://get.helm.sh/$asset"
  if is_dry_run; then
    log_dryrun "install helm $ver from $url -> $K8S_BIN_DIR/helm"
    changed "helm $ver"
    K8S_OK+=("helm $ver")
    return 0
  fi
  if ! http_ok "$url"; then
    log_warn "get.helm.sh publishes no $asset — skipping helm"
    K8S_SKIPPED+=("helm $ver")
    return 0
  fi
  dl="${DEVENV_CACHE:?}/dl"
  ensure_dir "$dl" || {
    K8S_FAILED+=("helm")
    return 0
  }
  if [ ! -f "$dl/$asset" ] && ! download "$url" "$dl/$asset"; then
    K8S_FAILED+=("helm")
    return 0
  fi
  if ! download "$url.sha256sum" "$dl/$asset.sha256sum"; then
    log_error "helm publishes $asset.sha256sum but it could not be fetched — refusing to install unverified"
    K8S_FAILED+=("helm")
    return 0
  fi
  sum=$(awk '{print $1; exit}' "$dl/$asset.sha256sum")
  if ! verify_sha256 "$dl/$asset" "$sum"; then
    K8S_FAILED+=("helm")
    return 0
  fi
  work=$(devenv_tmpdir) || {
    K8S_FAILED+=("helm")
    return 0
  }
  if ! run tar -xzf "$dl/$asset" -C "$work"; then
    K8S_FAILED+=("helm")
    return 0
  fi
  if ! k8s_install_file "$work/linux-$arch/helm" "$K8S_BIN_DIR/helm" 0755; then
    K8S_FAILED+=("helm")
    return 0
  fi
  log_success "installed helm $ver -> $K8S_BIN_DIR/helm"
  changed "helm $ver"
  K8S_OK+=("helm $ver")
  k8s_warn_shadow helm
  return 0
}

# k8s_install_file SRC DEST MODE
#   install(1) through the right privilege gate. Mirrors what lib/fs.sh does for
#   its own writers, using the public fs_needs_root predicate, so a box where
#   /usr/local/bin is user-writable never asks for a password.
k8s_install_file() {
  local src=${1:?k8s_install_file: SRC required} dest=${2:?k8s_install_file: DEST required}
  local mode=${3:-0755}
  ensure_dir "$(dirname -- "$dest")" || return 1
  if fs_needs_root "$dest"; then
    run_sudo install -m "$mode" -- "$src" "$dest"
  else
    run install -m "$mode" -- "$src" "$dest"
  fi
}

# ---------------------------------------------------------------------------
# yq — mikefarah's v4, and the digest table its releases actually publish
# ---------------------------------------------------------------------------

# k8s_yq_sha256 TAG ASSET
#   Prints the SHA-256 of ASSET as published by mikefarah/yq.
#   That project ships `checksums` as a TABLE — the filename in column 1 and one
#   column per algorithm, in the order listed in `checksums_hashes_order` (SHA-256
#   is the 18th, verified against the real binary) — so lib/net.sh's
#   `<sum>  <file>` parser cannot read it. Read-only; returns 1 when the lookup
#   fails, and the caller then installs with an explicit, documented exception.
k8s_yq_sha256() {
  local tag=${1:?k8s_yq_sha256: TAG required} asset=${2:?k8s_yq_sha256: ASSET required}
  local base="https://github.com/mikefarah/yq/releases/download/$tag" col
  col=$(http_body "$base/checksums_hashes_order" | grep -n '^SHA-256$' | head -n1 | cut -d: -f1) || return 1
  case ${col:-} in '' | *[!0-9]*) return 1 ;; esac
  http_body "$base/checksums" \
    | awk -v a="$asset" -v c="$col" '$1 == a { print $(c + 1); exit }' \
    | grep -xE '[0-9a-f]{64}'
}

# k8s_yq
#   Installs mikefarah's yq v4 into $K8S_BIN_DIR and REPORTS the distro `yq`,
#   which is kislyuk's Python jq wrapper — a different tool with the same name,
#   not an older version of this one (K29). MUST-FIX S9: it is never removed.
k8s_yq() {
  local asset sha=''
  asset="yq_linux_${OS_ARCH_GO:-amd64}"
  pkg_conflicts_report \
    "the distro 'yq' package is kislyuk's Python jq wrapper, NOT mikefarah's yq v4 — /usr/bin/yq and $K8S_BIN_DIR/yq are different tools" \
    yq || true
  if ! is_dry_run; then
    sha=$(k8s_yq_sha256 "${YQ_VERSION:?YQ_VERSION unset}" "$asset") || sha=''
  fi
  if [ -n "$sha" ]; then
    k8s_release yq "$YQ_VERSION" '--version' mikefarah/yq "$asset" --sha256 "$sha"
  else
    k8s_release yq "$YQ_VERSION" '--version' mikefarah/yq "$asset" \
      --no-verify --no-verify-reason \
      "mikefarah/yq publishes a multi-hash digest table rather than a checksum file; this module reads its SHA-256 column itself and only lands here when that lookup failed"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The roster
# ---------------------------------------------------------------------------

# k8s_core_tools
#   Everything in the default (devops) profile.
#   RULING: SPEC 7.2 tags hubble, kustomize, velero, crictl and dive as `full`
#   rather than `dev`. Profiles select MODULES, not individual tools, and
#   versions.env's own INSTALL_K8S_OPT block is described there as the one
#   opt-in tier for kubernetes ("`full` does NOT turn these on"), so the five
#   stay in the default set: each is a single checksum-verified binary, and
#   kustomize in particular is not optional in an Argo CD app-of-apps shop.
#   Anything genuinely situational lives in k8s_optional_tools below.
k8s_core_tools() {
  # k9s: the TARBALL is k9s_Linux_<arch>.tar.gz (capital L) and the DEB is
  # k9s_linux_<arch>.deb (lower case). Both exist for every release; the .deb
  # gives a dpkg-exact idempotency gate. Stop `go install`-ing it — that build
  # reports its version as "dev" and can never be pinned.
  k8s_deb k9s "${K9S_VERSION:?}" derailed/k9s 'k9s_linux_{arch_dpkg}.deb' \
    --checksum-asset checksums.sha256

  # kubecolor: the `kubectl` alias in ~/.bashrc.d/30-k8s.sh points here. Its own
  # config is create-if-absent below.
  k8s_deb kubecolor "${KUBECOLOR_VERSION:?}" kubecolor/kubecolor \
    'kubecolor_{version}_linux_{arch_dpkg}.deb' --checksum-asset checksums.txt

  # k3d — pinned release binary + the published checksums.txt. SPEC's `TAG=` +
  # vendor install script is deliberately NOT used: an unpinned `curl | bash`
  # is exactly what MUST-FIX F14 asks to replace where a checksum exists.
  k8s_release k3d "${K3D_VERSION:?}" '--version' k3d-io/k3d 'k3d-linux-{arch_go}' \
    --checksum-asset checksums.txt

  # kind — arch-aware. The old script guarded on `uname -m = x86_64` and so
  # silently installed nothing on arm64.
  k8s_release kind "${KIND_VERSION:?}" '--version' kubernetes-sigs/kind 'kind-linux-{arch_go}' \
    --checksum-url 'https://github.com/kubernetes-sigs/kind/releases/download/{tag}/kind-linux-{arch_go}.sha256sum'

  # kustomize — a monorepo: the tags are component-prefixed (kustomize/v5.8.1),
  # so `releases/latest` can point at an `api/` or `cmd/config/` tag, and the
  # DOWNLOAD URL needs the prefix — .../download/v5.8.1/… is a verified 404
  # while .../download/kustomize/v5.8.1/… is a 200. Both spellings of the pin
  # are therefore accepted here and normalised to the real tag; {version} is
  # unaffected either way, because tag_to_version strips the component.
  local kustomize_tag=${KUSTOMIZE_VERSION:?}
  case $kustomize_tag in
    latest | */*) ;;
    *) kustomize_tag="kustomize/$kustomize_tag" ;;
  esac
  k8s_release kustomize "$kustomize_tag" 'version' kubernetes-sigs/kustomize \
    'kustomize_v{version}_linux_{arch_go}.tar.gz' \
    --checksum-asset checksums.txt --tag-filter '^kustomize/'

  # kubeconform — kubeval's successor (kubeval is archived upstream and says so
  # in its own README).
  k8s_release kubeconform "${KUBECONFORM_VERSION:?}" '-v' yannh/kubeconform \
    'kubeconform-linux-{arch_go}.tar.gz' --checksum-asset CHECKSUMS

  # cilium CLI — the fleet's CNI. NOT the krew `cilium` plugin: that is a
  # different, third-party project (bmcustodio/kubectl-cilium) which module 36
  # also installs on purpose, because six shipped k9s plugins call
  # `kubectl cilium exec`. Keep both (MUST-FIX C10).
  k8s_release cilium "${CILIUM_CLI_VERSION:?}" 'version --client' cilium/cilium-cli \
    'cilium-linux-{arch_go}.tar.gz' \
    --checksum-url 'https://github.com/cilium/cilium-cli/releases/download/{tag}/cilium-linux-{arch_go}.tar.gz.sha256sum'

  # hubble — flow visibility for that CNI.
  k8s_release hubble "${HUBBLE_VERSION:?}" 'version' cilium/hubble \
    'hubble-linux-{arch_go}.tar.gz' \
    --checksum-url 'https://github.com/cilium/hubble/releases/download/{tag}/hubble-linux-{arch_go}.tar.gz.sha256sum'

  # argocd — app-of-apps is the deployment model, and `argocd app diff` is worth
  # having locally even without logging in.
  k8s_release argocd "${ARGOCD_VERSION:?}" 'version --client' argoproj/argo-cd \
    'argocd-linux-{arch_go}' --checksum-asset cli_checksums.txt

  # virtctl — must match the cluster's KubeVirt version, hence a manual pin.
  # config/k9s/plugins/63-kubevirt.yaml calls this binary directly, and module
  # 36 installs the krew `virt` plugin alongside it (MUST-FIX C10); doctor
  # reports the skew between the two.
  k8s_release virtctl "${VIRTCTL_VERSION:?}" 'version --client' kubevirt/kubevirt \
    'virtctl-{tag}-linux-{arch_go}' \
    --no-verify --no-verify-reason \
    "kubevirt publishes no per-asset digest: the only signature in a release is a detached GPG signature of the source tarball"

  # kubelogin — AZURE's kubelogin (Azure/kubelogin), the exec plugin for Entra
  # ID. It is a DIFFERENT project from the krew `oidc-login` plugin
  # (int128/kubelogin), which module 36 installs for the Keycloak flow. Both are
  # wanted; neither replaces the other.
  # It is also the only asset here that is a .zip, so make sure unzip exists
  # rather than failing inside the extractor.
  have unzip || pkg_install_optional unzip
  k8s_release kubelogin "${KUBELOGIN_VERSION:?}" '--version' Azure/kubelogin \
    'kubelogin-linux-{arch_go}.zip' \
    --checksum-url 'https://github.com/Azure/kubelogin/releases/download/{tag}/kubelogin-linux-{arch_go}.zip.sha256'

  # kubectl-pgo — Crunchy PGO's official CLI, and the one tool this fleet needs
  # that is not in the krew index. On PATH as kubectl-pgo it becomes
  # `kubectl pgo`.
  k8s_release kubectl-pgo "${KUBECTL_PGO_VERSION:?}" 'version --client' \
    CrunchyData/postgres-operator-client 'kubectl-pgo-linux-{arch_go}' \
    --no-verify --no-verify-reason \
    "CrunchyData publishes bare binaries with no checksum file or signature for this release"

  # velero — the on-prem backup story.
  k8s_release velero "${VELERO_VERSION:?}" 'version --client-only' velero-io/velero \
    'velero-{tag}-linux-{arch_go}.tar.gz' --checksum-asset CHECKSUM

  # crictl — k3s runs containerd, so this is the node-side debug tool. Keep its
  # minor near the kubectl stream.
  k8s_release crictl "${CRICTL_VERSION:?}" '--version' kubernetes-sigs/cri-tools \
    'crictl-{tag}-linux-{arch_go}.tar.gz' \
    --checksum-url 'https://github.com/kubernetes-sigs/cri-tools/releases/download/{tag}/crictl-{tag}-linux-{arch_go}.tar.gz.sha256'

  # dive — image-layer inspection; pairs with the k9s image plugin.
  k8s_deb dive "${DIVE_VERSION:?}" wagoodman/dive 'dive_{version}_linux_{arch_dpkg}.deb' \
    --checksum-asset 'dive_{version}_checksums.txt'

  # grpcurl — used against the fleet's Go services.
  k8s_deb grpcurl "${GRPCURL_VERSION:?}" fullstorydev/grpcurl \
    'grpcurl_{version}_linux_{arch_dpkg}.deb' \
    --checksum-asset 'grpcurl_{version}_checksums.txt'

  k8s_yq
  k8s_trivy
  return 0
}

# k8s_trivy — vendor apt repo; suite `generic`, identical on both distributions.
#   TRIVY_VERSION=apt in versions.env is the sentinel for "not pinned here": the
#   vendor repository decides the version and apt keeps it current.
#   The explicit pkg_update matters: pkg_install asks apt-cache for a CANDIDATE
#   before it refreshes the index, so a repository added seconds ago would look
#   as if it contained nothing and trivy would be dropped with a warning.
#   repo_ensure_trivy only sets NEED_APT_UPDATE=1; this is where it is honoured.
#   pkg_install also returns 0 when it drops a name it could not find, so the
#   outcome is decided by asking dpkg afterwards, not by that exit status.
k8s_trivy() {
  local rc=0
  repo_ensure_trivy || rc=$?
  case $rc in
    0) ;;
    78)
      K8S_SKIPPED+=("trivy")
      return 0
      ;;
    *)
      K8S_FAILED+=("trivy apt repository")
      return 0
      ;;
  esac
  pkg_update
  if ! pkg_install trivy; then
    K8S_FAILED+=("trivy")
    return 0
  fi
  if pkg_installed trivy || is_dry_run; then
    K8S_OK+=("trivy (apt)")
  else
    log_warn "the trivy repository is configured but apt found no 'trivy' candidate"
    K8S_SKIPPED+=("trivy")
  fi
  return 0
}

# k8s_optional_tools — INSTALL_K8S_OPT=1 only. Off even in `full`.
k8s_optional_tools() {
  if [ "${INSTALL_K8S_OPT:-0}" != 1 ]; then
    log_skip "optional kubernetes tools (kor, kube-linter, kube-bench, nerdctl, kubeseal): INSTALL_K8S_OPT=1 to install"
    return 0
  fi
  log_info "INSTALL_K8S_OPT=1 — installing the optional kubernetes tools"

  # kor — orphan/unused-resource finder. NOT `latest`: yonahd/kor's
  # releases/latest points at the Helm-CHART tag (kor-0.x), not the CLI.
  k8s_release kor "${KOR_VERSION:?}" 'version' yonahd/kor \
    "kor_Linux_${K8S_ARCH_X}.tar.gz" --checksum-asset 'kor_{version}_checksums.txt'

  # kube-linter — manifest linter for the umbrella charts' CI.
  k8s_release kube-linter "${KUBE_LINTER_VERSION:?}" 'version' stackrox/kube-linter \
    "kube-linter-linux${K8S_ARCH_LINTER}.tar.gz" \
    --no-verify --no-verify-reason \
    "stackrox publishes sigstore bundles (<asset>.sigstore.json) instead of a sha256 checksum file"

  # kube-bench — CIS benchmarks; pairs with the vm-hardening playbooks.
  k8s_deb kube-bench "${KUBE_BENCH_VERSION:?}" aquasecurity/kube-bench \
    'kube-bench_{version}_linux_{arch_dpkg}.deb' \
    --checksum-asset 'kube-bench_{version}_checksums.txt'

  # nerdctl — only useful ON a containerd node; docker covers the laptop.
  k8s_release nerdctl "${NERDCTL_VERSION:?}" '--version' containerd/nerdctl \
    'nerdctl-{version}-linux-{arch_go}.tar.gz' --checksum-asset SHA256SUMS

  # kubeseal — only if Sealed Secrets is genuinely in the fleet; this estate's
  # secrets go through External Secrets + OpenBao.
  k8s_release kubeseal "${KUBESEAL_VERSION:?}" '--version' bitnami-labs/sealed-secrets \
    'kubeseal-{version}-linux-{arch_go}.tar.gz' \
    --checksum-asset 'sealed-secrets_{version}_checksums.txt'
  return 0
}

# ---------------------------------------------------------------------------
# kubecolor's config, and completions
# ---------------------------------------------------------------------------

# k8s_kubecolor_config
#   Ships config/kubecolor/color.yaml to ~/.kube/color.yaml, create-if-absent:
#   themes are hand-tuned and kubecolor rewrites nothing, so an existing file is
#   the user's. ~/.kube/config is NEVER read or written by this module.
k8s_kubecolor_config() {
  local src="$DEVENV_HOME/config/kubecolor/color.yaml" dst="$HOME/.kube/color.yaml"
  have kubecolor || {
    log_skip "kubecolor is not installed — not shipping its config"
    return 0
  }
  [ -r "$src" ] || {
    log_warn "missing $src — skipping the kubecolor config"
    return 0
  }
  ensure_dir "$HOME/.kube" 0755 || return 0
  copy_if_absent "$src" "$dst" 0644 || return 0
  if [ "${DEVENV_CHANGED_LAST:-0}" = 1 ]; then
    log_info "wrote $dst (kubecolor reads it, or \$KUBECOLOR_CONFIG)"
  fi
  return 0
}

# k8s_completions
#   Caches the bash completion of every tool this module installed.
#   bin/devenv-completions covers the same commands, but module 10-shell runs it
#   BEFORE this module in numeric order: on a fresh box none of these binaries
#   exist yet at that point, so without this the k8s completions would only
#   appear on the second run. Every generator form below is spelled exactly as
#   bin/devenv-completions spells it, so the two writers can never produce
#   different bytes and fight over the same cache file.
#   correctness C3: only tools that really have a completion sub-command are
#   listed. Deliberately absent:
#     kubeconform  no completion command at all — it treats `completion bash` as
#                  two files to validate
#     kubeseal     `kubeseal completion bash` CONTACTS THE CLUSTER and fails (or
#                  hangs) when no sealed-secrets controller answers
#     grpcurl      not a cobra CLI
#   comp_cache discards empty or failing output, so a tool that changes its mind
#   about this never poisons the cache.
k8s_completions() {
  local c
  for c in kubectl helm k9s k3d kind kustomize argocd velero cilium hubble \
    trivy crictl kubectl-pgo kor kube-linter nerdctl; do
    comp_cache "$c"
  done
  # yq's generator is `shell-completion`, not `completion`.
  comp_cache yq yq shell-completion bash
  # `kubectl` completion under the kubecolor alias (K8): a standalone shim file,
  # never an append to the generated kubectl cache — an append is lost the next
  # time that file is regenerated. `-o default` is what keeps filename
  # completion working for the alias.
  if have kubecolor; then
    comp_shim kubecolor kubectl
    comp_shim k kubectl
  fi
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

module_main() {
  have_root || skip "the kubernetes tools install into /usr/local/bin and an apt repository; root is not available here"
  k8s_arch_init

  log_info "installing the kubernetes core into $K8S_BIN_DIR (arch ${OS_ARCH_DPKG:-unknown})"
  k8s_kubectl
  k8s_helm
  k8s_core_tools
  k8s_optional_tools
  k8s_kubecolor_config
  k8s_completions

  if [ ${#K8S_SKIPPED[@]} -gt 0 ]; then
    log_warn "not installed here: ${K8S_SKIPPED[*]}"
    log_warn "  each line above says why (no asset for ${OS_ARCH_DPKG:-this arch}, or an unresolvable pin)."
  fi
  if [ ${#K8S_FAILED[@]} -gt 0 ]; then
    log_error "these tools failed to install: ${K8S_FAILED[*]}"
    log_error "  re-run with --verbose for the failing command, or with --only kubernetes once the cause is fixed."
    return 1
  fi
  log_success "kubernetes core ready (${#K8S_OK[@]} tools)"
  log_info "next: 'devenv --only k8s-plugins' for krew and the kubectl/helm plugin roster"
  return 0
}

module_main "$@"
