# ECS Cluster Module for PMM Server
module "pmm_ecs" {
  source  = "infrahouse/ecs/aws"
  version = "6.0.0"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  # Core configuration
  service_name   = local.service_name
  docker_image   = local.docker_image
  container_port = 443

  # Resources
  container_cpu     = var.container_cpu
  container_memory  = var.container_memory
  asg_instance_type = var.instance_type

  # Networking
  load_balancer_subnets = var.public_subnet_ids
  asg_subnets           = var.private_subnet_ids
  internet_gateway_id   = data.aws_internet_gateway.selected.id

  # DNS
  zone_id   = var.zone_id
  dns_names = var.dns_names

  # Health checks
  healthcheck_path                  = "/v1/readyz"
  healthcheck_response_code_matcher = "200"
  healthcheck_interval              = var.healthcheck_interval
  healthcheck_timeout               = var.healthcheck_timeout

  # Auto-scaling (PMM should run as singleton for data consistency)
  asg_min_size       = 1
  asg_max_size       = 1
  task_min_count     = 1
  task_desired_count = 1
  task_max_count     = 1

  # Persistent storage
  task_efs_volumes = {
    "pmm-data" : {
      file_system_id : aws_efs_file_system.pmm_data.id
      container_path : "/srv"
    }
  }

  # Environment variables
  task_environment_variables = local.pmm_environment_variables

  # Secrets
  task_secrets = local.pmm_secrets

  # Logging
  enable_cloudwatch_logs         = true
  cloudwatch_log_group           = local.cloudwatch_log_group
  cloudwatch_log_group_retention = var.cloudwatch_log_retention_days

  # SSH access
  ssh_key_name   = var.ssh_key_name
  ssh_cidr_block = var.admin_cidr_blocks

  # IAM
  execution_task_role_policy_arn = aws_iam_policy.pmm_execution.arn
  task_role_arn                  = aws_iam_role.pmm_task.arn

  tags = local.common_tags

  depends_on = [
    aws_efs_mount_target.pmm_data
  ]
}
