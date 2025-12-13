# Required variables
variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = <<-EOF
    Private subnet IDs for ECS tasks and EFS
  EOF
  type        = list(string)
}

variable "zone_id" {
  description = <<-EOF
    Route53 zone ID for PMM DNS records
  EOF
  type        = string
}

# Service configuration
variable "service_name" {
  description = "Name for the PMM service"
  type        = string
  default     = "pmm-server"
}

variable "environment" {
  description = <<-EOF
    Environment name (e.g., production, staging, dev)
  EOF
  type        = string
}

variable "dns_names" {
  description = <<-EOF
    DNS names for PMM (will be created in the Route53 zone)
  EOF
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

# EBS Volume Configuration
variable "ebs_volume_size" {
  description = "Size of the EBS data volume in GB"
  type        = number
  default     = 100
}

variable "ebs_volume_type" {
  description = <<-EOF
    Type of the EBS data volume (gp3, gp2, io1, io2)
  EOF
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "gp2", "io1", "io2"], var.ebs_volume_type)
    error_message = "EBS volume type must be one of: gp3, gp2, io1, io2"
  }
}

variable "ebs_iops" {
  description = <<-EOF
    IOPS for the EBS data volume (only for gp3, io1, io2)
  EOF
  type        = number
  default     = 3000
}

variable "ebs_throughput" {
  description = <<-EOF
    Throughput for the EBS data volume in MB/s (only for gp3)
  EOF
  type        = number
  default     = 125
}

variable "root_volume_size" {
  description = "Size of the root volume in GB"
  type        = number
  default     = 20
}

variable "kms_key_id" {
  description = <<-EOF
    KMS key ID for EBS encryption. If null, uses AWS-managed key
  EOF
  type        = string
  default     = null
}

variable "create_initial_snapshot" {
  description = <<-EOF
    Create an initial snapshot of the EBS volume after attachment
  EOF
  type        = bool
  default     = false
}

# EC2 Configuration
variable "enable_auto_recovery" {
  description = <<-EOF
    Enable EC2 auto-recovery for hardware failures
  EOF
  type        = bool
  default     = true
}

variable "enable_detailed_monitoring" {
  description = <<-EOF
    Enable detailed monitoring (CloudWatch Agent metrics for memory and disk usage)
  EOF
  type        = bool
  default     = true
}

# ALB Configuration
variable "certificate_issuers" {
  description = <<-EOF
    List of certificate authority domains allowed to issue certificates for this domain (e.g., ["amazon.com", "letsencrypt.org"]). The module will format these as CAA records.
  EOF
  type        = list(string)
  default     = ["amazon.com"]
}

variable "additional_certificate_arns" {
  description = <<-EOF
    Additional ACM certificate ARNs for ALB
  EOF
  type        = list(string)
  default     = []
}

variable "ssl_policy" {
  description = "SSL policy for HTTPS listener"
  type        = string
  default     = "ELBSecurityPolicy-TLS-1-2-2017-01"
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for the ALB"
  type        = bool
  default     = false
}

variable "alb_logs_retention_days" {
  description = "Days to retain ALB access logs in S3"
  type        = number
  default     = 365
}

variable "alb_logs_bucket_force_destroy" {
  description = <<-EOF
    Allow deletion of S3 bucket with objects. Set to true for test environments only.
  EOF
  type        = bool
  default     = false
}

# Monitoring
variable "alarm_emails" {
  description = <<-EOF
    List of email addresses to receive alarm notifications. AWS will send confirmation emails that must be accepted.
    At least one email is required.
  EOF
  type        = list(string)

  validation {
    condition     = length(var.alarm_emails) > 0
    error_message = "At least one email address must be provided for alarm notifications"
  }
}

variable "alarm_topic_arns" {
  description = <<-EOF
    List of existing SNS topic ARNs to send alarms to (for advanced integrations like PagerDuty, Slack, etc.)
  EOF
  type        = list(string)
  default     = []
}

variable "sns_topic_name" {
  description = <<-EOF
    Name for the SNS topic. If not provided, defaults to '<service_name>-alarms'
  EOF
  type        = string
  default     = null
}

variable "create_dashboard" {
  description = <<-EOF
    Create CloudWatch dashboard for monitoring
  EOF
  type        = bool
  default     = true
}

# Backup configuration
variable "backup_schedule" {
  description = "Cron expression for backup schedule"
  type        = string
  default     = "cron(0 5 ? * * *)" # Daily at 5 AM UTC
}

variable "backup_retention_days" {
  description = "Days to retain daily backups"
  type        = number
  default     = 30
}

variable "backup_vault_force_destroy" {
  description = <<-EOF
    Allow deletion of backup vault with recovery points. Set to true for test environments only.
  EOF
  type        = bool
  default     = false
}

variable "backup_kms_key_id" {
  description = <<-EOF
    KMS key ARN for backup vault encryption. If null, uses AWS-managed key
  EOF
  type        = string
  default     = null
}

variable "enable_weekly_backup" {
  description = <<-EOF
    Enable weekly backups with longer retention
  EOF
  type        = bool
  default     = false
}

variable "weekly_backup_retention_days" {
  description = <<-EOF
    Days to retain weekly backups
  EOF
  type        = number
  default     = 90
}

variable "backup_root_volume" {
  description = <<-EOF
    Also backup the root volume (via tags)
  EOF
  type        = bool
  default     = false
}

variable "enable_backup_alarms" {
  description = <<-EOF
    Enable CloudWatch alarms for backup failures
  EOF
  type        = bool
  default     = true
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
  description = <<-EOF
    List of CIDR blocks allowed to access the PMM ALB
  EOF
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
  description = <<-EOF
    IAM role ARNs that can read the PMM admin password secret
  EOF
  type        = list(string)
  default     = []
}

# Tags
variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
