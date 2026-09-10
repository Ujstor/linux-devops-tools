# devops-env-config — development targets.
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

.PHONY: help lint fmt fmt-check syntax lint-policy lint-privacy lint-k9s lint-docs \
        test test-unit test-docker check bump bump-write clean

help: ## Show this help
	@printf 'devops-env-config — make targets\n\n'
	@grep -hE '^[a-z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) \
	  | sort \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@printf '\nContainers used: %s, %s\n' '$(SHELLCHECK_IMAGE)' '$(SHFMT_IMAGE)'

# --- linting ---------------------------------------------------------------

syntax: ## Parse every script with `bash -n` (fast, no tools needed)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@printf 'bash -n: %s files OK\n' '$(words $(SH_FILES))'

lint: ## shellcheck every script (container by default)
	$(SHELLCHECK) $(SHELLCHECK_FLAGS) $(SH_FILES)

fmt: ## Reformat every script in place with shfmt
	$(SHFMT) -w $(SHFMT_FLAGS) $(SH_FILES)

fmt-check: ## Fail if any script is not shfmt-clean
	$(SHFMT) -d $(SHFMT_FLAGS) $(SH_FILES)

lint-policy: ## The rules shellcheck cannot express (tests/policy/rules.sh)
	@if [ -f tests/policy/rules.sh ]; then \
	  bash tests/policy/rules.sh; \
	else \
	  printf 'skip: tests/policy/rules.sh is not in this checkout\n'; \
	fi

lint-privacy: ## The public-repo gate: no private host, IP, realm or kubeconfig
	@if [ -f tests/policy/privacy.sh ]; then \
	  bash tests/policy/privacy.sh; \
	else \
	  printf 'skip: tests/policy/privacy.sh is not in this checkout\n'; \
	fi

lint-k9s: ## Check the shipped k9s key map and plugin safety rules
	@if [ -f tests/k9s-keys.sh ]; then \
	  bash tests/k9s-keys.sh; \
	else \
	  printf 'skip: tests/k9s-keys.sh is not in this checkout\n'; \
	fi

lint-docs: ## Check docs/modules.md still matches the module meta headers
	@bash tests/policy/docs-drift.sh

# --- tests -----------------------------------------------------------------

test-unit: ## Run the unit tests (no network, no root)
	@if [ -f tests/unit/run.sh ]; then \
	  bash tests/unit/run.sh; \
	else \
	  printf 'skip: tests/unit/run.sh is not in this checkout\n'; \
	fi

test-docker: ## The container matrix: install twice, assert nothing changed
	@if [ -f tests/docker/matrix.sh ]; then \
	  bash tests/docker/matrix.sh; \
	else \
	  printf 'skip: tests/docker/matrix.sh is not in this checkout\n'; \
	fi

check: syntax lint fmt-check ## Everything that runs in under a minute
test: check lint-policy lint-privacy lint-k9s lint-docs test-unit test-docker ## Everything

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
