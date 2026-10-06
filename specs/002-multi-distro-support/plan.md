# 002 — plan

**How.** The intent is [spec.md](spec.md); this file may name every tool. The reference for the
pattern is the fleet's host automation — its configuration, hardening, update and cluster-deployment
playbooks, each already multi-distribution: one declared matrix, a gate that refuses
before any change, **names in data and mechanisms in code**, an identical key set per family
proven by a test, and a lab loop with baseline rollback. This plan transposes that pattern from
Ansible to this repository's bash library without changing its module contract.

## Families and the matrix (FR-001…005)

| `OS_FAMILY` | `OS_DISTRO` (`ID`) | releases | `OS_PKG_MGR` | container image (CI) |
|---|---|---|---|---|
| `debian` | `debian` | 12, 13 | `apt` | `docker.io/library/debian:{12,13}` |
| `debian` | `ubuntu` | 22.04, 24.04, 26.04 | `apt` | `docker.io/library/ubuntu:{22.04,24.04,26.04}` |
| `redhat` | `almalinux` | 9, 10 | `dnf` | `docker.io/library/almalinux:{9,10}` |
| `redhat` | `rocky` | 9, 10 | `dnf` | `docker.io/rockylinux/rockylinux:{9,10}` |
| `redhat` | `fedora` | 43, 44 | `dnf` (dnf5) | `docker.io/library/fedora:{43,44}` |
| `suse` | `opensuse-leap` | 16.0 | `zypper` | `docker.io/opensuse/leap:16.0` |
| `arch` | `arch` | rolling | `pacman` | `docker.io/library/archlinux:latest` |

**D1 — one declaration: `config/os-support.list`** (FR-002). Whitespace-separated rows
`family distro release image lab`, `#` comments. `release` is the exact `VERSION_ID` for Ubuntu and
Leap, the major for Debian/EL/Fedora, `rolling` for Arch. `lab` is `yes|no`. Read by:

- `lib/os.sh` — the run-time gate (tested vs untested).
- `tests/docker/matrix.sh` — its default `IMAGES` (no hard-coded list any more; `SOFT_IMAGES`
  defaults to empty).
- `tests/policy/os-support.sh` (new, `make lint-os-support`, in `make check`) — fails when
  `.gitlab-ci.yml`'s `container_matrix_images`, `.github/workflows/ci.yml`'s matrix, or any `lab=yes`
  row of the internal lab inventory disagree with the list (SC-006). GitLab includes cannot read a
  file at pipeline creation, so the CI input is a copy that this gate keeps honest.

**D2 — detection (`lib/os.sh`).** `os_detect` keeps every existing variable (Debian-family output
must stay byte-identical, FR-008) and adds:

| variable | values |
|---|---|
| `OS_FAMILY` | `debian` · `redhat` · `suse` · `arch` · empty (unknown) |
| `OS_DISTRO` | the os-release `ID` (`almalinux`, `rocky`, `fedora`, `opensuse-leap`, `arch`, `debian`, `ubuntu`, …) |
| `OS_RELEASE` | the matrix form of the release (see D1) |
| `OS_PKG_MGR` | `apt` · `dnf` · `zypper` · `pacman` |
| `OS_SUPPORT` | `tested` (a row in the list) · `untested` (family known, row absent) · empty |

Family from `ID`, then `ID_LIKE` tokens: `debian|ubuntu → debian`, `rhel|centos|fedora → redhat`,
`suse|opensuse|sles → suse`, `arch|archlinux → arch`. `OS_FLAVOR` stays `debian|ubuntu|''` and is
still what the Debian-only paths (codenames, deb822) key on. `os_require_supported` becomes: empty
family → refuse (message lists the matrix rendered from the list, FR-004); `untested` → exactly one
`log_warn` naming the nearest tested releases (FR-003); `tested` → silent. `OS_ARCH_DPKG` stays the
canonical arch name (it already falls back to `uname` without dpkg); add `OS_ARCH_RPM`
(`x86_64|aarch64`).

**D3 — family data: `lib/family/<family>.sh`** (FR-007, FR-013). Four files, each defining the
**identical** set of `FAM_*` variables — the bash form of the siblings' `vars/<family>.yml`, and
held to the same rule by a test (`tests/unit/test_family.sh`: same key set, no empty value except
where the key is documented as optional). Sourced once by `lib/os.sh` after detection. Keys:

| key | debian | redhat | suse | arch |
|---|---|---|---|---|
| `FAM_ADMIN_GROUP` | sudo | wheel | wheel | wheel |
| `FAM_CA_ANCHOR_DIR` | /usr/local/share/ca-certificates | /etc/pki/ca-trust/source/anchors | /etc/pki/trust/anchors | /etc/ca-certificates/trust-source/anchors |
| `FAM_CA_REFRESH` | update-ca-certificates | update-ca-trust | update-ca-certificates | trust extract-compat |
| `FAM_CA_BUNDLE` | /etc/ssl/certs/ca-certificates.crt | /etc/pki/tls/certs/ca-bundle.crt | /etc/ssl/ca-bundle.pem | /etc/ssl/certs/ca-certificates.crt |
| `FAM_PKG_QUERY` | dpkg-query | rpm | rpm | pacman |
| `FAM_MAC` | none | selinux | selinux | none |
| `FAM_PKG_FINGERPRINT` | `dpkg-query -W -f='${Package} ${Version}\n'` | `rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n'` | (as redhat) | `pacman -Q` |

**D4 — mechanisms: package backends** (FR-007, FR-010, FR-012). `lib/pkg.sh` keeps its whole public
API (`pkg_update`, `pkg_installed`, `pkg_candidate_version`, `pkg_available`, `pkg_install`,
`pkg_install_optional`, `pkg_install_first`, `pkg_install_local`, `pkg_remove`, `pkg_purge`,
`pkg_conflicts_report`, `pkg_upgrade`) — modules do not change. Each body dispatches to
`_pkg_<mgr>_<op>` in `lib/pkg_<mgr>.sh` (`apt`, `dnf`, `zypper`, `pacman`). The apt backend is the
current code moved verbatim (FR-008). Contract per backend: `refresh` (once per run, stamp),
`installed NAME`, `candidate NAME`, `install NAME…` (no weak deps / recommends), `install_local FILE`
(`.deb` on apt, `.rpm` on dnf/zypper; pacman: unsupported → 78), `upgrade_one NAME`, `upgrade_all`,
`mark_manual NAME`. The two direct `apt-get` calls in modules (35 `--only-upgrade`, 91
`apt-mark`/`autoremove`) move behind `pkg_upgrade_one` / `pkg_mark_manual`.

- **dnf**: `dnf -y install --setopt=install_weak_deps=False`; `rpm -q` for installed; candidate via
  `dnf repoquery --latest-limit=1 --qf '%{version}-%{release}\n'` (dnf4 and dnf5 both accept it);
  refresh = `dnf -y makecache`.
- **zypper**: `zypper --non-interactive --gpg-auto-import-keys` is **never** used (sibling rule:
  keys are imported explicitly); install `--no-recommends`; `rpm -q`; candidate from
  `zypper --xmlout info`; refresh = `zypper --non-interactive refresh`.
- **pacman**: install `pacman -S --needed --noconfirm` against the current sync DB. **Never `-Sy`
  without `-u`** (FR-012). An empty or stale sync DB (a target that 404s, or no DB) makes the
  install a skip with the reason "the package index needs a full upgrade: re-run with --upgrade";
  with `--upgrade`, the backend runs `pacman -Syu --needed --noconfirm <targets>` once.
- **Add-on repositories** — `pkg_ensure_addon` replaces `pkg_ensure_universe` (kept as an alias):
  Ubuntu → universe (today's code); EL (Alma/Rocky) → `epel-release` + CRB
  (`dnf config-manager --set-enabled crb`); Fedora, Leap, Arch → nothing. Reported via `changed`.

**D5 — package names: `config/packages.map`** (FR-007). Rows keyed by today's Debian name:
`debian-name redhat suse arch`, where `=` means the same name and `-` means "not available on this
family" (the install becomes a logged skip with the reason "no <family> package"). `pkg_install`
translates every name through the map before calling the backend; on the Debian family the map is
the identity and is never consulted (FR-008). Example rows: `build-essential gcc,gcc-c++,make
gcc,gcc-c++,make base-devel`; `xz-utils xz xz xz`; `fd-find fd-find fd fd`; `bind9-dnsutils
bind-utils bind-utils bind`; `apache2-utils httpd-tools apache2-utils apache`; `libssl-dev
openssl-devel libopenssl-devel openssl`; `p7zip-full p7zip p7zip p7zip`.

**D6 — third-party sources** (FR-009). Every `repo_ensure_<vendor>` keeps its signature and
dispatches on `OS_FAMILY`: `debian` → today's deb822 code; `redhat` → `/etc/yum.repos.d/<name>.repo`
with `gpgcheck=1`, `repo_gpgcheck` where the vendor signs metadata, and `rpm --import` of the key
(validated as an OpenPGP key and optionally digest-pinned exactly like the apt keys); `suse` →
`/etc/zypp/repos.d/<name>.repo` + `rpm --import`; `arch` → returns 78 (no vendor publishes pacman
repositories). Fallback order when a vendor has no source for the family: the distribution's own
package → a verified release artifact → `uv tool install` (Python CLIs) → skip with a reason.

| vendor | redhat | suse | arch |
|---|---|---|---|
| docker | `download.docker.com/linux/{centos,fedora}` (`rhel` for Alma/Rocky uses the `centos` tree) | distro `docker`, `docker-buildx`, `docker-compose` | distro `docker`, `docker-buildx`, `docker-compose` |
| hashicorp | `rpm.releases.hashicorp.com/{RHEL,fedora}` | release zip (`SHA256SUMS` verified) | distro `terraform` |
| kubernetes | `pkgs.k8s.io/core:/stable:/<minor>/rpm/` | same rpm repo via zypper | distro `kubectl` (version reported against `K8S_MINOR`) |
| github-cli | `cli.github.com/packages/rpm/gh-cli.repo` | same | distro `github-cli` |
| azure-cli | `packages.microsoft.com/yumrepos/azure-cli` (EL9/10), uv on Fedora | `uv tool install azure-cli` | `uv tool install azure-cli` |
| trivy | `aquasecurity.github.io/trivy-repo/rpm/releases/$basearch/` | same | distro `trivy` |

`repo_ensure_docker` is fixed (it writes a `Components: main` Docker's archive does not have and is
never called) and 30-containers uses it instead of its private copy.

**D7 — release artifacts** (FR-015, P3). `deb_release_install` is replaced by
`pkg_release_install REPO PKG VERSION --deb PAT [--rpm PAT] [--tarball PAT --bin NAME] [checksum
opts]`: apt → the `.deb` exactly as today (FR-008); dnf/zypper → the `.rpm` through
`pkg_install_local` when `--rpm` is given, else the tarball; pacman → the tarball. A package file is
never handed to `gh_release_install` as a binary; the `${pattern%.deb}.tar.gz` guess is deleted.
Callers: k9s, kubecolor, dive, grpcurl, kube-bench (35), openbao (40), yazi, fastfetch (10),
glab (45). Each caller's rpm/tarball pattern is checked against the pinned release's real asset list.

**D8 — applicability** (FR-014). New module header key `family=` (comma list, default: all), gated in
`lib/registry.sh:module_gate` before `os=`, skip message `<module>: not applicable on the <family>
family`. `91-purge-desktop`, `92-migrate` and `70-wsl`'s `wslu` step are `family=debian`;
`58-headless-browser`'s `install-deps` step skips with a reason off the Debian family (Playwright's
helper is apt-only). `tests/policy/rules.sh` learns the key; `tests/policy/docs-drift.sh` and
`docs/modules.md` get a family column.

**D9 — access control** (FR-011). Files installed into `/usr/local/bin` on an SELinux family get
`restorecon` when `restorecon` exists (`fs_install` path); nothing ever calls `setenforce` or edits
`/etc/selinux/config` — a policy rule enforces it.

## Proof (FR-016…022)

**D10 — container matrix.** `tests/docker/entry.sh` bootstraps per family (`apt-get` / `dnf` /
`zypper` / `pacman -Syu` for the image only), fingerprints packages with `FAM_PKG_FINGERPRINT`, and
expects the family's sudo hint. `matrix.sh` reads its images from `config/os-support.list`.
`.gitlab-ci.yml`: `$CI_SHELL@1.3.0` (per-job storage, FR-018), `container_matrix_images` = the 13
fully qualified images, `container_registry_prefix: ''`, `enable_container_soft_matrix: false`
(SC-007), `container_profile: devops` (the default set), `container_timeout: 90m`, and
`workflow:rules` that drop the branch pipeline when an MR is open (one pipeline per change). The Arch
row passes `--upgrade` (D4, FR-012).

**D11 — offline gate proof** (SC-004). `tests/unit/test_os.sh` gains an os-release fixture for every
supported release, a derivative per family (Linux Mint, Pop!_OS, CentOS Stream, RHEL, Oracle
Linux, Manjaro, EndeavourOS, Tumbleweed) and unsupported families (Alpine, Gentoo, NixOS, Void):
accepted-tested, accepted-untested with exactly one warning, refused with no change.

**D12 — lab proof (internal).** Before a release, the candidate is proven on a real machine of
every supported release that has one, each with a restorable known-good baseline: restore the
baseline, run the container matrix's own `tests/docker/entry.sh` on the machine — the same
assertions (preview changes nothing, the no-sudo path, install, a second install that changes
nothing), on a real init system, real access control and real disks — record the FR-020 evidence
row, restore the baseline. Machines too small for the default set get temporary swap, recorded in
the evidence. The tooling, its inventory and the evidence log are internal and never part of the
public variant (FR-021). Ubuntu 22.04 has no lab machine (A-01): it is proven by the matrix alone,
and the evidence says so.

## Prerequisite outside this repo

**tmux-config's installer pulls TPM on every run** (`git -C ~/.tmux/plugins/tpm pull --ff-only`),
writing `FETCH_HEAD`/`ORIG_HEAD` — the second-run check fails on every release in the full and
default profiles (found 2026-10-06, debian:12 and ubuntu:24.04). Fix in tmux-config (internal and
public): pull TPM only when the checkout is missing or under its own `--update` flag; release it
before the matrix runs the default profile.

## Constitution check

No `.specify/` constitution exists here; 001's spec and plan are the standing rules. This plan keeps:
a single pin file (001 FR-003 — `packages.map` and `os-support.list` are data, not pins), dry-run as
a true no-op (every new mutation goes through `run`/`run_sudo`), no removal of operator packages,
verified downloads (001 FR-017 — rpm keys get the same validation and optional digest pin as apt
keys), and the public-repo privacy gate (lab material is internal-only).

## Risks

| risk | mitigation |
|---|---|
| Fedora/Arch move weekly; an upstream package rename breaks the gate | the matrix is the early warning; the map is one line to fix |
| A vendor drops a family | D6's fallback order, and a skip with a reason (FR-006) |
| 13 parallel jobs × the default profile overload the CI runner | per-job storage; one pipeline at a time; `container_timeout: 90m` |
| Leap's `Defaults targetpw` and Ubuntu 26.04's sudo-rs | the lab user is created with an explicit NOPASSWD drop-in; `run_sudo` is exercised on both in the lab |

## Deviations recorded during implementation

Where the shipped code differs from the decisions above. The code is the behaviour; this table
says why it moved.

| # | decision | shipped | why |
|---|---|---|---|
| V1 | D3 `FAM_CA_BUNDLE` (redhat) | `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` | Fedora 44 ships without `/etc/pki/tls/certs/ca-bundle.crt`, which was only a symlink to the extracted bundle through Fedora 43 and EL 10. The extracted bundle is the file `update-ca-trust` writes and exists on all six RedHat releases |
| V2 | D6 azure-cli (redhat) | EL 9/10: `packages.microsoft.com/rhel/<major>/prod/`, narrowed with `includepkgs=azure-cli`. EL 10 is signed with `microsoft-2025.asc`, pinned separately (`AZURE_CLI_2025_KEY_SHA256`) | `yumrepos/azure-cli` holds el7 builds only. Fedora still takes uv |
| V3 | D6 kubernetes (arch) | the official `dl.k8s.io` kubectl, newest patch of the `K8S_MINOR` stream, `.sha256`-verified and gated on the installed version; the map's arch `kubectl` is `-` | Arch's own kubectl follows Arch — three minors past a v1.34 fleet on 2026-10-06, beyond kubectl's ±1 skew |
| V4 | D10 the Arch row passes `--upgrade` | no `--upgrade` on Arch | the harness levels the image with its sync database at setup (`pacman -Syu` for the image only), so plain installs resolve. `--upgrade` on both runs refreshed every helm plugin (new `FETCH_HEAD`, rebuilt binary), so no second run could be a no-op. The stale-index skip (FR-012) is proven by the unit tests and the lab |
| V5 | D4 zypper `install_local` | a local `.rpm` is installed with `--no-gpg-checks --no-refresh` (and `--allow-unsigned-rpm`), after its checksum is verified | kubecolor's and OpenBao's rpms are signed with vendor keys no repository imports, and zypper refuses them (exit 8). Same trust as dpkg on a `.deb` and dnf's `localpkg_gpgcheck=0`; repository keys stay strict |
| V6 | D7 (`http_ok` was boolean) | `http_ok` answers 0 published, 1 absent (404/410), 2 could not tell; release installers skip on 1 only and fail on 2 | a transient 5xx, 429 or timeout read as "not published" became a silent skip, and the next run installed the tool — the second-run check failed for a network blip |
| V7 | — | `OPENCODE_VERSION=latest` is resolved through the `releases/latest` redirect and handed to the vendor installer as a version; its version probe runs under a throwaway `HOME` | the installer's own lookup uses the GitHub API, whose unauthenticated limit (60/h per address) thirteen parallel CI jobs behind one egress exhausted. `opencode --version` creates config directories on first start |
| V8 | D10 `$CI_SHELL@1.3.0` | `$CI_SHELL@1.3.1`: the per-job podman store on the runner volume | 1.3.0 put the store in the build directory, on the node's ephemeral disk; the kubelet evicted matrix jobs for `ephemeral-storage` (FR-018) |
| V9 | — | the container harness sets `/etc/shadow` and `/etc/gshadow` to 0400 on images that ship them 0000 (EL) | on the CI runner a setuid `sudo` in the matrix container lacks `CAP_DAC_OVERRIDE`, and PAM refused the test user. Harness only — the lab runs machines as shipped |
| V10 | D6 hashicorp (suse) "release zip" | its own pin, `TERRAFORM_RELEASE_VERSION`, also used on a Fedora release HashiCorp has dropped; `CHECKPOINT_DISABLE=1` for every terraform the iac module runs | the `apt` sentinel has nothing to follow on that path. The version gate otherwise phones HashiCorp's checkpoint and writes `~/.terraform.d/checkpoint_*`, so the second run changed `$HOME` |
| V11 | FR-008 (Debian behaviour-neutral) | yazi below glibc 2.39 (Debian 12, Ubuntu 22.04) takes the static musl zip instead of the gnu `.deb`; yq's digest is verified again | the `.deb` never started there. yq's digest lookup died of SIGPIPE under `pipefail`, so yq had been installed unverified everywhere. Both are fixes, `full` profile only for yazi |
| V12 | — | four `producer \| grep -q` pipes read their input whole | under `pipefail` an early-exiting `grep -q` turned a found string into "absent" (SIGPIPE): Ubuntu 22.04's universe check failed once the vendor sources made `apt-cache policy` outgrow the pipe buffer |
