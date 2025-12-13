output "pmm_url" {
  description = "URL to access PMM server"
  value       = module.pmm.pmm_url
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret"
  value       = module.pmm.admin_password_secret_arn
}

output "instance_id" {
  description = "EC2 instance ID running PMM"
  value       = module.pmm.instance_id
}

output "instance_private_ip" {
  description = "Private IP of PMM instance"
  value       = module.pmm.instance_private_ip
}

output "ebs_volume_id" {
  description = "EBS volume ID for PMM data"
  value       = module.pmm.ebs_volume_id
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = module.pmm.alb_dns_name
}

output "backup_vault_name" {
  description = "AWS Backup vault name"
  value       = module.pmm.backup_vault_name
}