output "pmm_url" {
  description = "URL to access PMM server"
  value       = "https://${var.dns_names[0]}.${data.aws_route53_zone.selected.name}"
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret in Secrets Manager. Use AWS CLI or Console to retrieve the password."
  value       = module.admin_password_secret.secret_arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group running PMM server"
  value       = module.pmm_pod.asg_name
}
