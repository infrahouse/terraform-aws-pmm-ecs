# PMM Backup and Restore Procedures

This document provides detailed procedures for backing up and restoring PMM data using AWS Backup and EBS snapshots.

## Overview

The PMM module uses AWS Backup to create automated daily snapshots of the EBS data volume. This ensures that all PMM data (metrics, dashboards, configurations) can be restored in case of:
- Accidental data deletion
- EBS volume corruption or failure
- Availability zone failure
- Need to migrate to different infrastructure

## Backup Architecture

### Automated Backups

**Daily Backups**:
- Schedule: 5 AM UTC by default (configurable via `backup_schedule`)
- Target: EBS data volume (`/srv` mount point)
- Retention: 30 days by default (configurable via `backup_retention_days`)
- Encryption: KMS-encrypted snapshots
- Monitoring: CloudWatch alarms for backup job failures

**Weekly Backups** (optional):
- Enable with `enable_weekly_backup = true`
- Retention: 90 days by default (configurable via `weekly_backup_retention_days`)
- Useful for long-term data retention and compliance

### What is Backed Up

The EBS data volume (`/srv`) contains:
- **ClickHouse**: Query Analytics database
- **PostgreSQL**: PMM metadata and configuration
- **Prometheus/VictoriaMetrics**: Time-series metrics data
- **Grafana**: Dashboard definitions and user preferences
- **User data**: PMM user accounts and permissions

### What is NOT Backed Up

- Root volume (OS and Docker): Can be recreated via Terraform
- Running state: Container must restart after restore
- Network configuration: Managed by Terraform

## Backup Monitoring

### CloudWatch Alarms

If `enable_backup_alarms = true` (default), you'll receive SNS notifications for:
- Backup job failures
- Backup vault access issues
- Missing backups (if schedule didn't run)

### Checking Backup Status

**Via AWS Console**:
1. Navigate to AWS Backup → Backup vaults
2. Select your PMM backup vault (e.g., `pmm-server-backup-vault`)
3. View "Recovery points" tab for all available backups
4. Check "Jobs" tab for recent backup job status

**Via AWS CLI**:
```bash
# List all recovery points in the backup vault
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name pmm-server-backup-vault \
  --output table

# Get latest backup status
aws backup list-backup-jobs \
  --by-backup-vault-name pmm-server-backup-vault \
  --max-results 5
```

## Creating Manual Backups

### On-Demand Backup via AWS Backup

Create a manual backup before major changes (PMM upgrades, configuration changes):

```bash
# Get the EBS volume ID
VOLUME_ID=$(aws ec2 describe-volumes \
  --filters "Name=tag:Name,Values=pmm-server-data" \
  --query "Volumes[0].VolumeId" \
  --output text)

# Create on-demand backup
aws backup start-backup-job \
  --backup-vault-name pmm-server-backup-vault \
  --resource-arn arn:aws:ec2:us-east-1:123456789012:volume/$VOLUME_ID \
  --iam-role-arn arn:aws:iam::123456789012:role/aws-backup-service-role \
  --idempotency-token $(uuidgen)
```

### Quick EBS Snapshot

For immediate pre-upgrade snapshots:

```bash
# Create manual snapshot
aws ec2 create-snapshot \
  --volume-id $VOLUME_ID \
  --description "PMM manual backup before upgrade to v3.1" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=pmm-manual-backup},{Key=Purpose,Value=pre-upgrade}]'

# Monitor snapshot creation
aws ec2 describe-snapshots \
  --filters "Name=volume-id,Values=$VOLUME_ID" \
  --query "Snapshots[0].[State,Progress]" \
  --output text
```

## Restore Procedures

### Prerequisites

Before starting any restore:
1. Identify the recovery point to restore from (date/time)
2. Ensure you have necessary IAM permissions
3. Have Terraform configuration available
4. Notify users of potential downtime

### Scenario 1: Restore to Same Instance (Data Corruption)

Use this when the PMM instance is running but data is corrupted.

**Steps**:

1. **Identify the recovery point**:
   ```bash
   aws backup list-recovery-points-by-backup-vault \
     --backup-vault-name pmm-server-backup-vault \
     --output table

   # Note the RecoveryPointArn for your chosen backup
   ```

2. **Stop the PMM service** (to prevent data inconsistency):
   ```bash
   ssh ubuntu@<pmm-instance-ip>
   sudo systemctl stop pmm-server
   ```

3. **Create new volume from recovery point**:
   ```bash
   # Via AWS Console:
   # AWS Backup → Backup vaults → Select vault → Recovery points
   # → Select recovery point → Restore
   # → Choose "Create new volume" → Select AZ matching your instance

   # Via AWS CLI:
   aws backup start-restore-job \
     --recovery-point-arn <RecoveryPointArn> \
     --metadata '{"AvailabilityZone":"us-east-1a"}' \
     --iam-role-arn arn:aws:iam::123456789012:role/aws-backup-service-role \
     --resource-type EBS

   # Monitor restore job
   aws backup describe-restore-job --restore-job-id <job-id>
   ```

4. **Attach restored volume to instance**:
   ```bash
   # Detach old volume (IMPORTANT: Note volume ID for potential rollback)
   OLD_VOLUME_ID=$(aws ec2 describe-volumes \
     --filters "Name=attachment.instance-id,Values=<instance-id>" \
               "Name=attachment.device,Values=/dev/xvdf" \
     --query "Volumes[0].VolumeId" \
     --output text)

   aws ec2 detach-volume --volume-id $OLD_VOLUME_ID

   # Wait for detachment
   aws ec2 wait volume-available --volume-ids $OLD_VOLUME_ID

   # Attach restored volume
   NEW_VOLUME_ID=<restored-volume-id>
   aws ec2 attach-volume \
     --volume-id $NEW_VOLUME_ID \
     --instance-id <instance-id> \
     --device /dev/xvdf

   # Wait for attachment
   aws ec2 wait volume-in-use --volume-ids $NEW_VOLUME_ID
   ```

5. **Restart PMM service**:
   ```bash
   ssh ubuntu@<pmm-instance-ip>

   # Verify volume is mounted
   df -h | grep /srv

   # Start PMM
   sudo systemctl start pmm-server

   # Check status
   sudo systemctl status pmm-server
   sudo docker logs pmm-server --tail 100
   ```

6. **Verify data integrity**:
   - Access PMM UI: `https://pmm.example.com`
   - Check dashboards are accessible
   - Verify recent metrics data (up to last backup time)
   - Test database connections

7. **Clean up old volume** (after verification):
   ```bash
   # Create snapshot of old volume for safety
   aws ec2 create-snapshot \
     --volume-id $OLD_VOLUME_ID \
     --description "Old PMM volume before restore"

   # Delete old volume (after 7 days if all is well)
   aws ec2 delete-volume --volume-id $OLD_VOLUME_ID
   ```

### Scenario 2: Restore to New Instance (AZ Failure or Complete Rebuild)

Use this when the entire instance needs to be replaced (AZ failure, instance corruption).

**Steps**:

1. **Create new EBS volume from backup** (in target AZ):
   ```bash
   # Choose recovery point
   aws backup list-recovery-points-by-backup-vault \
     --backup-vault-name pmm-server-backup-vault

   # Restore to new volume in desired AZ
   aws backup start-restore-job \
     --recovery-point-arn <RecoveryPointArn> \
     --metadata '{"AvailabilityZone":"us-east-1b"}' \
     --iam-role-arn arn:aws:iam::123456789012:role/aws-backup-service-role \
     --resource-type EBS
   ```

2. **Update Terraform configuration** (if changing AZ):
   ```hcl
   module "pmm" {
     # ... other settings ...

     # Use subnet in the new AZ (us-east-1b)
     private_subnet_ids = ["subnet-new-az"]
   }
   ```

3. **Import existing EBS volume** into Terraform state:
   ```bash
   # Import the restored volume
   terraform import module.pmm.aws_ebs_volume.pmm_data <restored-volume-id>
   ```

4. **Apply Terraform**:
   ```bash
   terraform plan  # Review changes
   terraform apply # Creates new instance and attaches restored volume
   ```

5. **Verify deployment**:
   - Check EC2 instance is running
   - Verify EBS volume is attached at `/dev/xvdf`
   - Access PMM UI and verify data
   - Check ALB target health

### Scenario 3: Point-in-Time Recovery (Restore Specific Data)

Use this when you need to recover specific data without full restore.

**Steps**:

1. **Create temporary volume from backup**:
   ```bash
   aws backup start-restore-job \
     --recovery-point-arn <RecoveryPointArn> \
     --metadata '{"AvailabilityZone":"us-east-1a"}' \
     --iam-role-arn arn:aws:iam::123456789012:role/aws-backup-service-role
   ```

2. **Launch temporary EC2 instance** (for mounting):
   ```bash
   # Launch Ubuntu instance in same AZ
   aws ec2 run-instances \
     --image-id ami-xxxxxxxxx \
     --instance-type t3.micro \
     --subnet-id <subnet-id> \
     --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=pmm-recovery-temp}]'
   ```

3. **Attach restored volume** to temporary instance:
   ```bash
   aws ec2 attach-volume \
     --volume-id <restored-volume-id> \
     --instance-id <temp-instance-id> \
     --device /dev/xvdf
   ```

4. **Mount volume and extract data**:
   ```bash
   ssh ubuntu@<temp-instance-ip>

   # Mount volume
   sudo mkdir /mnt/pmm-backup
   sudo mount /dev/xvdf /mnt/pmm-backup

   # Extract specific data (example: Grafana dashboards)
   sudo tar czf grafana-dashboards-backup.tar.gz \
     /mnt/pmm-backup/grafana/

   # Copy to S3 or local
   aws s3 cp grafana-dashboards-backup.tar.gz s3://my-bucket/
   ```

5. **Restore to production PMM instance**:
   ```bash
   # On production PMM instance
   ssh ubuntu@<pmm-instance-ip>

   # Download extracted data
   aws s3 cp s3://my-bucket/grafana-dashboards-backup.tar.gz .

   # Stop PMM
   sudo systemctl stop pmm-server

   # Restore specific data
   sudo tar xzf grafana-dashboards-backup.tar.gz -C /srv/

   # Fix permissions
   sudo chown -R root:root /srv/grafana

   # Start PMM
   sudo systemctl start pmm-server
   ```

6. **Clean up temporary resources**:
   ```bash
   # Detach and delete temporary volume
   aws ec2 detach-volume --volume-id <restored-volume-id>
   aws ec2 delete-volume --volume-id <restored-volume-id>

   # Terminate temporary instance
   aws ec2 terminate-instances --instance-ids <temp-instance-id>
   ```

### Scenario 4: Cross-Region DR (Disaster Recovery)

Use this for regional disasters or compliance requirements.

**Prerequisites**:
- Enable cross-region copy in AWS Backup plan (not currently in module, manual setup required)
- Or manually copy snapshots to DR region

**Steps**:

1. **Copy snapshot to DR region** (if not automated):
   ```bash
   # Find latest snapshot
   SNAPSHOT_ID=$(aws ec2 describe-snapshots \
     --owner-ids self \
     --filters "Name=tag:Name,Values=pmm-server-data" \
     --query "Snapshots | sort_by(@, &StartTime)[-1].SnapshotId" \
     --output text)

   # Copy to DR region
   aws ec2 copy-snapshot \
     --source-region us-east-1 \
     --source-snapshot-id $SNAPSHOT_ID \
     --destination-region us-west-2 \
     --description "PMM DR copy"
   ```

2. **Deploy PMM in DR region** using Terraform:
   ```hcl
   # In DR region configuration
   provider "aws" {
     region = "us-west-2"
   }

   module "pmm_dr" {
     source = "infrahouse/pmm-ecs/aws"

     # Use DR VPC and subnets
     public_subnet_ids  = ["subnet-dr-public"]
     private_subnet_ids = ["subnet-dr-private"]

     # Rest of configuration...
   }
   ```

3. **Create EBS volume from copied snapshot**:
   ```bash
   # In DR region
   aws ec2 create-volume \
     --region us-west-2 \
     --availability-zone us-west-2a \
     --snapshot-id <copied-snapshot-id> \
     --volume-type gp3 \
     --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=pmm-server-data-dr}]'
   ```

4. **Import and attach to DR instance** (follow Scenario 2 steps)

## Backup Retention and Lifecycle

### Default Retention Policy

- **Daily backups**: 30 days
- **Weekly backups**: 90 days (if enabled)
- **Manual snapshots**: No automatic deletion (manage manually)

### Modifying Retention

**Update module configuration**:
```hcl
module "pmm" {
  # ... other settings ...

  backup_retention_days         = 7    # Shorter retention (cost savings)
  enable_weekly_backup          = true
  weekly_backup_retention_days  = 180  # Longer weekly retention
}
```

**Apply changes**:
```bash
terraform apply
```

### Managing Old Snapshots

**List all snapshots**:
```bash
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Name,Values=pmm-*" \
  --query "Snapshots[*].[SnapshotId,StartTime,VolumeSize,Description]" \
  --output table
```

**Delete old manual snapshots**:
```bash
# Delete specific snapshot
aws ec2 delete-snapshot --snapshot-id snap-xxxxxxxxx

# Batch delete snapshots older than 90 days
# (Use with caution - validate before running)
aws ec2 describe-snapshots \
  --owner-ids self \
  --filters "Name=tag:Name,Values=pmm-manual-*" \
  --query "Snapshots[?StartTime<'2024-09-01'].[SnapshotId]" \
  --output text | \
  xargs -n 1 aws ec2 delete-snapshot --snapshot-id
```

## Testing Backup and Restore

### Quarterly DR Test

Perform quarterly tests to validate backup and restore procedures:

1. **Create test environment**:
   ```hcl
   # test/terraform.tfvars
   module "pmm_test" {
     source = "infrahouse/pmm-ecs/aws"

     environment        = "dr-test"
     service_name       = "pmm-server-test"
     # Use isolated VPC/subnets
   }
   ```

2. **Restore from production backup**:
   - Follow Scenario 2 procedure
   - Use latest production backup
   - Deploy to test environment

3. **Validation checklist**:
   - [ ] PMM UI accessible
   - [ ] All dashboards load correctly
   - [ ] Metrics data is queryable
   - [ ] Database connections work
   - [ ] User accounts are intact
   - [ ] Custom configurations preserved

4. **Measure RTO/RPO**:
   - Record time from restore start to PMM accessible (RTO)
   - Check data timestamp vs. backup time (RPO)
   - Document any issues encountered

5. **Clean up test environment**:
   ```bash
   terraform destroy
   ```

### Automated Backup Validation

Monitor backup job success via CloudWatch:

```bash
# Check backup job metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Backup \
  --metric-name NumberOfBackupJobsCompleted \
  --dimensions Name=ResourceType,Value=EBS \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-31T23:59:59Z \
  --period 86400 \
  --statistics Sum
```

## Troubleshooting

### Backup Job Failures

**Check backup job logs**:
```bash
aws backup describe-backup-job --backup-job-id <job-id>
```

**Common issues**:
- **IAM permissions**: Ensure backup role has correct permissions
- **Vault access**: Check backup vault is accessible
- **Resource tags**: Verify EBS volume has correct tags for selection
- **KMS key**: Ensure KMS key allows backup service access

### Restore Failures

**Common issues**:
- **Wrong AZ**: Ensure restored volume is in same AZ as target instance
- **Volume busy**: Detach old volume before attaching restored volume
- **Filesystem corruption**: May need to run `fsck` on restored volume
- **Insufficient space**: Ensure instance has enough space for restored data

**Check restore job status**:
```bash
aws backup describe-restore-job --restore-job-id <job-id>
```

### Data Integrity Issues After Restore

**Check filesystem**:
```bash
# On PMM instance
sudo systemctl stop pmm-server
sudo umount /srv
sudo fsck -y /dev/xvdf
sudo mount /dev/xvdf /srv
```

**Verify ClickHouse data**:
```bash
# Check ClickHouse tables
docker exec pmm-server clickhouse-client --query "SHOW DATABASES"
docker exec pmm-server clickhouse-client --query "SELECT count() FROM pmm.metrics"
```

**Verify PostgreSQL**:
```bash
# Check PostgreSQL tables
docker exec pmm-server psql -U postgres -c "\l"
docker exec pmm-server psql -U postgres pmm -c "\dt"
```

## Best Practices

1. **Test restores regularly**: Quarterly DR tests validate your backup strategy
2. **Monitor backup jobs**: Enable CloudWatch alarms for backup failures
3. **Manual backups before changes**: Create snapshots before PMM upgrades
4. **Document procedures**: Keep this document updated with your specific setup
5. **Retain backups appropriately**: Balance cost vs. recovery needs
6. **Cross-region copies**: For critical deployments, replicate to DR region
7. **Tag snapshots clearly**: Use descriptive tags for manual snapshots
8. **Verify after restore**: Always validate data integrity after restore

## Cost Considerations

**EBS Snapshot Costs**:
- First snapshot: Full volume size (~$0.05/GB/month)
- Incremental snapshots: Only changed blocks
- Example: 100GB volume with daily backups, 30-day retention ≈ $5-10/month

**AWS Backup Costs**:
- Backup storage: $0.05/GB/month (warm storage)
- Restore: $0.02/GB (data transfer)
- Cross-region copy: Additional $0.05/GB/month in destination region

**Cost optimization**:
- Reduce retention period if acceptable
- Delete old manual snapshots
- Use lifecycle policies for long-term backups (move to cold storage)

## References

- [AWS Backup Documentation](https://docs.aws.amazon.com/aws-backup/)
- [EBS Snapshots Documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EBSSnapshots.html)
- [PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture overview
- [RUNBOOK.md](./RUNBOOK.md) - Operational procedures