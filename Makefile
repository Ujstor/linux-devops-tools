# linux-devops-tools — development targets.
#
# Nothing here is needed to USE this repository; `install.sh` and `bin/devenv`
# depend on bash, curl, git and coreutils and nothing else. These targets are for
# working ON it, and they are what CI runs.
#
# shellcheck and shfmt come from containers by default, so there is nothing to
# install. A local binary is used instead when one is on PATH — override with
# `make lint USE_DOCKER=1` to force the container, or point SHELLCHECK/SHFMT at
# your own build.

SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

# --- what to lint ----------------------------------------------------------
# $(wildcard) yields nothing for a directory that does not exist yet, so this
# stays correct while the tree is still being filled in.
#
# config/ is in here as well, and deliberately: config/bin/* become executables in
# ~/.local/bin, config/bashrc.d/* are sourced into every interactive shell and
# config/lib/detect.sh is sourced by both. They are shipped shell code, so a
# lint gate that skipped them would miss the files that run most often.
SH_FILES := install.sh \
            $(wildcard bin/*) \
            $(wildcard lib/*.sh) \
            $(wildcard modules/*.sh) \
            $(wildcard tools/*.sh) \
            $(wildcard config/bin/*) \
            $(wildcard config/lib/*.sh) \
            $(wildcard config/bashrc.d/*.sh) \
            $(wildcard config/bashrc.d/*.bash) \
            $(wildcard tests/*.sh) \
            $(wildcard tests/*/*.sh) \
            $(wildcard tests/*/*/*.sh) \
            $(wildcard tests/*/*.bash)

# --- how to reach the tools ------------------------------------------------
SHELLCHECK_IMAGE ?= koalaman/shellcheck:stable
SHFMT_IMAGE      ?= mvdan/shfmt:latest
DOCKER           ?= docker
USE_DOCKER       ?=

# `docker run` as the invoking user, so `shfmt -w` cannot leave root-owned files.
DOCKER_RUN = $(DOCKER) run --rm -u "$$(id -u):$$(id -g)" -v "$(CURDIR):/mnt" -w /mnt

ifeq ($(USE_DOCKER),1)
  SHELLCHECK ?= $(DOCKER_RUN) $(SHELLCHECK_IMAGE)
  SHFMT      ?= $(DOCKER_RUN) $(SHFMT_IMAGE)
else
  SHELLCHECK ?= $(shell command -v shellcheck 2>/dev/null || echo '$(DOCKER_RUN) $(SHELLCHECK_IMAGE)')
  SHFMT      ?= $(shell command -v shfmt 2>/dev/null || echo '$(DOCKER_RUN) $(SHFMT_IMAGE)')
endif

# The house shell style, in one place: two-space indent, switch cases indented,
# binary operators at the end of a continued line.
SHFMT_FLAGS ?= -i 2 -ci -bn
# -x follows `source`d files; -P . resolves a `# shellcheck source=lib/…`
# directive from the repository root.
SHELLCHECK_FLAGS ?= -x -P . -S style

# --- a gate that is not in the checkout is a FAILURE, never a skip ----------
#
# Every gate below used to be wrapped in
#
#     if [ -f <script> ]; then bash <script>; else printf 'skip: ...'; fi
#
# which was written while the tree was still being filled in, and outlived its
# reason. It is the worst kind of check: rename, move or mistype a gate and the
# target prints one line and exits 0 — here AND in CI, which runs exactly these
# targets. Same shape as a rule that greps zero files and reports "clean".
#
# `make lint-policy` on a checkout with no tests/ directory now stops, loudly.
gate = @test -f '$(1)' || { \
         printf 'MISSING GATE: %s is not in this checkout.\n' '$(1)' >&2; \
         printf 'A gate that is not here has not passed. Restore it, or delete the target that runs it.\n' >&2; \
         exit 1; \
       }

.PHONY: help lint lint-coverage fmt fmt-check syntax lint-policy lint-privacy \
        lint-k9s lint-docs lint-yaml test test-unit test-bootstrap test-docker \
        check bump bump-write clean

help: ## Show this help
	@printf 'linux-devops-tools — make targets\n\n'
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@printf '\nContainers used: %s, %s\n' '$(SHELLCHECK_IMAGE)' '$(SHFMT_IMAGE)'

# --- linting ---------------------------------------------------------------

syntax: ## Parse every script with `bash -n` (fast, no tools needed)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@printf 'bash -n: %s files OK\n' '$(words $(SH_FILES))'

lint: ## shellcheck every script (container by default)
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SH_FILES)

# SH_FILES is built from $(wildcard), which yields NOTHING for a directory that
# does not match instead of complaining. Rename modules/ and `make lint` still
# exits 0, having linted a shorter list — the quiet half of the same failure that
# let `git grep` scan a tree of untracked files and report "clean". This target
# is the tripwire: every shell file git knows about must be on the list.
lint-coverage: ## Fail if a shell file in the checkout is on nobody's lint list
	$(call gate,tests/policy/lint-coverage.sh)
	@bash tests/policy/lint-coverage.sh $(SH_FILES)

fmt: ## Reformat every script in place with shfmt
	$(SHFMT) -w $(SHFMT_FLAGS) $(SH_FILES)

fmt-check: ## Fail if any script is not shfmt-clean
	$(SHFMT) -d $(SHFMT_FLAGS) $(SH_FILES)

lint-policy: ## The rules shellcheck cannot express (tests/policy/rules.sh)
	$(call gate,tests/policy/rules.sh)
	@bash tests/policy/rules.sh

lint-privacy: ## The public-repo gate: no private host, IP, realm or kubeconfig
	$(call gate,tests/policy/privacy.sh)
	@bash tests/policy/privacy.sh

lint-k9s: ## Check the shipped k9s key map and plugin safety rules
	$(call gate,tests/k9s-keys.sh)
	@bash tests/k9s-keys.sh

lint-docs: ## Check docs/modules.md still matches the module meta headers
	$(call gate,tests/policy/docs-drift.sh)
	@bash tests/policy/docs-drift.sh

lint-yaml: ## Parse every shipped YAML file (k9s plugins, skins, the workflow)
	$(call gate,tests/policy/yaml-parse.sh)
	@bash tests/policy/yaml-parse.sh

# --- tests -----------------------------------------------------------------

test-unit: ## Run the unit tests (no network, no root)
	$(call gate,tests/unit/run.sh)
	@bash tests/unit/run.sh

test-bootstrap: ## `curl | bash` still survives: no tty, no BASH_SOURCE
	$(call gate,tests/bootstrap.sh)
	@bash tests/bootstrap.sh

test-docker: ## The container matrix: install twice, assert nothing changed
	$(call gate,tests/docker/matrix.sh)
	@bash tests/docker/matrix.sh

# `check` is what CI's lint job runs, so lint-coverage belongs in it: a wildcard
# that stopped matching is caught in the same second as a syntax error.
check: lint-coverage syntax lint fmt-check ## Everything that runs in under a minute

# `test` is the whole of CI, minus the container matrix's sibling jobs that are
# already covered by test-docker. Every CI job below maps to exactly one target
# here — see docs/development.md for the job-by-job table.
# One line on purpose: the `help` target greps `^target:.*## `, so a target whose
# doc comment sits on a continuation line silently vanishes from `make help`.
test: check lint-policy lint-privacy lint-k9s lint-docs lint-yaml test-unit test-bootstrap test-docker ## Everything

# --- maintenance -----------------------------------------------------------

bump: ## Report versions.env pins that have a newer upstream release
	@bash tools/bump-versions.sh

bump-write: ## As `bump`, but rewrite versions.env in place (review the diff!)
	@bash tools/bump-versions.sh --write

# There is deliberately no `docs` generator target. docs/modules.md is written by
# hand because its "what it does" column is prose that a `# meta: desc=` one-liner
# cannot carry — generating it would shrink the page, not maintain it. `lint-docs`
# keeps the machine-checkable half (the gates) honest instead.

clean: ## Remove bootstrap scratch left behind by an interrupted install
	@rm -rf .devenv-bootstrap.* .devenv-update.*
	@printf 'clean\n'
