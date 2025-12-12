#!/bin/bash
# Manual EFS backup script for PMM data
#
# Usage: ./backup-efs.sh <efs-file-system-id> <backup-vault-name>
#
# Example:
#   ./backup-efs.sh fs-abc123 pmm-server-backup-vault

set -e

EFS_ID=${1}
BACKUP_VAULT=${2:-"pmm-server-backup-vault"}

if [ -z "$EFS_ID" ]; then
    echo "Usage: $0 <efs-file-system-id> [backup-vault-name]"
    exit 1
fi

echo "Starting manual backup of EFS: $EFS_ID"
echo "Backup vault: $BACKUP_VAULT"

# Start backup job
BACKUP_JOB=$(aws backup start-backup-job \
    --backup-vault-name "$BACKUP_VAULT" \
    --resource-arn "arn:aws:elasticfilesystem:$(aws configure get region):$(aws sts get-caller-identity --query Account --output text):file-system/$EFS_ID" \
    --iam-role-arn "$(aws backup describe-backup-vault --backup-vault-name "$BACKUP_VAULT" --query BackupVaultArn --output text | sed 's/backup-vault/iam::role/')/pmm-server-backup-role" \
    --idempotency-token "$(uuidgen)" \
    --output json)

BACKUP_JOB_ID=$(echo "$BACKUP_JOB" | jq -r '.BackupJobId')

echo "Backup job started: $BACKUP_JOB_ID"
echo ""
echo "Monitor backup progress:"
echo "  aws backup describe-backup-job --backup-job-id $BACKUP_JOB_ID"
echo ""
echo "List recovery points when complete:"
echo "  aws backup list-recovery-points-by-backup-vault --backup-vault-name $BACKUP_VAULT"
