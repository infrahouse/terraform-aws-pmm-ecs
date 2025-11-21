# BACKUP DISABLED - Using local ephemeral storage
# TODO: Implement EBS snapshot-based backup or external backup solution if needed

# # AWS Backup Vault
# resource "aws_backup_vault" "pmm_efs" {
#   name = "${local.service_name}-backup-vault"
#
#   tags = merge(
#     local.common_tags,
#     {
#       Name = "${local.service_name}-backup-vault"
#     }
#   )
# }
#
# # AWS Backup Plan
# resource "aws_backup_plan" "pmm_efs" {
#   name = "${local.service_name}-backup-plan"
#
#   rule {
#     rule_name         = "${local.service_name}-daily-backup"
#     target_vault_name = aws_backup_vault.pmm_efs.name
#     schedule          = var.backup_schedule
#
#     lifecycle {
#       delete_after = var.backup_retention_days
#     }
#
#     recovery_point_tags = merge(
#       local.common_tags,
#       {
#         Name = "${local.service_name}-backup"
#       }
#     )
#   }
#
#   tags = local.common_tags
# }
#
# # IAM assume role policy for AWS Backup
# data "aws_iam_policy_document" "backup_assume_role" {
#   statement {
#     effect = "Allow"
#
#     principals {
#       type        = "Service"
#       identifiers = ["backup.amazonaws.com"]
#     }
#
#     actions = ["sts:AssumeRole"]
#   }
# }
#
# # IAM Role for AWS Backup
# resource "aws_iam_role" "backup" {
#   name_prefix = "${local.service_name}-backup-"
#   description = "IAM role for AWS Backup service"
#
#   assume_role_policy = data.aws_iam_policy_document.backup_assume_role.json
#
#   tags = local.common_tags
# }
#
# # AWS managed policy for backup operations
# data "aws_iam_policy" "backup_service_policy" {
#   name = "AWSBackupServiceRolePolicyForBackup"
# }
#
# # AWS managed policy for restore operations
# data "aws_iam_policy" "backup_restore_policy" {
#   name = "AWSBackupServiceRolePolicyForRestores"
# }
#
# # Attach backup policy to role
# resource "aws_iam_role_policy_attachment" "backup_service" {
#   role       = aws_iam_role.backup.name
#   policy_arn = data.aws_iam_policy.backup_service_policy.arn
# }
#
# # Attach restore policy to role
# resource "aws_iam_role_policy_attachment" "backup_restore" {
#   role       = aws_iam_role.backup.name
#   policy_arn = data.aws_iam_policy.backup_restore_policy.arn
# }
#
# # AWS Backup Selection
# resource "aws_backup_selection" "pmm_efs" {
#   name         = "${local.service_name}-efs-selection"
#   plan_id      = aws_backup_plan.pmm_efs.id
#   iam_role_arn = aws_iam_role.backup.arn
#
#   resources = [
#     aws_efs_file_system.pmm_data.arn
#   ]
# }
