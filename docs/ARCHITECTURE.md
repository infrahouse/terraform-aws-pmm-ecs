# PMM EC2 Architecture

This document describes the architecture of the Percona Monitoring and Management (PMM) deployment on AWS using EC2 with persistent EBS storage.

## Overview

The module deploys PMM on a dedicated EC2 instance with persistent EBS storage, ensuring data persistence across instance lifecycle events. The architecture follows AWS best practices for stateful applications with automated backup and recovery capabilities.

## Components

### 1. Application Load Balancer (ALB)

- **Purpose**: HTTPS endpoint for PMM web interface
- **Location**: Public subnets (multi-AZ)
- **Features**:
  - SSL/TLS termination with ACM certificates (DNS validation)
  - Health checks to `/v1/readyz` endpoint
  - Single target group pointing to EC2 instance
  - Security group allows HTTPS (443) from internet or configured CIDR blocks
  - Access logs stored in S3 (optional, configurable retention)

### 2. EC2 Instance

- **Purpose**: Runs PMM Docker container via systemd
- **Configuration**:
  - **OS**: Ubuntu Pro 24.04 LTS
  - **Instance type**: m5.large (default, configurable)
  - **Subnet**: Single private subnet (first from `private_subnet_ids`)
  - **Auto-recovery**: Enabled by default for hardware failures
  - **Monitoring**: Detailed CloudWatch monitoring enabled
  - **User data**: Cloud-init script that:
    - Installs Docker CE
    - Mounts EBS data volume at `/srv`
    - Starts PMM container via systemd service
    - Installs and configures CloudWatch Agent

**Why single EC2 instance?**
PMM stores metrics data locally, and running multiple instances would cause data inconsistency. The single instance pattern ensures:
- Single source of truth for metrics data
- No split-brain scenarios
- Simplified backup and recovery
- EBS volume can only attach to one instance at a time

**High Availability via Auto-Recovery:**
- EC2 auto-recovery restarts instance on same hardware (preserves EBS attachments)
- CloudWatch alarms trigger automatic recovery on system check failures
- Typical recovery time: 2-5 minutes
- EBS volume remains attached during recovery

### 3. PMM Docker Container

- **Purpose**: Runs all PMM services
- **Configuration**:
  - **Image**: `percona/pmm-server:3` (default, configurable via `pmm_version`)
  - **Management**: systemd service (`pmm-server.service`)
  - **Restart policy**: Always restart on failure
  - **Ports**: 80 and 443 (mapped to container)
  - **Volumes**:
    - `/srv/pmm-data:/srv` - Main PMM data directory
    - Custom query files mounted for PostgreSQL monitoring

**Services inside container:**
- **nginx**: Web server and reverse proxy
- **Grafana**: Dashboards and visualization
- **ClickHouse**: Query Analytics database
- **PostgreSQL**: PMM metadata database
- **Prometheus**: Time-series metrics database
- **VictoriaMetrics**: Alternative TSDB backend

### 4. EBS Data Volume

- **Purpose**: Persistent storage for all PMM data
- **Mount point**: `/srv` on EC2 instance
- **Configuration**:
  - **Size**: 100GB (default, configurable via `ebs_volume_size`)
  - **Type**: GP3 (default, supports gp3/gp2/io1/io2)
  - **IOPS**: 3000 (default for GP3, configurable)
  - **Throughput**: 125 MB/s (default for GP3, configurable)
  - **Encryption**: Always enabled (KMS, AWS-managed or customer-managed key)
  - **Availability Zone**: Same as EC2 instance
  - **Device name**: `/dev/xvdf`
  - **Filesystem**: ext4

**Data stored:**
- ClickHouse databases (Query Analytics)
- PostgreSQL databases (PMM metadata)
- Prometheus/VictoriaMetrics time-series data
- Grafana configurations and dashboards
- User accounts and permissions
- SSL certificates (if custom)

**Lifecycle protection:**
- `prevent_destroy` lifecycle rule prevents accidental deletion
- Independent from EC2 instance lifecycle
- Survives instance stop/start/replacement

### 5. AWS Secrets Manager

- **Purpose**: Secure storage of PMM admin password
- **Features**:
  - Auto-generated 32-character password
  - Encrypted at rest
  - Access via IAM policies
  - Rotation support (manual)

**Access control:**
- EC2 instance IAM role: Read access (required for container startup)
- Custom IAM roles: Read access via `secret_readers` variable
- No write access granted (password is Terraform-managed)

### 6. AWS Backup

- **Purpose**: Daily snapshots of EBS data volume
- **Configuration**:
  - **Schedule**: Daily at 5 AM UTC (default, configurable via `backup_schedule`)
  - **Retention**: 30 days (default, configurable via `backup_retention_days`)
  - **Vault**: Dedicated backup vault per PMM instance
  - **Encryption**: Encrypted backups (KMS, configurable)
  - **Recovery**: Point-in-time restore to new EBS volume
  - **Optional**: Weekly backups with longer retention (90 days default)

**Backup targets:**
- EBS data volume (always backed up)
- Root volume (optional, via `backup_root_volume = true`)

**Backup alarms:**
- Monitors backup job failures
- SNS notifications on backup job failure
- CloudWatch metrics for backup status

### 7. CloudWatch

**CloudWatch Agent:**
- Installed on EC2 instance
- Collects memory and disk usage metrics
- Configuration stored in `/opt/aws/amazon-cloudwatch-agent/etc/`
- Publishes to `CWAgent` namespace

**Logs:**
- SystemD journal logs for PMM service
- Docker container logs
- CloudWatch Agent logs
- Retention: 365 days (default, configurable)
- Log group: `/aws/ec2/<service-name>`

**Alarms:**
1. **Instance Status Checks**: System and instance check failures
2. **Auto-Recovery**: Triggers EC2 recovery on system failures
3. **Memory Usage**: Alert when > 90% utilized
4. **Disk Space - Root**: Alert when root volume > 85% full
5. **Disk Space - Data**: Alert when data volume > 85% full
6. **EBS Burst Balance**: Alert when < 20% (GP3 only)
7. **CPU Usage**: Alert on sustained high CPU
8. **Target Group Health**: HealthyHostCount < 1
9. **Backup Failures**: Alert on backup job failures

**Dashboard** (optional, via `create_dashboard = true`):
- EC2 instance status checks
- CPU and memory utilization
- Disk usage (root and data volumes)
- EBS volume performance metrics
- Network I/O

**Notifications:**
- SNS topic created with email subscriptions
- Additional SNS topics via `alarm_topic_arns`

## Network Architecture

```
Internet
    │
    ├─── Route53 DNS (pmm.example.com)
    │
    └─── Public Subnets (Multi-AZ)
           │
           └─── Application Load Balancer (HTTPS:443)
                  │
                  └─── Private Subnet (Single AZ)
                         │
                         ├─── EC2 Instance (m5.large)
                         │      │
                         │      ├─── Docker: PMM Container (pmm-server:3)
                         │      │    ├─── nginx (80/443)
                         │      │    ├─── Grafana
                         │      │    ├─── ClickHouse
                         │      │    ├─── PostgreSQL
                         │      │    └─── Prometheus/VictoriaMetrics
                         │      │
                         │      ├─── CloudWatch Agent
                         │      └─── EBS Data Volume (/srv, 100GB GP3)
                         │
                         └─── RDS Instances (Optional Monitoring)
                               └─── PostgreSQL/MySQL databases
```

## Security Architecture

### Network Security

1. **ALB Security Group**:
   - Inbound: HTTPS (443) from configured CIDR blocks (default: 0.0.0.0/0)
   - Outbound: HTTP (80) to EC2 instance security group

2. **EC2 Instance Security Group**:
   - Inbound: HTTP (80) from ALB security group
   - Inbound (optional): SSH (22) from admin CIDR block (if `admin_cidr_block` configured)
   - Outbound: All traffic (for Docker image pull, metrics collection, AWS API calls)

3. **RDS Access** (when configured):
   - Inbound rule added to RDS security group(s)
   - Source: EC2 instance security group
   - Port: 5432 (PostgreSQL) or 3306 (MySQL)
   - Automatically configured via `rds_security_group_ids` variable

### IAM Security

**EC2 Instance IAM Role**:
- **Secrets Manager**: GetSecretValue for admin password
- **CloudWatch Logs**: CreateLogGroup, CreateLogStream, PutLogEvents
- **CloudWatch**: PutMetricData (for CloudWatch Agent metrics)
- **SSM**: GetParameter, DescribeParameters (for CloudWatch Agent config)
- **EC2**: DescribeVolumes, DescribeTags (for EBS volume identification)

**AWS Backup Service Role**:
- AWS-managed policy: `AWSBackupServiceRolePolicyForBackup`
- AWS-managed policy: `AWSBackupServiceRolePolicyForRestores`
- Permissions to create/delete EBS snapshots
- Permissions to tag backup recovery points

## Data Flow

### Metrics Collection

1. **PMM Clients** → PMM Server (HTTP/HTTPS, Push or Pull)
2. **PMM Server** → Prometheus/VictoriaMetrics (Internal)
3. **Prometheus** → EBS Volume (`/srv/prometheus` or `/srv/victoriametrics`)
4. **Query Analytics** → EBS Volume (`/srv/clickhouse`)
5. **Grafana Dashboards** → EBS Volume (`/srv/grafana`)

### User Access

1. User → `https://pmm.example.com` (HTTPS request)
2. Route53 → Resolves DNS to ALB
3. ALB → SSL termination, forwards HTTP to EC2 instance on port 80
4. EC2 Instance → PMM Docker container (nginx on port 80)
5. PMM Container → Grafana/Prometheus (data retrieval from `/srv`)

### Backup Flow

1. AWS Backup → Daily schedule trigger (5 AM UTC)
2. Backup job → Create EBS snapshot
3. Snapshot → Encrypt and store in backup vault
4. Retention policy → Delete after configured retention period (30 days default)

## Scalability Considerations

### Vertical Scaling

The module supports vertical scaling through the `instance_type` variable:
- **CPU/Memory**: m5.large → m5.xlarge → m5.2xlarge
- **Compute Optimized**: c5.large → c5.xlarge (for high query load)
- **Memory Optimized**: r5.large → r5.xlarge (for large datasets)

**Recommended scaling triggers**:
- Monitoring 20+ database instances
- Storing 90+ days of high-resolution metrics
- 10+ concurrent users accessing dashboards
- High query analytics load

**Note**: Changing instance type requires instance replacement (brief downtime), but data persists on EBS volume.

### Horizontal Scaling

**Not supported** due to PMM architecture:
- PMM does not support multi-node deployment
- Data is stored locally on EBS, not in distributed system
- Running multiple instances would cause data inconsistency
- EBS volumes can only attach to one instance at a time

### Storage Scaling

**EBS volume can be resized online** (no downtime):

```hcl
module "pmm" {
  # ... other settings ...
  ebs_volume_size = 200  # Increase from 100GB to 200GB
}
```

After Terraform apply:
1. EBS volume is resized automatically
2. SSH to instance and extend filesystem:
   ```bash
   sudo resize2fs /dev/xvdf
   ```
3. No instance restart required

**Capacity planning**:
- ~1GB per monitored database per day (varies by workload)
- 100GB supports ~10 databases with 10-day retention
- 200GB supports ~20 databases with 10-day retention
- Monitor disk usage via CloudWatch alarm

## High Availability

While PMM runs on a single EC2 instance, the architecture provides HA through:

1. **EC2 Auto-Recovery**: Automatic instance recovery on hardware failures (2-5 min RTO)
2. **ALB Multi-AZ**: Load balancer spans multiple availability zones
3. **EBS Persistence**: Data survives instance stop/start/replacement
4. **Daily Backups**: Point-in-time recovery from EBS snapshots
5. **CloudWatch Alarms**: Immediate notification of failures

**Failure Scenarios**:

| Failure Type | Recovery Method | RTO | Data Loss |
|-------------|-----------------|-----|-----------|
| Hardware failure | EC2 auto-recovery | 2-5 min | None |
| Instance crash | Manual instance restart | 5 min | None |
| AZ failure | Manual: restore from backup in new AZ | 30 min | None (from last backup) |
| EBS volume failure | Restore from snapshot | 30 min | Last backup interval |
| Region failure | Manual: deploy in new region | Hours | Last backup interval |

**Recovery Time Objective (RTO)**: 2-5 minutes (auto-recovery), 30 minutes (manual restore)
**Recovery Point Objective (RPO)**: Daily backup interval (up to 24 hours of data loss)

**Improving HA**:
- Reduce RPO: Increase backup frequency (e.g., every 6 hours)
- Cross-region: Replicate snapshots to another region
- Multi-AZ standby: Keep standby instance in another AZ (requires manual failover)

## Monitoring the Monitor

The PMM deployment itself is monitored via CloudWatch:

1. **Instance health**: System and instance status checks (auto-recovery enabled)
2. **Storage health**: EBS burst balance, disk space usage (root and data volumes)
3. **Application health**: ALB target health, HTTP 5XX errors
4. **Backup health**: AWS Backup job success/failure notifications
5. **Resource usage**: CPU, memory, network I/O, disk I/O

**CloudWatch Dashboard** (optional, via `create_dashboard = true`):
- Real-time visualization of all metrics
- Custom views for instance, storage, and application health
- Accessible via AWS Console

**Alarm Destinations**:
- Email notifications (required, via `alarm_emails`)
- Custom SNS topics (optional, via `alarm_topic_arns`)
- Integration with PagerDuty, Slack, etc. via SNS

## Cost Optimization

**Fixed costs** (us-east-1 pricing):
- EC2 instance: ~$70/month (m5.large, on-demand)
- ALB: ~$23/month (includes LCU charges for typical load)

**Variable costs**:
- EBS GP3 storage: ~$0.08/GB/month (100GB = $8/month)
- EBS snapshots: ~$0.05/GB/month (incremental, ~$5/month for 100GB)
- CloudWatch logs: ~$0.50/GB ingested (typically <$5/month)
- Data transfer: Minimal (within VPC, free)

**Typical monthly cost** (monitoring 10 databases):
- Compute (m5.large): $70
- ALB: $23
- EBS storage (100GB): $8
- EBS snapshots: $5
- CloudWatch: $5
- **Total**: ~$111/month

**Cost optimization strategies**:
1. **Reserved Instances**: Save 30-40% on EC2 (1-year commitment)
   - m5.large RI: ~$42/month (saves ~$28/month)
2. **Savings Plans**: Flexible alternative to RIs
3. **Adjust backup retention**: 30 days default, reduce to 7 days (saves ~$3/month)
4. **Right-size instance**: Use t3.large if CPU usage consistently <20% (saves ~$40/month)
5. **Scheduled stop/start**: For dev/test environments (not for production)

**Total optimized cost** (1-year commitment):
- RI compute: $42
- ALB: $23
- Storage: $8
- Snapshots (7 days): $2
- CloudWatch: $5
- **Total**: ~$80/month (28% savings)

## Disaster Recovery

### Backup Strategy

**Automated Daily Backups**:
- Schedule: 5 AM UTC (configurable via `backup_schedule`)
- Target: EBS data volume
- Retention: 30 days (configurable via `backup_retention_days`)
- Encryption: KMS-encrypted snapshots
- Monitoring: CloudWatch alarms for backup failures

**Optional Weekly Backups** (long-term retention):
```hcl
module "pmm" {
  # ... other settings ...
  enable_weekly_backup           = true
  weekly_backup_retention_days   = 90  # Keep weekly backups for 90 days
}
```

**Backup Verification**:
- AWS Backup automatically validates snapshot integrity
- Test restores quarterly to verify backup procedures

**Manual On-Demand Backups**:
```bash
# Create manual snapshot via AWS CLI
aws ec2 create-snapshot \
  --volume-id vol-xxxxxxxxx \
  --description "PMM manual backup before upgrade" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=pmm-manual-backup}]'
```

### Recovery Procedures

**Scenario 1: Instance Failure (Auto-Recovery)**
- Automatic recovery triggered by CloudWatch alarm
- Instance restarts on same hardware
- EBS volume remains attached
- No manual intervention required
- RTO: 2-5 minutes

**Scenario 2: EBS Volume Corruption**
1. Identify latest healthy snapshot in AWS Backup console
2. Create new EBS volume from snapshot
3. Stop PMM instance
4. Detach corrupted volume, attach new volume as `/dev/xvdf`
5. Start PMM instance
6. Verify data integrity in PMM UI

**Scenario 3: Complete AZ Failure**
1. Create new EBS volume from snapshot in different AZ
2. Update Terraform configuration to use new subnet/AZ
3. Apply Terraform (creates new instance in new AZ with restored volume)
4. Update DNS if using hardcoded IPs (ALB handles automatically)

**Scenario 4: Accidental Data Deletion**
1. Stop PMM container: `sudo systemctl stop pmm-server`
2. Create snapshot from latest backup
3. Mount snapshot as secondary volume
4. Copy specific data back to live volume
5. Restart PMM: `sudo systemctl start pmm-server`

**Detailed procedures**: See [BACKUP_RESTORE.md](./BACKUP_RESTORE.md)

### Testing DR Procedures

**Quarterly DR Test**:
1. Create test environment in separate VPC
2. Restore from production backup
3. Verify all dashboards and data accessible
4. Document test results and lessons learned
5. Destroy test environment

**RTO/RPO Validation**:
- Measure actual recovery time vs. target (5 min auto-recovery, 30 min manual)
- Verify data loss window matches RPO (daily backups = up to 24h data loss)

## Future Enhancements

Potential improvements to consider:

1. **Multi-region deployment**: For global monitoring
2. **Read replicas**: PMM 3.x may support in future
3. **S3 backup export**: For long-term archive
4. **Automated password rotation**: Using Secrets Manager
5. **WAF integration**: Additional security for ALB
6. **Custom CloudWatch dashboards**: Pre-built monitoring views