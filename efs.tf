resource "aws_efs_file_system" "pmm_data" {
  creation_token = local.efs_creation_token
  encrypted      = true
  kms_key_id     = var.efs_kms_key_id

  performance_mode = var.efs_performance_mode
  throughput_mode  = var.efs_throughput_mode

  lifecycle_policy {
    transition_to_ia = var.efs_transition_to_ia
  }

  tags = merge(
    {
      module_version = local.module_version
    },
    local.common_tags,
    {
      Name = "${local.service_name}-data"
      type = "pmm-storage"
    }
  )
}

resource "aws_efs_mount_target" "pmm_data" {
  for_each       = toset(var.private_subnet_ids)
  file_system_id = aws_efs_file_system.pmm_data.id
  subnet_id      = each.key

  security_groups = [aws_security_group.efs.id]
}
