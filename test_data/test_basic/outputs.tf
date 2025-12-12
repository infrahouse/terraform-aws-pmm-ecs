# Outputs for testing
output "pmm_url" {
  description = "URL to access PMM server"
  value       = module.pmm.pmm_url
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret in Secrets Manager"
  value       = module.pmm.admin_password_secret_arn
}

output "admin_password" {
  description = "PMM admin password (for testing purposes)"
  value       = data.aws_secretsmanager_secret_version.admin_password.secret_string
  sensitive   = true
}

output "asg_name" {
  description = "Name of the Auto Scaling Group running PMM server"
  value       = module.pmm.asg_name
}

output "postgres_endpoint" {
  description = "PostgreSQL RDS endpoint"
  value       = var.postgres_endpoint
}

output "postgres_address" {
  description = "PostgreSQL RDS address (without port)"
  value       = var.postgres_address
}

output "postgres_port" {
  description = "PostgreSQL RDS port"
  value       = var.postgres_port
}

output "postgres_database" {
  description = "PostgreSQL database name"
  value       = var.postgres_database
}

output "postgres_username" {
  description = "PostgreSQL username"
  value       = var.postgres_username
  sensitive   = true
}

output "postgres_password" {
  description = "PostgreSQL password"
  value       = var.postgres_password
  sensitive   = true
}
