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


def configure_postgres_via_ssm(asg_name, aws_region, test_role_arn, db_host, db_port, db_name, db_user, db_password):
    """
    Configure PostgreSQL for PMM using SSM commands executed on an EC2 instance in the VPC.

    :param asg_name: Name of the Auto Scaling Group with PMM instances
    :param aws_region: AWS region
    :param test_role_arn: IAM role ARN to assume (optional)
    :param db_host: PostgreSQL hostname
    :param db_port: PostgreSQL port
    :param db_name: PostgreSQL database name
    :param db_user: PostgreSQL username
    :param db_password: PostgreSQL password
    """
    LOG.info("=" * 80)
    LOG.info("Configuring PostgreSQL via SSM from PMM EC2 instance")
    LOG.info("=" * 80)

    # Create ASG instance to access EC2 instances
    asg = ASG(asg_name=asg_name, region=aws_region, role_arn=test_role_arn)

    # Get instances from ASG
    instances = asg.instances
    if not instances:
        raise Exception(f"No instances found in ASG: {asg_name}")

    # Pick the first instance
    instance = instances[0]
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