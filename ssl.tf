# ACM certificate for PMM with DNS validation

resource "aws_acm_certificate" "pmm" {
  domain_name       = trimprefix(join(".", [var.dns_names[0], data.aws_route53_zone.selected.name]), ".")
  validation_method = "DNS"
  subject_alternative_names = [
    for record in var.dns_names : trimprefix(join(".", [record, data.aws_route53_zone.selected.name]), ".")
  ]
  lifecycle {
    create_before_destroy = true
  }
  tags = merge(
    local.common_tags,
    {
      Name = "${local.service_name}-certificate"
    }
  )
  depends_on = [
    aws_route53_record.pmm_caa
  ]
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.pmm.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  provider = aws.dns
  zone_id  = var.zone_id
  name     = each.value.name
  type     = each.value.type
  records = [
    each.value.record
  ]
  ttl = 60
}

resource "aws_acm_certificate_validation" "pmm" {
  certificate_arn = aws_acm_certificate.pmm.arn
  validation_record_fqdns = [
    for d in aws_route53_record.cert_validation : d.fqdn
  ]
  depends_on = [
    aws_route53_record.pmm_caa
  ]
}

# CAA record to allow AWS Certificate Manager to issue certificates
resource "aws_route53_record" "pmm_caa" {
  provider = aws.dns
  count    = length(var.dns_names)
  zone_id  = var.zone_id
  name     = trimprefix(join(".", [var.dns_names[count.index], data.aws_route53_zone.selected.name]), ".")
  type     = "CAA"
  ttl      = 300
  records = concat(
    [for issuer in var.certificate_issuers : "0 issue \"${issuer}\""],
    ["0 issuewild \";\""]
  )
}