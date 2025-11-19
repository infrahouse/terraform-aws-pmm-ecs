output "pmm_url" {
  description = "URL to access PMM server"
  value       = "https://${var.dns_names[0]}.${data.aws_route53_zone.selected.name}"
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = local.service_name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = local.service_name
}

output "efs_id" {
  description = "ID of the EFS file system"
  value       = aws_efs_file_system.pmm_data.id
}

output "efs_arn" {
  description = "ARN of the EFS file system"
  value       = aws_efs_file_system.pmm_data.arn
}

output "load_balancer_arn" {
  description = "ARN of the Application Load Balancer"
  value       = module.pmm_ecs.load_balancer_arn
}

output "load_balancer_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.pmm_ecs.load_balancer_dns_name
}

output "target_group_arn" {
  description = "ARN of the target group"
  value       = local.target_group_arn
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret in Secrets Manager. Use AWS CLI or Console to retrieve the password."
  value       = module.admin_password_secret.secret_arn
}

output "security_group_id" {
  description = "Security group ID for the PMM ECS tasks"
  value       = module.pmm_ecs.backend_security_group
}

output "efs_security_group_id" {
  description = "Security group ID for the EFS mount targets"
  value       = aws_security_group.efs.id
}
