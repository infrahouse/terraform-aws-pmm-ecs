output "pmm_url" {
  description = "URL to access PMM server"
  value       = "https://${var.dns_names[0]}.${data.aws_route53_zone.selected.name}"
}

output "admin_password_secret_arn" {
  description = "ARN of the admin password secret in Secrets Manager. Use AWS CLI or Console to retrieve the password."
  value       = module.admin_password_secret.secret_arn
}

output "instance_id" {
  description = "ID of the EC2 instance running PMM server"
  value       = aws_instance.pmm_server.id
}

output "instance_private_ip" {
  description = "Private IP address of the PMM server instance"
  value       = aws_instance.pmm_server.private_ip
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.pmm.dns_name
}

output "ebs_volume_id" {
  description = "ID of the EBS volume storing PMM data"
  value       = aws_ebs_volume.pmm_data.id
}

output "backup_vault_name" {
  description = "Name of the AWS Backup vault"
  value       = aws_backup_vault.pmm.name
}

output "alb_logs_bucket_name" {
  description = "Name of the S3 bucket for ALB access logs"
  value       = module.alb_logs_bucket.bucket_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS topic for alarm notifications (null if no emails configured)"
  value       = length(var.alarm_emails) > 0 ? aws_sns_topic.alarms[0].arn : null
}

output "certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS"
  value       = aws_acm_certificate.pmm.arn
}

output "backup_role_arn" {
  description = "ARN of the IAM role used by AWS Backup"
  value       = aws_iam_role.backup.arn
}
