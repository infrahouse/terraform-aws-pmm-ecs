variable "region" {
  description = "AWS region"
  type        = string
}

variable "role_arn" {
  description = "IAM role ARN to assume for testing"
  type        = string
  default     = null
}

variable "public_subnet_ids" {
  description = "Public subnet IDs"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs"
  type        = list(string)
}

variable "zone_id" {
  description = "Route53 zone ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "test"
}

variable "alarm_emails" {
  description = "Email addresses for alarms"
  type        = list(string)
  default     = ["test@example.com"]
}

# Variables from postgres fixture
variable "postgres_security_group_id" {
  description = "Security group ID from postgres fixture"
  type        = string
}

variable "postgres_endpoint" {
  description = "PostgreSQL RDS endpoint from fixture"
  type        = string
}

variable "postgres_address" {
  description = "PostgreSQL RDS address from fixture"
  type        = string
}

variable "postgres_port" {
  description = "PostgreSQL RDS port from fixture"
  type        = number
}

variable "postgres_database" {
  description = "PostgreSQL database name from fixture"
  type        = string
}

variable "postgres_username" {
  description = "PostgreSQL username from fixture"
  type        = string
}

variable "postgres_password" {
  description = "PostgreSQL password from fixture"
  type        = string
  sensitive   = true
}

# Variables from percona_server fixture
variable "mysql_security_group_id" {
  description = "Security group ID from Percona Server fixture"
  type        = string
}

variable "mysql_address" {
  description = "MySQL NLB DNS name from Percona Server fixture"
  type        = string
}

variable "mysql_port" {
  description = "MySQL port"
  type        = number
  default     = 3306
}

variable "mysql_username" {
  description = "MySQL monitor username"
  type        = string
}

variable "mysql_password" {
  description = "MySQL monitor password"
  type        = string
  sensitive   = true
}
