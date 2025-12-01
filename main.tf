# Website Pod Module for PMM Server
module "pmm_pod" {
  source  = "infrahouse/website-pod/aws"
  version = "5.12.1"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  # Core configuration
  service_name = local.service_name

  # Resources
  instance_type = var.instance_type

  # Networking
  subnets         = var.public_subnet_ids
  backend_subnets = var.private_subnet_ids

  # DNS
  zone_id       = var.zone_id
  dns_a_records = var.dns_names

  # Health checks
  alb_healthcheck_path = "/v1/readyz"
  target_group_port    = 80

  # Auto-scaling (PMM should run as singleton for data consistency)
  asg_min_size = 1
  asg_max_size = 1

  # SSH access
  key_pair_name = var.ssh_key_name

  # Security
  alb_ingress_cidr_blocks = var.allowed_cidr

  # User data to run PMM container
  userdata = data.cloudinit_config.pmm.rendered

  ami                 = data.aws_ami.ubuntu_pro.id
  internet_gateway_id = data.aws_internet_gateway.selected.id

  tags = local.common_tags

  alb_access_log_force_destroy = true
}
