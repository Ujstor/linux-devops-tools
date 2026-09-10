#!/usr/bin/env bash
# meta: name=k8s-plugins
# meta: desc=krew, the kubectl plugin roster and the helm plugins
# meta: profiles=devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=kubectl
# meta: root=no
#
# =============================================================================
# modules/36-k8s-plugins.sh — THE PLUGIN LAYER.
#
# The user's headline gap: the old scripts/devops.sh installed nine krew plugins
# and never mentioned kyverno, oidc-login or virt — all three of which are
# installed on the live box by hand — while installing `cilium`, which it never
# explained. Everything the machine actually has is captured here, in data.
#
# WHAT RUNS AS ROOT: nothing. krew installs into ~/.krew, helm plugins into
# ~/.local/share/helm/plugins and helm-docs into ~/.local/bin. That is why this
# module is `root=no` and why it still works on a box where the user is not a
# sudoer.
#
# THE TWO DELIBERATE DUPLICATES (MUST-FIX C10) — do not "deduplicate" them:
#   krew `cilium` + the cilium CLI. The krew plugin is bmcustodio/kubectl-cilium
#     (exec into the cilium agent on a node); the CLI is cilium/cilium-cli
#     (`cilium status`, `cilium connectivity test`). Six shipped k9s plugins in
#     config/k9s/plugins/60-cilium.yaml call `kubectl cilium exec`, so removing
#     the plugin breaks them. Module 35 installs the CLI.
#   krew `virt` + virtctl. config/k9s/plugins/63-kubevirt.yaml calls the
#     `virtctl` BINARY (12 invocations); `kubectl virt` is the same tool reached
#     through krew. Module 35 installs the binary pinned to the cluster's
#     KubeVirt version; the skew between the two is reported below and by
#     `devenv doctor`.
# Likewise krew `oidc-login` (int128/kubelogin, the Keycloak flow) and the
# `kubelogin` binary module 35 installs (Azure/kubelogin, Entra ID) are two
# different projects with confusingly similar names. Both are wanted.
#
# HELM: `schema-gen` IS ARCHIVED (MUST-FIX C11). karuppiah7890/helm-schema-gen
# was last pushed 2021-07-08 and is flagged archived upstream; the live box runs
# it against charts that ship to a fleet. The maintained replacement is
# losisin/helm-values-schema-json, which registers as `schema` — note that the
# command changes from `helm schema-gen values.yaml` to `helm schema`. This
# module installs `schema` and REPORTS `schema-gen` with the exact uninstall
# line; it never uninstalls a plugin for you (MUST-FIX S9).
#
# UPDATING LATER (MUST-FIX P5). The plugin layer is not inert after the first
# install:
#     devenv --only k8s-plugins --upgrade
# runs `kubectl krew upgrade` for every installed plugin and `helm plugin update`
# for every registered plugin. Without --upgrade this module only ever ADDS what
# is missing, so a normal re-run stays fast and offline-safe.
#
# IDEMPOTENCY. `krew install` skips an already-installed plugin and exits 0, and
# `helm plugin install` exits 1 with "plugin already exists" — which is why the
# helm guard matches the REGISTERED NAME (column 1 of `helm plugin list`) and
# not the repository URL: losisin/helm-values-schema-json registers as `schema`
# and aslafy-z/helm-git registers as `helm-git`, not `git`.
# =============================================================================

set -euo pipefail
source "${DEVENV_HOME:?}/lib/common.sh"

# ---------------------------------------------------------------------------
# The rosters — the single source of truth for what this box runs
# ---------------------------------------------------------------------------

# CORE (19). Installed unconditionally. Every name was checked against the
# krew-index manifest list; the four marked (live) are what the machine already
# had and what no script installed.
KREW_CORE=(
  ctx               # ahmetb/kubectx — context switching, constant across two sites
  ns                # ahmetb/kubectx — namespaces
  neat              # strips managedFields/status before a live object becomes a manifest
  tree              # ownerReferences tree; Rook, KubeVirt, PGO, ESO all mint children
  stern             # multi-pod log tail (same upstream as the standalone binary)
  node-shell        # root shell on a node without ssh — on-prem Proxmox work
  oidc-login        # (live) int128/kubelogin — the Keycloak OIDC flow for kubectl
  kyverno           # (live) the Kyverno CLI as a plugin: `kyverno apply` / `test`
  rook-ceph         # ceph status, toolbox and OSD ops on the on-prem storage
  virt              # (live) KubeVirt VM lifecycle; see the C10 note above
  cilium            # (live) exec into the cilium agent; k9s 60-cilium.yaml needs it
  view-secret       # read path for secrets
  modify-secret     # edit path, with implicit base64
  get-all           # `kubectl get all` misses CRDs — this does not
  resource-capacity # requests/limits/utilisation per node, for sizing a k3s node
  whoami            # with OIDC and a dozen kubeconfigs, "who am I here" is daily
  explore           # `kubectl explain` with a fuzzy finder (uses fzf)
  df-pv             # PV usage across Rook-Ceph and Crunchy PVCs
  deprecations      # kubepug — API deprecation scan before each k3s minor bump
)

# EXTRAS (14). Only with KREW_EXTRAS=1, which the `full` profile sets.
KREW_EXTRAS_LIST=(
  rbac-tool  # supersedes access-matrix, who-can and rbac-lookup — install one, not three
  rolesum    # per-subject RBAC summary; complements rbac-tool's resource-first view
  lineage    # dependency graph INCLUDING custom resources, where `tree` stops
  status     # dense human status for any resource
  blame      # reads managedFields: did Argo or a human last write this field?
  images     # image inventory across the cluster
  outdated   # which running images have newer tags upstream
  pv-migrate # move PVC data between StorageClasses (local-path <-> Rook-Ceph)
  browse-pvc # mount and browse a PVC
  konfig     # merge/split kubeconfigs — matches the per-cluster files in ~/.kube
  gadget     # Inspektor Gadget: eBPF tracing. HEAVY — deploys a DaemonSet
  sniff      # tcpdump in a pod
  popeye     # cluster sanity scan (krew, not the standalone binary)
  score      # kube-score against rendered manifests / `helm template` output
)

# DELIBERATELY NOT INSTALLED, so nobody re-adds them by accident:
#   snap                     krew's own description is "delete half of the pods in a
#                            namespace or cluster" — a chaos plugin. Never on a box
#                            that holds fleet kubeconfigs.
#   ktop, view-allocations   overlap k9s and resource-capacity.
#   access-matrix, who-can,  all subsumed by rbac-tool.
#   rbac-lookup
#   cnpg                     CloudNativePG. This fleet is Crunchy PGO — module 35
#                            installs kubectl-pgo, which is not in the krew index.
#   kubent, netshoot,        not in the krew index at all. `deprecations` covers
#   snapshot                 kubent; netshoot is a container image, shipped as the
#                            `kdebug` shell function in ~/.bashrc.d/30-k8s.sh.
#   cert-manager,            conditional on a FLEET FACT this repo cannot probe
#   ingress-nginx            from a laptop — see k8sp_report_conditional().

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Set by k8sp_krew_path before it prepends anything: whether $KREW_ROOT/bin was
# already on the PATH this module INHERITED, which is the only honest answer to
# "will my next login shell find kubectl-ctx".
K8SP_KREW_INHERITED_PATH=0

# k8sp_krew_path
#   Puts $(krew_root)/bin on THIS process's PATH, remembering whether it was
#   there already.
#   This is load-bearing for idempotency, not a convenience: krew_bootstrap's
#   version gate is `kubectl krew version`, which resolves kubectl-krew through
#   PATH. On a box where krew is installed but not yet on the login PATH — a
#   fresh container, or any first run before `exec bash -l` — the gate would
#   fail and the krew self-install would run again on EVERY invocation, so the
#   run-twice test would see a change that is not one. Verified in debian:12.
#   Always returns 0.
k8sp_krew_path() {
  local root
  root=$(krew_root)
  case ":${PATH}:" in
    *":$root/bin:"*)
      K8SP_KREW_INHERITED_PATH=1
      ;;
    *)
      K8SP_KREW_INHERITED_PATH=0
      PATH="$root/bin:$PATH"
      ;;
  esac
  export PATH KREW_ROOT="$root"
  return 0
}

# k8sp_krew_on_path
#   Reports whether $(krew_root)/bin will be on the PATH of the user's next
#   shell. The permanent export belongs to ~/.bashrc.d/30-k8s.sh, which module
#   10-shell writes; this module never appends to a dotfile. Always returns 0.
k8sp_krew_on_path() {
  [ "$K8SP_KREW_INHERITED_PATH" = 0 ] || return 0
  log_info "$(krew_root)/bin is not on your login PATH yet."
  log_info "  ~/.bashrc.d/30-k8s.sh exports it (module 'shell'); start a new shell with"
  log_info "  'exec bash -l' to pick it up. Nothing was appended to ~/.bashrc."
  return 0
}

# k8sp_plugin_version PLUGIN
#   Prints the version krew INSTALLED for PLUGIN, from its receipt.
#   Not `kubectl krew list`: that prints bare plugin names, one per line, with no
#   version column (which is exactly why lib/lang.sh matches it with `grep -qx`).
#   Not `kubectl krew info` either: its VERSION line is what the INDEX offers,
#   not what is on disk — on this box those differ. Best effort, read-only:
#   returns 1 when there is no receipt.
k8sp_plugin_version() {
  local p=${1:?k8sp_plugin_version: PLUGIN required} f
  f="$(krew_root)/receipts/$p.yaml"
  [ -r "$f" ] || return 1
  awk '$1 == "version:" { print $2; exit }' "$f"
}

# k8sp_report_virt_skew
#   K11: the krew `virt` plugin and the standalone virtctl are the same tool from
#   two lifecycles, and config/k9s/plugins/63-kubevirt.yaml calls the binary. A
#   version difference is not an error — it is worth knowing about. Reports only.
k8sp_report_virt_skew() {
  local krew_v bin_v
  krew_v=$(k8sp_plugin_version virt) || krew_v=''
  bin_v=$(bin_version virtctl 'version --client') || bin_v=''
  [ -n "$krew_v" ] || return 0
  [ -n "$bin_v" ] || return 0
  if [ "${krew_v#v}" != "${bin_v#v}" ]; then
    log_warn "kubectl virt (krew) is $krew_v while virtctl is $bin_v"
    log_warn "  virtctl must match the cluster's KubeVirt version — that is the pinned one"
    log_warn "  (VIRTCTL_VERSION in versions.env). The krew copy follows the krew index."
  else
    log_debug "virt/virtctl agree at $bin_v"
  fi
  return 0
}

# k8sp_report_conditional
#   cert-manager and ingress-nginx are useful only when the cluster in front of
#   you actually runs them.
#   RULING: this module does NOT probe the cluster to find out. A probe means
#   an API call on the current context, and on an OIDC context that call opens a
#   browser login — an installer must never do that. So they are reported, with
#   the exact command, and can be added non-interactively with
#   KREW_PLUGINS_EXTRA. Always returns 0.
k8sp_report_conditional() {
  local missing=() p
  for p in cert-manager ingress-nginx; do
    if ! k8sp_plugin_version "$p" >/dev/null 2>&1; then missing+=("$p"); fi
  done
  if [ ${#missing[@]} -eq 0 ]; then
    log_debug "the fleet-conditional plugins are already installed"
    return 0
  fi
  log_info "fleet-conditional plugins, not installed by default: ${missing[*]}"
  for p in "${missing[@]}"; do
    case $p in
      cert-manager) log_info "  kubectl krew install cert-manager    # only where cert-manager runs" ;;
      ingress-nginx) log_info "  kubectl krew install ingress-nginx   # only where ingress-nginx is the ingress" ;;
    esac
  done
  log_info "  or set KREW_PLUGINS_EXTRA='${missing[*]}' and re-run this module."
  return 0
}

# ---------------------------------------------------------------------------
# krew
# ---------------------------------------------------------------------------

# k8sp_krew
#   Bootstraps krew and installs the roster one plugin at a time after a single
#   index update — K24: krew's batch path returns non-zero when ANY plugin
#   fails, and under `set -e` one transient GitHub 5xx would kill a 19-plugin
#   run. krew itself is pinned to $KREW_VERSION (versions.env) and verified
#   against the .sha256 sidecar by lib/lang.sh's krew_bootstrap, which also
#   closes stdin — krew warns about a piped stdin otherwise.
k8sp_krew() {
  local extra=()
  k8sp_krew_path
  krew_bootstrap || {
    log_warn "krew could not be installed — skipping the kubectl plugin roster"
    return 1
  }
  k8sp_krew_on_path
  krew_install_plugins "${KREW_CORE[@]}"
  if [ "${KREW_EXTRAS:-0}" = 1 ]; then
    log_info "KREW_EXTRAS=1 — installing the optional roster (${#KREW_EXTRAS_LIST[@]} plugins)"
    krew_install_plugins "${KREW_EXTRAS_LIST[@]}"
  else
    log_skip "optional krew roster (${#KREW_EXTRAS_LIST[@]} plugins): --extras / KREW_EXTRAS=1 to install"
  fi
  if [ -n "${KREW_PLUGINS_EXTRA:-}" ]; then
    # Deliberately unquoted: this is a user-supplied, space-separated list.
    # shellcheck disable=SC2206
    extra=(${KREW_PLUGINS_EXTRA})
    log_info "KREW_PLUGINS_EXTRA — also installing: ${extra[*]}"
    krew_install_plugins "${extra[@]}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# helm plugins
# ---------------------------------------------------------------------------

# k8sp_helm_plugins
#   diff / schema / unittest always; secrets and helm-git under KREW_EXTRAS.
#   Every one is guarded on its registered name, so a re-run is silent.
k8sp_helm_plugins() {
  have helm || {
    log_skip "helm is not installed — skipping the helm plugins (run 'devenv --only kubernetes' first)"
    return 0
  }
  if ! have git; then
    log_warn "git is missing: 'helm plugin install' clones the plugin repository and will fail"
  fi

  # diff — the local equivalent of the fleet's helm-deploy diff job.
  helm_plugin_ensure diff https://github.com/databus23/helm-diff \
    --version "${HELM_DIFF_VERSION:?HELM_DIFF_VERSION unset}"

  # schema — REPLACES the archived schema-gen (C11). `helm schema`, not
  # `helm schema-gen values.yaml`.
  helm_plugin_ensure schema https://github.com/losisin/helm-values-schema-json \
    --version "${HELM_SCHEMA_VERSION:?HELM_SCHEMA_VERSION unset}"

  # unittest — the umbrella charts wrap a shared library chart, and library
  # regressions are exactly what this catches.
  helm_plugin_ensure unittest https://github.com/helm-unittest/helm-unittest \
    --version "${HELM_UNITTEST_VERSION:?HELM_UNITTEST_VERSION unset}"

  if [ "${KREW_EXTRAS:-0}" = 1 ]; then
    # secrets — only pays off with SOPS-encrypted values; this estate uses
    # External Secrets + OpenBao, so it is opt-in.
    helm_plugin_ensure secrets https://github.com/jkroepke/helm-secrets \
      --version "${HELM_SECRETS_VERSION:?HELM_SECRETS_VERSION unset}"
    # helm-git — registers as `helm-git`, NOT `git`. Only needed when a chart
    # dependency points at a git repository instead of a registry.
    helm_plugin_ensure helm-git https://github.com/aslafy-z/helm-git
  else
    log_skip "optional helm plugins (secrets, helm-git): --extras / KREW_EXTRAS=1 to install"
  fi

  k8sp_report_schema_gen
  return 0
}

# k8sp_report_schema_gen
#   MUST-FIX C11 + S9: report the archived plugin, never uninstall it.
k8sp_report_schema_gen() {
  helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx schema-gen || return 0
  log_warn "the helm plugin 'schema-gen' is ARCHIVED upstream (karuppiah7890, last push 2021-07-08)."
  log_warn "  'schema' (losisin/helm-values-schema-json) is installed as its maintained replacement."
  log_warn "  Migrate the chart Makefiles from 'helm schema-gen values.yaml' to 'helm schema', then:"
  log_warn "      helm plugin uninstall schema-gen"
  log_warn "  devops-env-config does not remove plugins you installed."
  return 0
}

# ---------------------------------------------------------------------------
# helm-docs — a binary, not a plugin
# ---------------------------------------------------------------------------

# k8sp_helm_docs
#   norwoodj/helm-docs renders the chart READMEs every umbrella in the fleet
#   carries. It is NOT a helm plugin (it is a standalone Go binary), and it was
#   in the old scripts/tools.sh, so it must not vanish in the rewrite.
#   Installed into ~/.local/bin because this module never asks for root; the
#   go-installed copy in ~/go/bin, if any, is reported by k8sp_warn_shadow.
#   The asset uses GoReleaser's mixed convention — Linux_x86_64 for amd64 and
#   Linux_arm64 for arm64 — so the arch string is computed rather than tokenised.
k8sp_helm_docs() {
  local dest="$HOME/.local/bin" want arch rc=0
  want=$(tag_to_version "${HELM_DOCS_VERSION:?HELM_DOCS_VERSION unset}")
  case ${OS_ARCH_DPKG:-amd64} in
    amd64) arch=x86_64 ;;
    arm64) arch=arm64 ;;
    *) arch=${OS_ARCH_GO:-amd64} ;;
  esac
  if [ -x "$dest/helm-docs" ] && "$dest/helm-docs" --version 2>&1 | grep -qF "$want"; then
    log_skip "helm-docs is already $want"
    k8sp_warn_shadow helm-docs "$dest/helm-docs"
    return 0
  fi
  gh_release_install norwoodj/helm-docs "helm-docs_{version}_Linux_${arch}.tar.gz" \
    helm-docs "$HELM_DOCS_VERSION" --dest "$dest" --checksum-asset checksums.txt || rc=$?
  case $rc in
    0) k8sp_warn_shadow helm-docs "$dest/helm-docs" ;;
    78) log_skip "helm-docs publishes no asset for ${OS_ARCH_DPKG:-this architecture}" ;;
    *) log_warn "helm-docs failed to install (exit $rc)" ;;
  esac
  return 0
}

# k8sp_warn_shadow BIN PATH
#   Reports another copy of BIN that wins on PATH. On the live box ~/go/bin
#   precedes ~/.local/bin and holds a go-installed helm-docs. Reported, never
#   removed. Always returns 0.
k8sp_warn_shadow() {
  local bin=${1:?k8sp_warn_shadow: BIN required} mine=${2:?k8sp_warn_shadow: PATH required} found
  have "$bin" || return 0
  found=$(command -v "$bin") || return 0
  [ "$found" != "$mine" ] || return 0
  [ -e "$mine" ] || return 0
  log_warn "$bin on PATH is $found, while this module installed $mine"
  log_warn "  the earlier PATH entry wins; 'devenv doctor' lists duplicate binaries."
  return 0
}

# ---------------------------------------------------------------------------
# update path (MUST-FIX P5)
# ---------------------------------------------------------------------------

# k8sp_upgrade
#   Only with --upgrade / DEVENV_UPGRADE=1. Refreshes the whole plugin layer:
#   the krew index, every installed krew plugin, and every registered helm
#   plugin. Always returns 0 — a plugin that fails to upgrade is a warning.
k8sp_upgrade() {
  if [ "${DEVENV_UPGRADE:-0}" != 1 ]; then
    log_debug "plugin upgrade not requested (devenv --only k8s-plugins --upgrade)"
    return 0
  fi
  log_step "refreshing the plugin layer (--upgrade)"
  krew_upgrade_all
  # shellcheck disable=SC2119  # no argument means "every registered plugin", by contract
  helm_plugin_update
  log_step_end
  return 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

module_main() {
  have kubectl || skip "kubectl is not installed — install it first with 'devenv --only kubernetes'"
  local rc=0

  k8sp_krew || rc=1
  k8sp_helm_plugins
  k8sp_helm_docs
  k8sp_upgrade
  k8sp_report_virt_skew
  k8sp_report_conditional

  # stern ships its completion behind a flag of its own rather than a
  # sub-command, so it cannot go through comp_cache's default form.
  # helm-docs is deliberately absent: it has NO `completion` sub-command, and
  # `helm-docs completion bash` runs the DOC GENERATOR over the current
  # directory — which would rewrite chart READMEs wherever devenv was started.
  comp_cache kubectl-stern kubectl-stern --completion=bash

  if [ "$rc" != 0 ]; then
    log_error "krew itself could not be installed, so the kubectl plugin roster is missing."
    log_error "  The helm side above is unaffected. Re-run 'devenv --only k8s-plugins' once"
    log_error "  the download works again."
    return 1
  fi
  log_success "plugin layer ready"
  log_info "refresh it later with:  devenv --only k8s-plugins --upgrade"
  return 0
}

module_main "$@"
