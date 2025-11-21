"""Test basic PMM deployment."""
import json
import os
import shutil
from os import path as osp
from textwrap import dedent

import pytest
from pytest_infrahouse import terraform_apply

from tests.conftest import TERRAFORM_ROOT_DIR, LOG


@pytest.mark.parametrize(
    "aws_provider_version", ["~> 5.31", "~> 6.0"], ids=["aws-5", "aws-6"]
)
def test_module(
    service_network,
    aws_provider_version,
    keep_after,
    test_role_arn,
    aws_region,
    subzone,
):
    """
    Test basic PMM server deployment.

    Verifies successful terraform apply with minimal validation.
    """
    subnet_public_ids = service_network["subnet_public_ids"]["value"]
    subnet_private_ids = service_network["subnet_private_ids"]["value"]

    terraform_module_dir = osp.join(TERRAFORM_ROOT_DIR, "test_basic")

    # Clean up Terraform cache files to ensure fresh provider installation
    try:
        shutil.rmtree(osp.join(terraform_module_dir, ".terraform"))
    except FileNotFoundError:
        pass

    try:
        os.remove(osp.join(terraform_module_dir, ".terraform.lock.hcl"))
    except FileNotFoundError:
        pass

    # Create terraform.tf with AWS provider
    with open(osp.join(terraform_module_dir, "terraform.tf"), "w") as tf_fp:
        tf_fp.write(
            dedent(
                f"""
                terraform {{
                  required_providers {{
                    aws = {{
                      source  = "hashicorp/aws"
                      version = "{aws_provider_version}"
                    }}
                    random = {{
                      source  = "hashicorp/random"
                      version = "~> 3.6"
                    }}
                  }}
                }}
                """
            )
        )

    # Create provider.tf
    with open(osp.join(terraform_module_dir, "provider.tf"), "w") as provider_fp:
        if test_role_arn:
            provider_fp.write(
                dedent(
                    f"""
                    provider "aws" {{
                      region = var.region
                      assume_role {{
                        role_arn = var.role_arn
                      }}
                    }}

                    provider "aws" {{
                      region = var.region
                      alias  = "dns"
                      assume_role {{
                        role_arn = var.role_arn
                      }}
                    }}
                    """
                )
            )
        else:
            provider_fp.write(
                dedent(
                    f"""
                    provider "aws" {{
                      region = var.region
                    }}

                    provider "aws" {{
                      region = var.region
                      alias  = "dns"
                    }}
                    """
                )
            )

    # Create terraform.tfvars with test values
    with open(osp.join(terraform_module_dir, "terraform.tfvars"), "w") as fp:
        fp.write(
            dedent(
                f"""
                region = "{aws_region}"

                public_subnet_ids  = {json.dumps(subnet_public_ids)}
                private_subnet_ids = {json.dumps(subnet_private_ids)}

                zone_id = "{subzone["subzone_id"]["value"]}"

                environment = "test"
                """
            )
        )
        if test_role_arn:
            fp.write(
                dedent(
                    f"""
                    role_arn = "{test_role_arn}"
                    """
                )
            )

    with terraform_apply(
        terraform_module_dir,
        destroy_after=not keep_after,
        json_output=True,
    ) as tf_output:
        LOG.info("%s", json.dumps(tf_output, indent=4))
        LOG.info("PMM deployment successful!")
