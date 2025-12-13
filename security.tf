# IAM policy document for EC2 instance
data "aws_iam_policy_document" "pmm_instance" {
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

  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData"
    ]
    resources = ["*"]
  }
}

# IAM policy for EC2 instance
resource "aws_iam_policy" "pmm_instance" {
  name_prefix = "${local.service_name}-instance-"
  description = "IAM policy for PMM EC2 instance"

  policy = data.aws_iam_policy_document.pmm_instance.json

  tags = local.common_tags
}

# Note: IAM role policy attachment is now handled in ec2.tf
# The aws_iam_role_policy_attachment.pmm_custom resource attaches this policy

# Allow PMM to access RDS instances on port 5432 (PostgreSQL)
resource "aws_security_group_rule" "pmm_to_rds_postgres" {
  count = length(var.rds_security_group_ids)

  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pmm_instance.id
  security_group_id        = var.rds_security_group_ids[count.index]
  description              = "Allow PMM server to connect to PostgreSQL"
}

# Generate random admin password
resource "random_password" "admin" {
  length  = 32
  special = false
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
    [
      aws_iam_role.pmm_instance.arn,
    ]
  )

  tags = local.common_tags
}
