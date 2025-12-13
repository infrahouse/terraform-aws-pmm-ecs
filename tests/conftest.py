"""Pytest configuration and fixtures for PMM ECS module tests."""
import logging
import time
from textwrap import dedent

import boto3
import pytest
from infrahouse_core.aws.asg import ASG
from infrahouse_core.logging import setup_logging

LOG = logging.getLogger(__name__)
TERRAFORM_ROOT_DIR = "test_data"

setup_logging(LOG, debug=True, debug_botocore=False)


@pytest.fixture(scope="session")
def postgres_pmm(request, service_network, keep_after, aws_region, test_role_arn, boto3_session, postgres):
    """
    Enhanced PostgreSQL fixture with PMM monitoring support.

    Uses AWS Systems Manager (SSM) to configure PostgreSQL from an EC2 instance
    inside the VPC, avoiding direct network connectivity requirements.

    Configures:
    - Custom parameter group with pg_stat_statements enabled
    - pg_stat_statements extension in the database
    - rds_superuser role for monitoring user
    """
    # Create the base PostgreSQL instance
    LOG.info("=" * 80)
    LOG.info("Configuring PostgreSQL for PMM monitoring via SSM")
    LOG.info("=" * 80)

    # Get connection details
    db_host = postgres["address"]["value"]
    db_port = postgres["port"]["value"]
    db_name = postgres["database_name"]["value"]
    db_user = postgres["master_username"]["value"]
    db_password = postgres["master_password"]["value"]

    LOG.info("PostgreSQL instance: %s:%s", db_host, db_port)
    LOG.info("Waiting for PostgreSQL to be fully ready...")
    time.sleep(30)

    # Note: We need the PMM deployment first to get an EC2 instance to run commands from
    # This fixture will be called AFTER the PMM deployment in the test
    # For now, just yield the postgres output - configuration happens in test
    yield postgres


def configure_postgres_via_ssm(instance_id, aws_region, test_role_arn, db_host, db_port, db_name, db_user, db_password):
    """
    Configure PostgreSQL for PMM using SSM commands executed on an EC2 instance in the VPC.

    :param instance_id: EC2 instance ID of the PMM server
    :param aws_region: AWS region
    :param test_role_arn: IAM role ARN to assume (optional)
    :param db_host: PostgreSQL hostname
    :param db_port: PostgreSQL port
    :param db_name: PostgreSQL database name
    :param db_user: PostgreSQL username
    :param db_password: PostgreSQL password
    """
    from infrahouse_core.aws.ec2_instance import EC2Instance

    LOG.info("=" * 80)
    LOG.info("Configuring PostgreSQL via SSM from PMM EC2 instance")
    LOG.info("=" * 80)

    # Create EC2Instance to access the PMM instance
    instance = EC2Instance(instance_id=instance_id, region=aws_region, role_arn=test_role_arn)
    LOG.info("Using EC2 instance: %s", instance.instance_id)

    # Install python3-psycopg2 via apt (Ubuntu Noble uses PEP 668)
    LOG.info("Installing python3-psycopg2 on EC2 instance...")
    install_cmd = dedent("""
        set -e
        export DEBIAN_FRONTEND=noninteractive
        sudo -E apt-get update -qq 2>&1 || true
        sudo -E apt-get install -y -qq python3-psycopg2 2>&1 || true
        echo "Installation complete"
    """).strip()

    exit_code, stdout, stderr = instance.execute_command(install_cmd, execution_timeout=300)

    # Check if installation was actually successful by looking for the success message
    if "Installation complete" not in stdout:
        LOG.error("Failed to install python3-psycopg2")
        LOG.error("STDOUT: %s", stdout)
        LOG.error("STDERR: %s", stderr)
        raise Exception(f"Installation failed - 'Installation complete' marker not found")

    LOG.info("✓ python3-psycopg2 installed")

    # Create Python script to configure PostgreSQL
    python_script = dedent(f"""
        import sys
        import psycopg2

        print("Connecting to PostgreSQL at {db_host}:{db_port}...")
        try:
            conn = psycopg2.connect(
                host='{db_host}',
                port={db_port},
                database='{db_name}',
                user='{db_user}',
                password='{db_password}',
                sslmode='require',
                connect_timeout=30
            )
            conn.autocommit = True
            cursor = conn.cursor()

            # Check shared_preload_libraries
            print("Checking shared_preload_libraries configuration...")
            cursor.execute("SHOW shared_preload_libraries;")
            shared_preload = cursor.fetchone()[0]
            print(f"  shared_preload_libraries = {{shared_preload}}")

            if 'pg_stat_statements' not in shared_preload:
                print("ERROR: pg_stat_statements is NOT in shared_preload_libraries!")
                print(f"  Current value: {{shared_preload}}")
                print("")
                print("To fix this for RDS PostgreSQL:")
                print("  1. Create a custom DB parameter group")
                print("  2. Set: shared_preload_libraries = 'pg_stat_statements'")
                print("  3. Assign the parameter group to the RDS instance")
                print("  4. Reboot the RDS instance")
                sys.exit(1)

            # Enable pg_stat_statements extension
            print("Enabling pg_stat_statements extension...")
            cursor.execute("CREATE EXTENSION IF NOT EXISTS pg_stat_statements;")
            print("✓ pg_stat_statements extension enabled")

            # Grant rds_superuser role
            print("Granting rds_superuser role to {db_user}...")
            cursor.execute("GRANT rds_superuser TO {db_user};")
            print("✓ rds_superuser role granted")

            # Verify extension
            cursor.execute("SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';")
            if cursor.fetchone():
                print("✓ pg_stat_statements extension is installed and ready")
            else:
                print("ERROR: pg_stat_statements extension verification failed!")
                sys.exit(1)

            # Verify role
            cursor.execute("SELECT pg_has_role('{db_user}', 'rds_superuser', 'member');")
            has_role = cursor.fetchone()[0]
            if has_role:
                print("✓ User {db_user} has rds_superuser role")
            else:
                print("ERROR: User {db_user} does NOT have rds_superuser role!")
                sys.exit(1)

            cursor.close()
            conn.close()

            print("")
            print("=" * 60)
            print("PostgreSQL PMM configuration completed successfully")
            print("All requirements for PMM monitoring are satisfied:")
            print("  ✓ shared_preload_libraries includes pg_stat_statements")
            print("  ✓ pg_stat_statements extension is enabled")
            print("  ✓ User has rds_superuser role")
            print("=" * 60)

        except Exception as e:
            print(f"ERROR: Failed to configure PostgreSQL: {{e}}")
            import traceback
            traceback.print_exc()
            sys.exit(1)
    """).strip()

    # Execute the configuration script via heredoc to avoid shell escaping issues
    LOG.info("Executing PostgreSQL configuration script...")
    config_cmd = dedent(f"""
        python3 <<'PYTHON_SCRIPT_EOF'
{python_script}
PYTHON_SCRIPT_EOF
    """).strip()

    exit_code, stdout, stderr = instance.execute_command(config_cmd, execution_timeout=300)

    # Log the output
    if stdout:
        for line in stdout.strip().split('\n'):
            LOG.info("  %s", line)

    if exit_code != 0:
        LOG.error("=" * 80)
        LOG.error("POSTGRESQL PMM CONFIGURATION FAILED")
        LOG.error("=" * 80)
        if stderr:
            LOG.error("Error output:")
            for line in stderr.strip().split('\n'):
                LOG.error("  %s", line)
        raise Exception(f"PostgreSQL configuration failed with exit code {exit_code}")

    LOG.info("=" * 80)
    LOG.info("PostgreSQL successfully configured for PMM monitoring")
    LOG.info("=" * 80)


def wait_for_instance_refresh(asg_name, aws_region, test_role_arn, timeout=600):
    """
    Wait for any in-progress ASG instance refreshes to complete.

    :param asg_name: Name of the Auto Scaling Group
    :param aws_region: AWS region
    :param test_role_arn: IAM role ARN to assume (optional)
    :param timeout: Maximum time to wait in seconds (default 600 = 10 minutes)
    """
    LOG.info("=" * 80)
    LOG.info("Checking for in-progress ASG instance refreshes")
    LOG.info("=" * 80)

    # Create boto3 client
    if test_role_arn:
        sts = boto3.client('sts', region_name=aws_region)
        assumed_role = sts.assume_role(
            RoleArn=test_role_arn,
            RoleSessionName="pmm-test-instance-refresh-check"
        )
        credentials = assumed_role['Credentials']
        asg_client = boto3.client(
            'autoscaling',
            region_name=aws_region,
            aws_access_key_id=credentials['AccessKeyId'],
            aws_secret_access_key=credentials['SecretAccessKey'],
            aws_session_token=credentials['SessionToken']
        )
    else:
        asg_client = boto3.client('autoscaling', region_name=aws_region)

    start_time = time.time()
    last_status = None

    while time.time() - start_time < timeout:
        try:
            # Check for instance refreshes
            response = asg_client.describe_instance_refreshes(
                AutoScalingGroupName=asg_name,
                MaxRecords=10
            )

            instance_refreshes = response.get('InstanceRefreshes', [])

            # Filter for in-progress refreshes
            in_progress = [
                ir for ir in instance_refreshes
                if ir['Status'] in ['Pending', 'InProgress', 'Cancelling', 'RollbackInProgress']
            ]

            if not in_progress:
                if last_status is not None:
                    LOG.info("All instance refreshes completed")
                else:
                    LOG.info("No in-progress instance refreshes found")
                LOG.info("=" * 80)
                return

            # Log status of in-progress refreshes
            for refresh in in_progress:
                refresh_id = refresh['InstanceRefreshId']
                status = refresh['Status']
                percentage = refresh.get('PercentageComplete', 0)

                status_msg = f"Instance refresh {refresh_id}: {status} ({percentage}% complete)"
                if status_msg != last_status:
                    LOG.info(status_msg)
                    last_status = status_msg

            time.sleep(10)  # Check every 10 seconds

        except Exception as e:
            LOG.warning("Error checking instance refresh status: %s", e)
            LOG.warning("Continuing anyway...")
            break

    if time.time() - start_time >= timeout:
        LOG.warning("Timeout waiting for instance refresh to complete")
        LOG.warning("Continuing anyway...")

    LOG.info("=" * 80)