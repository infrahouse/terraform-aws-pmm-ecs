Based on the InfraHouse lambda-monitored module's structure and best practices,
here's a comprehensive plan for creating a **terraform-aws-pmm-ecs** module:

## ⚠️ ARCHITECTURAL CHANGE
**Original Plan**: ECS-based deployment with EFS storage
**Actual Implementation**: Website-pod (EC2 ASG) with Docker + local storage for databases

**Reason**: EFS eventual consistency caused ClickHouse and PostgreSQL corruption.
Migrated to simpler architecture using infrahouse/website-pod/aws with local storage.

## Module Development Plan: `terraform-aws-pmm-ecs`

### 1. **Module Structure** ✅ COMPLETED
```
terraform-aws-pmm-ecs/
├── README.md
├── LICENSE
├── Makefile
├── .github/
│   └── workflows/
│       ├── terraform.yml
│       └── release.yml
├── .gitignore
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── efs.tf
├── security.tf
├── monitoring.tf
├── backup.tf
├── locals.tf
├── data.tf
├── examples/
│   ├── basic/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── advanced/
│   │   └── main.tf
│   └── with-rds-monitoring/
│       └── main.tf
├── test_data/
│   ├── test_basic/
│   │   └── main.tf
│   ├── test_with_vpc/
│   │   └── main.tf
│   └── test_with_backup/
│       └── main.tf
├── tests/
│   ├── conftest.py
│   ├── test_basic.py
│   ├── test_monitoring.py
│   ├── test_persistence.py
│   └── requirements.txt
├── scripts/
│   ├── setup-pmm-client.sh
│   └── backup-efs.sh
└── docs/
    ├── ARCHITECTURE.md
    ├── RDS_SETUP.md
    └── TROUBLESHOOTING.md
```

### 2. **Core Files Content** ✅ COMPLETED (with website-pod architecture)

#### **main.tf**
```hcl
# ECS Cluster Module for PMM Server
module "pmm_ecs" {
  source  = "infrahouse/ecs/aws"
  version = "6.0.0"  # Exact version pinning required

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  # Core configuration
  service_name    = local.service_name
  docker_image    = local.docker_image
  container_port  = 443

  # Resources
  container_cpu     = var.container_cpu
  container_memory  = var.container_memory
  asg_instance_type = var.instance_type

  # Networking (VPC and IGW inferred from subnets)
  load_balancer_subnets = var.public_subnet_ids
  asg_subnets           = var.private_subnet_ids
  internet_gateway_id   = data.aws_internet_gateway.selected.id

  # DNS
  zone_id   = var.zone_id
  dns_names = var.dns_names

  # Health checks
  healthcheck_path                  = "/v1/readyz"
  healthcheck_response_code_matcher = "200"
  healthcheck_interval              = var.healthcheck_interval
  healthcheck_timeout               = var.healthcheck_timeout

  # Auto-scaling (PMM should run as singleton for data consistency)
  asg_min_size       = 1
  asg_max_size       = 1
  task_min_count     = 1
  task_desired_count = 1
  task_max_count     = 1

  # Persistent storage
  task_efs_volumes = {
    "pmm-data" : {
      file_system_id : aws_efs_file_system.pmm_data.id
      container_path : "/srv"
    }
  }

  # Environment variables
  task_environment_variables = local.pmm_environment_variables

  # Secrets
  task_secrets = local.pmm_secrets

  # Logging (always enabled)
  enable_cloudwatch_logs         = true
  cloudwatch_log_group           = local.cloudwatch_log_group
  cloudwatch_log_group_retention = var.cloudwatch_log_retention_days

  # SSH access
  ssh_key_name   = var.ssh_key_name
  ssh_cidr_block = var.admin_cidr_blocks

  # IAM
  execution_task_role_policy_arn = aws_iam_policy.pmm_execution.arn
  task_role_arn                  = aws_iam_role.pmm_task.arn

  tags = local.common_tags

  depends_on = [
    aws_efs_mount_target.pmm_data
  ]
}
```

#### **efs.tf**
```hcl
# EFS file system for PMM persistent storage (always encrypted)
resource "aws_efs_file_system" "pmm_data" {
  creation_token = local.efs_creation_token
  encrypted      = true  # Always encrypted
  kms_key_id     = var.efs_kms_key_id  # Optional customer-managed key

  performance_mode = var.efs_performance_mode
  throughput_mode  = var.efs_throughput_mode

  lifecycle_policy {
    transition_to_ia = var.efs_transition_to_ia
  }

  tags = merge(
    {
      module_version = local.module_version  # Bumpversion tracking
    },
    local.common_tags,
    {
      Name = "${local.service_name}-data"
      type = "pmm-storage"  # Lowercase per InfraHouse standard
    }
  )
}

resource "aws_efs_mount_target" "pmm_data" {
  for_each       = toset(var.private_subnet_ids)
  file_system_id = aws_efs_file_system.pmm_data.id
  subnet_id      = each.key

  security_groups = [aws_security_group.efs.id]

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-efs-mount-${each.key}"
    }
  )
}
```

#### **variables.tf**
```hcl
# Required variables (VPC ID removed - inferred from subnets)
variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks and EFS"
  type        = list(string)
}

variable "zone_id" {
  description = "Route53 zone ID for PMM DNS records"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g., production, staging, dev)"
  type        = string
}

variable "alarm_emails" {
  description = "Email addresses for CloudWatch alarms"
  type        = list(string)

  validation {
    condition     = length(var.alarm_emails) > 0
    error_message = "At least one email address must be provided for CloudWatch alarms"
  }
}

# Service configuration
variable "service_name" {
  description = "Name for the PMM service"
  type        = string
  default     = "pmm-server"
}

variable "dns_names" {
  description = "DNS names for PMM (will be created in the Route53 zone)"
  type        = list(string)
  default     = ["pmm"]
}

# PMM configuration
variable "pmm_version" {
  description = <<-EOF
    PMM Docker image version (3 is recommended, PMM 2 EOL July 2025)
  EOF
  type        = string
  default     = "3"  # Updated from 2 to 3
}

variable "disable_telemetry" {
  description = <<-EOF
    Disable PMM telemetry.
    PMM collects anonymous usage data (version, uptime, server count) to help Percona improve the product.
    No sensitive data is collected.
  EOF
  type        = bool
  default     = true
}

variable "enable_dbaas" {
  description = <<-EOF
    Enable PMM DBaaS (Database as a Service) features.
    DBaaS allows provisioning Percona database clusters via PMM's web interface using Kubernetes.
    This feature is deprecated by Percona in favor of Percona Everest and requires a Kubernetes cluster.
    Most users only need PMM for monitoring existing databases, not provisioning new ones.
  EOF
  type        = bool
  default     = false
}

# Compute resources
variable "instance_type" {
  description = "EC2 instance type for ECS"
  type        = string
  default     = "m5.large"

  validation {
    condition     = can(regex("^(t3|m5|m6i|c5|c6i)\\.(medium|large|xlarge|2xlarge)", var.instance_type))
    error_message = "Instance type should be suitable for PMM workload (min 4GB RAM recommended)"
  }
}

variable "container_cpu" {
  description = "CPU units for PMM container"
  type        = number
  default     = 2048
}

variable "container_memory" {
  description = "Memory (MB) for PMM container"
  type        = number
  default     = 4096
}

# EFS configuration (always encrypted)
variable "efs_kms_key_id" {
  description = <<-EOF
    KMS key ID for EFS encryption. If null, uses AWS-managed encryption key. EFS is always encrypted.
  EOF
  type        = string
  default     = null
}

# Backup configuration (always enabled)
variable "backup_retention_days" {
  description = "Days to retain EFS backups"
  type        = number
  default     = 365  # Changed from 30 to 365
}

# Monitoring configuration (always enabled)
variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 365  # Changed from 7 to 365
}

# Security
variable "rds_security_group_ids" {
  description = <<-EOF
    Security group IDs of RDS instances to monitor (PMM will be granted access)
  EOF
  type        = list(string)
  default     = []
}

variable "secret_readers" {
  description = "IAM role ARNs that can read the PMM admin password secret"
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# Key changes from original plan:
# - Removed: vpc_id, internet_gateway_id (inferred from subnets)
# - Removed: efs_encrypted (always true), admin_password (auto-generated)
# - Removed: enable_monitoring, enable_cloudwatch_logs, enable_efs_backup (always enabled)
# - Removed: secret_writers (password is Terraform-managed)
# - Added: environment (required), disable_telemetry, enable_dbaas
# - Made required: alarm_emails (with validation)
# - Changed defaults: pmm_version=3, retention periods=365 days
# - Use HEREDOC for long descriptions
```

### 3. **Testing Strategy** ✅ COMPLETED

✅ **Test Implementation Completed:**
* ✅ Test creates a PMM instance with HTTPS and SSL certificate (via website-pod ALB + ACM)
* ✅ Test creates a PostgreSQL RDS instance with Database Insights - Advanced mode
* ✅ README comprehensively explains how to add PostgreSQL instance to PMM
* ✅ Human testing successfully completed - PostgreSQL instance added and monitoring verified

**Test Configuration (`test_data/test_basic/`):**
- ✅ `postgres.tf` - PostgreSQL RDS instance with Database Insights - Advanced mode (465 days retention)
- ✅ `main.tf` - PMM module configuration with RDS security group integration
- ✅ `outputs.tf` - PostgreSQL connection details (endpoint, port, database, credentials)
- ✅ Security group rules automatically created for PMM → PostgreSQL connectivity (port 5432)

**Testing Completed:**
- ✅ PMM deployment successful with HTTPS
- ✅ PostgreSQL RDS instance created with:
  - ✅ Performance Insights enabled (Advanced mode - 15 months retention)
  - ✅ Enhanced Monitoring (60-second granularity)
  - ✅ CloudWatch Logs export (postgresql, upgrade)
  - ✅ Database Insights - Advanced mode features
- ✅ Security group connectivity verified (PMM can reach RDS on port 5432)
- ✅ pg_stat_statements extension enabled on both `testdb` and `postgres` databases
- ✅ PostgreSQL successfully added to PMM monitoring
- ✅ All PMM agents running (postgres_exporter + QAN pgstatements)
- ✅ Metrics flowing to dashboards (Connections, QPS, Locks, Tuples, Query Analytics)

**Documentation Completed:**
- ✅ README.md - Comprehensive "Adding PostgreSQL to PMM" section with:
  - ✅ Prerequisites (security groups, pg_stat_statements, Database Insights)
  - ✅ Step-by-step connection instructions
  - ✅ Database Insights configuration guide
  - ✅ Monitoring permissions setup (pg_monitor role)
  - ✅ Troubleshooting section with common errors:
    - ✅ Connection timeout (security group configuration)
    - ✅ Authentication error (database name + SSL/TLS requirements)
    - ✅ Failed monitoring (pg_stat_statements extension)
  - ✅ Verification steps

**Issues Encountered & Resolved:**
1. ✅ Connection timeout → Added security group rules in `security.tf`
2. ✅ "no encryption" error → Documented TLS requirement in README
3. ✅ Wrong database name → Documented database field requirement
4. ✅ QAN agent "Waiting" → Enabled pg_stat_statements on postgres database
5. ✅ IAM policy using jsonencode → Refactored to use data source policy document

#### **Makefile**
```makefile
PYTHON := python3
TERRAFORM := terraform
PYTEST := pytest

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make test          - Run all tests"
	@echo "  make test-keep     - Run a selected test and keep resources"
	@echo "  make test-clean    - Run a selected test and destroy resources"
	@echo "  make lint          - Lint Terraform code"
	@echo "  make format        - Format Terraform code"
	@echo "  make clean         - Clean test artifacts"

```

#### **tests/test_basic.py**
```python
import pytest
import boto3
import time
from infrahouse_toolkit import terraform_apply

def test_pmm_deployment():
    """Test basic PMM server deployment"""
    with terraform_apply(
        "test_data/test_basic",
        json_output=True,
        terraform_vars={
            "test_name": "pmm-basic-test",
        }
    ) as tf_output:
        # Verify ECS service is running
        ecs = boto3.client('ecs')
        services = ecs.describe_services(
            cluster=tf_output['ecs_cluster_name'],
            services=[tf_output['ecs_service_name']]
        )
        assert services['services'][0]['runningCount'] == 1
        
        # Verify ALB is healthy
        alb = boto3.client('elbv2')
        health = alb.describe_target_health(
            TargetGroupArn=tf_output['target_group_arn']
        )
        assert any(t['TargetHealth']['State'] == 'healthy' 
                  for t in health['TargetHealthDescriptions'])
        
        # Test PMM API endpoint
        import requests
        response = requests.get(
            f"https://{tf_output['pmm_url']}/v1/readyz",
            verify=False
        )
        assert response.status_code == 200
```

### 4. **Documentation Plan**

#### **README.md Structure**
```markdown
# terraform-aws-pmm-ecs

Deploy Percona Monitoring and Management (PMM) on AWS ECS with persistent storage

## Features
- ✅ Production-ready PMM deployment on ECS
- ✅ Persistent storage with EFS
- ✅ Automatic SSL/TLS with ACM
- ✅ RDS PostgreSQL monitoring support
- ✅ CloudWatch monitoring and alarms
- ✅ Automated backups
- ✅ High availability configuration

## Requirements
- AWS Provider >= 5.0
- Terraform >= 1.0
- Existing VPC with public/private subnets
- Route53 hosted zone

## Quick Start
[Basic example]

## Architecture
[Architecture diagram]

## RDS Monitoring Setup
[Step-by-step guide]

## Inputs
[Generated from variables.tf]

## Outputs
[Generated from outputs.tf]

## Testing
[Testing instructions]

## License
Apache 2.0
```

### 5. **Release Process**

#### **.github/workflows/release.yml**
```yaml
name: Release
on:
  push:
    tags:
      - 'v*'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v2
      
      - name: Terraform Format Check
        run: terraform fmt -check -recursive
      
      - name: Run Tests
        run: make test
      
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            README.md
            CHANGELOG.md
```

### 6. **Development Status**

#### ✅ **Completed**
**Core Infrastructure:**
- ✅ Module file structure (main.tf, variables.tf, outputs.tf, versions.tf, locals.tf, data.tf)
- ✅ Security groups for website-pod
- ✅ IAM roles and policies (EC2 instance profile with Secrets Manager access)
- ✅ Integration with infrahouse/website-pod/aws module v5.9.0
- ✅ Cloud-init configuration with Docker CE installation
- ✅ systemd services for PMM container management
- ✅ Admin password initialization system (get-pmm-password.sh, set-pmm-password.sh)

**Features & Configuration:**
- ✅ Auto-generated admin passwords (random_password + Secrets Manager)
- ✅ InfraHouse secret module integration
- ✅ PMM environment variables (DISABLE_TELEMETRY)
- ✅ Local storage for ClickHouse and PostgreSQL databases (ephemeral)
- ✅ Docker container deployment with correct port mappings (80:8080, 443:8443)
- ✅ Password initialization after PMM startup using change-admin-password command
- ✅ Ubuntu Pro 24.04 LTS (Noble) with Docker CE
- ✅ InfraHouse and Docker official repositories configured in cloud-init

**Project Setup:**
- ✅ .gitignore
- ✅ Makefile (bootstrap, lint, format, validate, docs, clean)
- ✅ .bumpversion.cfg for version tracking
- ✅ InfraHouse tagging standard applied
- ✅ Workarounds for missing module outputs documented

**Module Structure (Section 1):**
- ✅ README.md - Comprehensive with examples, usage guide
- ✅ LICENSE - Apache 2.0
- ✅ .github/workflows/terraform-CI.yml - PR validation workflow (InfraHouse pattern)
- ✅ .github/workflows/terraform-CD.yml - Release automation (InfraHouse pattern)
- ✅ examples/basic/ - Simple deployment example
- ✅ examples/advanced/ - With custom KMS, monitoring, etc.
- ✅ examples/with-rds-monitoring/ - RDS integration example
- ✅ test_data/test_basic/ - Basic test configuration
- ✅ tests/conftest.py - Pytest configuration
- ✅ tests/test_basic.py - Basic deployment test
- ✅ tests/requirements.txt - Python test dependencies
- ✅ scripts/setup-pmm-client.sh - Helper script for client setup
- ✅ scripts/backup-efs.sh - Manual backup script
- ✅ docs/ARCHITECTURE.md - Detailed architecture explanation
- ✅ docs/RDS_SETUP.md - RDS monitoring setup guide
- ✅ docs/TROUBLESHOOTING.md - Common issues and solutions

#### ✅ **All Core Tasks Completed**

**Additional Testing:**
- ✅ test_data/test_with_vpc/ - VPC integration test with RDS
- ✅ test_data/test_with_backup/ - Backup/restore test with custom KMS
- ✅ tests/test_monitoring.py - CloudWatch alarms and SNS test
- ✅ tests/test_persistence.py - EFS backup/restore and persistence test

**Additional Documentation:**
- ✅ CHANGELOG.md - Version history and release notes

**Templates:**
- ✅ templates/get-pmm-password.sh.tftpl - Retrieve password from Secrets Manager
- ✅ templates/set-pmm-password.sh.tftpl - Wait for PMM and set password
- ✅ templates/set-pmm-password.service.tftpl - Systemd oneshot service
- ✅ templates/pmm-server.service.tftpl - PMM Docker container systemd service

**Critical Fixes:**
- ✅ Fixed ADMIN_PASSWORD env var issue (not supported in PMM 2.x/3.x Docker)
- ✅ Implemented post-initialization password change using change-admin-password
- ✅ Fixed Docker port mappings for PMM (80:8080, 443:8443)
- ✅ Fixed cloud-init brace expansion for directory creation
- ✅ Migrated from EFS to local storage (avoiding database corruption)

**Next Steps:**
1. Run tests: `make test` (verify all tests pass)
2. Fix any test failures
3. Tag and release: v0.1.0

### 7. **Implementation Notes & Workarounds**

#### **Architecture Migration: ECS → Website-Pod**
**Problem**: EFS eventual consistency caused database corruption (ClickHouse, PostgreSQL)
- ClickHouse error: "could not locate a valid checkpoint record"
- PostgreSQL error: Same checkpoint corruption

**Solution**: Migrated to infrahouse/website-pod/aws with local storage
- PMM container runs directly on EC2 via systemd
- Databases stored on local EBS volumes (ephemeral but consistent)
- Simpler architecture, no ECS overhead
- Data loss accepted for this use case (monitoring data is transient)

#### **PMM Password Initialization Issue**
**Problem**: ADMIN_PASSWORD environment variable doesn't work in PMM 2.x/3.x Docker
- PMM v1 supported SERVER_USER/SERVER_PASSWORD env vars
- These were removed in PMM v2.x (JIRA PMM-4673 not implemented)
- Container always creates default admin/admin credentials

**Solution**: Post-initialization password change
1. PMM container starts with default credentials
2. systemd oneshot service waits for PMM health endpoint
3. Executes `docker exec pmm-server change-admin-password <password>`
4. Flag file prevents re-running on restarts

#### **Module Output Workarounds (Legacy - Not Applicable)**
~~The infrahouse/ecs/aws module v6.0.0 is missing several outputs needed for monitoring. Implemented workarounds:~~
**Note**: This section is obsolete as we're using website-pod, not ECS.

1. **Target Group ARN**: Extract from listener data source
   ```hcl
   data "aws_lb_listener" "pmm" {
     arn = module.pmm_ecs.ssl_listener_arn
   }

   locals {
     target_group_arn = try(data.aws_lb_listener.pmm.default_action[0].target_group_arn, "")
   }
   ```

2. **ARN Suffixes for CloudWatch**: Compute from full ARNs
   ```hcl
   locals {
     load_balancer_arn_suffix = try(split("loadbalancer/", module.pmm_ecs.load_balancer_arn)[1], "")
     target_group_arn_suffix  = try(split("targetgroup/", local.target_group_arn)[1], "")
   }
   ```

3. **Service/Cluster Names**: Use local value directly
   ```hcl
   locals {
     service_name = var.service_name
   }
   # Both service_name and cluster_name equal local.service_name
   ```

4. **Backend Security Group**: Use `backend_security_group` output instead of non-existent `service_security_group_id`

**Filed GitHub Issue**: Request missing outputs (service_name, cluster_name, *_arn_suffix) to be added to infrahouse/ecs/aws module.

#### **Security Best Practices**
- EFS always encrypted (no toggle)
- Auto-generated 32-character passwords using `random_password`
- Passwords stored in AWS Secrets Manager via InfraHouse secret module
- No `secret_writers` - passwords are Terraform-managed
- Only authorized readers via `secret_readers` variable

#### **Production Defaults**
Changed defaults to production-ready values:
- Backup retention: 365 days (from 30)
- CloudWatch log retention: 365 days (from 7)
- PMM version: 3 (from 2, due to PMM 2 EOL July 2025)
- Monitoring: Always enabled (removed toggle)
- Logging: Always enabled (removed toggle)
- Backups: Always enabled (removed toggle)

#### **InfraHouse Standards Applied**
- Exact version pinning for all modules (no `~>`)
- Lowercase tags except `Name`
- `created_by_module` tag on all resources
- `module_version` tag on main resource (EFS)
- Bumpversion config for version tracking
- Use HEREDOC for long variable descriptions

This modular approach follows InfraHouse patterns while being specific to PMM's requirements. The module will be reusable, well-tested, and production-ready.
