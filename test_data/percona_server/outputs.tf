output "nlb_dns_name" {
  description = "DNS name of the Network Load Balancer"
  value       = module.percona_server.nlb_dns_name
}

output "writer_endpoint" {
  description = "MySQL writer endpoint (host:port)"
  value       = module.percona_server.writer_endpoint
}

output "reader_endpoint" {
  description = "MySQL reader endpoint (host:port)"
  value       = module.percona_server.reader_endpoint
}

output "security_group_id" {
  description = "ID of the Percona cluster security group"
  value       = module.percona_server.security_group_id
}

output "mysql_credentials_secret_arn" {
  description = "ARN of the Secrets Manager secret containing MySQL credentials"
  value       = module.percona_server.mysql_credentials_secret_arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group"
  value       = module.percona_server.asg_name
}
