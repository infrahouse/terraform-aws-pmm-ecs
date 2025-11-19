terraform {
  required_version = "~> 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.11, < 7.0"
      configuration_aliases = [
        aws.dns
      ]
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
