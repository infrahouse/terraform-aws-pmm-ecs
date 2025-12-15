# EC2 Instance for PMM Server with persistent storage
resource "aws_instance" "pmm_server" {
  ami                    = data.aws_ami.ubuntu_pro.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.pmm_instance.id]
  key_name               = var.ssh_key_name
  iam_instance_profile   = aws_iam_instance_profile.pmm.name

  # Enable detailed monitoring for auto-recovery
  monitoring = true

  # Root volume configuration
  # Size is automatically calculated: OS (10GB) + Swap (1x RAM) + Buffer (5GB)
  root_block_device {
    volume_size           = local.actual_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    kms_key_id            = var.kms_key_id
    delete_on_termination = true

    tags = merge(
      local.common_tags,
      {
        Name = "${local.service_name}-root"
        Type = "root-volume"
      }
    )
  }

  # User data for PMM setup with persistent storage
  user_data_base64            = data.cloudinit_config.pmm_persistent.rendered
  user_data_replace_on_change = true

  # Instance metadata options
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tags = merge(
    local.common_tags,
    {
      Name        = local.service_name
      Type        = "pmm-server"
      Environment = var.environment
    }
  )

  # Lifecycle management
  lifecycle {
    ignore_changes = [ami] # Ignore AMI updates unless explicitly changed
  }
}

# IAM role for EC2 instance
resource "aws_iam_role" "pmm_instance" {
  name_prefix = "${local.service_name}-instance-"
  description = "IAM role for PMM EC2 instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# IAM instance profile
resource "aws_iam_instance_profile" "pmm" {
  name_prefix = "${local.service_name}-profile-"
  role        = aws_iam_role.pmm_instance.name

  tags = local.common_tags
}

# Attach SSM policy for Session Manager access
resource "aws_iam_role_policy_attachment" "pmm_ssm" {
  role       = aws_iam_role.pmm_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach custom PMM policy
resource "aws_iam_role_policy_attachment" "pmm_custom" {
  role       = aws_iam_role.pmm_instance.name
  policy_arn = aws_iam_policy.pmm_instance.arn
}

# Security group for PMM instance
resource "aws_security_group" "pmm_instance" {
  name_prefix = "${local.service_name}-instance-"
  description = "Security group for PMM EC2 instance"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-instance"
    }
  )
}

# Allow egress to the internet
resource "aws_security_group_rule" "pmm_instance_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 65535
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.pmm_instance.id
  description       = "Allow all outbound traffic"
}

# Allow ingress from ALB on port 80
resource "aws_security_group_rule" "pmm_instance_http" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pmm_alb.id
  security_group_id        = aws_security_group.pmm_instance.id
  description              = "Allow HTTP from ALB"
}

# Allow ingress from ALB on port 443 (if PMM serves HTTPS directly)
resource "aws_security_group_rule" "pmm_instance_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pmm_alb.id
  security_group_id        = aws_security_group.pmm_instance.id
  description              = "Allow HTTPS from ALB"
}

# Note: CloudWatch alarms for auto-recovery and monitoring are defined in auto_recovery.tf