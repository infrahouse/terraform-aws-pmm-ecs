locals {
  module         = "infrahouse/pmm-ecs/aws"
  module_version = "0.1.0"

  service_name = var.service_name
  docker_image = "percona/pmm-server:${var.pmm_version}"

  ubuntu_codename      = "noble"
  ami_name_pattern_pro = "ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-${local.ubuntu_codename}-*"

  efs_creation_token = "${local.service_name}-data"

  cloudwatch_log_group = "/aws/ecs/${local.service_name}"

  # PMM environment variables
  pmm_environment_variables = [
    {
      name  = "DISABLE_TELEMETRY"
      value = tostring(var.disable_telemetry)
    },
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
