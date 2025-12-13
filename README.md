# terraform-aws-pmm-ecs

![GitHub release (latest SemVer)](https://img.shields.io/github/v/release/infrahouse/terraform-aws-pmm-ecs)
![Terraform Registry](https://img.shields.io/badge/terraform-registry-blue.svg)

Deploy [Percona Monitoring and Management (PMM)](https://www.percona.com/software/database-tools/percona-monitoring-and-management) on AWS using EC2 with Docker, featuring automatic SSL/TLS and CloudWatch monitoring.

## Features

- ✅ **Production-ready PMM deployment** on dedicated EC2 instance with persistent EBS storage
- ✅ **Persistent storage** using separate EBS volume mounted at `/srv` for PMM data
- ✅ **Automated backups** via AWS Backup with configurable retention (30 days default)
- ✅ **Auto-recovery** for hardware failures with EC2 auto-recovery and CloudWatch alarms
- ✅ **Docker-based deployment** with systemd service management
- ✅ **Automatic SSL/TLS** with ACM certificates and DNS validation via Application Load Balancer
- ✅ **RDS monitoring support** with automatic security group configuration
- ✅ **Custom PostgreSQL queries** with configurable collection intervals (high/medium/low resolution)
- ✅ **Comprehensive CloudWatch monitoring** with dashboard and alarms for instance, disk, memory, and EBS metrics
- ✅ **Auto-generated passwords** stored securely in AWS Secrets Manager
- ✅ **PMM 3.x by default** (PMM 2 EOL July 2025)
- ✅ **Ubuntu Pro 24.04 LTS** with official Docker CE installation

## Requirements

- **Terraform** >= 1.0
- **AWS Provider** >= 5.11, < 7.0
- Existing VPC with public and private subnets
- Route53 hosted zone for DNS records

## Quick Start

```hcl
module "pmm" {
  source  = "infrahouse/pmm-ecs/aws"
  version = "0.3.0"

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

## Adding PostgreSQL to PMM

After deploying PMM, you can add PostgreSQL databases for monitoring. Here's how to add an RDS PostgreSQL instance:

### Prerequisites

1. Ensure your RDS security group is included in `rds_security_group_ids` in the PMM module configuration
2. The PostgreSQL database must have the `pg_stat_statements` extension enabled
3. **Recommended**: Enable Database Insights (Performance Insights + Enhanced Monitoring) for advanced analytics and unified troubleshooting in CloudWatch

### Steps to Add PostgreSQL Database

1. **Access PMM UI**: Navigate to `https://pmm.<your-zone>/` and log in with the admin credentials

2. **Navigate to Inventory**: Go to `Configuration` → `PMM Inventory` → `Add Service`

3. **Select PostgreSQL**: Choose "PostgreSQL" from the service type dropdown

4. **Enter Connection Details**:
   - **Hostname**: Your RDS endpoint (e.g., `mydb.abc123.us-west-2.rds.amazonaws.com`)
   - **Port**: `5432` (default PostgreSQL port)
   - **Username**: Your PostgreSQL username (must have monitoring privileges)
   - **Password**: Your PostgreSQL password
   - **Database**: Your database name (e.g., `testdb`, `mydb`) - **REQUIRED**, cannot use default "postgres"
   - **Use TLS**: Enable (required for RDS - check "Use TLS" and select "Skip TLS certificate validation" for RDS)
   - **Service Name**: A friendly name for this database (e.g., `production-postgres`)

5. **Configure Monitoring Options**:
   - **Query Analytics**: Enable to collect query performance data
   - **Table Statistics**: Enable to collect table-level metrics
   - **Custom Labels**: Add any custom labels for organization (e.g., `environment=production`)

6. **Click "Add Service"**: PMM will validate the connection and start collecting metrics

### Enabling Database Insights (Recommended)

Database Insights combines database metrics and logs into a unified view in CloudWatch to speed up database troubleshooting. For enhanced monitoring capabilities and advanced analytics, modify your RDS instance to use the Advanced mode of Database Insights:

```hcl
resource "aws_db_instance" "example" {
  # ... other configuration ...

  # Database Insights - Advanced mode
  # Combines Performance Insights + Enhanced Monitoring in unified CloudWatch view
  performance_insights_enabled          = true
  performance_insights_retention_period = 465  # Days (~15 months for Advanced mode)
  # Standard mode: 7 days (free tier)
  # Advanced mode: 465 days (~15 months) or 731 days (24 months)

  # Enhanced Monitoring for OS-level metrics (required for Database Insights)
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 60  # Seconds (1, 5, 10, 15, 30, 60)
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn
}
```

**Database Insights - Advanced mode** provides:
- **15-24 months of performance history retention** (vs 7 days in Standard)
- **Fleet-level monitoring** across multiple databases
- **CloudWatch Application Signals integration** for advanced analytics
- **Performance Insights**: Query-level performance data and wait events
- **Enhanced Monitoring**: OS-level metrics (CPU, memory, I/O) at 1-60 second granularity
- **CloudWatch Logs**: PostgreSQL logs and upgrade logs for troubleshooting
- **Unified Dashboard**: All metrics and logs in one CloudWatch view

### Granting Monitoring Permissions

For comprehensive monitoring, create a dedicated PMM user in PostgreSQL:

```sql
-- Create monitoring user
CREATE USER pmm_user WITH PASSWORD 'secure_password';

-- Grant necessary permissions
GRANT pg_monitor TO pmm_user;
GRANT SELECT ON pg_stat_database TO pmm_user;

-- Enable pg_stat_statements (required for query analytics)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
GRANT SELECT ON pg_stat_statements TO pmm_user;
```

### Verification

After adding the database:

1. Check the PMM dashboard for incoming metrics
2. Navigate to `Dashboards` → `PostgreSQL` → `PostgreSQL Instance Summary`
3. Verify that data is being collected (graphs should show activity within 1-2 minutes)

### Troubleshooting

#### Connection Timeout: `dial tcp x.x.x.x:5432: i/o timeout`

**Cause**: PMM cannot reach the PostgreSQL instance due to security group configuration.

**Solution**: Ensure the RDS security group is included in the `rds_security_group_ids` variable when deploying the PMM module:

#### Authentication Error: `no pg_hba.conf entry for host ... no encryption`

**Cause**: Two common issues:
1. Wrong database name (trying to connect to "postgres" instead of your actual database)
2. SSL/TLS not enabled (RDS requires encrypted connections by default)

**Solution**: When adding the PostgreSQL instance in PMM UI:
1. **Database field**: Enter your actual database name (e.g., `testdb`, `mydb`) - do NOT leave it as the default "postgres"
2. **Use TLS**: Check this box and select "Skip TLS certificate validation" (RDS uses AWS-managed certificates)

#### Connection Error: Wrong database specified

```hcl
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  # ... other configuration ...

  # REQUIRED: Add RDS security group IDs to allow PMM access
  rds_security_group_ids = [aws_security_group.postgres.id]
}
```

The module automatically creates ingress rules on the specified security groups to allow PMM traffic on port 5432.

**Verify connectivity:**
```bash
# SSH to PMM EC2 instance
ssh ec2-user@<pmm-instance-ip>

# Test PostgreSQL connectivity
nc -zv <rds-endpoint> 5432
# Should output: Connection to <rds-endpoint> 5432 port [tcp/postgresql] succeeded!
```

#### Other Common Issues

If metrics aren't appearing:

- **Check connectivity**: Ensure PMM can reach the RDS instance (security groups configured correctly)
- **Verify credentials**: Ensure the username/password are correct
- **Check permissions**: Ensure the monitoring user has the required grants
- **Review logs**: Check PMM server logs for connection errors:
  ```bash
  # SSH to PMM EC2 instance
  sudo journalctl -u pmm-server -f
  ```

For detailed RDS monitoring setup, see [docs/RDS_SETUP.md](./docs/RDS_SETUP.md).

## Custom PostgreSQL Queries

PMM allows you to extend PostgreSQL monitoring with custom queries collected at different intervals. This module supports adding custom query files for three resolution levels:

- **High Resolution** - Executed every few seconds (most frequent)
- **Medium Resolution** - Executed every minute
- **Low Resolution** - Executed every few minutes (least frequent)

### Adding Custom Queries

Create a YAML file following the [PMM custom queries format](https://docs.percona.com/percona-monitoring-and-management/how-to/extend-metrics.html):

**Example: Medium-resolution query for PostgreSQL activity (`pg-activity.yml`)**:
```yaml
---
pg_activity:
  query: |
    SELECT datname, state, wait_event_type, wait_event, COUNT(*) as processes
    FROM pg_stat_activity
    WHERE datname !~ '^(postgres|rdsadmin|template(0|1))$'
    GROUP BY datname, state, wait_event_type, wait_event
  master: true
  metrics:
    - datname:
        usage: "LABEL"
        description: "Name of the database"
    - state:
        usage: "LABEL"
        description: "State of the process"
    - processes:
        usage: "GAUGE"
        description: "Processes count (per database, state)"
```

**Use the query in your module**:
```hcl
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  # ... other configuration ...

  # Add custom PostgreSQL queries at different intervals
  postgresql_custom_queries_high_resolution   = file("${path.module}/queries/pg-connections.yml")
  postgresql_custom_queries_medium_resolution = file("${path.module}/queries/pg-activity.yml")
  postgresql_custom_queries_low_resolution    = file("${path.module}/queries/pg-table-stats.yml")
}
```

### How It Works

1. **Files Created on EC2**: Custom query files are written to the EC2 instance during initialization via cloud-init
2. **Mounted into Container**: Files are volume-mounted from the host into the PMM container at the appropriate collection intervals
3. **PMM Collection**: PMM automatically discovers and executes queries in:
   - `/usr/local/percona/pmm/collectors/custom-queries/postgresql/high-resolution/`
   - `/usr/local/percona/pmm/collectors/custom-queries/postgresql/medium-resolution/`
   - `/usr/local/percona/pmm/collectors/custom-queries/postgresql/low-resolution/`

### Query Format Reference

Each query file should follow this structure:

```yaml
---
query_name:
  query: |
    SELECT column1, column2, metric_value
    FROM your_table
    WHERE conditions
  master: true  # Run on primary server only
  metrics:
    - column1:
        usage: "LABEL"          # Use as a label
        description: "Description"
    - metric_value:
        usage: "GAUGE"          # Metric type: GAUGE, COUNTER
        description: "Metric description"
```

**Key fields**:
- `query`: SQL query to execute
- `master`: Set to `true` to run only on primary servers (not replicas)
- `metrics`: Define how each column should be used (label vs metric)
- `usage`: Either `LABEL` (for grouping) or metric types (`GAUGE`, `COUNTER`, `HISTOGRAM`)

### Best Practices

- **Choose appropriate resolution**: High-resolution queries execute frequently, so keep them lightweight
- **Test queries first**: Verify query performance on your database before deploying
- **Use labels wisely**: Labels create unique metric series; too many labels can cause high cardinality
- **Set master flag**: For primary-only queries, set `master: true` to avoid running on replicas
- **Monitor query cost**: Check `pg_stat_statements` to ensure custom queries don't impact performance

### Example Use Cases

- **High Resolution**: Active connection counts, current wait events
- **Medium Resolution**: Per-database activity, transaction rates, lock monitoring
- **Low Resolution**: Table statistics, index usage, vacuum progress

For complete query format documentation, see [Percona PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/how-to/extend-metrics.html).

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         Internet                            │
└────────────────────────┬────────────────────────────────────┘
                         │
                    ┌────▼────┐
                    │   ALB   │  (HTTPS, ACM Certificate + DNS Validation)
                    │  (Public│
                    │ Subnets)│
                    └────┬────┘
                         │
        ┌────────────────▼────────────────────┐
        │   EC2 Instance (Ubuntu Pro 24.04)   │
        │   ┌──────────────────────────────┐  │
        │   │  PMM Docker Container        │  │
        │   │  - nginx: 8080/8443          │  │
        │   │  - ClickHouse (/srv)         │  │
        │   │  - PostgreSQL (/srv)         │  │
        │   │  - Grafana (/srv)            │  │
        │   └──────────────────────────────┘  │
        │   Managed by systemd                │
        │                                     │
        │   ┌──────────────────────────────┐  │
        │   │  EBS Data Volume (100GB)     │  │
        │   │  Mounted at /srv             │  │
        │   │  GP3 with encryption         │  │
        │   └──────────────────────────────┘  │
        │  (Private Subnet)                   │
        │                                     │
        │  - EC2 Auto-Recovery enabled        │
        │  - CloudWatch Agent for monitoring  │
        └──────────────────┬──────────────────┘
                           │
             ┌─────────────┼──────────────┐
             │             │              │
      ┌──────▼──────┐  ┌───▼────┐  ┌──────▼──────┐
      │  Secrets    │  │ AWS    │  │ CloudWatch  │
      │  Manager    │  │ Backup │  │ Dashboard   │
      │ (Password)  │  │(Daily) │  │ + Alarms    │
      └─────────────┘  └────────┘  └─────────────┘
```

### Key Components

- **Application Load Balancer (ALB)**: HTTPS endpoint with ACM certificate (DNS validation), routes to EC2 instance
- **EC2 Instance**: Single dedicated instance (Ubuntu Pro 24.04 LTS) with Docker CE and auto-recovery
- **EBS Data Volume**: Separate 100GB encrypted GP3 volume mounted at `/srv` for persistent storage
- **PMM Docker Container**: Runs via systemd, manages all PMM services (ClickHouse, PostgreSQL, Grafana)
- **AWS Backup**: Daily automated snapshots with 30-day retention (configurable)
- **Secrets Manager**: Auto-generated 32-character admin password
- **CloudWatch**: Dashboard with instance metrics + alarms for EC2, ALB, memory, disk, and EBS burst balance
- **CloudWatch Agent**: Collects memory and disk usage metrics from the instance

## Performance Sizing

PMM performance depends on workload (number of monitored databases, metrics retention, query analytics load). This guide helps you choose appropriate instance types and EBS performance settings.

### Instance Sizing

| Instance Type | Monitored Databases | Metrics Retention | Memory | vCPUs |
|---------------|---------------------|-------------------|--------|-------|
| **m5.large** (default) | 1-10 databases | 7-30 days | 8 GB | 2 |
| **m5.xlarge** | 10-20 databases | 30-90 days | 16 GB | 4 |
| **m5.2xlarge** | 20-50 databases | 90+ days | 32 GB | 8 |

**Note:** Actual requirements depend on metrics frequency, query analytics load, and custom queries.

### EBS Volume Performance

Default settings (100GB, 3000 IOPS, 125 MB/s throughput) are suitable for:
- 1-5 monitored databases
- 7-day metrics retention
- Light query analytics load
- Cost-effective baseline ($10-15/month for storage)

**Increase performance for higher workloads:**

| Workload | Volume Size | IOPS | Throughput | Use Case |
|----------|-------------|------|------------|----------|
| **Baseline** (default) | 100 GB | 3000 | 125 MB/s | 1-5 databases, 7-day retention |
| **Medium** | 200 GB | 5000 | 250 MB/s | 10-20 databases, 30-day retention |
| **Heavy** | 500 GB | 8000 | 500 MB/s | 20+ databases, 90+ day retention |
| **High Performance** | 500+ GB | io2 volume | — | Heavy query analytics, 50+ databases |

**Example configurations:**

```hcl
# Medium workload (10-20 databases, 30-day retention)
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  instance_type       = "m5.xlarge"
  ebs_volume_size     = 200
  ebs_iops            = 5000
  ebs_throughput      = 250

  # ... other configuration ...
}

# Heavy workload (20+ databases, 90-day retention)
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  instance_type       = "m5.2xlarge"
  ebs_volume_size     = 500
  ebs_iops            = 8000
  ebs_throughput      = 500

  # ... other configuration ...
}

# High-performance workload (50+ databases, heavy analytics)
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  instance_type       = "m5.2xlarge"
  ebs_volume_size     = 1000
  ebs_volume_type     = "io2"
  ebs_iops            = 16000

  # ... other configuration ...
}
```

### Monitoring EBS Performance

Watch for these CloudWatch metrics to determine if you need to increase IOPS/throughput:

- **EBS Burst Balance** (gp2 only): Alarm fires when < 20% (indicates sustained IOPS demand)
- **VolumeReadOps/VolumeWriteOps**: High values approaching IOPS limits
- **PMM Query Response Time**: Slow dashboard loads may indicate I/O bottleneck

Check CloudWatch Dashboard (created automatically by this module) for real-time performance metrics.

## Examples

### Basic Deployment

See [examples/basic](./examples/basic/) for a minimal configuration.

### Advanced Deployment

See [examples/advanced](./examples/advanced/) for configuration with:
- Larger instance types for high-volume monitoring
- SSH access to EC2 instances
- Custom tags and naming

### RDS Monitoring Setup

See [examples/with-rds-monitoring](./examples/with-rds-monitoring/) and [docs/RDS_SETUP.md](./docs/RDS_SETUP.md) for detailed RDS integration.

## Usage Notes

### PMM Version

The module defaults to PMM 3.x (`pmm_version = "3"`). PMM 2 reaches EOL in July 2025.

### Telemetry

PMM telemetry is **disabled by default** (`disable_telemetry = true`). PMM collects anonymous usage data (version, uptime, server count) to help Percona improve the product. No sensitive data is collected.

### Data Persistence

This module uses **persistent EBS storage** for all PMM data with automated backups.

**How it works:**
- Separate 100GB EBS volume (GP3, encrypted) mounted at `/srv`
- All PMM databases (ClickHouse, PostgreSQL) and Grafana configs stored on this volume
- Data persists across EC2 instance stop/start and Docker container restarts
- Automated daily backups via AWS Backup (30-day retention by default, configurable)

**Benefits over EFS:**
- No corruption issues (EFS eventual consistency caused problems)
- Better performance and consistent I/O
- Simpler architecture
- Point-in-time recovery via EBS snapshots

**Backup & Recovery:**
- Backups run daily at 5 AM UTC (configurable via `backup_schedule`)
- Retention period is 30 days by default (configurable via `backup_retention_days`)
- To restore from backup: Create new EBS volume from snapshot, attach to instance
- See [docs/BACKUP_RESTORE.md](./docs/BACKUP_RESTORE.md) for detailed procedures

### Security

- Admin password is **auto-generated** (32 characters) and stored in Secrets Manager
- CloudWatch monitoring and alarms are **always enabled**
- At least one alarm email is **required**
- Docker container runs with systemd service isolation

<!-- BEGIN_TF_DOCS -->

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.11, < 7.0 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | ~> 2.3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.11, < 7.0 |
| <a name="provider_cloudinit"></a> [cloudinit](#provider\_cloudinit) | ~> 2.3 |
| <a name="provider_random"></a> [random](#provider\_random) | ~> 3.6 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_admin_password_secret"></a> [admin\_password\_secret](#module\_admin\_password\_secret) | infrahouse/secret/aws | 1.1.1 |
| <a name="module_pmm_pod"></a> [pmm\_pod](#module\_pmm\_pod) | infrahouse/website-pod/aws | 5.10.0 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_policy.pmm_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role_policy_attachment.pmm_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_security_group_rule.pmm_to_rds_postgres](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [random_password.admin](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_ami.ubuntu_pro](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.pmm_instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_internet_gateway.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/internet_gateway) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_subnet.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [cloudinit_config.pmm](https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs/data-sources/config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_admin_cidr_block"></a> [admin\_cidr\_block](#input\_admin\_cidr\_block) | CIDR block for admin SSH access | `string` | `null` | no |
| <a name="input_allowed_cidr"></a> [allowed\_cidr](#input\_allowed\_cidr) | List of CIDR blocks allowed to access the PMM ALB | `list(string)` | <pre>[<br/>  "0.0.0.0/0"<br/>]</pre> | no |
| <a name="input_backup_retention_days"></a> [backup\_retention\_days](#input\_backup\_retention\_days) | Days to retain EFS backups | `number` | `365` | no |
| <a name="input_backup_schedule"></a> [backup\_schedule](#input\_backup\_schedule) | Cron expression for backup schedule | `string` | `"cron(0 2 * * ? *)"` | no |
| <a name="input_cloudwatch_log_retention_days"></a> [cloudwatch\_log\_retention\_days](#input\_cloudwatch\_log\_retention\_days) | CloudWatch log retention in days | `number` | `365` | no |
| <a name="input_container_cpu"></a> [container\_cpu](#input\_container\_cpu) | CPU units for PMM container | `number` | `512` | no |
| <a name="input_container_memory"></a> [container\_memory](#input\_container\_memory) | Memory (MB) for PMM container | `number` | `4096` | no |
| <a name="input_disable_telemetry"></a> [disable\_telemetry](#input\_disable\_telemetry) | Disable PMM telemetry.<br/>PMM collects anonymous usage data (version, uptime, server count) to help Percona improve the product.<br/>No sensitive data is collected. | `bool` | `true` | no |
| <a name="input_dns_names"></a> [dns\_names](#input\_dns\_names) | DNS names for PMM (will be created in the Route53 zone) | `list(string)` | <pre>[<br/>  "pmm"<br/>]</pre> | no |
| <a name="input_efs_kms_key_id"></a> [efs\_kms\_key\_id](#input\_efs\_kms\_key\_id) | KMS key ID for EFS encryption. If null, uses AWS-managed encryption key. EFS is always encrypted. | `string` | `null` | no |
| <a name="input_efs_performance_mode"></a> [efs\_performance\_mode](#input\_efs\_performance\_mode) | EFS performance mode (generalPurpose or maxIO) | `string` | `"generalPurpose"` | no |
| <a name="input_efs_throughput_mode"></a> [efs\_throughput\_mode](#input\_efs\_throughput\_mode) | EFS throughput mode (bursting or provisioned) | `string` | `"bursting"` | no |
| <a name="input_efs_transition_to_ia"></a> [efs\_transition\_to\_ia](#input\_efs\_transition\_to\_ia) | Days until files are transitioned to Infrequent Access storage class | `string` | `"AFTER_30_DAYS"` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (e.g., production, staging, dev) | `string` | n/a | yes |
| <a name="input_healthcheck_interval"></a> [healthcheck\_interval](#input\_healthcheck\_interval) | Health check interval in seconds | `number` | `30` | no |
| <a name="input_healthcheck_timeout"></a> [healthcheck\_timeout](#input\_healthcheck\_timeout) | Health check timeout in seconds | `number` | `5` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type for ECS | `string` | `"m5.large"` | no |
| <a name="input_pmm_version"></a> [pmm\_version](#input\_pmm\_version) | PMM Docker image version (3 is recommended, PMM 2 EOL July 2025) | `string` | `"3"` | no |
| <a name="input_postgresql_custom_queries_high_resolution"></a> [postgresql\_custom\_queries\_high\_resolution](#input\_postgresql\_custom\_queries\_high\_resolution) | Custom PostgreSQL queries for high-resolution collection (executed every few seconds).<br/>YAML content following PMM custom queries format.<br/>See: https://docs.percona.com/percona-monitoring-and-management/how-to/extend-metrics.html | `string` | `null` | no |
| <a name="input_postgresql_custom_queries_low_resolution"></a> [postgresql\_custom\_queries\_low\_resolution](#input\_postgresql\_custom\_queries\_low\_resolution) | Custom PostgreSQL queries for low-resolution collection (executed every few minutes).<br/>YAML content following PMM custom queries format. | `string` | `null` | no |
| <a name="input_postgresql_custom_queries_medium_resolution"></a> [postgresql\_custom\_queries\_medium\_resolution](#input\_postgresql\_custom\_queries\_medium\_resolution) | Custom PostgreSQL queries for medium-resolution collection (executed every minute).<br/>YAML content following PMM custom queries format. | `string` | `null` | no |
| <a name="input_private_subnet_ids"></a> [private\_subnet\_ids](#input\_private\_subnet\_ids) | Private subnet IDs for ECS tasks and EFS | `list(string)` | n/a | yes |
| <a name="input_public_subnet_ids"></a> [public\_subnet\_ids](#input\_public\_subnet\_ids) | Public subnet IDs for ALB | `list(string)` | n/a | yes |
| <a name="input_rds_security_group_ids"></a> [rds\_security\_group\_ids](#input\_rds\_security\_group\_ids) | Security group IDs of RDS instances to monitor (PMM will be granted access) | `list(string)` | `[]` | no |
| <a name="input_secret_readers"></a> [secret\_readers](#input\_secret\_readers) | IAM role ARNs that can read the PMM admin password secret | `list(string)` | `[]` | no |
| <a name="input_service_name"></a> [service\_name](#input\_service\_name) | Name for the PMM service | `string` | `"pmm-server"` | no |
| <a name="input_ssh_key_name"></a> [ssh\_key\_name](#input\_ssh\_key\_name) | SSH key name for EC2 instances | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all resources | `map(string)` | `{}` | no |
| <a name="input_zone_id"></a> [zone\_id](#input\_zone\_id) | Route53 zone ID for PMM DNS records | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_admin_password_secret_arn"></a> [admin\_password\_secret\_arn](#output\_admin\_password\_secret\_arn) | ARN of the admin password secret in Secrets Manager. Use AWS CLI or Console to retrieve the password. |
| <a name="output_asg_name"></a> [asg\_name](#output\_asg\_name) | Name of the Auto Scaling Group running PMM server |
| <a name="output_pmm_url"></a> [pmm\_url](#output\_pmm\_url) | URL to access PMM server |
<!-- END_TF_DOCS -->

## Monitoring

Access PMM server logs:

```bash
# SSH to PMM EC2 instance
ssh ubuntu@<pmm-instance-ip>

# View PMM container logs
sudo journalctl -u pmm-server -f

# View Docker container logs
sudo docker logs pmm-server --tail 100 -f

# Check container status
sudo docker ps
sudo systemctl status pmm-server
```

## Data Persistence

PMM data is stored on a **persistent EBS data volume** (separate from the EC2 instance root volume) mounted at `/srv`.

**Storage Details:**
- Separate 100GB EBS volume (GP3 by default, configurable)
- Encrypted at rest with KMS
- Contains all PMM databases (ClickHouse, PostgreSQL, Grafana configs)
- Data **persists** across EC2 instance stop/start, replacements, and Docker container restarts
- Automated daily backups via AWS Backup (30-day retention by default)

**Configuration:**
```hcl
module "pmm" {
  # ... other settings ...

  ebs_volume_size         = 100  # GB, adjust based on your metrics retention needs
  ebs_volume_type         = "gp3"
  ebs_iops                = 3000
  backup_retention_days   = 30
}
```

**Backup & Recovery:**
- Daily backups at 5 AM UTC (configurable via `backup_schedule`)
- Optional weekly backups with longer retention
- Point-in-time recovery from any backup
- See [docs/BACKUP_RESTORE.md](./docs/BACKUP_RESTORE.md) for restore procedures

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
