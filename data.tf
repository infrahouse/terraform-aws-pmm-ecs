data "aws_subnet" "selected" {
  id = var.private_subnet_ids[0]
}

data "aws_vpc" "selected" {
  id = data.aws_subnet.selected.vpc_id
}

data "aws_internet_gateway" "selected" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_route53_zone" "selected" {
  zone_id = var.zone_id
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

# Get latest Ubuntu Pro 24.04 LTS (Noble) AMI
data "aws_ami" "ubuntu_pro" {
  most_recent = true

  filter {
    name   = "name"
    values = [local.ami_name_pattern_pro]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name = "state"
    values = [
      "available"
    ]
  }

  owners = ["099720109477"] # Canonical
}

# Cloud-init configuration for PMM
data "cloudinit_config" "pmm" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = join(
      "\n",
      [
        "#cloud-config",
        yamlencode(
          {
            bootcmd : [
              # Install dependencies
              ["apt-get", "update"],
              ["apt-get", "install", "-y", "ca-certificates", "curl"],
              ["install", "-m", "0755", "-d", "/etc/apt/keyrings"],
              # Add Docker's official GPG key
              ["bash", "-c", "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"],
              ["chmod", "a+r", "/etc/apt/keyrings/docker.asc"],
              # Add Docker repository
              ["bash", "-c", "echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${local.ubuntu_codename} stable' > /etc/apt/sources.list.d/docker.list"],
              # Add InfraHouse GPG key
              ["bash", "-c", "curl -fsSL https://release-${local.ubuntu_codename}.infrahouse.com/DEB-GPG-KEY-release-${local.ubuntu_codename}.infrahouse.com | gpg --dearmor -o /etc/apt/keyrings/infrahouse.gpg"],
              # Add InfraHouse repository
              ["bash", "-c", "echo 'deb [signed-by=/etc/apt/keyrings/infrahouse.gpg] https://release-${local.ubuntu_codename}.infrahouse.com/ ${local.ubuntu_codename} main' > /etc/apt/sources.list.d/infrahouse.list"],
              ["apt-get", "update"]
            ]
            package_update : true
            packages : [
              "docker-ce",
              "docker-ce-cli",
              "containerd.io",
              "docker-buildx-plugin",
              "docker-compose-plugin",
              "awscli"
            ]
            write_files : concat(
              [
                {
                  path : "/usr/local/bin/get-pmm-password.sh"
                  permissions : "0755"
                  content : templatefile("${path.module}/templates/get-pmm-password.sh.tftpl", {
                    admin_password = module.admin_password_secret.secret_arn
                    aws_region     = data.aws_region.current.name
                  })
                },
                {
                  path : "/usr/local/bin/set-pmm-password.sh"
                  permissions : "0755"
                  content : file("${path.module}/templates/set-pmm-password.sh.tftpl")
                },
                {
                  path : "/etc/systemd/system/pmm-server.service"
                  permissions : "0644"
                  content : templatefile("${path.module}/templates/pmm-server.service.tftpl", {
                    docker_image               = local.docker_image
                    disable_telemetry          = var.disable_telemetry
                    custom_query_volume_mounts = local.custom_query_volume_mounts
                  })
                },
                {
                  path : "/etc/systemd/system/set-pmm-password.service"
                  permissions : "0644"
                  content : file("${path.module}/templates/set-pmm-password.service.tftpl")
                }
              ],
              local.custom_query_files
            )
            runcmd : [
              # Create PMM data directories
              ["bash", "-c", "mkdir -p /mnt/pmm-data/{postgres14,clickhouse,grafana,logs,backup}"],
              ["chown", "-R", "1000:1000", "/mnt/pmm-data"],
              ["chmod", "-R", "755", "/mnt/pmm-data"],
              ["chmod", "700", "/mnt/pmm-data/postgres14"],
              # Enable and start Docker
              ["systemctl", "enable", "docker"],
              ["systemctl", "start", "docker"],
              # Enable and start PMM
              ["systemctl", "daemon-reload"],
              ["systemctl", "enable", "pmm-server"],
              ["systemctl", "start", "pmm-server"],
              # Enable and start password setter (will wait for PMM to be ready)
              ["systemctl", "enable", "set-pmm-password"],
              ["systemctl", "start", "set-pmm-password"]
            ]
          }
        )
      ]
    )
  }
}
