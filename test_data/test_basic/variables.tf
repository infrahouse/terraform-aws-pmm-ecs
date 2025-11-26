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
