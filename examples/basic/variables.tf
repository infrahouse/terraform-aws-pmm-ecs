variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks and EFS"
  type        = list(string)
}

variable "zone_id" {
  description = "Route53 zone ID for PMM DNS records"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "development"
}