# S3 bucket for ALB access logs

# Data source for ELB service account (region-specific)
data "aws_elb_service_account" "main" {}

module "alb_logs_bucket" {
  source  = "registry.infrahouse.com/infrahouse/s3-bucket/aws"
  version = "0.3.0"

  bucket_prefix = "${local.service_name}-alb-logs-"

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
      "${module.alb_logs_bucket.bucket_arn}/*"
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
      module.alb_logs_bucket.bucket_arn
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

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
