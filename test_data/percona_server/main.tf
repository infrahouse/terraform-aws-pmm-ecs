module "percona_server" {
  source  = "infrahouse/percona-server/aws"
  version = "0.4.0"

  cluster_id   = "pmm-test"
  environment  = var.environment
  subnet_ids   = var.subnet_ids
  alarm_emails = var.alarm_emails

  s3_force_destroy = true

  tags = {
    created_by = "infrahouse/terraform-aws-pmm-ecs"
  }
}
