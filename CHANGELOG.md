# Changelog

All notable changes to this project will be documented in this file.

## [0.3.0] - 2025-11-26

## [0.2.0] - 2025-11-22

## [0.1.0] - 2025-11-21

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial module implementation for deploying Percona Monitoring and Management (PMM) on AWS ECS
- ECS service deployment with singleton pattern (exactly 1 task) for data consistency
- Application Load Balancer (ALB) with SSL/TLS termination via ACM certificates
- Elastic File System (EFS) for persistent storage with mandatory encryption
- AWS Secrets Manager integration for auto-generated admin passwords using InfraHouse secret module
- AWS Backup configuration with daily EFS snapshots and configurable retention (default 365 days)
- CloudWatch monitoring with alarms for:
  - ECS service health (RunningTaskCount)
  - ALB target health (HealthyHostCount)
  - EFS burst credits (BurstCreditBalance)
  - ALB 5XX errors (HTTPCode_Target_5XX_Count)
- SNS topic integration for alarm notifications via email
- CloudWatch Logs with configurable retention (default 365 days)
- RDS PostgreSQL monitoring support via security group configuration
- IAM roles and policies for ECS task execution, task runtime, and AWS Backup
- Multiple deployment examples:
  - Basic deployment
  - Advanced deployment with custom KMS, compute, retention
  - RDS monitoring integration
- Comprehensive documentation:
  - Architecture guide with component diagrams, HA strategy, cost analysis
  - RDS setup guide with step-by-step PostgreSQL monitoring configuration
  - Troubleshooting guide covering deployment, access, performance, storage, monitoring, and recovery
- Helper scripts:
  - `setup-pmm-client.sh` for registering RDS instances with PMM
  - `backup-efs.sh` for manual EFS backup jobs
- Automated testing:
  - Basic deployment test
  - VPC/RDS integration test
  - CloudWatch monitoring test
  - EFS persistence and backup test
- GitHub workflows for CI/CD:
  - terraform-CI.yml for pull request validation
  - terraform-CD.yml for module publishing

### Configuration
- PMM version 3 as default (PMM 2 reaches EOL July 2025)
- Telemetry disabled by default
- DBaaS disabled by default (deprecated feature)
- Backup retention: 365 days (production-ready default)
- CloudWatch log retention: 365 days (production-ready default)
- Container resources: 2048 CPU units, 4096 MB memory
- Instance type: m5.large
- Always-on monitoring and logging (no toggle to disable)
- Always-encrypted EFS (AWS-managed or customer-managed KMS key)
- Auto-scaling: Fixed at 1 task for singleton deployment pattern

### Dependencies
- AWS Provider >= 5.0
- Terraform >= 1.0
- infrahouse/ecs/aws module v6.0.0
- infrahouse/secret/aws module v1.1.1
- infrahouse/website-pod/aws module v4.1.0
- infrahouse/service-network/aws module v3.1.0

### Standards
- Follows InfraHouse coding standards:
  - Exact version pinning (no `~>`)
  - Lowercase tags except `Name`
  - `created_by_module` and `module_version` tags on all resources
  - Bumpversion for version tracking
  - HEREDOC format for long variable descriptions
- No VPC or Internet Gateway parameters required (inferred from subnets)
- Admin password auto-generated (no manual input)
- Monitoring, logging, backups, and encryption always enabled (no toggles)

### Workarounds
- Target Group ARN extraction via ALB listener data source (infrahouse/ecs/aws v6.0.0 missing output)
- ARN suffix computation for CloudWatch alarms using `split()` and `try()` (missing module outputs)
- Direct use of `local.service_name` for ECS service/cluster names (missing module outputs)
- Use of `backend_security_group` instead of non-existent `service_security_group_id` output

### Known Issues
- infrahouse/ecs/aws module v6.0.0 missing several outputs (filed GitHub issue):
  - service_name
  - cluster_name
  - target_group_arn_suffix
  - load_balancer_arn_suffix
  - service_security_group_id

## [0.1.0] - YYYY-MM-DD

### Release Notes
Initial release of terraform-aws-pmm-ecs module.

Production-ready deployment of Percona Monitoring and Management (PMM) on AWS ECS with:
- Persistent storage (EFS)
- High availability (multi-AZ)
- Automated backups (AWS Backup)
- Comprehensive monitoring (CloudWatch)
- Security best practices (encryption, IAM, secrets management)
- RDS integration support

**Note:** This is the first release. Please review documentation and test thoroughly in non-production environments before deploying to production.

[Unreleased]: https://github.com/infrahouse/terraform-aws-pmm-ecs/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/infrahouse/terraform-aws-pmm-ecs/releases/tag/v0.1.0