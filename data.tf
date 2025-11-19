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

# Get listener details to extract target group ARN
data "aws_lb_listener" "pmm" {
  arn = module.pmm_ecs.ssl_listener_arn
}
