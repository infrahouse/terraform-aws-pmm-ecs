# Data sources for VPC information
data "aws_subnet" "selected" {
  id = var.private_subnet_ids[0]
}

data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
}

# Test PostgreSQL RDS instance for PMM monitoring
resource "aws_security_group" "test_postgres" {
  name_prefix = "test-postgres-"
  description = "Security group for test PostgreSQL RDS instance"
  vpc_id      = data.aws_vpc.selected.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "test-postgres-pmm"
    Environment = var.environment
  }
}

resource "aws_db_subnet_group" "test_postgres" {
  name_prefix = "test-postgres-"
  subnet_ids  = var.private_subnet_ids

  tags = {
    Name        = "test-postgres-pmm"
    Environment = var.environment
  }
}

resource "random_password" "postgres_password" {
  length  = 32
  special = false # Avoid special characters for simplicity
}

# IAM role for Enhanced Monitoring
data "aws_iam_policy_document" "rds_enhanced_monitoring_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  name_prefix = "rds-enhanced-monitoring-"

  assume_role_policy = data.aws_iam_policy_document.rds_enhanced_monitoring_assume.json

  tags = {
    Name        = "rds-enhanced-monitoring"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_db_instance" "test_postgres" {
  identifier_prefix = "test-pmm-"

  engine         = "postgres"
  engine_version = "16.6"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "testdb"
  username = "pmm_test_user"
  password = random_password.postgres_password.result

  db_subnet_group_name   = aws_db_subnet_group.test_postgres.name
  vpc_security_group_ids = [aws_security_group.test_postgres.id]

  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false

  publicly_accessible = false

  # Database Insights - Advanced mode
  # Combines Performance Insights + Enhanced Monitoring in unified CloudWatch view
  # Advanced mode provides:
  # - 15 months of performance history retention
  # - Fleet-level monitoring across databases
  # - Integration with CloudWatch Application Signals
  performance_insights_enabled          = true
  performance_insights_retention_period = 465 # Days (~15 months for Advanced mode)

  # Enhanced Monitoring for OS-level metrics (required for Database Insights)
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 60 # Seconds (0, 1, 5, 10, 15, 30, 60)
  monitoring_role_arn             = aws_iam_role.rds_enhanced_monitoring.arn

  tags = {
    Name        = "test-postgres-pmm"
    Environment = var.environment
  }
}