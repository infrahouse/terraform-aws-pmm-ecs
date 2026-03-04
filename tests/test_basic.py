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
                    LOG.info("✓ Backup completed successfully!")
                    LOG.info("Recovery point: %s", recovery_point_arn)
                    return
                elif status in ["FAILED", "ABORTED", "EXPIRED"]:
                    LOG.error(
                        "Backup job details: %s", json.dumps(job, indent=2, default=str)
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

    # Prepare the payload with inline node creation
    # Note: Using NODE_TYPE_REMOTE_NODE instead of NODE_TYPE_REMOTE_RDS_NODE
    # because add_node only supports generic remote nodes
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
            "skip_connection_check": False,  # Re-enable connection check now that we have TLS
            "tls": True,  # RDS requires SSL/TLS
            "tls_skip_verify": True,  # Skip certificate verification (no CA cert configured)
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

    # Log response details for debugging
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
        # Log the detailed error message from PMM
        try:
            error_detail = service_response.json()
            LOG.error("PMM API error details: %s", json.dumps(error_detail, indent=2))
        except:
            LOG.error("PMM API error response: %s", service_response.text)
        raise Exception(
            f"Failed to add PostgreSQL service: {e}. Response: {service_response.text[:500]}"
        )


def check_mysql_in_pmm(pmm_url, auth_header, mysql_address):
    """Check if a MySQL instance is already monitored in PMM."""
    services = list_pmm_services(pmm_url, auth_header)
    if not services:
        return False

    for service in services.get("services", []):
        service_type = service.get("service_type", "").upper()
        service_address = service.get("address", "")

        if (
            service_type in ("MYSQL_SERVICE", "MYSQL")
            and mysql_address in service_address
        ):
            LOG.info(
                "MySQL instance already registered: %s",
                service.get("service_name"),
            )
            return True
    return False


def add_mysql_to_pmm(
    pmm_url,
    auth_header,
    mysql_address,
    mysql_port,
    mysql_username,
    mysql_password,
    service_name="test-mysql-percona",
    node_id=None,
):
    """
    Add MySQL instance to PMM monitoring using PMM 3 API.

    :param pmm_url: PMM server URL
    :param auth_header: Authentication header dict
    :param mysql_address: MySQL hostname
    :param mysql_port: MySQL port
    :param mysql_username: MySQL username
    :param mysql_password: MySQL password
    :param service_name: Name for the service in PMM
    :param node_id: Existing PMM node ID to reuse (skips add_node)
    :return: API response data
    """
    pmm_agent_id = get_pmm_server_agent_id(pmm_url, auth_header)
    if not pmm_agent_id:
        raise Exception("Could not find PMM agent ID")

    add_service_url = f"{pmm_url}/v1/management/services"

    mysql_params = {
        "service_name": service_name,
        "address": mysql_address,
        "port": int(mysql_port),
        "username": mysql_username,
        "password": mysql_password,
        "pmm_agent_id": pmm_agent_id,
        "qan_mysql_perfschema": True,
        "skip_connection_check": False,
    }

    if node_id:
        mysql_params["node_id"] = node_id
    else:
        mysql_params["add_node"] = {
            "node_type": "NODE_TYPE_REMOTE_NODE",
            "node_name": f"{service_name}-node",
            "region": os.environ.get("AWS_DEFAULT_REGION", "us-west-2"),
        }

    service_payload = {"mysql": mysql_params}

    LOG.info("Adding MySQL service to PMM...")
    LOG.debug("Payload: %s", json.dumps(service_payload, indent=2))

    response = requests.post(
        add_service_url,
        headers={
            **auth_header,
            "Content-Type": "application/json",
        },
        json=service_payload,
        timeout=30,
    )

    LOG.debug("Response status: %d", response.status_code)
    LOG.debug("Response body: %s", response.text[:1000])

    try:
        response.raise_for_status()
        data = response.json()
        LOG.info(
            "MySQL service added successfully: %s",
            json.dumps(data, indent=2),
        )
        return data
    except requests.exceptions.HTTPError as e:
        try:
            error_detail = response.json()
            LOG.error(
                "PMM API error details: %s",
                json.dumps(error_detail, indent=2),
            )
        except ValueError:
            LOG.error("PMM API error response: %s", response.text)
        raise Exception(
            f"Failed to add MySQL service: {e}. " f"Response: {response.text[:500]}"
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
    postgres_pmm,
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

    print(json.dumps(postgres_pmm, indent=4))

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

                # Pass postgres fixture outputs
                postgres_security_group_id = "{postgres_pmm["security_group_id"]["value"]}"
                postgres_endpoint = "{postgres_pmm["endpoint"]["value"]}"
                postgres_address = "{postgres_pmm["address"]["value"]}"
                postgres_port = {postgres_pmm["port"]["value"]}
                postgres_database = "{postgres_pmm["database_name"]["value"]}"
                postgres_username = "{postgres_pmm["master_username"]["value"]}"
                postgres_password = "{postgres_pmm["master_password"]["value"]}"

                # Pass MySQL fixture outputs
                mysql_security_group_id = "{percona_pmm["security_group_id"]}"
                mysql_address = "{percona_pmm["address"]}"
                mysql_port = {percona_pmm["port"]}
                mysql_username = "{percona_pmm["username"]}"
                mysql_password = "{percona_pmm["password"]}"
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
            db_host=tf_output["postgres_address"]["value"],
            db_port=tf_output["postgres_port"]["value"],
            db_name=tf_output["postgres_database"]["value"],
            db_user=tf_output["postgres_username"]["value"],
            db_password=tf_output["postgres_password"]["value"],
        )

        # Test PostgreSQL monitoring integration
        LOG.info("=" * 80)
        LOG.info("Testing PostgreSQL monitoring integration")
        LOG.info("=" * 80)

        # Check PMM version to understand API structure
        LOG.info("Checking PMM version...")
        pmm_version = get_pmm_version(pmm_url)

        # Get PostgreSQL connection details from outputs
        postgres_address = tf_output["postgres_address"]["value"]
        postgres_port = tf_output["postgres_port"]["value"]
        postgres_database = tf_output["postgres_database"]["value"]
        postgres_username = tf_output["postgres_username"]["value"]
        postgres_password = tf_output["postgres_password"]["value"]

        LOG.info("PostgreSQL instance: %s:%s", postgres_address, postgres_port)

        # Prepare PMM API authentication
        auth_header = get_pmm_auth_header("admin", admin_password)

        # Check Swagger UI is accessible
        LOG.info("Checking PMM Swagger UI accessibility...")
        swagger_response = requests.get(
            f"{pmm_url}/swagger/",
            auth=("admin", admin_password),
            timeout=10,
            allow_redirects=False,
        )
        LOG.info("Swagger UI status: %d", swagger_response.status_code)
        if swagger_response.status_code in (200, 301, 302):
            LOG.info("Swagger UI is available at %s/swagger/", pmm_url)

        # Check if PostgreSQL is already monitored
        LOG.info("Checking if PostgreSQL is already monitored in PMM...")
        is_monitored = check_postgres_in_pmm(pmm_url, auth_header, postgres_address)

        api_integration_successful = False

        if is_monitored:
            LOG.info("PostgreSQL instance is already being monitored by PMM")
            api_integration_successful = True
        else:
            LOG.info("PostgreSQL instance not found in PMM, attempting to add it...")
            try:
                add_postgres_to_pmm(
                    pmm_url=pmm_url,
                    auth_header=auth_header,
                    postgres_address=postgres_address,
                    postgres_port=postgres_port,
                    postgres_database=postgres_database,
                    postgres_username=postgres_username,
                    postgres_password=postgres_password,
                    service_name=f"test-postgres-{aws_region}",
                )
                LOG.info("PostgreSQL instance successfully added to PMM via API")

                # Note: The QAN agent may show as "Waiting" if:
                # 1. pg_stat_statements extension is not enabled
                # 2. PostgreSQL user doesn't have rds_superuser role
                # 3. Parameter group doesn't have shared_preload_libraries configured
                LOG.info("")
                LOG.info("Note: For full PMM monitoring, ensure PostgreSQL has:")
                LOG.info("  - pg_stat_statements extension enabled")
                LOG.info("  - User has rds_superuser role (for RDS)")
                LOG.info(
                    "  - Parameter group: shared_preload_libraries = 'pg_stat_statements'"
                )
                LOG.info("")

                # Verify it's now in the list
                time.sleep(5)
                is_monitored = check_postgres_in_pmm(
                    pmm_url, auth_header, postgres_address
                )
                if is_monitored:
                    LOG.info("Verified: PostgreSQL is now being monitored by PMM")
                    api_integration_successful = True
                else:
                    LOG.warning("PostgreSQL was added but not found in services list")
            except Exception as e:
                LOG.warning("Could not add PostgreSQL via API: %s", e)
                LOG.warning("This may be due to PMM 3 API changes")

        # List all services for verification
        LOG.info("Listing all services in PMM...")
        services = list_pmm_services(pmm_url, auth_header)
        if services:
            LOG.info("PMM Services (%d total):", len(services.get("services", [])))
            for service in services.get("services", []):
                LOG.info(
                    "  - %s (%s) at %s",
                    service.get("service_name"),
                    service.get("service_type"),
                    service.get("address", "N/A"),
                )
        else:
            LOG.warning("Could not retrieve services list via API")

        LOG.info("=" * 80)
        LOG.info("PostgreSQL monitoring test completed")
        LOG.info("=" * 80)

        # Test MySQL monitoring integration
        LOG.info("=" * 80)
        LOG.info("Testing MySQL monitoring integration")
        LOG.info("=" * 80)

        mysql_username = tf_output["mysql_username"]["value"]
        mysql_password = tf_output["mysql_password"]["value"]

        mysql_integration_successful = True
        mysql_failed = []

        # Build list of MySQL services to register:
        # writer NLB endpoint + individual cluster nodes
        mysql_services = []

        writer_ep = percona_pmm["writer_endpoint"]
        writer_host, writer_port = writer_ep.rsplit(":", 1)
        mysql_services.append(("test-mysql-writer", writer_host, int(writer_port)))

        for idx, ip in enumerate(percona_pmm["instance_ips"]):
            mysql_services.append((f"test-mysql-node-{idx}", ip, 3306))

        for svc_name, svc_host, svc_port in mysql_services:
            if check_mysql_in_pmm(pmm_url, auth_header, svc_host):
                LOG.info("%s already monitored, skipping", svc_name)
                continue
            LOG.info(
                "Adding MySQL service: %s (%s:%d)",
                svc_name,
                svc_host,
                svc_port,
            )
            try:
                add_mysql_to_pmm(
                    pmm_url=pmm_url,
                    auth_header=auth_header,
                    mysql_address=svc_host,
                    mysql_port=svc_port,
                    mysql_username=mysql_username,
                    mysql_password=mysql_password,
                    service_name=svc_name,
                )
                LOG.info("Successfully added %s to PMM", svc_name)
            except Exception as e:
                LOG.warning("Could not add %s to PMM: %s", svc_name, e)
                mysql_failed.append(svc_name)

        if mysql_failed:
            mysql_integration_successful = False
            LOG.warning(
                "Failed to add %d MySQL services: %s",
                len(mysql_failed),
                mysql_failed,
            )

        # List all services for verification
        time.sleep(5)
        LOG.info("Listing all services in PMM...")
        services = list_pmm_services(pmm_url, auth_header)
        if services:
            LOG.info(
                "PMM Services (%d total):",
                len(services.get("services", [])),
            )
            for service in services.get("services", []):
                LOG.info(
                    "  - %s (%s) at %s",
                    service.get("service_name"),
                    service.get("service_type"),
                    service.get("address", "N/A"),
                )

        LOG.info("=" * 80)
        LOG.info("MySQL monitoring test completed")
        LOG.info("=" * 80)

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

        failures = []
        if api_integration_successful:
            LOG.info("Status: PostgreSQL successfully added to PMM")
        else:
            LOG.error("FAILED: Could not add PostgreSQL instance to PMM")
            failures.append("PostgreSQL")

        if mysql_integration_successful:
            LOG.info("Status: MySQL successfully added to PMM")
        else:
            LOG.error("FAILED: Could not add MySQL instance to PMM")
            failures.append("MySQL")

        if failures:
            LOG.info("")
            LOG.info("For manual verification/debugging:")
            LOG.info("  PMM URL: %s", pmm_url)
            LOG.info("  Username: admin")
            LOG.info("  Password: %s", admin_password)
            LOG.info("")

            pytest.fail(
                f"Failed to add {', '.join(failures)} to PMM "
                f"monitoring. Check logs above for details."
            )
