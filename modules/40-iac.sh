#!/usr/bin/env bash
# meta: name=iac
# meta: desc=terraform, tflint, terraform-docs, openbao, ansible and the docs toolchain
# meta: profiles=devops,full,ci
# meta: os=any
# meta: arch=amd64,arm64
# meta: needs=
# meta: root=yes
#
# modules/40-iac.sh — infrastructure-as-code tooling.
#
#   terraform, packer          HashiCorp apt repository (suite from an allowlist,
#                              never a probe — three of their suites answer 200
#                              with an EMPTY index, see lib/repo.sh)
#   terraform-docs, tflint     pinned GitHub releases, sha256-verified
#   bao (OpenBao)              pinned release .deb; dpkg package `openbao`,
#                              binary `bao` (MUST-FIX C5)
#   ansible + collection deps  uv tool venvs (D7/K34)
#   ansible-lint, checkov,     uv tool venvs
#   yamllint, detect-secrets
#   mkdocs + mkdocs-material   one uv venv, requested as `mkdocs` (the theme ships no
#   + mike                     console script); mike is an mkdocs PLUGIN and must share it
#
# Nothing here is pinned in this file: every version comes from versions.env.
#
# Ownership notes, so two modules never fight over one tool:
#   * trivy belongs to `kubernetes` (versions.env says `# owner: kubernetes`).
#     It is installed here ONLY when it is absent, so `devenv --only iac` on a box
#     without the kubernetes module still gets the IaC misconfiguration scanner,
#     and a normal profile run is a no-op here because 35 already installed it.
#   * The uv tools below are named by SPEC 5.5 for both this module and
#     `lang-python`. uv_tool_install is idempotent and logs a skip when the tool
#     is already there, so whichever module runs first installs it and the other
#     one costs nothing.
#   * mkdocs belongs to THIS module (docs/tools.md files it under `iac`, and the
#     why-it-is-shaped-like-this comment lives in _iac_python_tools below).
#     modules/23-lang-python.sh installs it only when it is absent — that is what
#     gives `--profile minimal`, which has no iac module, a docs toolchain — with
#     the SAME spec, so the two never build two venvs for one tool.

set -euo pipefail
# shellcheck source=lib/common.sh
source "${DEVENV_HOME:?}/lib/common.sh"

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

IAC_FAILURES=()

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

# _iac_fail MSG   (private) — record a real failure and keep going.
_iac_fail() {
  IAC_FAILURES+=("$1")
  log_error "$1"
  return 0
}

# _iac_release_result BIN RC   (private)
#   Turns gh_release_install's tri-state into module semantics: 78 is "upstream
#   publishes no asset for this architecture", which is a logged skip, not a
#   failure (constraint C4 — never a silent no-op either).
_iac_release_result() {
  case $2 in
    0) return 0 ;;
    78) log_skip "$1: no release asset for ${OS_ARCH_DPKG:-this architecture}" ;;
    *) _iac_fail "$1 could not be installed" ;;
  esac
  return 0
}

# _iac_hashicorp
#   The HashiCorp apt repository, then terraform, then packer when
#   INSTALL_PACKER=1 (the `full` profile sets it). Always returns 0.
_iac_hashicorp() {
  local rc=0
  repo_ensure_hashicorp || rc=$?
  if [ "$rc" != 0 ]; then
    log_warn "HashiCorp publishes no apt suite usable on ${OS_PRETTY:-this release}."
    log_warn "  terraform and packer are not installed. Install terraform by hand from"
    log_warn "  https://developer.hashicorp.com/terraform/install if you need it here."
    return 0
  fi
  # repo_add sets NEED_APT_UPDATE=1 when it changed the sources file, and
  # pkg_install checks availability BEFORE it refreshes the index. Without this
  # line the very first run reports "no installation candidate for terraform"
  # against the index that predates the repository we just added.
  pkg_update
  if ! apt_run pkg_install terraform; then
    _iac_fail "terraform could not be installed from the HashiCorp repository"
  fi
  if [ "${INSTALL_PACKER:-0}" = 1 ]; then
    if ! apt_run pkg_install packer; then
      _iac_fail "packer could not be installed from the HashiCorp repository"
    fi
  else
    log_debug "packer: INSTALL_PACKER is not 1 (the 'full' profile sets it)"
  fi
  # terraform's completion is a `complete -C <binary>` BINDING, not generated
  # output, so it cannot go through comp_cache. The path is resolved here and
  # never hardcoded: terraform is /usr/bin/terraform from apt but /usr/local/bin
  # or ~/.local/bin from a manual install.
  comp_complete_c terraform tf t terraform
  return 0
}

# _iac_terraform_docs
#   terraform-docs: one binary in a tarball beside LICENSE and README, with a
#   published <asset> sha256sum file listing every platform. Always returns 0.
_iac_terraform_docs() {
  local rc=0
  gh_release_install terraform-docs/terraform-docs \
    'terraform-docs-{tag}-{os}-{arch_go}.tar.gz' terraform-docs \
    "${TERRAFORM_DOCS_VERSION:?TERRAFORM_DOCS_VERSION is not set}" \
    --checksum-asset 'terraform-docs-{tag}.sha256sum' || rc=$?
  _iac_release_result terraform-docs "$rc"
  return 0
}

# _iac_tflint
#   tflint ships a ZIP whose name carries NO version (tflint_linux_amd64.zip).
#   That used to need a workaround here — a stale copy of the previous release
#   sat in the download cache under exactly this name and failed the new digest on
#   every run — and no longer does: lib/net.sh keys the cache on the tag too
#   (net_cache_path) and prunes older copies. Always returns 0.
_iac_tflint() {
  local rc=0
  if ! have unzip; then
    log_skip "tflint ships a .zip and unzip is not installed — run 'devenv --only base-packages'"
    return 0
  fi
  gh_release_install terraform-linters/tflint \
    'tflint_{os}_{arch_go}.zip' tflint "${TFLINT_VERSION:?TFLINT_VERSION is not set}" \
    --checksum-asset checksums.txt || rc=$?
  _iac_release_result tflint "$rc"
  return 0
}

# _iac_openbao
#   OpenBao. MUST-FIX C5, all three halves of it: the asset is
#   openbao_<version>_linux_<arch>.deb, the dpkg package is `openbao`, and the
#   command is `bao`. Getting any one of them wrong makes the module reinstall on
#   every run (or 404 outright).
#   The .deb is the server distribution: it also lays down
#   /usr/lib/systemd/system/openbao.service, /etc/openbao/openbao.hcl and a
#   self-signed certificate under /opt/openbao/tls. Its postinst does a
#   daemon-reload and nothing else — the unit is NOT enabled and NOT started, by
#   the vendor's choice and ours. This module only ever wants the `bao` CLI.
#   Always returns 0.
_iac_openbao() {
  local rc=0
  deb_release_install openbao/openbao \
    'openbao_{version}_linux_{arch_dpkg}.deb' openbao \
    "${OPENBAO_VERSION:?OPENBAO_VERSION is not set}" \
    --bin bao --checksum-asset checksums.txt || rc=$?
  _iac_release_result bao "$rc"
  # No completion cache for `bao`: it has no completion subcommand (MUST-FIX C3).
  # `bao -autocomplete-install` writes to the user's shell rc file, which this
  # repository does not do on anyone's behalf.
  return 0
}

# _iac_trivy
#   Misconfiguration and vulnerability scanning for terraform, Kubernetes
#   manifests and images. Owned by `kubernetes`; installed here only when it is
#   missing, so the two modules can never both act in the same run.
#   Always returns 0.
_iac_trivy() {
  local rc=0
  if have trivy; then
    log_skip "trivy is already installed (owner: the kubernetes module)"
    return 0
  fi
  repo_ensure_trivy || rc=$?
  if [ "$rc" != 0 ]; then
    log_warn "the trivy apt repository could not be configured — skipping trivy"
    return 0
  fi
  pkg_update
  if ! apt_run pkg_install trivy; then
    _iac_fail "trivy could not be installed"
  fi
  return 0
}

# _iac_python_tools
#   Every Python CLI goes through `uv tool install` (D7/K17/MUST-FIX S12).
#   PEP 668's EXTERNALLY-MANAGED marker is never moved, renamed or deleted here
#   or anywhere else in this repository, and neither pip --user nor pipx nor
#   --break-system-packages appears in it.
#   Always returns 0; individual failures are recorded.
_iac_python_tools() {
  if ! have uv; then
    log_skip "uv is not on PATH — run 'devenv --only lang-python' first, then this module"
    return 0
  fi

  # K34, the single highest-risk detail of the Python migration: these three
  # packages are imported by Ansible COLLECTIONS, not by ansible itself.
  # kubernetes.core needs `kubernetes`, ansible.utils needs `netaddr`, and
  # community.general's json_query filter needs `jmespath`. `pip --user`
  # satisfied that by accident because everything shared one prefix; a per-tool
  # venv does not, so they must be named here.
  if ! uv_tool_install ansible --with kubernetes --with netaddr --with jmespath; then
    _iac_fail "uv tool install ansible failed"
  fi

  local t
  for t in ansible-lint checkov yamllint detect-secrets; do
    if ! uv_tool_install "$t"; then
      _iac_fail "uv tool install $t failed"
    fi
  done

  # THE REQUESTED PACKAGE MUST BE THE ONE THAT PROVIDES THE COMMAND.
  # `uv tool install mkdocs-material --with mike` — which is what SPEC §5.5 and
  # docs/tools.md both asked for — fails outright:
  #
  #     No executables are provided by package `mkdocs-material`; removing tool
  #     error: Failed to install entrypoints for `mkdocs-material`
  #
  # mkdocs-material is a THEME. It ships no console script; `mkdocs` does. uv
  # installs entry points only from the package it was asked for, so the theme has
  # to be a `--with`, not the target. Reproduced on debian:12 and ubuntu:24.04 in
  # the container matrix, where it failed the whole module on every run.
  #
  # mike stays in the SAME venv for the original reason: it is an mkdocs PLUGIN,
  # loaded by mkdocs's own interpreter. Installing it separately would give a
  # working `mike` command and an mkdocs that cannot see it.
  #
  # THIS MODULE OWNS mkdocs. modules/23-lang-python.sh carries the same line
  # behind a `have mkdocs` guard so a profile without `iac` still gets it; the two
  # specs must stay identical. It said `mkdocs-material --with mike` until a real
  # install failed exactly as described above, which is how the copy came to be
  # marked with an owner.
  if ! uv_tool_install mkdocs --with mkdocs-material --with mike; then
    _iac_fail "uv tool install mkdocs (with mkdocs-material and mike) failed"
  fi
  return 0
}

module_main() {
  # uv, and everything uv installs, lives in ~/.local/bin. A module runs as a
  # child process of bin/devenv with the invoking shell's PATH, which on a box
  # that has never had ~/.local/bin does not contain it yet.
  _path_prepend "$HOME/.local/bin"
  # go_ensure_path also picks up the /usr/local/go that modules/20-lang-go.sh may
  # have installed earlier in THIS run, which the invoking shell's PATH does not
  # know about yet. It adds $GOPATH/bin itself, so no second _path_prepend.
  go_ensure_path || log_debug 'no go toolchain on this box'

  _iac_hashicorp
  _iac_terraform_docs
  _iac_tflint
  _iac_openbao
  _iac_trivy
  _iac_python_tools

  if [ ${#IAC_FAILURES[@]} -gt 0 ]; then
    log_error "${#IAC_FAILURES[@]} step(s) in this module failed:"
    printf '  - %s\n' "${IAC_FAILURES[@]}" >&2
    # A deliberate failure exit: clear the ERR trap first, or lib/common.sh's
    # trap prints two more "failed (exit 1) … command: return 1" lines after the
    # list above and buries the real reason.
    trap - ERR
    exit 1
  fi
  return 0
}

module_main "$@"
