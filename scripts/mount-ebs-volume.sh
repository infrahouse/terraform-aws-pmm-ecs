#!/bin/bash
set -e

echo "Starting EBS volume setup..."

# Wait for EBS volume to be attached
# This module only supports NVMe-based instance types (t3, m5, m6i, c5, c6i, r5, r6i)
# On NVMe instances, EBS volumes appear as /dev/nvme[1-26]n1
# Legacy fallback to /dev/xvdf is kept for defensive programming
MAX_ATTEMPTS=180  # 15 minutes (180 attempts × 5 seconds) to handle AWS API delays
ATTEMPT=0

DEVICE=""
while [ -z "$DEVICE" ]; do
  if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
    echo "ERROR: EBS volume not attached after $((MAX_ATTEMPTS * 5 / 60)) minutes ($MAX_ATTEMPTS attempts)"
    echo "Troubleshooting information:"
    echo "Available block devices:"
    ls -la /dev/nvme* /dev/xvd* 2>/dev/null || echo "No NVMe or xvd devices found"
    echo ""
    echo "Check AWS Console/CloudWatch for:"
    echo "  - EBS volume attachment status"
    echo "  - EC2 instance system logs"
    echo "  - Potential AWS service issues in this AZ"
    exit 1
  fi

  # Try NVMe device (supported instance types)
  if [ -e /dev/nvme1n1 ]; then
    DEVICE="/dev/nvme1n1"
  # Legacy fallback (should not be reached with validated instance types)
  elif [ -e /dev/xvdf ]; then
    DEVICE="/dev/xvdf"
    echo "WARNING: Using legacy device name. This may indicate unsupported instance type."
  fi

  if [ -z "$DEVICE" ]; then
    echo "Waiting for EBS volume... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)"
    sleep 5
    ATTEMPT=$((ATTEMPT+1))
  fi
done

echo "EBS volume found at $DEVICE"

# Check if the volume needs formatting using blkid (more reliable than file -s)
# blkid returns empty string only if no filesystem exists
if [ -z "$(blkid $DEVICE)" ]; then
  echo "New unformatted EBS volume detected"
  echo "Formatting volume with ext4 filesystem..."
  mkfs -t ext4 -L pmm-data $DEVICE
  echo "Volume formatted successfully"
else
  echo "Volume already formatted, skipping format step"
  echo "Existing filesystem: $(blkid $DEVICE)"
fi

# Create mount point
mkdir -p /srv

# Mount the volume
echo "Mounting EBS volume..."
mount $DEVICE /srv

# Add to fstab for persistent mounting (using UUID for reliability)
UUID=$(blkid -s UUID -o value $DEVICE)
echo "UUID=$UUID /srv ext4 defaults,nofail 0 2" >> /etc/fstab

# PMM Server will create its required subdirectories automatically on first boot
# We just need to ensure the mount point has proper permissions for PMM (UID 1000)
echo "Setting permissions for PMM data volume..."
chown 1000:1000 /srv
chmod 755 /srv

echo "EBS volume setup completed successfully"