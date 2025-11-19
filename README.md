# terraform-aws-pmm-ecs

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/infrahouse/terraform-aws-pmm-ecs)
![Terraform Registry](https://img.shields.io/badge/terraform-registry-blue.svg)

Deploy [Percona Monitoring and Management (PMM)](https://www.percona.com/software/database-tools/percona-monitoring-and-management) on AWS ECS with persistent storage, automatic backups, and CloudWatch monitoring.

## Features

- ✅ **Production-ready PMM deployment** on ECS with singleton pattern (1 task exactly)
- ✅ **Persistent storage** with encrypted EFS (AWS-managed or customer-managed KMS)
- ✅ **Automatic SSL/TLS** with ACM certificates
- ✅ **RDS monitoring support** with automatic security group configuration
- ✅ **CloudWatch monitoring** with alarms for ECS, ALB, EFS, and target health
- ✅ **Automated daily backups** with 1-year retention (configurable)
- ✅ **Auto-generated passwords** stored securely in AWS Secrets Manager
- ✅ **PMM 3.x by default** (PMM 2 EOL July 2025)

## Requirements

- **Terraform** >= 1.0
- **AWS Provider** >= 5.11, < 7.0
- Existing VPC with public and private subnets
- Route53 hosted zone for DNS records

## Quick Start

```hcl
module "pmm" {
  source  = "infrahouse/pmm-ecs/aws"
  version = "~> 0.1"

  # Network configuration
  public_subnet_ids  = ["subnet-abc123", "subnet-def456"]
  private_subnet_ids = ["subnet-ghi789", "subnet-jkl012"]

  # DNS configuration
  zone_id   = "Z1234567890ABC"
  dns_names = ["pmm"]

  # Required variables
  environment   = "production"
  alarm_emails  = ["devops@example.com"]

  # Optional: RDS monitoring
  rds_security_group_ids = ["sg-rds123"]

  tags = {
    Project = "monitoring"
    Team    = "platform"
  }
}
```

After deployment, PMM will be available at `https://pmm.<your-zone>/` (e.g., `https://pmm.example.com/`).

**Retrieve the admin password:**
```bash
aws secretsmanager get-secret-value \
  --secret-id pmm-server-admin-password \
  --query SecretString \
  --output text
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                             │
└────────────────────────┬────────────────────────────────────┘
                         │
                    ┌────▼────┐
                    │   ALB   │  (HTTPS, ACM Certificate)
                    │  (Public│
                    │ Subnets)│
                    └────┬────┘
                         │
     ┌───────────────────┼───────────────────┐
     │  ECS Cluster      │                   │
     │  ┌────────────────▼────────────┐     │
     │  │   PMM Container (Singleton) │     │
     │  │   - Port 443                │     │
     │  │   - Auto-scaling: 1-1-1     │     │
     │  └────────┬────────────────────┘     │
     │           │                           │
     │  (Private Subnets)                   │
     └───────────┼───────────────────────────┘
                 │
        ┌────────┴─────────┐
        │                  │
   ┌────▼────┐      ┌─────▼──────┐
   │   EFS   │      │  Secrets   │
   │ (Data)  │      │  Manager   │
   │Encrypted│      │ (Password) │
   └─────────┘      └────────────┘
```

### Key Components

- **Application Load Balancer (ALB)**: HTTPS endpoint with ACM certificate
- **ECS Cluster**: Single-instance deployment for data consistency
- **EFS**: Persistent storage for PMM data (always encrypted)
- **Secrets Manager**: Auto-generated 32-character admin password
- **CloudWatch**: Monitoring and alarms for service health
- **AWS Backup**: Daily EFS backups with 1-year retention

## Examples

### Basic Deployment

See [examples/basic](./examples/basic/) for a minimal configuration.

### Advanced Deployment

See [examples/advanced](./examples/advanced/) for configuration with:
- Custom KMS key for EFS encryption
- Custom backup retention
- Custom CloudWatch log retention
- SSH access to EC2 instances

### RDS Monitoring Setup

See [examples/with-rds-monitoring](./examples/with-rds-monitoring/) and [docs/RDS_SETUP.md](./docs/RDS_SETUP.md) for detailed RDS integration.

## Usage Notes

### PMM Version

The module defaults to PMM 3.x (`pmm_version = "3"`). PMM 2 reaches EOL in July 2025.

### Telemetry

PMM telemetry is **disabled by default** (`disable_telemetry = true`). PMM collects anonymous usage data (version, uptime, server count) to help Percona improve the product. No sensitive data is collected.

### DBaaS

PMM DBaaS features are **disabled by default** (`enable_dbaas = false`). DBaaS is deprecated by Percona in favor of Percona Everest and requires a Kubernetes cluster.

### Retention Periods

Default retention periods are set for production use:
- **EFS backups**: 365 days
- **CloudWatch logs**: 365 days

Adjust via `backup_retention_days` and `cloudwatch_log_retention_days` variables.

### Security

- EFS is **always encrypted** (choice of AWS-managed or customer-managed KMS key)
- Admin password is **auto-generated** (32 characters) and stored in Secrets Manager
- CloudWatch monitoring and alarms are **always enabled**
- At least one alarm email is **required**

<!-- BEGIN_TF_DOCS -->

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| public_subnet_ids | Public subnet IDs for ALB | `list(string)` | n/a | yes |
| private_subnet_ids | Private subnet IDs for ECS tasks and EFS | `list(string)` | n/a | yes |
| zone_id | Route53 zone ID for PMM DNS records | `string` | n/a | yes |
| environment | Environment name (e.g., production, staging, dev) | `string` | n/a | yes |
| alarm_emails | Email addresses for CloudWatch alarms | `list(string)` | n/a | yes |
| service_name | Name for the PMM service | `string` | `"pmm-server"` | no |
| dns_names | DNS names for PMM (will be created in the Route53 zone) | `list(string)` | `["pmm"]` | no |
| pmm_version | PMM Docker image version (3 is recommended, PMM 2 EOL July 2025) | `string` | `"3"` | no |
| disable_telemetry | Disable PMM telemetry | `bool` | `true` | no |
| enable_dbaas | Enable PMM DBaaS features (deprecated) | `bool` | `false` | no |
| instance_type | EC2 instance type for ECS | `string` | `"m5.large"` | no |
| container_cpu | CPU units for PMM container | `number` | `2048` | no |
| container_memory | Memory (MB) for PMM container | `number` | `4096` | no |
| efs_kms_key_id | KMS key ID for EFS encryption (null = AWS-managed) | `string` | `null` | no |
| backup_retention_days | Days to retain EFS backups | `number` | `365` | no |
| cloudwatch_log_retention_days | CloudWatch log retention in days | `number` | `365` | no |
| rds_security_group_ids | Security group IDs of RDS instances to monitor | `list(string)` | `[]` | no |
| secret_readers | IAM role ARNs that can read the PMM admin password secret | `list(string)` | `[]` | no |
| ssh_key_name | SSH key name for EC2 instances | `string` | `null` | no |
| admin_cidr_blocks | CIDR blocks for admin SSH access | `list(string)` | `[]` | no |
| tags | Tags to apply to all resources | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| pmm_url | URL to access PMM server |
| ecs_cluster_name | Name of the ECS cluster |
| ecs_service_name | Name of the ECS service |
| efs_id | ID of the EFS file system |
| efs_arn | ARN of the EFS file system |
| load_balancer_arn | ARN of the Application Load Balancer |
| load_balancer_dns_name | DNS name of the Application Load Balancer |
| target_group_arn | ARN of the target group |
| admin_password_secret_arn | ARN of the admin password secret in Secrets Manager |
| security_group_id | Security group ID for the PMM ECS tasks |
| efs_security_group_id | Security group ID for the EFS mount targets |

<!-- END_TF_DOCS -->

## Monitoring

The module creates CloudWatch alarms for:

- **ECS Service Health**: Alerts if PMM task is not running
- **Target Group Health**: Alerts if ALB targets are unhealthy
- **EFS Burst Credits**: Alerts if EFS burst credit balance is low (bursting mode only)
- **ALB 5XX Errors**: Alerts if ALB is returning server errors

All alarms send notifications to the email addresses specified in `alarm_emails`.

## Backup and Recovery

EFS backups run daily at 2 AM UTC with 365-day retention by default. To restore from backup:

```bash
# List available recovery points
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name pmm-server-backup-vault

# Restore from recovery point
aws backup start-restore-job \
  --recovery-point-arn <arn> \
  --metadata file-system-id=<new-efs-id>
```

See [docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) for detailed recovery procedures.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) for common issues and solutions.

## Testing

This module uses [infrahouse-toolkit](https://github.com/infrahouse/infrahouse-toolkit) for testing.

```bash
# Install dependencies
make bootstrap

# Run tests
make test

# Lint and format
make lint
make format
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

Apache 2.0 Licensed. See [LICENSE](./LICENSE) for full details.

## Author

Maintained by [InfraHouse](https://github.com/infrahouse).
