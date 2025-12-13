# Application Load Balancer configuration for PMM

# ALB Security Group
resource "aws_security_group" "pmm_alb" {
  name_prefix = "${local.service_name}-alb-"
  description = "Security group for PMM Application Load Balancer"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-alb"
    }
  )
}

# Allow HTTPS inbound traffic
resource "aws_security_group_rule" "pmm_alb_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr
  security_group_id = aws_security_group.pmm_alb.id
  description       = "Allow HTTPS from allowed CIDRs"
}

# Allow HTTP inbound traffic (for redirect to HTTPS)
resource "aws_security_group_rule" "pmm_alb_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = var.allowed_cidr
  security_group_id = aws_security_group.pmm_alb.id
  description       = "Allow HTTP from allowed CIDRs (for redirect)"
}

# Allow all outbound traffic
resource "aws_security_group_rule" "pmm_alb_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.pmm_alb.id
  description       = "Allow all outbound traffic"
}

# Application Load Balancer
resource "aws_lb" "pmm" {
  name_prefix        = substr(local.service_name, 0, 6) # ALB names have a 32 char limit, prefix is 6 chars
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.pmm_alb.id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.enable_deletion_protection
  enable_http2              = true
  enable_cross_zone_load_balancing = true

  # Access logs
  access_logs {
    bucket  = module.alb_logs_bucket.bucket_name
    prefix  = local.service_name
    enabled = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-alb"
    }
  )
}

# Target Group for PMM instance
resource "aws_lb_target_group" "pmm" {
  name_prefix = substr(local.service_name, 0, 6)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.selected.id
  target_type = "instance"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/v1/readyz"
    matcher             = "200"
    port                = "traffic-port"
    protocol            = "HTTP"
  }

  deregistration_delay = 30

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 86400
    enabled         = true
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-tg"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Attach EC2 instance to target group
resource "aws_lb_target_group_attachment" "pmm" {
  target_group_arn = aws_lb_target_group.pmm.arn
  target_id        = aws_instance.pmm_server.id
  port             = 80
}

# HTTP listener (redirects to HTTPS)
resource "aws_lb_listener" "pmm_http" {
  load_balancer_arn = aws_lb.pmm.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-http-listener"
    }
  )
}

# HTTPS listener
resource "aws_lb_listener" "pmm_https" {
  load_balancer_arn = aws_lb.pmm.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = var.ssl_policy
  certificate_arn   = aws_acm_certificate.pmm.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.pmm.arn
  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-https-listener"
    }
  )

  depends_on = [
    aws_acm_certificate_validation.pmm
  ]
}

# Additional SSL certificates (optional)
resource "aws_lb_listener_certificate" "pmm" {
  for_each = toset(var.additional_certificate_arns)

  listener_arn    = aws_lb_listener.pmm_https.arn
  certificate_arn = each.value
}

# Route53 A record for ALB
resource "aws_route53_record" "pmm" {
  provider = aws.dns
  for_each = toset(var.dns_names)

  zone_id = var.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = aws_lb.pmm.dns_name
    zone_id                = aws_lb.pmm.zone_id
    evaluate_target_health = true
  }
}

# CloudWatch alarms for ALB
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.service_name}-alb-unhealthy-hosts"
  alarm_description   = "Alert when PMM instance is unhealthy"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    LoadBalancer = aws_lb.pmm.arn_suffix
    TargetGroup  = aws_lb_target_group.pmm.arn_suffix
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-unhealthy-alarm"
      Type = "alb-monitoring"
    }
  )
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${local.service_name}-alb-response-time"
  alarm_description   = "Alert when PMM response time is high"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 2
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    LoadBalancer = aws_lb.pmm.arn_suffix
  }

  alarm_actions = local.all_alarm_targets

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-response-time-alarm"
      Type = "alb-monitoring"
    }
  )
}