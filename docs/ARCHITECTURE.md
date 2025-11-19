# PMM ECS Architecture

This document describes the architecture of the Percona Monitoring and Management (PMM) deployment on AWS ECS.

## Overview

The module deploys PMM as a singleton service on Amazon ECS, ensuring data consistency while providing high availability through AWS managed services. The architecture follows AWS best practices for containerized applications.

## Components

### 1. Application Load Balancer (ALB)

- **Purpose**: HTTPS endpoint for PMM web interface
- **Location**: Public subnets
- **Features**:
  - SSL/TLS termination with ACM certificates
  - Health checks to `/v1/readyz` endpoint
  - Single target group pointing to ECS service
  - Security group allows HTTPS (443) from internet

### 2. ECS Cluster and Service

- **Purpose**: Runs PMM container
- **Configuration**:
  - **Task count**: Exactly 1 (min=1, desired=1, max=1)
  - **Deployment strategy**: Rolling update with minimum healthy percent
  - **Container**:
    - Image: `percona/pmm-server:3` (or specified version)
    - Port: 443 (HTTPS)
    - CPU: 2048 units (2 vCPU) by default
    - Memory: 4096 MB (4 GB) by default
  - **EC2 backing**: m5.large instances (or specified type)
  - **Auto Scaling Group**: 1-1 instances for cost efficiency

**Why singleton?**
PMM stores metrics data locally, and running multiple instances would cause data inconsistency. The singleton pattern ensures:
- Single source of truth for metrics data
- No split-brain scenarios
- Simplified backup and recovery

### 3. Elastic File System (EFS)

- **Purpose**: Persistent storage for PMM data
- **Mount point**: `/srv` in container
- **Features**:
  - Always encrypted (AWS-managed or customer-managed KMS key)
  - Mount targets in all private subnets for high availability
  - Performance mode: General Purpose (default) or Max I/O
  - Throughput mode: Bursting (default) or Provisioned
  - Lifecycle policy: Transition to Infrequent Access after 30 days

**Data stored**:
- Prometheus time-series data
- Query Analytics data
- PMM configuration and settings
- User accounts and permissions

### 4. AWS Secrets Manager

- **Purpose**: Secure storage of PMM admin password
- **Features**:
  - Auto-generated 32-character password
  - Encrypted at rest
  - Access via IAM policies
  - Rotation support (manual)

**Access control**:
- ECS task role: Read access (required for container startup)
- Custom IAM roles: Read access via `secret_readers` variable
- No write access granted (password is Terraform-managed)

### 5. AWS Backup

- **Purpose**: Daily backups of EFS data
- **Configuration**:
  - Schedule: Daily at 2 AM UTC
  - Retention: 365 days (default, configurable)
  - Vault: Dedicated backup vault per PMM instance
  - Recovery: Point-in-time restore to new or existing EFS

### 6. CloudWatch

**Logs**:
- ECS container logs
- Retention: 365 days (default, configurable)
- Log group: `/aws/ecs/<service-name>`

**Alarms**:
1. **ECS Service Health**: RunningTaskCount < 1
2. **Target Group Health**: HealthyHostCount < 1
3. **EFS Burst Credits**: BurstCreditBalance < 1TB (bursting mode only)
4. **ALB 5XX Errors**: HTTPCode_Target_5XX_Count > 10

**Notifications**: SNS topics with email subscriptions

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
                  └─── Private Subnets (Multi-AZ)
                         │
                         ├─── ECS Service (Singleton)
                         │      │
                         │      ├─── Container (pmm-server:3)
                         │      └─── Auto Scaling Group (1 instance)
                         │
                         ├─── EFS Mount Targets (All AZs)
                         │      └─── EFS File System (Encrypted)
                         │
                         └─── RDS Instances (Optional Monitoring)
```

## Security Architecture

### Network Security

1. **ALB Security Group**:
   - Inbound: HTTPS (443) from 0.0.0.0/0
   - Outbound: All traffic to ECS security group

2. **ECS Security Group**:
   - Inbound: 443 from ALB security group
   - Outbound: All traffic (for pulling metrics from monitored systems)

3. **EFS Security Group**:
   - Inbound: NFS (2049) from ECS security group
   - Outbound: None required

4. **RDS Access** (when configured):
   - Inbound rule added to RDS security group
   - Source: ECS security group
   - Port: 5432 (PostgreSQL) or as configured

### IAM Security

**ECS Task Execution Role**:
- CloudWatch Logs: CreateLogGroup, CreateLogStream, PutLogEvents
- Secrets Manager: GetSecretValue (admin password only)
- ECR: Pull PMM container image

**ECS Task Role**:
- Currently minimal (can be extended for AWS service monitoring)

**Backup Role**:
- AWS Backup service role
- Permissions to backup and restore EFS

## Data Flow

### Metrics Collection

1. **PMM Clients** → PMM Server (Push or Pull)
2. **PMM Server** → Prometheus (Internal)
3. **Prometheus** → EFS (`/srv/prometheus`)
4. **Query Analytics** → EFS (`/srv/clickhouse`)

### User Access

1. User → `https://pmm.example.com`
2. Route53 → ALB
3. ALB → ECS Service
4. ECS Service → PMM Container
5. PMM Container → EFS (data retrieval)

### Backup Flow

1. AWS Backup → Daily schedule trigger (2 AM UTC)
2. Backup job → Snapshot EFS file system
3. Snapshot → Backup vault
4. Retention policy → Delete after 365 days

## Scalability Considerations

### Vertical Scaling

The module supports vertical scaling through:
- `instance_type`: Larger EC2 instances (m5.large → m5.xlarge, etc.)
- `container_cpu`: More CPU units
- `container_memory`: More memory

**Recommended for**:
- Monitoring more database instances
- Longer metrics retention periods
- More concurrent users

### Horizontal Scaling

**Not supported** due to PMM architecture:
- PMM does not support multi-node deployment
- Data is stored locally, not in distributed system
- Running multiple instances causes data inconsistency

### Storage Scaling

EFS automatically scales:
- No provisioning required
- Pay for what you use
- Throughput scales with storage size (bursting mode)

## High Availability

While PMM runs as a singleton, the architecture provides HA through:

1. **EFS Multi-AZ**: Mount targets in all availability zones
2. **ALB Multi-AZ**: Deployed across all public subnets
3. **Auto Scaling Group**: Automatically replaces failed instances
4. **Daily Backups**: Restore from backup if disaster occurs

**Recovery Time Objective (RTO)**: ~15 minutes (ECS task restart)
**Recovery Point Objective (RPO)**: 24 hours (daily backups)

## Monitoring the Monitor

The PMM deployment itself is monitored via CloudWatch:

1. **Service health**: ECS task count and ALB target health
2. **Storage health**: EFS burst credits and IOPs
3. **Application health**: ALB 5XX errors and response times
4. **Backup health**: AWS Backup job success/failure

## Cost Optimization

**Fixed costs**:
- ECS EC2 instance: ~$70/month (m5.large, on-demand)
- ALB: ~$23/month

**Variable costs**:
- EFS storage: ~$0.30/GB/month
- EFS backups: ~$0.05/GB/month (warm storage)
- CloudWatch logs: ~$0.50/GB ingested
- Data transfer: Minimal (within VPC)

**Typical monthly cost** (monitoring 10 databases):
- Compute: $70
- ALB: $23
- EFS (40GB): $12
- Backups: $2
- **Total**: ~$107/month

**Cost optimization tips**:
- Use Reserved Instances for EC2 (save 30-40%)
- Transition EFS data to IA storage class
- Adjust backup retention to needs (default 365 days)
- Use cold storage for old backups

## Disaster Recovery

### Backup Strategy

**Automated**:
- Daily EFS snapshots at 2 AM UTC
- 365-day retention
- Stored in AWS Backup vault

**Manual**:
- Use `scripts/backup-efs.sh` for on-demand backups
- Export important dashboards and configurations

### Recovery Procedures

See [TROUBLESHOOTING.md](./TROUBLESHOOTING.md) for detailed recovery procedures.

## Future Enhancements

Potential improvements to consider:

1. **Multi-region deployment**: For global monitoring
2. **Read replicas**: PMM 3.x may support in future
3. **S3 backup export**: For long-term archive
4. **Automated password rotation**: Using Secrets Manager
5. **WAF integration**: Additional security for ALB
6. **Custom CloudWatch dashboards**: Pre-built monitoring views