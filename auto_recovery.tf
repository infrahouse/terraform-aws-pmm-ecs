# Auto-recovery configuration for PMM EC2 instance
# This ensures high availability by automatically recovering failed instances

# Primary auto-recovery alarm - triggers EC2 auto-recovery
resource "aws_cloudwatch_metric_alarm" "pmm_system_auto_recovery" {
  count = var.enable_auto_recovery ? 1 : 0

  alarm_name          = "${local.service_name}-system-auto-recovery"
  alarm_description   = "Auto recover PMM instance when underlying hardware fails"
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

  # Auto-recovery action
  alarm_actions = ["arn:aws:automate:${data.aws_region.current.name}:ec2:recover"]

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-system-recovery"
      Type = "auto-recovery"
    }
  )
}

# Instance status check alarm - alerts but doesn't auto-recover
resource "aws_cloudwatch_metric_alarm" "pmm_instance_check" {
  alarm_name          = "${local.service_name}-instance-status-check"
  alarm_description   = "Alert when PMM instance fails status checks (software/network issues)"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_Instance"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
  }

  # Send notifications but don't auto-recover (instance issues often need investigation)
  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-instance-check"
      Type = "monitoring"
    }
  )
}

# Combined status check alarm - alerts on any failure
resource "aws_cloudwatch_metric_alarm" "pmm_status_check_failed" {
  alarm_name          = "${local.service_name}-status-check-failed"
  alarm_description   = "Alert when PMM instance fails any status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-status-check"
      Type = "monitoring"
    }
  )
}

# High memory usage alarm
resource "aws_cloudwatch_metric_alarm" "pmm_high_memory" {
  count = var.enable_detailed_monitoring ? 1 : 0

  alarm_name          = "${local.service_name}-high-memory"
  alarm_description   = "Alert when PMM instance memory usage is high"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-memory-usage"
      Type = "monitoring"
    }
  )
}

# Disk space alarm for root volume
resource "aws_cloudwatch_metric_alarm" "pmm_root_disk_space" {
  count = var.enable_detailed_monitoring ? 1 : 0

  alarm_name          = "${local.service_name}-root-disk-space"
  alarm_description   = "Alert when root volume disk space is low"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
    device     = local.root_device_name
    fstype     = "ext4"
    path       = "/"
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-root-disk"
      Type = "monitoring"
    }
  )
}

# Disk space alarm for data volume
resource "aws_cloudwatch_metric_alarm" "pmm_data_disk_space" {
  count = var.enable_detailed_monitoring ? 1 : 0

  alarm_name          = "${local.service_name}-data-disk-space"
  alarm_description   = "Alert when data volume disk space is low"
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.pmm_server.id
    device     = local.data_device_name
    fstype     = "ext4"
    path       = "/srv"
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-data-disk"
      Type = "monitoring"
    }
  )
}

# EBS burst balance alarm
resource "aws_cloudwatch_metric_alarm" "pmm_ebs_burst_balance" {
  count = var.enable_detailed_monitoring && var.ebs_volume_type == "gp3" ? 1 : 0

  alarm_name          = "${local.service_name}-ebs-burst-balance"
  alarm_description   = "Alert when EBS volume burst balance is low"
  namespace           = "AWS/EBS"
  metric_name         = "BurstBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 20
  comparison_operator = "LessThanThreshold"

  dimensions = {
    VolumeId = aws_ebs_volume.pmm_data.id
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-burst-balance"
      Type = "monitoring"
    }
  )
}

# CloudWatch dashboard for monitoring
resource "aws_cloudwatch_dashboard" "pmm_monitoring" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${local.service_name}-monitoring"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title = "EC2 Instance Status"
          metrics = [
            ["AWS/EC2", "StatusCheckFailed", "InstanceId", aws_instance.pmm_server.id, { stat = "Maximum", label = "Total Failures" }],
            ["AWS/EC2", "StatusCheckFailed_System", "InstanceId", aws_instance.pmm_server.id, { stat = "Maximum", label = "System Failures" }],
            ["AWS/EC2", "StatusCheckFailed_Instance", "InstanceId", aws_instance.pmm_server.id, { stat = "Maximum", label = "Instance Failures" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title = "CPU and Memory Utilization"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.pmm_server.id, { stat = "Average", label = "CPU %" }],
            ["CWAgent", "mem_used_percent", ".", ".", { stat = "Average", label = "Memory %" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title = "Disk Usage"
          metrics = [
            ["CWAgent", "disk_used_percent", "device", local.root_device_name, "fstype", "ext4", "path", "/", "InstanceId", aws_instance.pmm_server.id, { stat = "Average", label = "Root Volume" }],
            ["CWAgent", "disk_used_percent", "device", local.data_device_name, "fstype", "ext4", "path", "/srv", "InstanceId", aws_instance.pmm_server.id, { stat = "Average", label = "Data Volume" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title = "EBS Volume Performance"
          metrics = [
            ["AWS/EBS", "VolumeReadOps", "VolumeId", aws_ebs_volume.pmm_data.id, { stat = "Sum", label = "Read Ops" }],
            [".", "VolumeWriteOps", ".", ".", { stat = "Sum", label = "Write Ops" }],
            [".", "BurstBalance", ".", ".", { stat = "Average", label = "Burst Balance %" }]
          ]
          period = 300
          stat   = "Average"
          region = data.aws_region.current.name
          view   = "timeSeries"
        }
      }
    ]
  })
}