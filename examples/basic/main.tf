module "pmm" {
  source = "../.."

  # Network configuration
  public_subnet_ids  = var.public_subnet_ids
  private_subnet_ids = var.private_subnet_ids

  # DNS configuration
  zone_id   = var.zone_id
  dns_names = ["pmm"]

  # Required variables
  environment  = var.environment
  alarm_emails = ["devops@example.com"]

  tags = {
    environment = var.environment
  }
}
