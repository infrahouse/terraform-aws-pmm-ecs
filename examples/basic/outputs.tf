output "pmm_url" {
  description = "URL to access PMM server"
  value       = module.pmm.pmm_url
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret"
  value       = module.pmm.admin_password_secret_arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = module.pmm.ecs_cluster_name
}

output "efs_id" {
  description = "ID of the EFS file system"
  value       = module.pmm.efs_id
}