module "pmm" {
  source = "../.."

  # Network configuration
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids

  # DNS configuration
  zone_id   = var.zone_id
  dns_names = ["pmm"]

  # Required variables
  environment  = var.environment
  alarm_emails = ["devops@example.com", "oncall@example.com"]

  # Custom EBS encryption with customer-managed KMS key
  kms_key_id = aws_kms_key.ebs.id

  # Custom EBS volume configuration for high workload
  ebs_volume_size = 200
  ebs_iops        = 5000
  ebs_throughput  = 250

  # Custom retention periods
  backup_retention_days        = 90
  weekly_backup_retention_days = 730 # 2 years

  # Larger instance for high-volume monitoring
  instance_type = "m5.xlarge"

  # SSH access to EC2 instance
  ssh_key_name = var.ssh_key_name

  # Restrict ALB access to VPN/office network
  allowed_cidr = ["10.0.0.0/8"] # Example: VPN CIDR

  # Enable PMM telemetry
  disable_telemetry = false

  tags = {
    Terraform   = "true"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Customer-managed KMS key for EBS encryption
resource "aws_kms_key" "ebs" {
  description             = "PMM EBS encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "pmm-ebs-key"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "ebs" {
  name          = "alias/pmm-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}