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

  # Grant PMM access to the test PostgreSQL instance
  rds_security_group_ids = [
    aws_security_group.test_postgres.id
  ]

  # Use shorter retention for tests
  backup_retention_days         = 7
  cloudwatch_log_retention_days = 7

}
