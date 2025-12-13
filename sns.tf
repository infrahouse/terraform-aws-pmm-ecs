# SNS topic for CloudWatch alarms

locals {
  sns_topic_name = var.sns_topic_name != null ? var.sns_topic_name : "${local.service_name}-alarms"
  # Combine email-based topic and external topic ARNs
  all_alarm_targets = concat(
    length(var.alarm_emails) > 0 ? [aws_sns_topic.alarms[0].arn] : [],
    var.alarm_topic_arns
  )
}

# SNS topic for alarm notifications (created only if emails are provided)
resource "aws_sns_topic" "alarms" {
  count = length(var.alarm_emails) > 0 ? 1 : 0

  name              = local.sns_topic_name
  display_name      = "PMM Server Alarms"
  kms_master_key_id = var.kms_key_id

  tags = merge(
    local.common_tags,
    {
      Name = local.sns_topic_name
    }
  )
}

# Email subscriptions for the alarm topic
resource "aws_sns_topic_subscription" "alarm_emails" {
  for_each = length(var.alarm_emails) > 0 ? toset(var.alarm_emails) : []

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = each.value
}