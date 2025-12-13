# AWS Backup configuration for PMM EBS volume
# Provides automated daily snapshots with configurable retention

# Backup vault for storing snapshots
resource "aws_backup_vault" "pmm" {
  name          = "${local.service_name}-backup-vault"
  kms_key_arn   = var.backup_kms_key_id # Note: Despite the variable name, this needs to be an ARN
  force_destroy = var.backup_vault_force_destroy

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-backup-vault"
      Type = "backup-vault"
    }
  )
}

# Backup plan with daily schedule
resource "aws_backup_plan" "pmm" {
  name = "${local.service_name}-backup-plan"

  rule {
    rule_name         = "daily_backup"
    target_vault_name = aws_backup_vault.pmm.name
    schedule          = var.backup_schedule # Default: "cron(0 5 ? * * *)" - Daily at 5 AM UTC
    start_window      = 60                  # 60 minutes to start backup
    completion_window = 120                 # 120 minutes to complete backup

    lifecycle {
      delete_after = var.backup_retention_days
    }

    recovery_point_tags = merge(
      local.common_tags,
      {
        Type = "daily-backup"
      }
    )
  }

  # Optional: Add weekly backup for longer retention
  dynamic "rule" {
    for_each = var.enable_weekly_backup ? [1] : []
    content {
      rule_name         = "weekly_backup"
      target_vault_name = aws_backup_vault.pmm.name
      schedule          = "cron(0 6 ? * 1 *)" # Weekly on Monday at 6 AM UTC
      start_window      = 60
      completion_window = 180

      lifecycle {
        delete_after = var.weekly_backup_retention_days
      }

      recovery_point_tags = merge(
        local.common_tags,
        {
          Type = "weekly-backup"
        }
      )
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-backup-plan"
    }
  )
}

# IAM role for AWS Backup
resource "aws_iam_role" "backup" {
  name_prefix = "${local.service_name}-backup-"
  description = "IAM role for AWS Backup to manage PMM snapshots"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Attach AWS managed policy for backup operations
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# Attach AWS managed policy for restore operations
resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# Backup selection - which resources to backup
resource "aws_backup_selection" "pmm" {
  name         = "${local.service_name}-backup-selection"
  plan_id      = aws_backup_plan.pmm.id
  iam_role_arn = aws_iam_role.backup.arn

  resources = [
    aws_ebs_volume.pmm_data.arn
  ]

  # Optional: Backup root volume as well
  dynamic "selection_tag" {
    for_each = var.backup_root_volume ? [1] : []
    content {
      type  = "STRINGEQUALS"
      key   = "Backup"
      value = "true"
    }
  }
}

# CloudWatch alarm for backup failures
resource "aws_cloudwatch_metric_alarm" "backup_failed" {
  count = var.enable_backup_alarms ? 1 : 0

  alarm_name          = "${local.service_name}-backup-failed"
  alarm_description   = "Alert when PMM backup fails"
  namespace           = "AWS/Backup"
  metric_name         = "NumberOfBackupJobsFailed"
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    BackupVaultName = aws_backup_vault.pmm.name
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-backup-alarm"
      Type = "backup-monitoring"
    }
  )
}