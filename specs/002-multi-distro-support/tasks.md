# 002 — tasks

Format: `- [ ] T### [P] [US#] description — files`. `[P]` = parallel-safe (disjoint files).
User stories: US1 = S1 (RedHat), US2 = S2 (Debian parity), US3 = S3 (gate), US4 = S4 (lab),
US5 = S5 (SUSE/Arch), US6 = S6 (untested/refused). Owner lanes (A–D) keep files disjoint while
work runs in parallel.

## Phase 0 — prerequisites

- [X] T001 tmux-config: pull TPM only when the checkout is missing or under `--update`; release on
      the internal and public repos — `devops/misc/tmux-config/install.sh` (outside this repo)
- [X] T002 [P] The supported matrix as data (D1) — `config/os-support.list`

## Phase 1 — foundation (blocking)

Lane A — platform
- [X] T003 [P] [US6] Detection: `OS_FAMILY/OS_DISTRO/OS_RELEASE/OS_PKG_MGR/OS_SUPPORT/OS_ARCH_RPM`,
      gate rendered from the list, one untested warning (D2) — `lib/os.sh`
- [X] T004 [P] Family data, identical key sets (D3) — `lib/family/{debian,redhat,suse,arch}.sh`,
      `tests/unit/test_family.sh`
- [X] T005 [P] [US6] `family=` module gate (D8) — `lib/registry.sh`, headers of `modules/91-*`,
      `modules/92-*`, `modules/70-wsl.sh`
- [X] T006 [P] [US6] Offline gate proof: fixtures for 13 releases, derivatives, unsupported (D11)
      — `tests/unit/test_os.sh`, `tests/unit/fixtures/os-release/*`

Lane B — packages
- [X] T007 [US2] Move the apt bodies verbatim behind a dispatch (D4) — `lib/pkg.sh`, `lib/pkg_apt.sh`
- [X] T008 [P] [US1] [US5] Backends (D4) — `lib/pkg_dnf.sh`, `lib/pkg_zypper.sh`, `lib/pkg_pacman.sh`
- [X] T009 [P] [US1] Name map + translation (D5) — `config/packages.map`, `lib/pkg.sh`
- [X] T010 [P] [US1] `pkg_ensure_addon`, `pkg_upgrade_one`, `pkg_mark_manual` (D4) — `lib/pkg*.sh`
- [X] T011 [P] [US1] restorecon on installed executables (D9) — `lib/fs.sh`
- [X] T012 [US2] Unit tests for the dispatch and the map — `tests/unit/test_pkg.sh`

## Phase 2 — capabilities on every family (US1, US5)

Lane C — sources and release artifacts
- [X] T013 [US1] Vendor sources per family + fixed `repo_ensure_docker` (D6) — `lib/repo.sh`
- [X] T014 [US1] `pkg_release_install`, delete the `.deb`→tarball guess (D7, FR-015) — `lib/net.sh`
- [X] T015 [US1] Callers with verified rpm/tarball patterns; 35's `--only-upgrade` → `pkg_upgrade_one`
      — `modules/10-shell.sh`, `modules/30-containers.sh`, `modules/35-kubernetes.sh`,
      `modules/40-iac.sh`, `modules/45-cloud.sh`

Lane A — family-aware hints and gating
- [X] T016 [US1] Admin group / CA hints from `FAM_*` (FR-013) — `lib/run.sh`, `modules/15-git.sh`,
      `modules/90-doctor.sh`, `modules/00-preflight.sh`
- [X] T017 [US1] 58's apt-only `install-deps` → skip with reason; 91 `apt-mark` → `pkg_mark_manual`
      — `modules/58-headless-browser.sh`, `modules/91-purge-desktop.sh`

Lane B — names used by modules
- [X] T018 [US1] [US5] Map rows for every name in 00/05/10/20/28/45/50/55 — `config/packages.map`

## Phase 3 — proof (US3)

Lane D — harness and CI
- [X] T019 [US3] Policy: package-manager calls only in backends, `family=` in meta rules, lib list,
      no SELinux relaxation — `tests/policy/rules.sh`
- [X] T020 [US3] Drift gate list ↔ CI ↔ GitHub matrix ↔ lab inventory (SC-006) —
      `tests/policy/os-support.sh`, `Makefile`
- [X] T021 [US3] Family column in the module table — `tests/policy/docs-drift.sh`, `docs/modules.md`
- [X] T022 [US3] Per-family container bootstrap, fingerprint and sudo hint; images from the list
      (D10) — `tests/docker/entry.sh`, `tests/docker/matrix.sh`
- [X] T023 [US3] 13 hard images, no soft lane, default profile, `workflow:rules` (D10) —
      `.gitlab-ci.yml`, `.github/workflows/ci.yml`

## Phase 4 — integration

- [X] T024 [US1] [US5] Local container matrix, all 13, default profile, twice: iterate to green
- [ ] T025 [US2] SC-003: Debian-family fingerprints identical before/after on the 5 releases
- [ ] T026 [US3] One GitLab MR pipeline, 13/13 hard jobs green (cancel any other pipeline first)

## Phase 5 — lab proof (US4, INTERNAL)

- [X] T027 [US4] Lab inventory + loop (D12) — `tests/lab/inventory.list`, `tests/lab/lab-loop.sh`
- [ ] T028 [US4] Run the loop on the 12 lab guests; evidence — `specs/002-multi-distro-support/lab-results.md`

## Phase 6 — polish and port

- [X] T029 Docs: README, `docs/tools.md` family notes, `docs/configuration.md`, 001 pointers —
      `README.md`, `docs/*.md`, `specs/001-linux-devops-tools/spec.md`
- [ ] T030 Merge the MR after T026 + T028
- [ ] T031 Public variant: same behaviour minus `tests/lab/` and `lab-results.md`, on a branch in
      the GitHub checkout for the operator to push (FR-022)
