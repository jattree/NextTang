SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

-include .env.local

TOOLCHAIN ?= $(or $(NEXTTANG_TOOLCHAIN),oss)
TARGET ?= $(or $(NEXTTANG_TARGET),console138k)
PROFILE ?= $(or $(NEXTTANG_PROFILE),release)

export NEXTTANG_GOWIN_HOME
export NEXTTANG_OSS_CAD_SUITE

.PHONY: help show-config doctor doctor-strict repo-check shell-lint test check ci synth clean

help: ## Show the supported development commands.
	@awk 'BEGIN {FS = ":.*## "; printf "NextTang development commands:\n\n"} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

show-config: ## Print the selected toolchain, target, profile, and output path.
	@printf 'toolchain=%s\ntarget=%s\nprofile=%s\noutput=%s\n' \
		'$(TOOLCHAIN)' '$(TARGET)' '$(PROFILE)' \
		'$(REPO_ROOT)/build/$(TOOLCHAIN)/$(TARGET)/$(PROFILE)'

doctor: ## Report repository, vendor, and open-source tool availability.
	@$(REPO_ROOT)/scripts/doctor.sh --mode all

doctor-strict: ## Require the selected TOOLCHAIN to be ready.
	@$(REPO_ROOT)/scripts/doctor.sh --mode '$(TOOLCHAIN)' --strict

repo-check: ## Validate tracked files, local links, and generated-artifact policy.
	@python3 $(REPO_ROOT)/scripts/check_repo.py

shell-lint: ## Parse shell scripts and run ShellCheck when it is installed.
	@bash -n $(REPO_ROOT)/scripts/*.sh $(REPO_ROOT)/tests/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -P SCRIPTDIR $(REPO_ROOT)/scripts/*.sh $(REPO_ROOT)/tests/*.sh; \
	else \
		printf '%s\n' 'shellcheck: SKIP (not installed)'; \
	fi

test: ## Run unit and shell regression tests.
	@python3 -m unittest discover -s $(REPO_ROOT)/tests -p 'test_*.py'
	@$(REPO_ROOT)/tests/doctor_test.sh

check: repo-check shell-lint test ## Run every local non-synthesis quality gate.

ci: check ## Run the deterministic CI gate.

synth: ## Dispatch a real board build; fails closed until that board driver exists.
	@$(REPO_ROOT)/scripts/synth.sh \
		--toolchain '$(TOOLCHAIN)' --target '$(TARGET)' --profile '$(PROFILE)'

clean: ## Remove only the repository build directory.
	@$(REPO_ROOT)/scripts/clean.sh
