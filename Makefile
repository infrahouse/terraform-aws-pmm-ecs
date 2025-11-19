PYTHON := python3
TERRAFORM := terraform
PYTEST := pytest

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make bootstrap     - Install dependencies for testing"
	@echo "  make test          - Run all tests"
	@echo "  make test-basic    - Test basic PMM deployment"
	@echo "  make test-vpc      - Test VPC/RDS integration"
	@echo "  make test-backup   - Test backup functionality"
	@echo "  make lint          - Lint Terraform code"
	@echo "  make format        - Format Terraform code"
	@echo "  make validate      - Validate Terraform configuration"
	@echo "  make docs          - Generate documentation"
	@echo "  make clean         - Clean test artifacts"

.PHONY: bootstrap
bootstrap:
	pip3 install -r tests/requirements.txt

.PHONY: lint
lint:
	$(TERRAFORM) fmt -check -recursive
	@if command -v tflint > /dev/null; then \
		tflint; \
	else \
		echo "tflint not found, skipping..."; \
	fi

.PHONY: format
format:
	$(TERRAFORM) fmt -recursive

.PHONY: validate
validate:
	$(TERRAFORM) init -backend=false
	$(TERRAFORM) validate

.PHONY: test
test: test-basic test-vpc test-backup

.PHONY: test-basic
test-basic:
	$(PYTEST) tests/test_basic.py -v

.PHONY: test-vpc
test-vpc:
	$(PYTEST) tests/test_monitoring.py -v

.PHONY: test-backup
test-backup:
	$(PYTEST) tests/test_persistence.py -v

.PHONY: docs
docs:
	@if command -v terraform-docs > /dev/null; then \
		terraform-docs markdown table --output-file README.md --output-mode inject .; \
	else \
		echo "terraform-docs not found. Install from https://terraform-docs.io/"; \
	fi

.PHONY: clean
clean:
	find . -type d -name ".terraform" -exec rm -rf {} + 2>/dev/null || true
	find . -type f -name "*.tfstate*" -exec rm -f {} + 2>/dev/null || true
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -type d -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
