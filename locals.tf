locals {
  module         = "infrahouse/pmm-ecs/aws"
  module_version = "0.0.0"

  service_name = var.service_name
  docker_image = "percona/pmm-server:${var.pmm_version}"

  efs_creation_token = "${local.service_name}-data"

  cloudwatch_log_group = "/aws/ecs/${local.service_name}"

  # Extract ARN suffixes for CloudWatch alarms
  # ARN format: arn:aws:elasticloadbalancing:region:account:loadbalancer/app/name/id
  # Suffix format: app/name/id
  load_balancer_arn_suffix = try(split("loadbalancer/", module.pmm_ecs.load_balancer_arn)[1], "")
  # Get target group ARN from listener's default action
  target_group_arn        = try(data.aws_lb_listener.pmm.default_action[0].target_group_arn, "")
  target_group_arn_suffix = try(split("targetgroup/", local.target_group_arn)[1], "")

  # PMM environment variables
  pmm_environment_variables = [
    {
      name  = "DISABLE_TELEMETRY"
      value = tostring(var.disable_telemetry)
    },
    {
      name  = "ENABLE_DBAAS"
      value = tostring(var.enable_dbaas)
    }
  ]

  # PMM secrets (admin password from Secrets Manager)
  pmm_secrets = [
    {
      name      = "ADMIN_PASSWORD"
      valueFrom = module.admin_password_secret.secret_arn
    }
  ]

  default_module_tags = {
    created_by_module = local.module
  }

  common_tags = merge(
    var.tags,
    local.default_module_tags,
    {
      service     = local.service_name
      environment = var.environment
    }
  )
}
