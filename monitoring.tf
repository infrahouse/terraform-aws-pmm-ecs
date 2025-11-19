# SNS Topic for alarms
resource "aws_sns_topic" "pmm_alarms" {
  name_prefix = "${local.service_name}-alarms-"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-alarms"
    }
  )
}

# SNS Topic subscription
resource "aws_sns_topic_subscription" "pmm_alarms" {
  for_each = toset(var.alarm_emails)

  topic_arn = aws_sns_topic.pmm_alarms.arn
  protocol  = "email"
  endpoint  = each.key
}

# CloudWatch Alarm: ECS Service Running Count
resource "aws_cloudwatch_metric_alarm" "ecs_service_running" {
  alarm_name          = "${local.service_name}-ecs-service-running"
  alarm_description   = "PMM ECS service is not running the desired number of tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    ServiceName = local.service_name
    ClusterName = local.service_name
  }

  alarm_actions = [aws_sns_topic.pmm_alarms.arn]

  tags = local.common_tags
}

# CloudWatch Alarm: Target Health
resource "aws_cloudwatch_metric_alarm" "target_health" {
  alarm_name          = "${local.service_name}-target-health"
  alarm_description   = "PMM target group has unhealthy targets"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = {
    TargetGroup  = local.target_group_arn_suffix
    LoadBalancer = local.load_balancer_arn_suffix
  }

  alarm_actions = [aws_sns_topic.pmm_alarms.arn]

  tags = local.common_tags
}

# CloudWatch Alarm: EFS Burst Credit Balance
resource "aws_cloudwatch_metric_alarm" "efs_burst_credit" {
  count = var.efs_throughput_mode == "bursting" ? 1 : 0

  alarm_name          = "${local.service_name}-efs-burst-credit"
  alarm_description   = "PMM EFS burst credit balance is low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "BurstCreditBalance"
  namespace           = "AWS/EFS"
  period              = 300
  statistic           = "Average"
  threshold           = 1000000000000 # 1TB in bytes
  treat_missing_data  = "notBreaching"

  dimensions = {
    FileSystemId = aws_efs_file_system.pmm_data.id
  }

  alarm_actions = [aws_sns_topic.pmm_alarms.arn]

  tags = local.common_tags
}

# CloudWatch Alarm: ALB 5XX errors
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.service_name}-alb-5xx-errors"
  alarm_description   = "PMM ALB is returning 5XX errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.load_balancer_arn_suffix
  }

  alarm_actions = [aws_sns_topic.pmm_alarms.arn]

  tags = local.common_tags
}
