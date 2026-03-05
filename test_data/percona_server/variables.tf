variable "region" {
  description = "AWS region"
  type        = string
}

variable "role_arn" {
  description = "IAM role ARN to assume for testing"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Subnet IDs for the Percona Server cluster"
  type        = list(string)
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

