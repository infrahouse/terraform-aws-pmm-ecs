# S3 bucket for ALB access logs

# Data source for ELB service account (region-specific)
data "aws_elb_service_account" "main" {}

module "alb_logs_bucket" {
  source  = "infrahouse/s3-bucket/aws"
  version = "0.3.0"

  bucket_name = "${local.service_name}-alb-logs-${data.aws_caller_identity.current.account_id}"

  # ALB logging requires specific bucket policy
  bucket_policy = data.aws_iam_policy_document.alb_logs.json

  force_destroy = var.alb_logs_bucket_force_destroy

  tags = local.common_tags
}

# Bucket policy to allow ALB to write access logs
data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
    actions = [
      "s3:PutObject"
    ]
    resources = [
      "arn:aws:s3:::${local.service_name}-alb-logs-${data.aws_caller_identity.current.account_id}/*"
    ]
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["elasticloadbalancing.amazonaws.com"]
    }
    actions = [
      "s3:GetBucketAcl"
    ]
    resources = [
      "arn:aws:s3:::${local.service_name}-alb-logs-${data.aws_caller_identity.current.account_id}"
    ]
  }
}

# Lifecycle rule to manage log retention
resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = module.alb_logs_bucket.bucket_name

  rule {
    id     = "delete-old-logs"
    status = "Enabled"

    expiration {
      days = var.alb_logs_retention_days
    }
  }
}
