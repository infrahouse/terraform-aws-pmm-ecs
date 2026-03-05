"""Test basic PMM deployment."""

import json
import os
import shutil
import time
from base64 import b64encode
from os import path as osp
from textwrap import dedent

import pytest
import requests
from infrahouse_core.timeout import timeout
from pytest_infrahouse import terraform_apply

from infrahouse_core.aws.asg import ASG

from tests.conftest import (
    TERRAFORM_ROOT_DIR,
    LOG,
    configure_postgres_via_ssm,
)


def validate_backup_creation(
    boto3_session, aws_region, vault_name, volume_id, backup_role_arn
):
    """
    Trigger and validate an on-demand backup of the EBS volume.

    :param boto3_session: Boto3 session for AWS API calls
    :param aws_region: AWS region
    :param vault_name: AWS Backup vault name
    :param volume_id: EBS volume ID to backup
    :param backup_role_arn: IAM role ARN for AWS Backup
    :raises: pytest.fail if backup fails or times out
    """

    LOG.info("=" * 80)
    LOG.info("Testing AWS Backup")
    LOG.info("=" * 80)
    LOG.info("Backup vault: %s", vault_name)
    LOG.info("EBS volume: %s", volume_id)

    # Create backup client
    backup_client = boto3_session.client("backup", region_name=aws_region)

    # Get account ID for ARN
    sts_client = boto3_session.client("sts", region_name=aws_region)
    account_id = sts_client.get_caller_identity()["Account"]

    # Start on-demand backup
    LOG.info("Starting on-demand backup of volume %s", volume_id)
    response = backup_client.start_backup_job(
        BackupVaultName=vault_name,
        ResourceArn=f"arn:aws:ec2:{aws_region}:{account_id}:volume/{volume_id}",
        IamRoleArn=backup_role_arn,
        RecoveryPointTags={"test": "automated", "created_by": "pytest"},
    )

    backup_job_id = response["BackupJobId"]
    LOG.info("Backup job started: %s", backup_job_id)

    # Wait for backup to complete (with timeout)
    try:
        with timeout(seconds=600):  # 10 minutes
            while True:
                job = backup_client.describe_backup_job(BackupJobId=backup_job_id)
                status = job["State"]

                LOG.info("Backup job status: %s", status)

                if status == "COMPLETED":
                    recovery_point_arn = job["RecoveryPointArn"]
                    LOG.info("Backup completed successfully!")
                    LOG.info("Recovery point: %s", recovery_point_arn)
                    return
                elif status in ["FAILED", "ABORTED", "EXPIRED"]:
                    LOG.error(
                        "Backup job details: %s",
                        json.dumps(job, indent=2, default=str),
                    )
                    pytest.fail(f"Backup job failed with status: {status}")

                time.sleep(30)
    except TimeoutError:
        pytest.fail("Backup did not complete within 10 minutes")


def get_pmm_auth_header(username, password):
    """Generate Basic Auth header for PMM API."""
    credentials = f"{username}:{password}"
    encoded = b64encode(credentials.encode()).decode()
    return {"Authorization": f"Basic {encoded}"}


def get_pmm_version(pmm_url):
    """Get PMM server version to determine API paths."""
    try:
        # Try to get version from the API
        response = requests.get(f"{pmm_url}/v1/version", timeout=10, verify=True)
        if response.status_code == 200:
            version_data = response.json()
            LOG.info("PMM Version: %s", json.dumps(version_data, indent=2))
            return version_data
    except Exception as e:
        LOG.warning("Could not determine PMM version: %s", e)
    return None


def list_pmm_services(pmm_url, auth_header):
    """List all services registered in PMM."""
    # PMM 3 uses GET /v1/management/services
    api_url = f"{pmm_url}/v1/management/services"
    try:
        LOG.debug("Fetching services from: %s", api_url)
        response = requests.get(
            api_url,
            headers={**auth_header, "Content-Type": "application/json"},
            timeout=30,
        )
        response.raise_for_status()
        LOG.info("Successfully retrieved services list")
        return response.json()
    except requests.exceptions.RequestException as e:
        LOG.error("Failed to list PMM services: %s", e)
        return None


def check_postgres_in_pmm(pmm_url, auth_header, postgres_address):
    """Check if PostgreSQL instance is already monitored in PMM."""
    services = list_pmm_services(pmm_url, auth_header)
    if not services:
        return False

    # Check if any PostgreSQL service matches our address
    for service in services.get("services", []):
        service_type = service.get("service_type", "").upper()
        service_address = service.get("address", "")

        # PMM 3 uses "POSTGRESQL_SERVICE" enum value
        if (
            service_type in ("POSTGRESQL_SERVICE", "POSTGRESQL")
            and postgres_address in service_address
        ):
            LOG.info(
                "PostgreSQL instance already registered: %s",
                service.get("service_name"),
            )
            return True
    return False


def get_pmm_server_agent_id(pmm_url, auth_header):
    """Get the PMM server's agent ID."""
    try:
        # Use /v1/inventory/agents to list all PMM agents
        # Filter for AGENT_TYPE_PMM_AGENT
        agents_url = f"{pmm_url}/v1/inventory/agents"
        params = {"agent_type": "AGENT_TYPE_PMM_AGENT"}

        response = requests.get(
            agents_url,
            headers={**auth_header, "Content-Type": "application/json"},
            params=params,
            timeout=30,
        )
        response.raise_for_status()
        agents_data = response.json()

        # PMM agents are in the "pmm_agent" array (note: singular, not plural)
        pmm_agents = agents_data.get("pmm_agent", [])

        if pmm_agents:
            # Get the first connected PMM agent
            for agent in pmm_agents:
                if agent.get("connected"):
                    agent_id = agent.get("agent_id")
                    LOG.info("Found connected PMM agent ID: %s", agent_id)
                    return agent_id

            # If no connected agents, use the first one
            agent_id = pmm_agents[0].get("agent_id")
            LOG.info("Using first PMM agent ID: %s", agent_id)
            return agent_id

        LOG.warning(
            "No PMM agents found in response: %s", json.dumps(agents_data, indent=2)
        )

    except Exception as e:
        LOG.warning("Could not get PMM agent ID: %s", e)

    return None


def add_postgres_to_pmm(
    pmm_url,
    auth_header,
    postgres_address,
    postgres_port,
    postgres_database,
    postgres_username,
    postgres_password,
    service_name="test-postgres-rds",
):
    """Add PostgreSQL instance to PMM monitoring using PMM 3 API."""
    # Get PMM agent ID (required for adding services)
    pmm_agent_id = get_pmm_server_agent_id(pmm_url, auth_header)
    if not pmm_agent_id:
        raise Exception("Could not find PMM agent ID")

    # PMM 3 API: POST /v1/management/services with inline node creation
    add_service_url = f"{pmm_url}/v1/management/services"

    service_payload = {
        "postgresql": {
            "service_name": service_name,
            "address": postgres_address,
            "port": int(postgres_port),
            "database": postgres_database,
            "username": postgres_username,
            "password": postgres_password,
            "pmm_agent_id": pmm_agent_id,
            "qan_postgresql_pgstatements_agent": True,
            "skip_connection_check": False,
            "tls": True,
            "tls_skip_verify": True,
            "add_node": {
                "node_type": "NODE_TYPE_REMOTE_NODE",
                "node_name": f"{service_name}-node",
                "region": os.environ.get("AWS_DEFAULT_REGION", "us-west-2"),
            },
        }
    }

    LOG.info("Adding PostgreSQL service to PMM with inline remote node...")
    LOG.debug("Payload: %s", json.dumps(service_payload, indent=2))

    service_response = requests.post(
        add_service_url,
        headers={**auth_header, "Content-Type": "application/json"},
        json=service_payload,
        timeout=30,
    )

    LOG.debug("Response status: %d", service_response.status_code)
    LOG.debug("Response body: %s", service_response.text[:1000])

    try:
        service_response.raise_for_status()
        service_data = service_response.json()
        LOG.info(
            "PostgreSQL service added successfully: %s",
            json.dumps(service_data, indent=2),
        )
        return service_data
    except requests.exceptions.HTTPError as e:
        try:
            error_detail = service_response.json()
            LOG.error("PMM API error details: %s", json.dumps(error_detail, indent=2))
        except Exception:
            LOG.error("PMM API error response: %s", service_response.text)
        raise Exception(
            f"Failed to add PostgreSQL service: {e}. "
            f"Response: {service_response.text[:500]}"
        )


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
    postgres,
    percona_pmm,
    boto3_session,
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

    # Create terraform.tfvars with test values.
    # Escape postgres_password for HCL: \->\\, "->\" , ${->$${ , %{->%%{
    pg_pass = postgres["master_password"]["value"]
    pg_pass_escaped = (
        pg_pass.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("${", "$${")
        .replace("%{", "%%{")
    )
    with open(osp.join(terraform_module_dir, "terraform.tfvars"), "w") as fp:
        fp.write(
            dedent(
                f"""
                region = "{aws_region}"

                public_subnet_ids  = {json.dumps(subnet_public_ids)}
                private_subnet_ids = {json.dumps(subnet_private_ids)}

                zone_id = "{subzone["subzone_id"]["value"]}"

                environment = "test"

                # Pass postgres fixture outputs
                postgres_security_group_id = "{postgres["security_group_id"]["value"]}"
                postgres_endpoint = "{postgres["endpoint"]["value"]}"
                postgres_address = "{postgres["address"]["value"]}"
                postgres_port = {postgres["port"]["value"]}
                postgres_database = "{postgres["database_name"]["value"]}"
                postgres_username = "{postgres["master_username"]["value"]}"
                postgres_password = "{pg_pass_escaped}"

                # Pass MySQL fixture outputs
                mysql_security_group_id = "{percona_pmm["security_group_id"]}"
                mysql_asg_name = "{percona_pmm["asg_name"]}"
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

        # Log PMM access information for testing
        pmm_url = tf_output["pmm_url"]["value"]
        admin_password = tf_output["admin_password"]["value"]
        instance_id = tf_output["instance_id"]["value"]
        LOG.info("PMM URL: %s", pmm_url)
        LOG.info("PMM admin password: %s", admin_password)
        LOG.info("PMM EC2 instance ID: %s", instance_id)

        # Wait for PMM to be fully ready
        LOG.info("Waiting for PMM to be fully ready...")
        wait_interval = 10

        try:
            with timeout(seconds=600):  # 10 minutes
                while True:
                    try:
                        response = requests.get(
                            f"{pmm_url}/v1/readyz", timeout=10, verify=True
                        )
                        if response.status_code == 200:
                            LOG.info("PMM readiness endpoint is responding")
                            break
                    except Exception as e:
                        LOG.debug("PMM /v1/readyz not ready yet: %s", e)

                    time.sleep(wait_interval)
                    LOG.info("Still waiting for PMM...")
        except TimeoutError:
            pytest.fail(f"PMM did not become ready within 600 seconds. URL: {pmm_url}")

        # Configure PostgreSQL for PMM monitoring via SSM
        LOG.info("Configuring PostgreSQL for PMM monitoring...")
        configure_postgres_via_ssm(
            instance_id=instance_id,
            aws_region=aws_region,
            test_role_arn=test_role_arn,
            db_host=postgres["address"]["value"],
            db_port=postgres["port"]["value"],
            db_name=postgres["database_name"]["value"],
            db_user=postgres["master_username"]["value"],
            db_password=postgres["master_password"]["value"],
        )

        # Test PostgreSQL monitoring integration
        LOG.info("=" * 80)
        LOG.info("Testing PostgreSQL monitoring integration")
        LOG.info("=" * 80)

        # Check PMM version to understand API structure
        LOG.info("Checking PMM version...")
        get_pmm_version(pmm_url)

        # Prepare PMM API authentication
        auth_header = get_pmm_auth_header("admin", admin_password)

        # Add PostgreSQL to PMM monitoring
        if not check_postgres_in_pmm(
            pmm_url, auth_header, postgres["address"]["value"]
        ):
            LOG.info("Adding PostgreSQL to PMM...")
            add_postgres_to_pmm(
                pmm_url=pmm_url,
                auth_header=auth_header,
                postgres_address=postgres["address"]["value"],
                postgres_port=postgres["port"]["value"],
                postgres_database=postgres["database_name"]["value"],
                postgres_username=postgres["master_username"]["value"],
                postgres_password=postgres["master_password"]["value"],
            )
        else:
            LOG.info("PostgreSQL already registered in PMM")

        LOG.info("=" * 80)
        LOG.info("PostgreSQL monitoring test completed")
        LOG.info("=" * 80)

        # Test Lambda ASG reconciler (registers MySQL instances in PMM)
        reconciler_arn = tf_output.get("reconciler_lambda_function_arn", {}).get(
            "value"
        )

        reconciler_successful = True
        if reconciler_arn:
            LOG.info("=" * 80)
            LOG.info("Testing Lambda ASG reconciler")
            LOG.info("=" * 80)
            LOG.info("Lambda ARN: %s", reconciler_arn)

            lambda_client = boto3_session.client("lambda", region_name=aws_region)

            # Invoke the reconciler Lambda synchronously
            LOG.info("Invoking reconciler Lambda...")
            invoke_response = lambda_client.invoke(
                FunctionName=reconciler_arn,
                InvocationType="RequestResponse",
                Payload=json.dumps({"source": "pytest"}),
            )

            response_payload = json.loads(invoke_response["Payload"].read())
            LOG.info(
                "Lambda response: %s",
                json.dumps(response_payload, indent=2),
            )

            if invoke_response.get("FunctionError"):
                LOG.error(
                    "Lambda invocation error: %s",
                    response_payload,
                )
                reconciler_successful = False
            else:
                # Verify services were added
                asg_name = percona_pmm["asg_name"]
                expected_count = len(percona_pmm["instance_ips"])

                try:
                    with timeout(seconds=30):
                        while True:
                            services = list_pmm_services(pmm_url, auth_header)
                            reconciler_services = [
                                s
                                for s in (
                                    services.get("services", []) if services else []
                                )
                                if s.get("service_name", "").startswith(f"{asg_name}/")
                            ]
                            if len(reconciler_services) >= expected_count:
                                break
                            time.sleep(2)
                except TimeoutError:
                    reconciler_successful = False

                LOG.info(
                    "Reconciler created %d services for ASG %s:",
                    len(reconciler_services),
                    asg_name,
                )
                for svc in reconciler_services:
                    LOG.info(
                        "  - %s at %s",
                        svc.get("service_name"),
                        svc.get("address"),
                    )

                # Verify pmm-client is installed on each Percona instance
                LOG.info("Verifying pmm-client installation on instances...")
                asg_obj = ASG(
                    asg_name,
                    region=aws_region,
                    role_arn=test_role_arn,
                )
                for inst in asg_obj.instances:
                    exit_code, stdout, _ = inst.execute_command(
                        "dpkg -l pmm-client | grep '^ii'",
                        execution_timeout=30,
                    )
                    assert (
                        exit_code == 0
                    ), f"pmm-client not installed on {inst.instance_id}"
                    LOG.info(
                        "  pmm-client OK on %s: %s",
                        inst.instance_id,
                        stdout.strip(),
                    )

            LOG.info("=" * 80)
            LOG.info("Lambda ASG reconciler test completed")
            LOG.info("=" * 80)
        else:
            LOG.info("No reconciler Lambda deployed, skipping test")

        # Test AWS Backup functionality
        LOG.info("Testing AWS Backup...")
        vault_name = tf_output["backup_vault_name"]["value"]
        volume_id = tf_output["ebs_volume_id"]["value"]
        backup_role_arn = tf_output["backup_role_arn"]["value"]

        validate_backup_creation(
            boto3_session=boto3_session,
            aws_region=aws_region,
            vault_name=vault_name,
            volume_id=volume_id,
            backup_role_arn=backup_role_arn,
        )

        if reconciler_arn and not reconciler_successful:
            LOG.error("FAILED: Lambda reconciler did not work correctly")
            LOG.info("")
            LOG.info("For manual verification/debugging:")
            LOG.info("  PMM URL: %s", pmm_url)
            LOG.info("  Username: admin")
            LOG.info("  Password: %s", admin_password)
            LOG.info("")

            pytest.fail(
                "Lambda reconciler did not register MySQL instances in PMM. "
                "Check logs above for details."
            )
