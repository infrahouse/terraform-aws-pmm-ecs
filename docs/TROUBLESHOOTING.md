# PMM ECS Troubleshooting Guide

This guide covers common issues and their solutions when deploying and operating PMM on AWS ECS.

## Table of Contents

- [Deployment Issues](#deployment-issues)
- [Access Issues](#access-issues)
- [Performance Issues](#performance-issues)
- [Storage Issues](#storage-issues)
- [Monitoring Issues](#monitoring-issues)
- [Recovery Procedures](#recovery-procedures)

## Deployment Issues

### Terraform Apply Fails

#### Issue: ECS task fails to start

**Symptoms**:
- Terraform times out waiting for ECS service to become healthy
- ECS task in STOPPED state with error message

**Diagnosis**:
```bash
# Check ECS task status
aws ecs list-tasks --cluster pmm-server --desired-status STOPPED

# Get task details
aws ecs describe-tasks --cluster pmm-server --tasks <task-arn>

# Check CloudWatch logs
aws logs tail /aws/ecs/pmm-server --follow
```

**Common causes**:
1. EFS mount failure
2. Secrets Manager permission denied
3. Out of memory/CPU
4. Container image pull failure

**Resolution**:
```hcl
# Verify EFS mount targets exist
resource "aws_efs_mount_target" "pmm_data" {
  for_each       = toset(var.private_subnet_ids)
  file_system_id = aws_efs_file_system.pmm_data.id
  subnet_id      = each.key

  security_groups = [aws_security_group.efs.id]
}

# Verify depends_on in main.tf
depends_on = [
  aws_efs_mount_target.pmm_data
]
```

#### Issue: ALB health checks failing

**Symptoms**:
- Target group shows unhealthy targets
- 503 errors when accessing PMM URL

**Diagnosis**:
```bash
# Check target health
aws elbv2 describe-target-health \
    --target-group-arn <target-group-arn>

# Check ALB logs
aws s3 ls s3://<alb-logs-bucket>/AWSLogs/
```

**Resolution**:
1. Verify PMM container is listening on port 443
2. Check security group rules allow ALB → ECS traffic
3. Increase health check grace period:
```hcl
health_check_grace_period_seconds = 300
```

### Terraform Destroy Fails

#### Issue: EFS filesystem cannot be deleted

**Symptoms**:
```
Error: deleting EFS File System: FileSystemInUse
```

**Resolution**:
```bash
# Manually delete mount targets first
aws efs describe-mount-targets \
    --file-system-id fs-xxxxx \
    --query 'MountTargets[*].MountTargetId' \
    --output text | \
    xargs -n1 aws efs delete-mount-target --mount-target-id

# Wait 30 seconds, then retry terraform destroy
sleep 30
terraform destroy
```

## Access Issues

### Cannot Access PMM Web Interface

#### Issue: DNS not resolving

**Diagnosis**:
```bash
# Check DNS record
dig pmm.your-domain.com

# Check Route53 record
aws route53 list-resource-record-sets \
    --hosted-zone-id Z1234567890ABC \
    --query "ResourceRecordSets[?Name=='pmm.your-domain.com.']"
```

**Resolution**:
1. Verify `zone_id` variable is correct
2. Verify `dns_names` variable matches desired hostname
3. Check Route53 hosted zone has correct NS records

#### Issue: SSL certificate error

**Symptoms**:
- Browser shows "Your connection is not private"
- Certificate mismatch error

**Diagnosis**:
```bash
# Check certificate
openssl s_client -connect pmm.your-domain.com:443 -servername pmm.your-domain.com
```

**Resolution**:
1. Ensure domain is included in ACM certificate
2. Verify ACM certificate is in the same region as ALB
3. Wait for ACM validation to complete (DNS or email)

#### Issue: Cannot login to PMM

**Symptoms**:
- "Invalid username or password" error
- Forgot admin password

**Resolution**:
```bash
# Retrieve admin password
aws secretsmanager get-secret-value \
    --secret-id pmm-server-admin-password \
    --query SecretString \
    --output text

# Or using Terraform output
terraform output -raw admin_password_secret_arn | \
    xargs -I {} aws secretsmanager get-secret-value \
        --secret-id {} \
        --query SecretString \
        --output text
```

## Performance Issues

### PMM Web Interface is Slow

**Diagnosis**:
```bash
# Check ECS task metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/ECS \
    --metric-name CPUUtilization \
    --dimensions Name=ServiceName,Value=pmm-server \
                  Name=ClusterName,Value=pmm-server \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average

# Check EFS metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name BurstCreditBalance \
    --dimensions Name=FileSystemId,Value=fs-xxxxx \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average
```

**Common causes**:
1. Insufficient CPU/memory
2. EFS throughput limits
3. Too many monitored databases
4. Long retention periods

**Resolution**:

**Scale up compute resources**:
```hcl
module "pmm" {
  # ... other config ...

  instance_type    = "m5.xlarge"    # from m5.large
  container_cpu    = 4096           # from 2048
  container_memory = 8192           # from 4096
}
```

**Provision EFS throughput**:
```hcl
variable "efs_throughput_mode" {
  default = "provisioned"
}

variable "efs_provisioned_throughput" {
  default = 100  # MiB/s
}
```

### High EFS Burst Credit Consumption

**Symptoms**:
- CloudWatch alarm: "EFS burst credit balance is low"
- Slow PMM queries

**Diagnosis**:
```bash
# Check burst credit balance
aws cloudwatch get-metric-statistics \
    --namespace AWS/EFS \
    --metric-name BurstCreditBalance \
    --dimensions Name=FileSystemId,Value=fs-xxxxx \
    --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 3600 \
    --statistics Minimum
```

**Resolution**:
1. **Immediate**: Add more data to EFS (increases baseline throughput)
2. **Long-term**: Switch to provisioned throughput mode
3. **Optimization**: Reduce metrics retention in PMM settings

## Storage Issues

### EFS Running Out of Space

**Diagnosis**:
```bash
# Check EFS size
aws efs describe-file-systems \
    --file-system-id fs-xxxxx \
    --query 'FileSystems[0].SizeInBytes'

# Connect to EC2 instance and check disk usage
sudo df -h /mnt/efs
sudo du -sh /mnt/efs/*
```

**Resolution**:
1. Reduce metrics retention in PMM:
   - Login to PMM
   - Go to **Configuration** → **Settings** → **Advanced Settings**
   - Adjust **Data Retention** (default: 30 days)

2. Clean up old data manually:
```bash
# SSH to EC2 instance
aws ssm start-session --target <instance-id>

# Find large directories
sudo du -sh /mnt/efs/* | sort -rh | head -10

# Clean Prometheus data (if needed)
sudo rm -rf /mnt/efs/prometheus/data/old_chunks
```

3. EFS automatically expands, but consider costs

### Backup Failures

**Diagnosis**:
```bash
# List recent backup jobs
aws backup list-backup-jobs \
    --by-resource-arn "arn:aws:elasticfilesystem:us-west-1:123456789012:file-system/fs-xxxxx" \
    --max-results 10

# Get backup job details
aws backup describe-backup-job \
    --backup-job-id <backup-job-id>
```

**Common causes**:
1. IAM permissions issues
2. Backup vault policy restrictions
3. EFS in use during backup

**Resolution**:
```bash
# Verify backup role permissions
aws iam get-role --role-name pmm-server-backup-role

# Manually trigger backup
./scripts/backup-efs.sh fs-xxxxx
```

## Monitoring Issues

### CloudWatch Alarms Not Triggering

**Diagnosis**:
```bash
# Check alarm state
aws cloudwatch describe-alarms \
    --alarm-names pmm-server-ecs-service-running

# Check SNS topic subscriptions
aws sns list-subscriptions-by-topic \
    --topic-arn <topic-arn>
```

**Resolution**:
1. Verify email subscriptions are confirmed
2. Check SNS topic permissions
3. Test alarm manually:
```bash
aws cloudwatch set-alarm-state \
    --alarm-name pmm-server-ecs-service-running \
    --state-value ALARM \
    --state-reason "Testing alarm"
```

### No Metrics from Monitored Databases

**Symptoms**:
- PMM shows "No Data" for database instance
- Queries not appearing in Query Analytics

**Diagnosis**:
1. Check PMM inventory: **Configuration** → **Inventory**
2. Verify service status
3. Check network connectivity from PMM to database

**Resolution**:
See [RDS_SETUP.md](./RDS_SETUP.md) for detailed RDS monitoring setup.

## Recovery Procedures

### Recover from EFS Backup

#### Scenario: Data corruption or accidental deletion

**Steps**:

1. List available recovery points:
```bash
aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name pmm-server-backup-vault \
    --query 'RecoveryPoints[*].[RecoveryPointArn,CreationDate]' \
    --output table
```

2. Create new EFS filesystem:
```bash
aws efs create-file-system \
    --creation-token pmm-recovery-$(date +%s) \
    --encrypted \
    --performance-mode generalPurpose \
    --throughput-mode bursting
```

3. Restore from backup:
```bash
# Get the recovery point ARN from step 1
RECOVERY_POINT_ARN="arn:aws:backup:..."
NEW_EFS_ID="fs-xxxxx"

aws backup start-restore-job \
    --recovery-point-arn "$RECOVERY_POINT_ARN" \
    --iam-role-arn "arn:aws:iam::account-id:role/pmm-server-backup-role" \
    --metadata file-system-id="$NEW_EFS_ID"
```

4. Monitor restore progress:
```bash
aws backup describe-restore-job \
    --restore-job-id <restore-job-id>
```

5. Update Terraform to use new EFS:
```hcl
# In a emergency, manually update
# Or import new EFS into Terraform state
terraform import aws_efs_file_system.pmm_data fs-xxxxx
```

6. Restart ECS service to mount new EFS

### Complete Disaster Recovery

#### Scenario: Region failure or complete infrastructure loss

**Prerequisites**:
- Terraform state backed up (S3 with versioning)
- Recent EFS backup available
- DNS records documented

**Steps**:

1. Deploy infrastructure in new region:
```bash
# Update provider region
terraform apply -var="region=us-east-1"
```

2. Restore data from backup (see above)

3. Update DNS records to point to new ALB

4. Verify PMM is accessible

5. Re-add monitored databases to PMM

**RTO**: ~2 hours
**RPO**: 24 hours (daily backups)

### Rollback After Failed Upgrade

#### Scenario: PMM upgrade breaks functionality

**Steps**:

1. Revert to previous PMM version:
```hcl
module "pmm" {
  # ... other config ...

  pmm_version = "2"  # or previous working version
}
```

2. Apply Terraform:
```bash
terraform apply
```

3. ECS will perform rolling update back to old version

4. Data persists on EFS (no data loss)

## Getting Help

### Collect Diagnostic Information

```bash
# ECS service status
aws ecs describe-services \
    --cluster pmm-server \
    --services pmm-server > ecs-service.json

# ECS task details
aws ecs describe-tasks \
    --cluster pmm-server \
    --tasks $(aws ecs list-tasks \
        --cluster pmm-server \
        --service-name pmm-server \
        --query 'taskArns[0]' \
        --output text) > ecs-task.json

# CloudWatch logs
aws logs tail /aws/ecs/pmm-server \
    --since 1h > pmm-logs.txt

# EFS status
aws efs describe-file-systems \
    --file-system-id fs-xxxxx > efs-status.json

# Target health
aws elbv2 describe-target-health \
    --target-group-arn <target-group-arn> > target-health.json
```

### Support Resources

- **PMM Documentation**: https://docs.percona.com/percona-monitoring-and-management/
- **PMM Forums**: https://forums.percona.com/c/percona-monitoring-and-management-pmm/
- **AWS Support**: Via AWS Console
- **Module Issues**: https://github.com/infrahouse/terraform-aws-pmm-ecs/issues

### Useful Commands

```bash
# SSH to EC2 instance (if ssh_key_name configured)
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=pmm-server*" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)

aws ssm start-session --target "$INSTANCE_ID"

# Check PMM container status
sudo docker ps
sudo docker logs <container-id>

# Check EFS mount
df -h | grep efs
sudo mount | grep efs

# Restart ECS service (last resort)
aws ecs update-service \
    --cluster pmm-server \
    --service pmm-server \
    --force-new-deployment
```