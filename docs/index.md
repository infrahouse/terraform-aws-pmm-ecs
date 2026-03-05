# terraform-aws-pmm-ecs

Terraform module for deploying
[Percona Monitoring and Management (PMM)](https://www.percona.com/software/database-tools/percona-monitoring-and-management)
on AWS EC2 with Docker.

## Features

- **Production-ready PMM deployment** on dedicated EC2 instance with persistent
  EBS storage
- **Automatic SSL/TLS** with ACM certificates and DNS validation via ALB
- **Automated backups** via AWS Backup with configurable retention
- **Auto-recovery** for hardware failures with EC2 auto-recovery and
  CloudWatch alarms
- **RDS monitoring** with automatic security group configuration for
  PostgreSQL and MySQL
- **Custom PostgreSQL queries** with configurable collection intervals
  (high/medium/low resolution)
- **MySQL/Percona Server ASG monitoring** via Lambda reconciler that
  automatically installs pmm-client on instances via SSM
- **Comprehensive CloudWatch monitoring** with dashboard and alarms for
  instance, disk, memory, and EBS metrics
- **Auto-generated passwords** stored securely in AWS Secrets Manager
- **PMM 3.x by default** (PMM 2 EOL July 2025)

## Prerequisites

The operational documentation uses CLI tools from
[infrahouse-toolkit](https://github.com/infrahouse/infrahouse-toolkit)
(`ih-secrets`, `ih-ec2`, etc.). Install it on Ubuntu:

```bash
# Install dependencies
apt-get update
apt-get install gpg lsb-release curl

# Add InfraHouse GPG key
mkdir -p /etc/apt/cloud-init.gpg.d/
curl -fsSL https://release-$(lsb_release -cs).infrahouse.com/DEB-GPG-KEY-release-$(lsb_release -cs).infrahouse.com \
    | gpg --dearmor -o /etc/apt/cloud-init.gpg.d/infrahouse.gpg

# Add InfraHouse repository
echo "deb [signed-by=/etc/apt/cloud-init.gpg.d/infrahouse.gpg] https://release-$(lsb_release -cs).infrahouse.com/ $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/infrahouse.list

# Install
apt-get update
apt-get install infrahouse-toolkit
```

## Quick Start

```hcl
module "pmm" {
  source  = "registry.infrahouse.com/infrahouse/pmm-ecs/aws"
  version = "1.1.0"

  providers = {
    aws     = aws
    aws.dns = aws.dns
  }

  public_subnet_ids  = ["subnet-abc123", "subnet-def456"]
  private_subnet_ids = ["subnet-ghi789", "subnet-jkl012"]
  zone_id            = "Z1234567890ABC"
  environment        = "production"
  alarm_emails       = ["devops@example.com"]

  # Optional: RDS monitoring
  rds_security_group_ids = [aws_security_group.postgres.id]
}
```

After deployment, PMM is available at `https://pmm.<your-zone>/`.

Retrieve the admin password:

```bash
ih-secrets get <admin_password_secret_arn from module output>
```

## Monitoring Percona Server ASG Instances

For MySQL/Percona Server instances running in Auto Scaling Groups, the module
provides an automated Lambda reconciler. It runs every 5 minutes, installs
`pmm-client` on new instances via SSM, and removes services for terminated
instances.

```hcl
module "percona" {
  source  = "registry.infrahouse.com/infrahouse/percona-server/aws"
  version = "0.6.0"
  # ...
}

module "pmm" {
  source  = "registry.infrahouse.com/infrahouse/pmm-ecs/aws"
  version = "1.1.0"

  # ... other configuration ...

  monitored_asgs = [
    {
      asg_name          = module.percona.asg_name
      service_type      = "mysql"
      port              = 3306
      username          = "monitor"
      security_group_id = module.percona.security_group_id
    }
  ]
}
```

![PMM Inventory showing Percona Server ASG services](images/pmm-inventory-services.png)

![PMM Node Summary dashboard](images/pmm-node-summary.png)

## Documentation

- [Architecture](ARCHITECTURE.md) -- how it works, component details,
  security model
- [RDS Setup](RDS_SETUP.md) -- adding PostgreSQL/MySQL RDS instances to PMM
- [Percona Server Setup](PERCONA_SERVER_SETUP.md) -- automated MySQL/Percona
  Server ASG monitoring via Lambda reconciler
- [Backup & Restore](BACKUP_RESTORE.md) -- backup configuration and
  recovery procedures
- [Runbook](RUNBOOK.md) -- operational procedures, maintenance tasks,
  Lambda reconciler management
- [Troubleshooting](TROUBLESHOOTING.md) -- common issues and solutions
