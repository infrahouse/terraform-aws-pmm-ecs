resource "random_id" "this" {
  byte_length = 4
}

module "percona_server" {
  source  = "registry.infrahouse.com/infrahouse/percona-server/aws"
  version = "0.6.0"

  cluster_id   = "pmm-test-${random_id.this.hex}"
  environment  = var.environment
  subnet_ids   = var.subnet_ids
  alarm_emails = var.alarm_emails

  s3_force_destroy = true

  tags = {
    created_by = "infrahouse/terraform-aws-pmm-ecs"
  }
}
