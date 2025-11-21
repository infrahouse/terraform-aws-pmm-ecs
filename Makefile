.DEFAULT_GOAL := help

define PRINT_HELP_PYSCRIPT
import re, sys

for line in sys.stdin:
    match = re.match(r'^([a-zA-Z_-]+):.*?## (.*)$$', line)
    if match:
        target, help = match.groups()
        print("%-40s %s" % (target, help))
endef
export PRINT_HELP_PYSCRIPT

TEST_REGION ?= us-west-2
TEST_ROLE ?= arn:aws:iam::303467602807:role/pmm-ecs-tester
TEST_SELECTOR ?= test_module and aws-6

help:
	@python -c "$$PRINT_HELP_PYSCRIPT" < Makefile

.PHONY: lint
lint:  ## Run code style checks
	terraform fmt --check -recursive

.PHONY: test
test:  ## Run tests on the module
	pytest -xvvs tests/

.PHONY: test-keep
test-keep:  ## Run a test and keep resources
	pytest -xvvs \
		--aws-region=${TEST_REGION} \
		--test-role-arn=${TEST_ROLE} \
		--keep-after \
		-k "${TEST_SELECTOR}" \
		tests/test_basic.py \
		2>&1 | tee pytest-`date +%Y%m%d-%H%M%S`-output.log

.PHONY: test-clean
test-clean:  ## Run a test and destroy resources
	pytest -xvvs \
		--aws-region=${TEST_REGION} \
		--test-role-arn=${TEST_ROLE} \
		-k "${TEST_SELECTOR}" \
		tests/test_basic.py \
		2>&1 | tee pytest-`date +%Y%m%d-%H%M%S`-output.log

.PHONY: bootstrap
bootstrap: ## bootstrap the development environment
	pip install -U "pip ~= 25.2"
	pip install -U "setuptools ~= 80.9"
	pip install -r tests/requirements.txt

.PHONY: clean
clean: ## clean the repo from cruft
	rm -rf .pytest_cache
	find . -name '.terraform' -exec rm -fr {} +
	rm -f pytest-*-output.log

.PHONY: fmt
fmt: format

.PHONY: format
format:  ## Use terraform fmt to format all files in the repo
	@echo "Formatting terraform files"
	terraform fmt -recursive

.PHONY: validate
validate:  ## Validate Terraform configuration
	terraform init -backend=false
	terraform validate

.PHONY: docs
docs:  ## Generate documentation
	@if command -v terraform-docs > /dev/null; then \
		terraform-docs markdown table --output-file README.md --output-mode inject .; \
	else \
		echo "terraform-docs not found. Install from https://terraform-docs.io/"; \
	fi
