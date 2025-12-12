module "pmm" {
  source = "../.."

  # Network configuration
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids

  # DNS configuration
  zone_id   = var.zone_id
  dns_names = ["pmm"]

  # Required variables
  environment = var.environment

  # Custom EFS encryption with customer-managed KMS key
  efs_kms_key_id = aws_kms_key.efs.id

  # Custom retention periods
  backup_retention_days         = 90
  cloudwatch_log_retention_days = 90

  # Custom compute resources
  instance_type    = "m5.xlarge"
  container_cpu    = 4096
  container_memory = 8192

  # SSH access to EC2 instances
  ssh_key_name      = var.ssh_key_name
  admin_cidr_blocks = var.admin_cidr_blocks

  # Enable PMM telemetry
  disable_telemetry = false

  tags = {
    Terraform   = "true"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Customer-managed KMS key for EFS encryption
resource "aws_kms_key" "efs" {
  description             = "PMM EFS encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name        = "pmm-efs-key"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "efs" {
  name          = "alias/pmm-efs"
  target_key_id = aws_kms_key.efs.key_id
}