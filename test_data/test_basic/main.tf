module "pmm" {
  source = "../.."

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids
  zone_id            = var.zone_id
  environment        = var.environment

  service_name = "pmm-ecs-test"

  # Grant PMM access to the test PostgreSQL instance (from pytest-infrahouse fixture)
  rds_security_group_ids = [
    var.postgres_security_group_id
  ]

  # Use shorter retention for tests
  backup_retention_days         = 7
  cloudwatch_log_retention_days = 7
  alb_logs_retention_days       = 7

  # Enable force destroy for test cleanup
  backup_vault_force_destroy     = true
  alb_logs_bucket_force_destroy  = true

  # Alarm notifications
  alarm_emails = var.alarm_emails

  # custom queries
  postgresql_custom_queries_medium_resolution = file("${path.module}/queries/pg-med-res.yml")
}

# Data source to read the actual admin password from Secrets Manager
data "aws_secretsmanager_secret_version" "admin_password" {
  secret_id = module.pmm.admin_password_secret_arn

  depends_on = [module.pmm]
}
