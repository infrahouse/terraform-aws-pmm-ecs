# Required variables
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

# Service configuration
variable "service_name" {
  description = "Name for the PMM service"
  type        = string
  default     = "pmm-server"
}

variable "environment" {
  description = "Environment name (e.g., production, staging, dev)"
  type        = string
}

variable "dns_names" {
  description = "DNS names for PMM (will be created in the Route53 zone)"
  type        = list(string)
  default     = ["pmm"]
}

# PMM configuration
variable "pmm_version" {
  description = <<-EOF
    PMM Docker image version (3 is recommended, PMM 2 EOL July 2025)
  EOF
  type        = string
  default     = "3"
}


variable "disable_telemetry" {
  description = <<-EOF
    Disable PMM telemetry.
    PMM collects anonymous usage data (version, uptime, server count) to help Percona improve the product.
    No sensitive data is collected.
  EOF
  type        = bool
  default     = true
}

# Custom PostgreSQL Queries
variable "postgresql_custom_queries_high_resolution" {
  description = <<-EOF
    Custom PostgreSQL queries for high-resolution collection (executed every few seconds).
    YAML content following PMM custom queries format.
    See: https://docs.percona.com/percona-monitoring-and-management/how-to/extend-metrics.html
  EOF
  type        = string
  default     = null
}

variable "postgresql_custom_queries_medium_resolution" {
  description = <<-EOF
    Custom PostgreSQL queries for medium-resolution collection (executed every minute).
    YAML content following PMM custom queries format.
  EOF
  type        = string
  default     = null
}

variable "postgresql_custom_queries_low_resolution" {
  description = <<-EOF
    Custom PostgreSQL queries for low-resolution collection (executed every few minutes).
    YAML content following PMM custom queries format.
  EOF
  type        = string
  default     = null
}

# Compute resources
variable "instance_type" {
  description = "EC2 instance type for ECS"
  type        = string
  default     = "m5.large"

  validation {
    condition     = can(regex("^(t3|m5|m6i|c5|c6i)\\.(medium|large|xlarge|2xlarge)", var.instance_type))
    error_message = "Instance type should be suitable for PMM workload (min 4GB RAM recommended)"
  }
}

variable "container_cpu" {
  description = "CPU units for PMM container"
  type        = number
  default     = 512
}

variable "container_memory" {
  description = "Memory (MB) for PMM container"
  type        = number
  default     = 4096
}

# EFS configuration
variable "efs_kms_key_id" {
  description = <<-EOF
    KMS key ID for EFS encryption. If null, uses AWS-managed encryption key. EFS is always encrypted.
  EOF
  type        = string
  default     = null
}

variable "efs_performance_mode" {
  description = "EFS performance mode (generalPurpose or maxIO)"
  type        = string
  default     = "generalPurpose"

  validation {
    condition     = contains(["generalPurpose", "maxIO"], var.efs_performance_mode)
    error_message = "EFS performance mode must be either 'generalPurpose' or 'maxIO'"
  }
}

variable "efs_throughput_mode" {
  description = "EFS throughput mode (bursting or provisioned)"
  type        = string
  default     = "bursting"

  validation {
    condition     = contains(["bursting", "provisioned"], var.efs_throughput_mode)
    error_message = "EFS throughput mode must be either 'bursting' or 'provisioned'"
  }
}

variable "efs_transition_to_ia" {
  description = "Days until files are transitioned to Infrequent Access storage class"
  type        = string
  default     = "AFTER_30_DAYS"
}

# Backup configuration
variable "backup_schedule" {
  description = "Cron expression for backup schedule"
  type        = string
  default     = "cron(0 2 * * ? *)" # Daily at 2 AM UTC
}

variable "backup_retention_days" {
  description = "Days to retain EFS backups"
  type        = number
  default     = 365
}

# Monitoring configuration
variable "cloudwatch_log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 365
}

# Health check configuration
variable "healthcheck_interval" {
  description = "Health check interval in seconds"
  type        = number
  default     = 30
}

variable "healthcheck_timeout" {
  description = "Health check timeout in seconds"
  type        = number
  default     = 5
}

# SSH access
variable "ssh_key_name" {
  description = "SSH key name for EC2 instances"
  type        = string
  default     = null
}

variable "admin_cidr_block" {
  description = "CIDR block for admin SSH access"
  type        = string
  default     = null
}

variable "allowed_cidr" {
  description = "List of CIDR blocks allowed to access the PMM ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# Security
variable "rds_security_group_ids" {
  description = <<-EOF
    Security group IDs of RDS instances to monitor (PMM will be granted access)
  EOF
  type        = list(string)
  default     = []
}

# IAM roles for secret access
variable "secret_readers" {
  description = "IAM role ARNs that can read the PMM admin password secret"
  type        = list(string)
  default     = []
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
