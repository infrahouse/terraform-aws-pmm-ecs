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

output "instance_id" {
  description = "ID of the EC2 instance running PMM server"
  value       = module.pmm.instance_id
}

output "ebs_volume_id" {
  description = "ID of the EBS volume storing PMM data"
  value       = module.pmm.ebs_volume_id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.pmm.alb_dns_name
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

output "backup_vault_name" {
  description = "Name of the AWS Backup vault"
  value       = module.pmm.backup_vault_name
}

output "backup_role_arn" {
  description = "ARN of the IAM role used by AWS Backup"
  value       = module.pmm.backup_role_arn
}
