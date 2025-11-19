# Security group for EFS mount targets
resource "aws_security_group" "efs" {
  name_prefix = "${local.service_name}-efs-"
  description = "Security group for PMM EFS mount targets"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-efs"
    }
  )

  lifecycle {
    create_before_destroy = true
  }
}

# Allow NFS traffic from ECS tasks to EFS
resource "aws_vpc_security_group_ingress_rule" "efs_from_ecs" {
  security_group_id = aws_security_group.efs.id
  description       = "Allow NFS from ECS tasks"

  referenced_security_group_id = module.pmm_ecs.backend_security_group
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-efs-from-ecs"
    }
  )
}

# Allow PMM to access RDS instances for monitoring
resource "aws_vpc_security_group_ingress_rule" "rds_from_pmm" {
  for_each          = toset(var.rds_security_group_ids)
  security_group_id = each.key
  description       = "Allow PMM monitoring access"

  referenced_security_group_id = module.pmm_ecs.backend_security_group
  from_port                    = 5432 # PostgreSQL port
  to_port                      = 5432
  ip_protocol                  = "tcp"

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-to-rds"
    }
  )
}

# IAM policy document for ECS task execution role
data "aws_iam_policy_document" "pmm_execution" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${local.cloudwatch_log_group}:*"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      module.admin_password_secret.secret_arn
    ]
  }
}

# IAM policy for ECS task execution role
resource "aws_iam_policy" "pmm_execution" {
  name_prefix = "${local.service_name}-execution-"
  description = "IAM policy for PMM ECS task execution"

  policy = data.aws_iam_policy_document.pmm_execution.json

  tags = local.common_tags
}

# IAM assume role policy for ECS task
data "aws_iam_policy_document" "pmm_task_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

# IAM role for ECS task (runtime permissions)
resource "aws_iam_role" "pmm_task" {
  name_prefix = "${local.service_name}-task-"
  description = "IAM role for PMM ECS task"

  assume_role_policy = data.aws_iam_policy_document.pmm_task_assume_role.json

  tags = local.common_tags
}

# Generate random admin password
resource "random_password" "admin" {
  length  = 32
  special = true
}

# Admin password secret using InfraHouse secret module
module "admin_password_secret" {
  source  = "infrahouse/secret/aws"
  version = "1.1.1"

  secret_name        = "${local.service_name}-admin-password"
  secret_description = "PMM admin password for ${local.service_name}"
  secret_value       = random_password.admin.result
  environment        = var.environment

  readers = concat(
    var.secret_readers,
    [aws_iam_role.pmm_task.arn]
  )

  tags = local.common_tags
}
