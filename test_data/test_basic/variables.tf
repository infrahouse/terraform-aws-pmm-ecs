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
