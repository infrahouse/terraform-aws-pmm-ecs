# Cloud-init configuration for PMM with persistent EBS storage
data "cloudinit_config" "pmm_persistent" {
  gzip          = true
  base64_encode = true

  # Part 1: Bash script to handle EBS volume mounting
  part {
    content_type = "text/x-shellscript"
    content      = templatefile("${path.module}/scripts/mount-ebs-volume.sh", {})
  }

  # Part 2: Install Docker and repositories
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/install-docker.sh.tftpl", {
      ubuntu_codename = local.ubuntu_codename
    })
  }

  # Part 3: Configure swap to prevent OOM kills
  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/templates/configure-swap.sh.tftpl", {
      instance_ram_mb = data.aws_ec2_instance_type.pmm.memory_size
    })
  }

  # Part 4: Cloud-config for package installation and configuration files
  part {
    content_type = "text/cloud-config"
    content = join(
      "\n",
      [
        "#cloud-config",
        yamlencode(
          {
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
                  content : templatefile("${path.module}/templates/pmm-server-persistent.service.tftpl", {
                    docker_image               = local.docker_image
                    disable_telemetry          = var.disable_telemetry
                    custom_query_volume_mounts = local.custom_query_volume_mounts
                    pmm_public_address         = "${var.dns_names[0]}.${data.aws_route53_zone.selected.name}"
                  })
                },
                {
                  path : "/etc/systemd/system/set-pmm-password.service"
                  permissions : "0644"
                  content : file("${path.module}/templates/set-pmm-password.service.tftpl")
                },
                {
                  path : "/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"
                  permissions : "0644"
                  content : jsonencode({
                    agent : {
                      metrics_collection_interval : 60
                      run_as_user : "root"
                    }
                    metrics : {
                      namespace : "CWAgent"
                      metrics_collected : {
                        cpu : {
                          measurement : [
                            {
                              name : "cpu_usage_idle"
                              unit : "Percent"
                            },
                            {
                              name : "cpu_usage_iowait"
                              unit : "Percent"
                            }
                          ]
                          metrics_collection_interval : 60
                          totalcpu : false
                        }
                        disk : {
                          measurement : [
                            {
                              name : "used_percent"
                              unit : "Percent"
                            }
                          ]
                          metrics_collection_interval : 60
                          resources : [
                            "/",
                            "/srv",
                          ]
                          ignore_file_system_types : [
                            "sysfs",
                            "devtmpfs",
                            "tmpfs",
                          ]
                        }
                        mem : {
                          measurement : [
                            {
                              name : "mem_used_percent"
                              unit : "Percent"
                            }
                          ]
                          metrics_collection_interval : 60
                        }
                      }
                      append_dimensions : {
                        InstanceId : "$${aws:InstanceId}"
                      }
                    }
                  })
                }
              ],
              local.custom_query_files
            )
          }
        )
      ]
    )
  }

  # Part 5: Start all services
  part {
    content_type = "text/x-shellscript"
    content      = templatefile("${path.module}/templates/start-services.sh.tftpl", {})
  }
}
