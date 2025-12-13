variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for PMM EC2 instance"
  type        = list(string)
}

variable "zone_id" {
  description = "Route53 zone ID for PMM DNS records"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "ssh_key_name" {
  description = "SSH key name for EC2 access"
  type        = string
  default     = null
}