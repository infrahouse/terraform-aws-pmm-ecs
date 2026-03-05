# Lambda-based ASG-to-PMM reconciler
# Periodically syncs ASG membership with PMM monitored services.
# Only created when var.monitored_asgs is non-empty.

locals {
  create_reconciler = length(var.monitored_asgs) > 0
}

module "pmm_reconciler" {
  count = local.create_reconciler ? 1 : 0

  source  = "registry.infrahouse.com/infrahouse/lambda-monitored/aws"
  version = "1.0.4"

  function_name     = "${local.service_name_uid}-asg-reconciler"
  lambda_source_dir = "${path.module}/lambda/pmm_reconciler"
  handler           = "main.lambda_handler"
  timeout           = 300
  memory_size       = 512

  environment_variables = {
    PMM_HOST              = aws_instance.pmm_server.private_ip
    PMM_ADMIN_SECRET_ARN  = module.admin_password_secret.secret_arn
    MONITORED_ASGS_CONFIG = jsonencode(var.monitored_asgs)
    PMM_AWS_REGION        = data.aws_region.current.name
  }

  lambda_subnet_ids         = var.private_subnet_ids
  lambda_security_group_ids = [aws_security_group.reconciler_lambda[0].id]
  additional_iam_policy_arns = [
    aws_iam_policy.reconciler[0].arn
  ]

  alarm_emails = var.alarm_emails

  tags = local.common_tags
}

# Security group for Lambda reconciler
resource "aws_security_group" "reconciler_lambda" {
  count = local.create_reconciler ? 1 : 0

  name_prefix = "${local.service_name}-reconciler-"
  description = "Security group for PMM ASG reconciler Lambda"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-reconciler"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Allow Lambda to reach PMM instance on port 80
resource "aws_security_group_rule" "reconciler_to_pmm" {
  count = local.create_reconciler ? 1 : 0

  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pmm_instance.id
  security_group_id        = aws_security_group.reconciler_lambda[0].id
  description              = "Allow Lambda to reach PMM on port 80"
}

# Allow Lambda to reach AWS APIs (Secrets Manager, ASG, EC2) via NAT
resource "aws_security_group_rule" "reconciler_to_aws_apis" {
  count = local.create_reconciler ? 1 : 0

  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.reconciler_lambda[0].id
  description       = "Allow Lambda to reach AWS APIs via NAT"
}

# Allow PMM instance to accept connections from Lambda on port 80
resource "aws_security_group_rule" "pmm_from_reconciler" {
  count = local.create_reconciler ? 1 : 0

  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.reconciler_lambda[0].id
  security_group_id        = aws_security_group.pmm_instance.id
  description              = "Allow PMM ASG reconciler Lambda"
}

# Allow monitored ASG instances to reach PMM on port 443 (pmm-agent gRPC)
resource "aws_security_group_rule" "pmm_from_monitored_asg" {
  count = length(var.monitored_asgs)

  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = var.monitored_asgs[count.index].security_group_id
  security_group_id        = aws_security_group.pmm_instance.id
  description              = "Allow pmm-agent from ${var.monitored_asgs[count.index].asg_name}"
}

# IAM policy for Lambda reconciler
data "aws_iam_policy_document" "reconciler" {
  count = local.create_reconciler ? 1 : 0

  # Describe actions do not support resource-level permissions per AWS docs.
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/aws:autoscaling:groupName"
      values   = [for asg in var.monitored_asgs : asg.asg_name]
    }
  }

  # ssm:GetCommandInvocation does not support resource-level permissions.
  # AWS requires resource = "*". See:
  # https://docs.aws.amazon.com/service-authorization/latest/reference/list_awssystemsmanager.html
  statement {
    effect = "Allow"
    actions = [
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "reconciler" {
  count = local.create_reconciler ? 1 : 0

  name_prefix = "${local.service_name}-reconciler-"
  description = "IAM policy for PMM ASG reconciler Lambda"
  policy      = data.aws_iam_policy_document.reconciler[0].json

  tags = local.common_tags
}

# EventBridge rule to trigger Lambda every 5 minutes
resource "aws_cloudwatch_event_rule" "reconciler" {
  count = local.create_reconciler ? 1 : 0

  name_prefix         = "${local.service_name}-reconciler-"
  description         = "Trigger PMM ASG reconciler every 5 minutes"
  schedule_expression = "rate(5 minutes)"

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "reconciler" {
  count = local.create_reconciler ? 1 : 0

  rule = aws_cloudwatch_event_rule.reconciler[0].name
  arn  = module.pmm_reconciler[0].lambda_function_arn
}

resource "aws_lambda_permission" "reconciler_eventbridge" {
  count = local.create_reconciler ? 1 : 0

  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.pmm_reconciler[0].lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reconciler[0].arn
}
