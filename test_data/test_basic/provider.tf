
provider "aws" {
  region = var.region
  assume_role {
    role_arn = var.role_arn
  }
}

provider "aws" {
  region = var.region
  alias  = "dns"
  assume_role {
    role_arn = var.role_arn
  }
}
