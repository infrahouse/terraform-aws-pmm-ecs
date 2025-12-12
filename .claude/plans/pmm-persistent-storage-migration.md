# PMM Persistent Storage Migration Plan

## Executive Summary
Migrate PMM deployment from ASG with ephemeral storage to single EC2 instance with persistent 
EBS volume to ensure data persistence while maintaining high availability through auto-recovery mechanisms.

## Current State Analysis

### Problems with Current Architecture
1. **Data Loss Risk**: ASG instance replacement destroys all PMM data (metrics, dashboards, settings)
2. **Unnecessary Complexity**: ASG with min=1, max=1 provides no scaling benefit
3. **EFS Incompatibility**: Already tried and failed due to ClickHouse/PostgreSQL corruption issues
4. **No Real HA**: Can't run multiple PMM instances anyway due to software limitations

### Current Components to Retain
- Application Load Balancer (ALB) for HTTPS termination
- Route 53 DNS configuration
- Security groups and network setup
- CloudWatch monitoring and alarms
- IAM roles and policies

## Target Architecture

### Core Components
1. **Single EC2 Instance**
   - Dedicated EC2 instance (not in ASG)
   - Same instance type as current (configurable)
   - User data script for PMM container setup

2. **Persistent EBS Volume**
   - Separate data volume (e.g., 100GB GP3)
   - Encrypted with KMS
   - Mounted at `/srv` for PMM data
   - Tagged for easy identification

3. **High Availability Features**
   - EC2 Auto Recovery for instance failures
   - EBS snapshots via AWS Backup
   - CloudWatch alarms for monitoring
   - Optional: Lambda function for advanced recovery scenarios

4. **Networking**
   - Keep existing ALB configuration
   - Instance in private subnet
   - ALB in public subnets
   - Security groups for proper access control

## Implementation Steps

### Phase 1: Prepare New Resources (No Downtime)

#### 1.1 Create EBS Volume Resource ✅ COMPLETED
```hcl
# ebs.tf
resource "aws_ebs_volume" "pmm_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size             = var.ebs_volume_size
  type             = var.ebs_volume_type
  iops             = var.ebs_volume_type == "gp3" ? var.ebs_iops : null
  throughput       = var.ebs_volume_type == "gp3" ? var.ebs_throughput : null
  encrypted        = true
  kms_key_id       = var.kms_key_id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-data"
      Type = "pmm-persistent-data"
    }
  )

  # Prevent accidental deletion
  lifecycle {
    prevent_destroy = true
  }
}
```

#### 1.2 Create EC2 Instance Resource ✅ COMPLETED
```hcl
# ec2.tf
resource "aws_instance" "pmm_server" {
  ami                    = data.aws_ami.ubuntu_pro.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.pmm_instance.id]
  key_name              = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.pmm.name

  # Enable auto-recovery
  monitoring = true

  # Root volume configuration
  root_block_device {
    volume_size           = var.root_volume_size
    volume_type          = "gp3"
    encrypted            = true
    delete_on_termination = true
  }

  user_data = data.cloudinit_config.pmm.rendered

  tags = merge(
    local.common_tags,
    {
      Name = local.service_name
    }
  )

  # Ensure instance is replaced if user data changes
  user_data_replace_on_change = true
}

# Attach the EBS volume
resource "aws_volume_attachment" "pmm_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.pmm_data.id
  instance_id = aws_instance.pmm_server.id

  # Force detach on destroy (careful with this)
  force_detach = false
}
```

#### 1.3 Setup Auto Recovery ✅ COMPLETED
```hcl
# auto_recovery.tf
resource "aws_cloudwatch_metric_alarm" "pmm_auto_recovery" {
  alarm_name          = "${local.service_name}-auto-recovery"
  alarm_description   = "Auto recover PMM instance if it fails"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
  }

  alarm_actions = ["arn:aws:automate:${data.aws_region.current.name}:ec2:recover"]

  tags = local.common_tags
}
```

#### 1.4 Update User Data Script
```bash
#!/bin/bash
set -e

# Wait for EBS volume to be attached
while [ ! -e /dev/xvdf ]; do
  echo "Waiting for EBS volume..."
  sleep 5
done

# Format volume if new (first time only)
if [ "$(file -s /dev/xvdf)" == "/dev/xvdf: data" ]; then
  mkfs -t ext4 /dev/xvdf
fi

# Mount the volume
mkdir -p /srv
mount /dev/xvdf /srv

# Add to fstab for persistent mounting
echo '/dev/xvdf /srv ext4 defaults,nofail 0 2' >> /etc/fstab

# Create PMM directories on persistent volume
mkdir -p /srv/pmm-data
mkdir -p /srv/prometheus
mkdir -p /srv/clickhouse
mkdir -p /srv/postgres

# Set permissions
chmod 755 /srv/pmm-data

# Run PMM container with persistent volumes
docker run -d \
  --name pmm-server \
  --restart always \
  -p 80:80 \
  -p 443:443 \
  -v /srv/pmm-data:/srv \
  -v /srv/prometheus:/srv/prometheus \
  -v /srv/clickhouse:/srv/clickhouse \
  -v /srv/postgres:/srv/postgres \
  ${PMM_DOCKER_IMAGE}
```

### Phase 2: Configure Backup Strategy

#### 2.1 AWS Backup Configuration
```hcl
# backup.tf
resource "aws_backup_vault" "pmm" {
  name        = "${local.service_name}-backup-vault"
  kms_key_id  = var.backup_kms_key_id

  tags = local.common_tags
}

resource "aws_backup_plan" "pmm" {
  name = "${local.service_name}-backup-plan"

  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.pmm.name
    schedule          = "cron(0 5 ? * * *)"  # Daily at 5 AM UTC

    lifecycle {
      delete_after = var.backup_retention_days
    }

    recovery_point_tags = local.common_tags
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "pmm" {
  name         = "${local.service_name}-backup-selection"
  plan_id      = aws_backup_plan.pmm.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    aws_ebs_volume.pmm_data.arn
  ]

  tags = local.common_tags
}
```

### Phase 3: Update ALB Target Group

#### 3.1 Create New Target Group for Instance
```hcl
# alb.tf
resource "aws_lb_target_group" "pmm" {
  name     = "${local.service_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.selected.id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/v1/readyz"
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = local.common_tags
}

resource "aws_lb_target_group_attachment" "pmm" {
  target_group_arn = aws_lb_target_group.pmm.arn
  target_id        = aws_instance.pmm_server.id
  port             = 80
}
```

### Phase 4: Fresh Deployment (No Migration Needed)

Since there are no existing live setups, we can implement the new architecture directly:

#### 4.1 Implementation Steps
1. **Remove website-pod module** dependency from main.tf
2. **Implement new EC2-based resources** as designed:
   - Create `ec2.tf` with instance configuration
   - Create `ebs.tf` with persistent volume
   - Update `main.tf` to remove website-pod module
   - Update `data.tf` for user data configuration
   - Create/update ALB target group configuration
3. **Run local tests with `make test-keep`** ← You can test at this point!
4. **Validate all functionality** works correctly
5. **Deploy to production** environments as needed

#### 4.2 When You Can Run Tests
After completing the following files, you'll be able to run `make test-keep`:
- ✅ `ec2.tf` - EC2 instance resource
- ✅ `ebs.tf` - EBS volume and attachment
- ✅ Updated `main.tf` - Remove website-pod, add new resources
- ✅ Updated user data - Mount EBS and run PMM container
- ✅ ALB target group attachment

#### 4.3 Testing with `make test-keep`
```bash
# Run the test to create PMM with RDS
make test-keep

# This will:
# 1. Deploy PMM with new EC2/EBS architecture
# 2. Attach an RDS instance for monitoring
# 3. Keep infrastructure running for validation

# After testing is complete:
# - Verify PMM web interface is accessible
# - Check that RDS is being monitored
# - Stop/start EC2 instance to verify data persistence
# - Check that data survived the restart

# Clean up when done:
make test-clean  # or similar command
```

#### 4.4 Testing Checklist
- [ ] Run `make test-keep` successfully
- [ ] EC2 instance launches successfully
- [ ] EBS volume attaches and mounts correctly
- [ ] PMM container starts with persistent volumes
- [ ] ALB health checks pass
- [ ] DNS resolution works
- [ ] PMM web interface accessible
- [ ] RDS instance connects and is monitored
- [ ] Data persists after instance stop/start
- [ ] Auto-recovery triggers on failure (optional test)
- [ ] Backups complete successfully

#### 4.3 No Rollback Needed
Since this is a fresh implementation:
- No data to migrate
- No downtime concerns
- Can iterate on design before any production deployment

### Phase 5: Post-Migration Tasks

#### 5.1 Monitoring Setup
- CloudWatch dashboard for instance and volume metrics
- Alarms for:
  - Instance status checks
  - EBS volume burst balance
  - High CPU/memory usage
  - Low disk space

#### 5.2 Documentation Updates
- Update README with new architecture
- Document backup/restore procedures
- Create runbook for common operations

#### 5.3 Testing
- Test instance failure and auto-recovery
- Test backup and restore
- Test PMM client connections
- Verify all dashboards and data queries work

## Variable Updates

### New Variables to Add
```hcl
variable "ebs_volume_size" {
  description = "Size of the EBS data volume in GB"
  type        = number
  default     = 100
}

variable "ebs_volume_type" {
  description = "Type of the EBS data volume"
  type        = string
  default     = "gp3"
}

variable "ebs_iops" {
  description = "IOPS for the EBS data volume (only for gp3)"
  type        = number
  default     = 3000
}

variable "ebs_throughput" {
  description = "Throughput for the EBS data volume in MB/s (only for gp3)"
  type        = number
  default     = 125
}

variable "root_volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 20
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

variable "enable_auto_recovery" {
  description = "Enable EC2 auto-recovery"
  type        = bool
  default     = true
}
```

### Variables to Remove
- `asg_min_size` (no longer needed)
- `asg_max_size` (no longer needed)
- `efs_*` variables (if any remain)

## Benefits of New Architecture

### Immediate Benefits
1. **Data Persistence**: Survives instance failures
2. **Simpler Architecture**: Easier to troubleshoot and maintain
3. **Cost Optimization**: No unnecessary ASG overhead
4. **Better Backups**: EBS snapshots are faster and more reliable than EFS

### Long-term Benefits
1. **Predictable Performance**: No EFS latency or burst credit issues
2. **Easy Scaling**: Can resize EBS volume online
3. **Disaster Recovery**: Point-in-time recovery from snapshots
4. **Migration Path**: Easier to migrate to containers or managed services later

## Risks and Mitigations

### Risk 1: Single Point of Failure
**Mitigation**:
- EC2 auto-recovery for hardware failures
- Regular EBS snapshots
- Monitoring and alerting
- Optional: Standby instance in another AZ (manual failover)

### Risk 2: EBS Volume Failure
**Mitigation**:
- Daily automated backups
- Consider RAID 1 for critical deployments
- Monitor EBS CloudWatch metrics

### Risk 3: Availability Zone Failure
**Mitigation**:
- Accept as trade-off for simplicity
- Can implement cross-AZ snapshot restore procedure
- For critical deployments: consider active-standby in multiple AZs

## Success Criteria

1. PMM data persists through instance replacements
2. Auto-recovery works within 5 minutes of failure
3. Backups complete successfully daily
4. No performance degradation vs. current setup
5. Simplified operational procedures

## Timeline

- **Week 1**: Develop and test new module version
- **Week 2**: Deploy to test environment
- **Week 3**: Performance testing and optimization
- **Week 4**: Ready for production deployments

## Approval and Sign-off

- [ ] Architecture approved
- [ ] Security review completed
- [ ] Cost analysis accepted
- [ ] Migration window scheduled
- [ ] Rollback plan tested

---

## Next Steps

1. Review and approve this plan
2. Create feature branch for development
3. Implement Phase 1 resources
4. Test in development environment
5. Schedule production migration window

## Questions to Address

1. What size should the EBS volume be initially?
2. What's the acceptable RTO/RPO for PMM?
3. Do we need cross-region backup replication?
4. Should we implement automated restore testing?
5. Any compliance requirements for data retention?
