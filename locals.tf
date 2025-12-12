locals {
  module         = "infrahouse/pmm-ecs/aws"
  module_version = "0.3.0"

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

  # Custom PostgreSQL query files for PMM
  # These are created on the EC2 host and mounted into the PMM container
  custom_query_files = concat(
    var.postgresql_custom_queries_high_resolution != null ? [{
      path        = "/opt/pmm/custom-queries/postgresql-high-resolution.yml"
      permissions = "0644"
      content     = var.postgresql_custom_queries_high_resolution
    }] : [],
    var.postgresql_custom_queries_medium_resolution != null ? [{
      path        = "/opt/pmm/custom-queries/postgresql-medium-resolution.yml"
      permissions = "0644"
      content     = var.postgresql_custom_queries_medium_resolution
    }] : [],
    var.postgresql_custom_queries_low_resolution != null ? [{
      path        = "/opt/pmm/custom-queries/postgresql-low-resolution.yml"
      permissions = "0644"
      content     = var.postgresql_custom_queries_low_resolution
    }] : []
  )

  # Docker volume mount arguments for custom query files
  custom_query_volume_mounts = join(" ", concat(
    var.postgresql_custom_queries_high_resolution != null ? [
      "-v /opt/pmm/custom-queries/postgresql-high-resolution.yml:/usr/local/percona/pmm/collectors/custom-queries/postgresql/high-resolution/custom-queries.yml:ro"
    ] : [],
    var.postgresql_custom_queries_medium_resolution != null ? [
      "-v /opt/pmm/custom-queries/postgresql-medium-resolution.yml:/usr/local/percona/pmm/collectors/custom-queries/postgresql/medium-resolution/custom-queries.yml:ro"
    ] : [],
    var.postgresql_custom_queries_low_resolution != null ? [
      "-v /opt/pmm/custom-queries/postgresql-low-resolution.yml:/usr/local/percona/pmm/collectors/custom-queries/postgresql/low-resolution/custom-queries.yml:ro"
    ] : []
  ))
}
