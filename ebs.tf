# Persistent EBS volume for PMM data storage
resource "aws_ebs_volume" "pmm_data" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.ebs_volume_size
  type              = var.ebs_volume_type
  iops              = var.ebs_volume_type == "gp3" ? var.ebs_iops : null
  throughput        = var.ebs_volume_type == "gp3" ? var.ebs_throughput : null
  encrypted         = true
  kms_key_id        = var.kms_key_id

  # Enable final snapshot before deletion
  final_snapshot = true

  tags = merge(
    local.common_tags,
    {
      Name        = "${local.service_name}-data"
      Type        = "pmm-persistent-data"
      Environment = var.environment
      Backup      = "true"
    }
  )

  # Note: prevent_destroy is set to false to allow CI/CD test cleanup.
  # Data protection is provided by AWS Backup with daily snapshots (30-day retention).
  # For production deployments, rely on backup/restore procedures rather than lifecycle rules.
  # See docs/BACKUP_RESTORE.md for recovery procedures.
  lifecycle {
    prevent_destroy = false
  }
}

# Attach the EBS volume to EC2 instance
resource "aws_volume_attachment" "pmm_data" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.pmm_data.id
  instance_id = aws_instance.pmm_server.id

  # Don't force detach on destroy to prevent data loss
  force_detach = false

  # Stop instance before detaching (safer)
  stop_instance_before_detaching = true
}

# CloudWatch alarm for EBS volume burst balance (for gp2 volumes)
resource "aws_cloudwatch_metric_alarm" "ebs_burst_balance" {
  count = var.ebs_volume_type == "gp2" ? 1 : 0

  alarm_name          = "${local.service_name}-ebs-burst-balance"
  alarm_description   = "Alert when EBS burst balance is low"
  namespace           = "AWS/EBS"
  metric_name         = "BurstBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "LessThanThreshold"

  dimensions = {
    VolumeId = aws_ebs_volume.pmm_data.id
  }

  alarm_actions = local.all_alarm_targets

  tags = local.common_tags
}

# CloudWatch alarm for EBS volume read/write ops (performance monitoring)
resource "aws_cloudwatch_metric_alarm" "ebs_high_iops" {
  alarm_name          = "${local.service_name}-ebs-high-iops"
  alarm_description   = "Alert when EBS IOPS usage is high"
  namespace           = "AWS/EBS"
  metric_name         = "VolumeReadOps"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.ebs_iops * 300 * 0.8  # 80% of provisioned IOPS over 5 minutes
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    VolumeId = aws_ebs_volume.pmm_data.id
  }

  alarm_actions = local.all_alarm_targets

  tags = local.common_tags
}

# EBS snapshot for initial backup (optional)
resource "aws_ebs_snapshot" "pmm_data_initial" {
  count = var.create_initial_snapshot ? 1 : 0

  volume_id   = aws_ebs_volume.pmm_data.id
  description = "Initial snapshot of ${local.service_name} data volume"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-initial-snapshot"
      Type = "initial-backup"
    }
  )

  # Create snapshot after volume is attached and potentially formatted
  depends_on = [aws_volume_attachment.pmm_data]

  lifecycle {
    ignore_changes = [volume_id, description]
  }
}