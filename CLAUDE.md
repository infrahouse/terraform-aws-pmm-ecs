# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
## First Steps

**Your first tool call in this repository MUST be reading .claude/CODING_STANDARD.md.
Do not read any other files, search, or take any actions until you have read it.**
This contains InfraHouse's comprehensive coding standards for Terraform, Python, and general formatting rules.

## Project Overview

Terraform module (`infrahouse/pmm-ecs/aws`) that deploys Percona Monitoring and Management (PMM) on AWS. Despite the "ecs" name, this deploys on a **single EC2 instance** running Docker (not ECS Fargate/service). Uses persistent EBS storage mounted at `/srv`, an ALB for HTTPS termination, and AWS Backup for snapshots.

## Common Commands

```bash
make bootstrap          # Install Python test dependencies (pip + tests/requirements.txt)
make lint               # terraform fmt --check -recursive
make format             # terraform fmt -recursive
make test               # pytest -xvvs tests/
make docs               # Regenerate README.md with terraform-docs
make validate           # terraform init -backend=false && terraform validate

# Run specific test with AWS credentials:
make test-keep          # Run test, keep AWS resources after (for debugging)
make test-clean         # Run test, destroy resources after

# Releases (requires git-cliff + bumpversion):
make release-patch      # Bump x.x.PATCH
make release-minor      # Bump x.MINOR.0
make release-major      # Bump MAJOR.0.0
```

## Architecture

### Terraform Files (root)

- `ec2.tf` - EC2 instance, IAM role/profile, security groups
- `ebs.tf` - Persistent EBS data volume (GP3, encrypted, mounted at `/srv`)
- `alb.tf` - Application Load Balancer, listeners, target groups
- `ssl.tf` - ACM certificate with DNS validation, CAA records
- `backup.tf` - AWS Backup vault, plan, and selection (daily + optional weekly)
- `auto_recovery.tf` - CloudWatch alarms, auto-recovery, dashboard
- `userdata.tf` - Cloud-init configuration (5 parts: EBS mount, Docker install, swap, cloud-config, service start)
- `lambda.tf` - Lambda ASG reconciler (pmm-client install via SSM, EventBridge schedule, IAM, security groups)
- `security.tf` - RDS security group rules for PostgreSQL/MySQL monitoring
- `sns.tf` - SNS topic for alarm notifications
- `data.tf` - Data sources (AMI, VPC, subnet, Route53 zone)
- `locals.tf` - Local values and computed configurations
- `variables.tf` - All input variables with validations
- `outputs.tf` - Module outputs
- `versions.tf` - Provider requirements (AWS >= 5.11 < 7.0, uses `aws.dns` alias)

### Templates (`templates/`)

Shell scripts and systemd units rendered via `templatefile()` into cloud-init:
- `install-docker.sh.tftpl` - Docker CE installation on Ubuntu
- `pmm-server-persistent.service.tftpl` - systemd unit for PMM Docker container with EBS volume mounts
- `configure-swap.sh.tftpl` - Swap file configuration based on instance RAM
- `start-services.sh.tftpl` - Service startup orchestration
- `get-pmm-password.sh.tftpl` / `set-pmm-password.sh.tftpl` - Password management via Secrets Manager

### Scripts (`scripts/`)

- `mount-ebs-volume.sh` - EBS volume detection, formatting (xfs), and mounting at `/srv`

### Lambda (`lambda/pmm_reconciler/`)

Python Lambda function that reconciles ASG membership with PMM monitored services:
- `main.py` - Installs pmm-client on ASG instances via SSM, removes terminated instances via PMM API
- `requirements.txt` - Dependencies (`requests`, `infrahouse-core`)

Key flow: Lambda discovers ASG instances, runs idempotent bash script via SSM `execute_command()`
to install pmm-client, configure PMM server connection (direct HTTPS:443 with `--server-insecure-tls`),
and add MySQL monitoring. pmm-agent uses gRPC which is NOT supported by ALB, so it connects directly
to the PMM EC2 instance.

### Key Module Dependencies

- `infrahouse/secret/aws` (v1.1.1) - Admin password in Secrets Manager
- `infrahouse/lambda-monitored/aws` - Lambda function with CloudWatch alarms (used by reconciler)
- `infrahouse/website-pod/aws` (v5.10.0) - ALB infrastructure (referenced as `module.pmm_pod` but may be partially used)

## Testing

Tests use `pytest-infrahouse` framework which manages Terraform lifecycle (init/apply/destroy). Tests deploy real AWS infrastructure.

- **Test config**: `test_data/test_basic/` - Terraform config that calls the module under test
- **Test code**: `tests/test_basic.py` - Parameterized for AWS provider v5 and v6 (`@pytest.mark.parametrize`)
- **Fixtures**: `tests/conftest.py` - Session-scoped fixtures for PostgreSQL RDS, SSM-based DB configuration
- **Test flow**: Deploy PMM → wait for readiness (`/v1/readyz`) → configure PostgreSQL via SSM →
  add PostgreSQL to PMM via API → validate AWS Backup → invoke Lambda reconciler →
  verify pmm-client installed on Percona instances via SSM
- **CI**: GitHub Actions on self-hosted runners, 4-hour timeout, assumes IAM role `pmm-ecs-tester`

The test dynamically generates `terraform.tf`, `provider.tf`, and `terraform.tfvars` in the test data directory.

## Provider Configuration

The module requires **two AWS provider configurations**: default `aws` and `aws.dns` alias (for Route53 operations that may be in a different account).

## Conventions

- Variable descriptions use heredoc (`<<-EOF`) syntax
- Resources use `name_prefix` (not `name`) for IAM roles/profiles/security groups
- All resources get `local.common_tags`
- README includes `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` markers for terraform-docs injection
- Versioning managed by `.bumpversion.cfg` with `CHANGELOG.md` generated by `git-cliff`
