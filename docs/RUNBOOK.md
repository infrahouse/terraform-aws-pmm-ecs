# PMM Operational Runbook

This runbook provides step-by-step procedures for common operational tasks related to managing your PMM (Percona Monitoring and Management) deployment on AWS.

## Table of Contents

- [Access and Authentication](#access-and-authentication)
- [Instance Management](#instance-management)
- [Data Management](#data-management)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Upgrades and Maintenance](#upgrades-and-maintenance)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)
- [Emergency Procedures](#emergency-procedures)

## Access and Authentication

### Accessing the PMM Web Interface

**URL**: `https://pmm.<your-domain>`
- Example: `https://pmm.example.com`

**Default credentials**:
- Username: `admin`
- Password: Stored in AWS Secrets Manager

### Retrieving the Admin Password

**Via AWS Console**:
1. Go to AWS Secrets Manager
2. Find secret named `pmm-server-admin-password`
3. Click "Retrieve secret value"
4. Copy the password

**Via AWS CLI**:
```bash
aws secretsmanager get-secret-value \
  --secret-id pmm-server-admin-password \
  --query SecretString \
  --output text
```

**Via Terraform Output** (if configured):
```bash
terraform output admin_password_secret_arn
```

### SSH Access to EC2 Instance

**Prerequisites**:
- SSH key configured via `ssh_key_name` variable
- `admin_cidr_block` variable set to allow SSH from your IP

**Connect to instance**:
```bash
# Get instance IP
INSTANCE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=pmm-server" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PrivateIpAddress" \
  --output text)

# SSH (from bastion or VPN)
ssh ubuntu@$INSTANCE_IP
```

### Changing Admin Password

**Option 1: Via PMM UI**:
1. Log in to PMM as admin
2. Go to Settings → Users
3. Select admin user → Change password

**Option 2: Update Secret in AWS**:
```bash
# Generate new password
NEW_PASSWORD=$(openssl rand -base64 24)

# Update secret
aws secretsmanager put-secret-value \
  --secret-id pmm-server-admin-password \
  --secret-string "$NEW_PASSWORD"

# Restart PMM container to pick up new password
ssh ubuntu@$INSTANCE_IP
sudo systemctl restart pmm-server
```

## Instance Management

### Starting PMM Service

```bash
ssh ubuntu@<instance-ip>

# Start PMM container
sudo systemctl start pmm-server

# Verify status
sudo systemctl status pmm-server

# Check container logs
sudo docker logs pmm-server --tail 50
```

### Stopping PMM Service

**Use case**: Maintenance windows, troubleshooting

```bash
ssh ubuntu@<instance-ip>

# Stop PMM container
sudo systemctl stop pmm-server

# Verify it's stopped
sudo systemctl status pmm-server
sudo docker ps | grep pmm-server  # Should show nothing
```

### Restarting PMM Service

**Use case**: Configuration changes, memory issues

```bash
ssh ubuntu@<instance-ip>

# Restart PMM
sudo systemctl restart pmm-server

# Monitor restart
sudo journalctl -u pmm-server -f
```

### Checking Instance Health

**EC2 Status Checks**:
```bash
aws ec2 describe-instance-status \
  --instance-ids <instance-id> \
  --query "InstanceStatuses[0].[SystemStatus.Status,InstanceStatus.Status]" \
  --output text
```

**System Resources**:
```bash
ssh ubuntu@<instance-ip>

# CPU usage
top -bn1 | head -20

# Memory usage
free -h

# Disk usage
df -h

# EBS volume status
lsblk
mount | grep /srv

# Docker container status
sudo docker stats pmm-server --no-stream
```

### Rebooting EC2 Instance

**Use case**: Kernel updates, persistent issues

**Planned reboot**:
```bash
# Reboot via AWS Console or CLI
aws ec2 reboot-instances --instance-ids <instance-id>

# Monitor instance state
aws ec2 describe-instance-status --instance-ids <instance-id>
```

**After reboot**:
```bash
# Verify PMM restarted
ssh ubuntu@<instance-ip>
sudo systemctl status pmm-server

# Check mount points
df -h | grep /srv

# Verify PMM web interface
curl -k https://pmm.example.com/v1/readyz
```

## Data Management

### Checking Disk Space

```bash
ssh ubuntu@<instance-ip>

# Overall disk usage
df -h

# Data volume usage
df -h /srv

# Top directories consuming space
sudo du -sh /srv/* | sort -h

# PMM database sizes
sudo du -sh /srv/clickhouse
sudo du -sh /srv/postgres
sudo du -sh /srv/prometheus
```

### Cleaning Up Old Data

**PMM data retention** is managed within PMM settings:

1. Log in to PMM UI
2. Go to Settings → Advanced Settings
3. Adjust data retention:
   - Metrics retention: Default 30 days
   - Query Analytics retention: Default 8 days

**Manual cleanup** (if needed):
```bash
ssh ubuntu@<instance-ip>

# Stop PMM
sudo systemctl stop pmm-server

# Clean up old Prometheus data (older than 30 days)
sudo find /srv/prometheus -type f -mtime +30 -delete

# Start PMM
sudo systemctl start pmm-server
```

### Expanding Data Volume

**When to expand**:
- Disk usage >80%
- CloudWatch alarm triggered
- Planning to increase retention

**Steps**:

1. **Update Terraform configuration**:
   ```hcl
   module "pmm" {
     # ... other settings ...
     ebs_volume_size = 200  # Increase from 100GB
   }
   ```

2. **Apply Terraform**:
   ```bash
   terraform plan   # Verify only volume size changes
   terraform apply
   ```

3. **Extend filesystem** (no downtime):
   ```bash
   ssh ubuntu@<instance-ip>

   # Verify new volume size
   lsblk | grep xvdf

   # Extend filesystem
   sudo resize2fs /dev/xvdf

   # Verify new size
   df -h /srv
   ```

### Backup and Restore

See [BACKUP_RESTORE.md](./BACKUP_RESTORE.md) for detailed procedures.

**Quick backup**:
```bash
# Create on-demand snapshot
aws ec2 create-snapshot \
  --volume-id <volume-id> \
  --description "PMM manual backup $(date +%Y-%m-%d)" \
  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=pmm-manual-backup}]'
```

## Monitoring and Alerting

### Viewing CloudWatch Metrics

**Via CloudWatch Dashboard** (if enabled):
1. Go to CloudWatch → Dashboards
2. Select `pmm-server-monitoring` dashboard
3. View real-time metrics

**Via AWS CLI**:
```bash
# CPU utilization
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average

# Memory usage (CloudWatch Agent)
aws cloudwatch get-metric-statistics \
  --namespace CWAgent \
  --metric-name mem_used_percent \
  --dimensions Name=InstanceId,Value=<instance-id> \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average
```

### Checking CloudWatch Alarms

**List active alarms**:
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix pmm-server \
  --state-value ALARM \
  --output table
```

**View alarm history**:
```bash
aws cloudwatch describe-alarm-history \
  --alarm-name pmm-server-high-memory \
  --max-records 10
```

### Viewing Logs

**PMM service logs (systemd)**:
```bash
ssh ubuntu@<instance-ip>

# Real-time logs
sudo journalctl -u pmm-server -f

# Last 100 lines
sudo journalctl -u pmm-server -n 100

# Logs from last hour
sudo journalctl -u pmm-server --since "1 hour ago"
```

**Docker container logs**:
```bash
# Real-time logs
sudo docker logs pmm-server -f

# Last 100 lines
sudo docker logs pmm-server --tail 100

# Logs with timestamps
sudo docker logs pmm-server --timestamps
```

**CloudWatch Logs** (if shipped):
```bash
aws logs tail /aws/ec2/pmm-server --follow
```

### Managing SNS Notifications

**Add email subscribers**:
```bash
# Get SNS topic ARN
TOPIC_ARN=$(aws sns list-topics \
  --query "Topics[?contains(TopicArn, 'pmm-server-alarms')].TopicArn" \
  --output text)

# Subscribe new email
aws sns subscribe \
  --topic-arn $TOPIC_ARN \
  --protocol email \
  --notification-endpoint devops@example.com

# Subscriber must confirm via email
```

**List subscribers**:
```bash
aws sns list-subscriptions-by-topic --topic-arn $TOPIC_ARN
```

## Upgrades and Maintenance

### Upgrading PMM Version

**Before upgrade**:
1. Review [PMM release notes](https://docs.percona.com/percona-monitoring-and-management/release-notes.html)
2. Create manual backup (see Backup section)
3. Schedule maintenance window
4. Notify users

**Steps**:

1. **Update Terraform configuration**:
   ```hcl
   module "pmm" {
     # ... other settings ...
     pmm_version = "3.1"  # Update from "3" to specific version
   }
   ```

2. **Apply Terraform** (will recreate container):
   ```bash
   terraform plan   # Review changes
   terraform apply
   ```

3. **Verify upgrade**:
   ```bash
   ssh ubuntu@<instance-ip>

   # Check PMM version
   sudo docker exec pmm-server pmm-admin --version

   # Verify service health
   sudo systemctl status pmm-server
   curl -k https://pmm.example.com/v1/readyz
   ```

4. **Post-upgrade checks**:
   - Log in to PMM UI
   - Verify dashboards load
   - Check database connections
   - Review logs for errors

### Patching EC2 Instance

**Ubuntu OS patches**:

```bash
ssh ubuntu@<instance-ip>

# Update package list
sudo apt update

# Check available updates
apt list --upgradable

# Install updates (kernel updates require reboot)
sudo apt upgrade -y

# Reboot if needed
sudo reboot
```

**Automated patching** (recommended):
- Enable AWS Systems Manager Patch Manager
- Or use maintenance windows in Terraform

### Updating Docker

```bash
ssh ubuntu@<instance-ip>

# Check current Docker version
docker --version

# Update Docker
sudo apt update
sudo apt install --only-upgrade docker-ce

# Restart Docker daemon
sudo systemctl restart docker

# Restart PMM
sudo systemctl restart pmm-server
```

## Performance Tuning

### Optimizing ClickHouse Performance

**Increase ClickHouse memory** (if high query load):
```bash
ssh ubuntu@<instance-ip>

# Edit PMM container environment
sudo systemctl stop pmm-server

# Modify Docker container settings (example: increase memory)
# Edit systemd service file
sudo nano /etc/systemd/system/pmm-server.service

# Add environment variable
Environment="CLICKHOUSE_MAX_MEMORY=8GB"

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl start pmm-server
```

### Optimizing Query Analytics

**Reduce retention** (if disk space constrained):
1. PMM UI → Settings → Advanced Settings
2. Query Analytics retention: 8 days → 3 days

**Disable slow query log** (if not needed):
1. PMM UI → Database monitoring settings
2. Disable slow query log collection for specific databases

### Scaling Instance Type

**When to scale**:
- CPU usage consistently >70%
- Memory usage consistently >85%
- Monitoring 20+ database instances

**Steps**:

1. **Update Terraform**:
   ```hcl
   module "pmm" {
     # ... other settings ...
     instance_type = "m5.xlarge"  # Scale up from m5.large
   }
   ```

2. **Apply (requires instance replacement)**:
   ```bash
   terraform plan   # Note: instance will be replaced
   terraform apply  # Downtime: 5-10 minutes
   ```

3. **Verify**:
   - Check PMM UI accessibility
   - Verify data persistence
   - Monitor new instance performance

### Optimizing EBS Performance

**Increase IOPS** (for high I/O workloads):
```hcl
module "pmm" {
  # ... other settings ...
  ebs_volume_type = "gp3"
  ebs_iops        = 6000  # Increase from 3000
  ebs_throughput  = 250   # Increase from 125 MB/s
}
```

**Apply Terraform**:
```bash
terraform apply  # No downtime, volume modified online
```

## Troubleshooting

### PMM Container Won't Start

**Check logs**:
```bash
sudo journalctl -u pmm-server -n 100 --no-pager
sudo docker logs pmm-server --tail 100
```

**Common issues**:

1. **Port conflict**:
   ```bash
   # Check if ports 80/443 are in use
   sudo netstat -tlnp | grep -E ':(80|443)'

   # Kill conflicting process if needed
   sudo kill <pid>
   ```

2. **Volume mount failure**:
   ```bash
   # Check if /srv is mounted
   mount | grep /srv

   # Remount if needed
   sudo mount /dev/xvdf /srv
   ```

3. **Insufficient memory**:
   ```bash
   # Check available memory
   free -h

   # Kill memory-intensive processes or scale instance
   ```

### High Memory Usage

**Identify memory consumers**:
```bash
ssh ubuntu@<instance-ip>

# System memory
free -h

# Docker container memory
sudo docker stats pmm-server --no-stream

# Processes within container
sudo docker exec pmm-server ps aux --sort=-%mem | head -20
```

**Mitigation**:
1. Restart PMM: `sudo systemctl restart pmm-server`
2. Reduce retention periods in PMM settings
3. Scale to larger instance type

### Disk Space Running Out

**Immediate action**:
```bash
# Identify large directories
sudo du -sh /srv/* | sort -h

# Clean up old snapshots/temp files
sudo find /srv -name "*.tmp" -delete
```

**Long-term solution**:
1. Expand EBS volume (see Data Management)
2. Reduce data retention in PMM settings
3. Archive old data to S3

### Database Connection Failures

**Check PMM to RDS connectivity**:
```bash
ssh ubuntu@<instance-ip>

# Test PostgreSQL connection
nc -zv <rds-endpoint> 5432

# Check security group rules
aws ec2 describe-security-groups \
  --group-ids <pmm-security-group-id> \
  --query "SecurityGroups[0].IpPermissionsEgress"
```

**Verify RDS security group**:
```bash
# Check if PMM security group is allowed
aws ec2 describe-security-groups \
  --group-ids <rds-security-group-id> \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`5432\`]"
```

### ALB Health Check Failures

**Check target health**:
```bash
# Get target group ARN
TG_ARN=$(aws elbv2 describe-target-groups \
  --query "TargetGroups[?contains(TargetGroupName, 'pmm')].TargetGroupArn" \
  --output text)

# Check target health
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

**Common causes**:
1. PMM container not running: Check systemd status
2. Health endpoint not responding: `curl http://localhost/v1/readyz`
3. Security group blocking traffic: Verify ALB can reach instance on port 80

**Fix**:
```bash
# Restart PMM
sudo systemctl restart pmm-server

# Test health endpoint
curl -v http://localhost/v1/readyz
```

## Emergency Procedures

### Service Outage Response

1. **Assess severity**:
   - PMM UI inaccessible?
   - Instance down?
   - Data corruption?

2. **Check CloudWatch alarms**:
   ```bash
   aws cloudwatch describe-alarms \
     --alarm-name-prefix pmm-server \
     --state-value ALARM
   ```

3. **Check instance status**:
   ```bash
   aws ec2 describe-instance-status --instance-ids <instance-id>
   ```

4. **Immediate actions**:
   - If instance failed: EC2 auto-recovery should trigger
   - If service crashed: SSH and restart PMM
   - If AZ down: Follow disaster recovery procedures

### Data Corruption Recovery

**Symptoms**:
- PMM UI shows errors
- Dashboards won't load
- Database query failures

**Recovery**:
1. Stop PMM: `sudo systemctl stop pmm-server`
2. Check filesystem: `sudo fsck -y /dev/xvdf`
3. Restore from backup (see BACKUP_RESTORE.md)

### Emergency Rollback

**Use case**: Bad upgrade, configuration change caused issues

**Steps**:

1. **Revert Terraform changes**:
   ```bash
   git revert <commit-hash>
   terraform apply
   ```

2. **Or restore from backup** (if data changed):
   - See BACKUP_RESTORE.md Scenario 1
   - Use backup from before the change

### Accessing Instance During AWS Console Outage

**Via AWS CLI** (pre-configured):
```bash
# Stop instance
aws ec2 stop-instances --instance-ids <instance-id>

# Start instance
aws ec2 start-instances --instance-ids <instance-id>

# Reboot instance
aws ec2 reboot-instances --instance-ids <instance-id>
```

**Via Terraform**:
```bash
# Emergency destroy and recreate
terraform destroy -target=module.pmm.aws_instance.pmm_server
terraform apply -target=module.pmm.aws_instance.pmm_server
```

## Regular Maintenance Schedule

### Daily
- Monitor CloudWatch alarms via email
- Check backup job success (AWS Backup console)

### Weekly
- Review PMM UI performance and dashboards
- Check disk usage trends
- Review CloudWatch metrics

### Monthly
- Review access logs and user activity
- Check for PMM version updates
- Review and optimize data retention settings
- Test database connections

### Quarterly
- Test disaster recovery procedures (see BACKUP_RESTORE.md)
- Review and update documentation
- Patch EC2 instance OS
- Review CloudWatch alarm thresholds

### Annually
- Review architecture for cost optimization
- Evaluate PMM version and plan upgrades
- Audit IAM roles and permissions
- Review backup retention policies

## Contacts and Escalation

**Primary contacts**:
- Team Email: devops@example.com
- On-call Rotation: [PagerDuty/Slack channel]

**Escalation path**:
1. L1: Team on-call engineer
2. L2: Platform engineering lead
3. L3: AWS Support (if AWS infrastructure issue)
4. L4: Percona Support (if PMM software issue)

**External resources**:
- [Percona PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [Percona Community Forums](https://forums.percona.com/)
- [AWS Support](https://console.aws.amazon.com/support/)

## Appendix

### Useful Commands Cheat Sheet

```bash
# Instance status
aws ec2 describe-instance-status --instance-ids <id>

# Get admin password
aws secretsmanager get-secret-value --secret-id pmm-server-admin-password --query SecretString --output text

# Restart PMM
ssh ubuntu@<ip> "sudo systemctl restart pmm-server"

# Check disk usage
ssh ubuntu@<ip> "df -h /srv"

# View logs
ssh ubuntu@<ip> "sudo journalctl -u pmm-server -f"

# Create manual backup
aws ec2 create-snapshot --volume-id <vol-id> --description "Manual backup"

# Check alarms
aws cloudwatch describe-alarms --alarm-name-prefix pmm-server --state-value ALARM
```

### Terraform Commands Reference

```bash
# View current state
terraform show

# Plan changes
terraform plan

# Apply changes
terraform apply

# Target specific resource
terraform apply -target=module.pmm.aws_ebs_volume.pmm_data

# Import existing resource
terraform import module.pmm.aws_ebs_volume.pmm_data vol-xxxxx

# View outputs
terraform output
```

## Document Revision History

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2024-01-15 | 1.0 | Initial runbook creation | DevOps Team |

---

**Last updated**: 2024-01-15
**Review cycle**: Quarterly
**Next review**: 2024-04-15