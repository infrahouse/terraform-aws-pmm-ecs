#!/bin/bash
set -e

echo "Starting EBS volume setup..."

# Wait for EBS volume to be attached
DEVICE="/dev/xvdf"
MAX_ATTEMPTS=60
ATTEMPT=0

while [ ! -e "$DEVICE" ]; do
  if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
    echo "ERROR: EBS volume not attached after $MAX_ATTEMPTS attempts"
    exit 1
  fi
  echo "Waiting for EBS volume at $DEVICE... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)"
  sleep 5
  ATTEMPT=$((ATTEMPT+1))
done

echo "EBS volume found at $DEVICE"

# Check if the volume needs formatting
if [ "$(file -s $DEVICE)" == "$DEVICE: data" ]; then
  echo "Formatting new EBS volume..."
  mkfs -t ext4 $DEVICE
  echo "Volume formatted successfully"
else
  echo "Volume already formatted, skipping format step"
fi

# Create mount point
mkdir -p /srv

# Mount the volume
echo "Mounting EBS volume..."
mount $DEVICE /srv

# Add to fstab for persistent mounting (using UUID for reliability)
UUID=$(blkid -s UUID -o value $DEVICE)
echo "UUID=$UUID /srv ext4 defaults,nofail 0 2" >> /etc/fstab

# Create PMM directories on persistent volume
echo "Creating PMM data directories..."
mkdir -p /srv/pmm-data
mkdir -p /srv/postgres14
mkdir -p /srv/clickhouse
mkdir -p /srv/grafana
mkdir -p /srv/prometheus
mkdir -p /srv/logs
mkdir -p /srv/backup
mkdir -p /srv/alertmanager

# Set proper permissions (PMM runs as UID 1000)
chown -R 1000:1000 /srv/pmm-data
chown -R 1000:1000 /srv/grafana
chown -R 1000:1000 /srv/prometheus
chown -R 1000:1000 /srv/alertmanager
chown -R 1000:1000 /srv/logs
chown -R 1000:1000 /srv/backup

# PostgreSQL needs special permissions
chown -R 1000:1000 /srv/postgres14
chmod 700 /srv/postgres14

# ClickHouse needs special permissions
chown -R 1000:1000 /srv/clickhouse
chmod 755 /srv/clickhouse

echo "EBS volume setup completed successfully"