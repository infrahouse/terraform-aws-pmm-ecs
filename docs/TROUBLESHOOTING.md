# PMM Troubleshooting Guide

This guide covers common issues and their solutions when deploying and
operating PMM on AWS EC2.

## Table of Contents

- [Deployment Issues](#deployment-issues)
- [Access Issues](#access-issues)
- [Performance Issues](#performance-issues)
- [Storage Issues](#storage-issues)
- [Monitoring Issues](#monitoring-issues)
- [ASG Reconciler Lambda Issues](#asg-reconciler-lambda-issues)
- [Recovery Procedures](#recovery-procedures)

## Deployment Issues

### Terraform Apply Fails

#### Issue: PMM container fails to start

**Symptoms**:
- PMM UI not accessible after deployment
- `systemctl status pmm-server` shows failed state

**Diagnosis**:
```bash
# SSH to instance or use SSM Session Manager
aws ssm start-session --target <instance-id>

# Check systemd service status
sudo systemctl status pmm-server

# Check Docker container logs
sudo docker logs pmm-server --tail 100

# Check cloud-init logs for startup issues
sudo cat /var/log/cloud-init-output.log | tail -100
```

**Common causes**:
1. EBS volume mount failure
2. Secrets Manager permission denied
3. Out of memory/CPU
4. Docker image pull failure

**Resolution**:
```bash
# Verify EBS volume is mounted
mount | grep /srv
df -h /srv

# Remount if needed
sudo mount /dev/xvdf /srv

# Restart PMM container
sudo systemctl restart pmm-server
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
1. Verify PMM container is running: `sudo docker ps | grep pmm`
2. Check security group rules allow ALB → EC2 on port 80
3. Test health endpoint locally: `curl http://localhost/v1/readyz`
4. Restart PMM if needed: `sudo systemctl restart pmm-server`

### Terraform Destroy Fails

#### Issue: EBS volume cannot be deleted

**Symptoms**:
```
Error: deleting EBS Volume: VolumeInUse
```

**Resolution**:
```bash
# Stop the instance first
aws ec2 stop-instances --instance-ids <instance-id>

# Wait for instance to stop, then retry
terraform destroy
```

#### Issue: Backup vault cannot be deleted

**Symptoms**:
```
Error: deleting Backup Vault: vault has recovery points
```

**Resolution**:
Set `backup_vault_force_destroy = true` in your Terraform config and apply,
then destroy. Or delete recovery points manually via AWS Console.

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
# Check EC2 instance metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions Name=InstanceId,Value=<instance-id> \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Average

# Check EBS volume performance
aws cloudwatch get-metric-statistics \
    --namespace AWS/EBS \
    --metric-name VolumeReadOps \
    --dimensions Name=VolumeId,Value=<volume-id> \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --statistics Sum
```

**Common causes**:
1. Insufficient CPU/memory
2. EBS IOPS/throughput limits
3. Too many monitored databases
4. Long retention periods

**Resolution**:

**Scale up compute resources**:
```hcl
module "pmm" {
  # ... other config ...
  instance_type = "m5.xlarge"  # from m5.large
}
```

**Increase EBS performance**:
```hcl
module "pmm" {
  # ... other config ...
  ebs_iops       = 6000  # from 3000
  ebs_throughput = 250   # from 125 MB/s
}
```

## Storage Issues

### EBS Data Volume Running Out of Space

**Diagnosis**:
```bash
# SSH to EC2 instance
aws ssm start-session --target <instance-id>

# Check disk usage
df -h /srv
sudo du -sh /srv/* | sort -rh | head -10
```

**Resolution**:
1. Reduce metrics retention in PMM:
   - Login to PMM UI
   - Go to **Settings** → **Advanced Settings**
   - Adjust **Data Retention** (default: 30 days)

2. Expand EBS volume (no downtime):
```hcl
module "pmm" {
  # ... other config ...
  ebs_volume_size = 200  # increase from 100GB
}
```
   After `terraform apply`, extend the filesystem:
```bash
sudo resize2fs /dev/xvdf
```

3. Clean up old data manually:
```bash
sudo du -sh /srv/* | sort -rh | head -10
```

### Backup Failures

**Diagnosis**:
```bash
# List recent backup jobs
aws backup list-backup-jobs \
    --by-backup-vault-name <vault-name> \
    --max-results 10

# Get backup job details
aws backup describe-backup-job \
    --backup-job-id <backup-job-id>
```

**Common causes**:
1. IAM permissions issues
2. Backup vault policy restrictions

**Resolution**:
```bash
# Verify backup role permissions
aws iam get-role --role-name <backup-role-name>

# Create manual snapshot
aws ec2 create-snapshot \
    --volume-id <volume-id> \
    --description "PMM manual backup"
```

## Monitoring Issues

### CloudWatch Alarms Not Triggering

**Diagnosis**:
```bash
# Check alarm state
aws cloudwatch describe-alarms \
    --alarm-name-prefix pmm-server

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
    --alarm-name <alarm-name> \
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

## ASG Reconciler Lambda Issues

### Lambda Not Creating Services

**Symptoms**: New ASG instances don't appear in PMM inventory

**Diagnosis**:
```bash
# Check Lambda logs
FUNCTION_NAME=$(aws lambda list-functions \
    --query "Functions[?contains(FunctionName, 'reconciler')].FunctionName" \
    --output text)
aws logs tail /aws/lambda/$FUNCTION_NAME --since 1h

# Manually invoke and check result
aws lambda invoke \
    --function-name $FUNCTION_NAME \
    output.json && cat output.json
```

**Common causes and fixes**:

1. **pmm-agent connection timeout** (`dial tcp ...:443: i/o timeout`):
   - Security group missing: port 443 ingress from ASG SG to PMM instance SG
   - pmm-agent connects directly to PMM EC2 (NOT via ALB)
   - Fix: ensure `security_group_id` is set in `monitored_asgs` config

2. **"already exists" error on `pmm-admin add mysql`**:
   - Service exists from a previous registration (stale)
   - Lambda should auto-remove and retry, check logs for retry attempt
   - Manual fix: delete stale service from PMM UI (Inventory > Services)

3. **SSM command timeout**:
   - Instance not SSM-managed (missing IAM role or SSM agent)
   - Check: `aws ssm describe-instance-information --filters Key=InstanceIds,Values=<id>`

4. **Credential lookup failure**:
   - Puppet facts not available (`facter -p percona.credentials_secret`)
   - `ih-secrets` CLI not installed
   - Check `/opt/puppetlabs/bin` is in PATH

### pmm-client Connected but No MySQL Metrics

**Symptoms**: `pmm-admin status` shows `Connected : true` but no
`mysqld_exporter`

**Diagnosis** (on the instance):
```bash
sudo pmm-admin status
sudo pmm-admin list
```

**Resolution**:
```bash
# Get credentials and add MySQL manually
CREDS_SECRET=$(sudo facter -p percona.credentials_secret)
DB_PASSWORD=$(sudo ih-secrets get "$CREDS_SECRET" | jq -r '.monitor')

sudo pmm-admin add mysql \
    --username='monitor' \
    --password="$DB_PASSWORD" \
    --host=127.0.0.1 \
    --port=3306 \
    --query-source=perfschema \
    --service-name='<asg-name>/<hostname>'
```

### Lambda Returns Errors

**Check the result payload**:
```bash
aws lambda invoke \
    --function-name $FUNCTION_NAME \
    output.json && cat output.json
```

Expected success: `{"status": "ok", "added": 0, "removed": 0, "errors": []}`

If `"status": "error"`, check the `errors` array for per-ASG failure messages.

## Recovery Procedures

### Recover from EBS Backup

#### Scenario: Data corruption or accidental deletion

**Steps**:

1. List available recovery points:
```bash
aws backup list-recovery-points-by-backup-vault \
    --backup-vault-name <vault-name> \
    --query 'RecoveryPoints[*].[RecoveryPointArn,CreationDate]' \
    --output table
```

2. Stop PMM instance and detach corrupted volume.

3. Create new EBS volume from snapshot in the same AZ.

4. Attach new volume as `/dev/xvdf` and start instance.

5. Verify data integrity in PMM UI.

See [BACKUP_RESTORE.md](./BACKUP_RESTORE.md) for detailed procedures.

### Complete Disaster Recovery

#### Scenario: Region failure or complete infrastructure loss

**Prerequisites**:
- Terraform state backed up (S3 with versioning)
- Recent EBS snapshot available
- DNS records documented

**Steps**:

1. Deploy infrastructure in new region
2. Restore EBS volume from snapshot
3. DNS records update automatically via ALB
4. Verify PMM is accessible
5. Re-add monitored databases to PMM

**RTO**: ~30 minutes (same AZ), ~2 hours (new region)
**RPO**: 24 hours (daily backups)

### Rollback After Failed Upgrade

#### Scenario: PMM upgrade breaks functionality

**Steps**:

1. Revert to previous PMM version:
```hcl
module "pmm" {
  # ... other config ...
  pmm_version = "3"  # or previous working version
}
```

2. Apply Terraform:
```bash
terraform apply
```

3. Instance will be recreated with previous Docker image version.

4. Data persists on EBS volume (no data loss).

## Getting Help

### Collect Diagnostic Information

```bash
# EC2 instance status
aws ec2 describe-instance-status \
    --instance-ids <instance-id> > instance-status.json

# PMM container logs
ssh ubuntu@<instance-ip> \
    "sudo journalctl -u pmm-server --since '1 hour ago'" > pmm-logs.txt

# Target health
aws elbv2 describe-target-health \
    --target-group-arn <target-group-arn> > target-health.json

# Lambda reconciler logs (if configured)
aws logs tail /aws/lambda/<reconciler-function-name> \
    --since 1h > lambda-logs.txt
```

### Support Resources

- **PMM Documentation**: https://docs.percona.com/percona-monitoring-and-management/
- **PMM Forums**: https://forums.percona.com/c/percona-monitoring-and-management-pmm/
- **AWS Support**: Via AWS Console
- **Module Issues**: https://github.com/infrahouse/terraform-aws-pmm-ecs/issues

### Useful Commands

```bash
# Connect to EC2 instance via SSM
INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=pmm-server*" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text)

aws ssm start-session --target "$INSTANCE_ID"

# Check PMM container status
sudo docker ps
sudo docker logs pmm-server --tail 100

# Check EBS mount
df -h /srv
mount | grep /srv

# Check pmm-client on an ASG instance (if reconciler configured)
sudo pmm-admin status
sudo pmm-admin list
```