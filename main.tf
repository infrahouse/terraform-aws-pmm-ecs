# PMM Server with Persistent Storage on EC2
# This module deploys Percona Monitoring and Management (PMM) server
# on a single EC2 instance with persistent EBS storage

# The infrastructure components are defined in separate files:
# - ec2.tf: EC2 instance configuration
# - ebs.tf: Persistent EBS volume for PMM data
# - alb.tf: Application Load Balancer for HTTPS access
# - backup.tf: AWS Backup for automated snapshots
# - auto_recovery.tf: CloudWatch alarms and auto-recovery
# - userdata.tf: Cloud-init configuration for instance setup

# All resources work together to provide:
# - Data persistence across instance replacements
# - Automatic recovery from hardware failures
# - Daily backups with configurable retention
# - Secure HTTPS access through ALB
# - Monitoring and alerting via Cloud Watch
