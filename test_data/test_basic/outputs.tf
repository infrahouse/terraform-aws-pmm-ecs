# Outputs for testing
output "pmm_url" {
  description = "URL to access PMM server"
  value       = module.pmm.pmm_url
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret in Secrets Manager"
  value       = module.pmm.admin_password_secret_arn
}

output "postgres_endpoint" {
  description = "PostgreSQL RDS endpoint"
  value       = aws_db_instance.test_postgres.endpoint
}

output "postgres_address" {
  description = "PostgreSQL RDS address (without port)"
  value       = aws_db_instance.test_postgres.address
}

output "postgres_port" {
  description = "PostgreSQL RDS port"
  value       = aws_db_instance.test_postgres.port
}

output "postgres_database" {
  description = "PostgreSQL database name"
  value       = aws_db_instance.test_postgres.db_name
}

output "postgres_username" {
  description = "PostgreSQL username"
  value       = aws_db_instance.test_postgres.username
  sensitive   = true
}

output "postgres_password" {
  description = "PostgreSQL password"
  value       = random_password.postgres_password.result
  sensitive   = true
}
