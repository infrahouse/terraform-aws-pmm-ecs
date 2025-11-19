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

  # RDS monitoring configuration
  # PMM will be granted access to these RDS security groups on port 5432
  rds_security_group_ids = [
    aws_security_group.rds_postgres.id,
  ]

  # Grant RDS instances read access to the PMM admin password
  # This allows automated setup of PMM client on RDS
  secret_readers = [
    aws_iam_role.rds_monitoring.arn,
  ]

  tags = {
    Terraform   = "true"
    Environment = var.environment
  }
}

# Example RDS security group
resource "aws_security_group" "rds_postgres" {
  name_prefix = "rds-postgres-"
  description = "Security group for RDS PostgreSQL instance"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "rds-postgres"
    Environment = var.environment
  }
}

# Example IAM role for RDS monitoring
resource "aws_iam_role" "rds_monitoring" {
  name_prefix = "rds-pmm-monitoring-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "rds-pmm-monitoring"
    Environment = var.environment
  }
}

# Data source to get VPC from subnets
data "aws_subnet" "selected" {
  id = var.private_subnet_ids[0]
}

data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
}