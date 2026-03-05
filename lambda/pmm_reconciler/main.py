"""
Lambda function to reconcile ASG membership with PMM monitored services.

Installs pmm-client on new ASG instances via SSM, configures them to
connect to the PMM server, and adds MySQL monitoring. Removes services
for terminated instances via the PMM HTTP API.
"""

import json
import os
from base64 import b64encode
from logging import getLogger
from textwrap import dedent
from typing import Dict, List, Tuple

import requests
from infrahouse_core.aws.asg import ASG
from infrahouse_core.logging import setup_logging
from infrahouse_core.aws.asg_instance import ASGInstance
from infrahouse_core.aws.secretsmanager import Secret

LOG = getLogger(__name__)

setup_logging(LOG)


PMM_HOST = os.environ.get("PMM_HOST", "")
PMM_ADMIN_SECRET_ARN = os.environ.get("PMM_ADMIN_SECRET_ARN", "")
MONITORED_ASGS_CONFIG = os.environ.get("MONITORED_ASGS_CONFIG", "[]")
AWS_REGION = os.environ.get("PMM_AWS_REGION", "us-east-1")


def _shell_escape(value: str) -> str:
    """
    Escape a string for safe embedding inside single-quoted shell strings.

    Replaces each single quote with the sequence ``'\\''`` which ends the
    current single-quoted string, adds an escaped literal quote, and
    reopens a new single-quoted string.

    :param value: Raw string to escape.
    :return: Escaped string safe for single-quoted shell contexts.
    """
    return value.replace("'", "'\\''")


class PMMClient:
    """
    Client for the Percona Monitoring and Management (PMM) HTTP API.

    Used only for listing existing services and removing services
    for terminated instances.

    :param base_url: PMM server base URL (e.g., ``http://10.0.1.5``).
    :type base_url: str
    :param username: PMM admin username.
    :type username: str
    :param password: PMM admin password.
    :type password: str
    :param timeout: HTTP request timeout in seconds.
    :type timeout: int
    """

    def __init__(
        self,
        base_url: str,
        username: str,
        password: str,
        timeout: int = 30,
    ):
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout
        encoded = b64encode(f"{username}:{password}".encode()).decode()
        self._headers = {
            "Authorization": f"Basic {encoded}",
            "Content-Type": "application/json",
        }

    @property
    def services(self) -> List[Dict]:
        """
        List all services registered in PMM.

        :return: List of service dicts from the PMM API.
        """
        url = f"{self._base_url}/v1/management/services"
        response = requests.get(
            url,
            headers=self._headers,
            timeout=self._timeout,
        )
        response.raise_for_status()
        return response.json().get("services", [])

    def remove_service(self, service_id: str) -> None:
        """
        Remove a service from PMM inventory.

        :param service_id: PMM service ID to remove.
        """
        url = f"{self._base_url}/v1/inventory/services/{service_id}"
        response = requests.delete(
            url,
            headers=self._headers,
            params={"force": "true"},
            timeout=self._timeout,
        )
        response.raise_for_status()


def ensure_pmm_client(
    instance: ASGInstance,
    pmm: PMMClient,
    pmm_host: str,
    pmm_password: str,
    db_username: str,
    port: int,
    service_name: str,
    existing_service_id: str = None,
) -> None:
    """
    Install and configure pmm-client on a Percona instance via SSM.

    Runs an idempotent bash script that:

    1. Installs pmm-client if not already present (via percona-release).
    2. Configures the PMM server connection if not already connected.
       Connects directly to the PMM instance on port 443 (HTTPS with
       self-signed cert) because pmm-agent uses gRPC which is not
       supported by ALB.
    3. Reads DB credentials from the instance's own Puppet facts and
       Secrets Manager (via ``ih-secrets get``).
    4. Adds MySQL monitoring if not already registered locally.

    If the service already exists on the PMM server (e.g., from a
    previous remote-node registration) but not locally, it is removed
    via the PMM API before running ``pmm-admin add mysql``.

    :param instance: ASGInstance object with ``execute_command()`` method.
    :param pmm: PMMClient for removing stale services.
    :param pmm_host: PMM server private IP address.
    :param pmm_password: PMM admin password.
    :param db_username: Key in the credentials JSON for password lookup.
    :param port: MySQL port number.
    :param service_name: Service name for PMM (e.g., ``asg-name/hostname``).
    :param existing_service_id: PMM service ID if already registered on server.
    """
    # The PMM admin password is embedded in the script via f-string.
    # Alternatives (SSM env vars, Secrets Manager on instance) were
    # considered but either are not supported by SSM SendCommand or
    # would grant every ASG instance access to the PMM admin secret.
    # Current mitigations: base64-encoded, umask 077, immediate cleanup.
    # The password does appear in SSM command history, which is an
    # inherent trade-off of any SSM-based approach.
    script = dedent(
        f"""\
        #!/bin/bash
        set -euo pipefail
        export PATH=/opt/puppetlabs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

        # Step 1: Install pmm-client if not present
        if ! dpkg -l pmm-client 2>/dev/null | grep -q "^ii"; then
            echo 'Installing pmm-client...'
            percona-release enable pmm3-client
            DEBIAN_FRONTEND=noninteractive apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pmm-client
            echo 'pmm-client installed'
        fi

        # Step 2: Configure PMM server connection if not connected
        if ! pmm-admin status 2>/dev/null | grep -q "Connected.*true"; then
            echo 'Configuring PMM server connection...'
            pmm-admin config \
                --server-insecure-tls \
                --server-url='https://admin:{_shell_escape(pmm_password)}@{_shell_escape(pmm_host)}' \
                --force
            systemctl restart pmm-agent
            echo 'Waiting for pmm-agent to connect...'
            for i in $(seq 1 30); do
                if pmm-admin status 2>/dev/null | grep -q "Connected.*true"; then
                    echo 'pmm-agent connected'
                    break
                fi
                sleep 2
            done
            echo 'PMM server configured'
        fi

        # Step 3: Add MySQL monitoring if mysqld_exporter is not running
        if ! pmm-admin status 2>/dev/null | grep -q "mysqld_exporter"; then
            echo 'Reading DB credentials from Puppet facts...'
            CREDS_SECRET=$(facter -p percona.credentials_secret)
            DB_PASSWORD=$(ih-secrets get "$CREDS_SECRET" | jq -r '.{_shell_escape(db_username)}')
            echo 'Adding MySQL monitoring...'
            ADD_OUTPUT=$(pmm-admin add mysql \
                --username='{_shell_escape(db_username)}' \
                --password="$DB_PASSWORD" \
                --host=127.0.0.1 \
                --port={port} \
                --query-source=perfschema \
                --service-name='{_shell_escape(service_name)}' 2>&1) || {{
                if echo "$ADD_OUTPUT" | grep -q "already exists"; then
                    echo 'MySQL monitoring already registered'
                else
                    echo "$ADD_OUTPUT"
                    exit 1
                fi
            }}
            echo 'MySQL monitoring added'
        fi

        echo 'pmm-client setup complete'
        """
    )

    script_b64 = b64encode(script.encode()).decode()
    wrapper = (
        f"umask 077"
        f" && echo {script_b64} | base64 -d > /tmp/pmm-setup.sh"
        f" && chmod 700 /tmp/pmm-setup.sh"
        f" && sudo /tmp/pmm-setup.sh"
        f"; rc=$?; rm -f /tmp/pmm-setup.sh; exit $rc"
    )

    LOG.info(
        "Running pmm-client setup on %s (service: %s)",
        instance.instance_id,
        service_name,
    )

    exit_code, stdout, stderr = instance.execute_command(
        wrapper,
        execution_timeout=300,
    )

    if stdout:
        for line in stdout.strip().split("\n"):
            LOG.info("  [%s] %s", instance.instance_id, line)

    # If pmm-admin add mysql failed because the service already exists
    # on the PMM server (e.g., from a previous remote-node registration),
    # remove the stale service via API and retry.
    if exit_code != 0 and existing_service_id:
        combined = (stdout or "") + (stderr or "")
        if "already exists" in combined:
            LOG.info(
                "Service %s exists on server but not locally, "
                "removing stale service (id=%s) and retrying",
                service_name,
                existing_service_id,
            )
            pmm.remove_service(existing_service_id)
            exit_code, stdout, stderr = instance.execute_command(
                wrapper,
                execution_timeout=300,
            )
            if stdout:
                for line in stdout.strip().split("\n"):
                    LOG.info("  [%s] %s", instance.instance_id, line)

    if exit_code != 0:
        LOG.error(
            "pmm-client setup failed on %s (exit_code=%d)",
            instance.instance_id,
            exit_code,
        )
        if stderr:
            for line in stderr.strip().split("\n"):
                LOG.error("  [%s] %s", instance.instance_id, line)
        raise RuntimeError(
            f"pmm-client setup failed on {instance.instance_id}: "
            f"exit_code={exit_code}"
        )


def reconcile_asg(
    asg_config: Dict,
    pmm: PMMClient,
    pmm_host: str,
    pmm_password: str,
    existing_services: List[Dict],
) -> Tuple[int, int]:
    """
    Reconcile a single ASG's instances with PMM services.

    For NEW instances: installs pmm-client via SSM and configures monitoring.
    For TERMINATED instances: removes the service via PMM HTTP API.
    For EXISTING instances: skips (already configured).

    Services are named ``{asg_name}/{hostname}`` where hostname is the
    instance's private DNS short name (e.g., ``ip-10-0-1-42``).

    :param asg_config: ASG configuration dict with keys: asg_name,
        service_type, port, username.
    :param pmm: PMMClient instance (for listing/removing services).
    :param pmm_host: PMM server private IP for pmm-client config.
    :param pmm_password: PMM admin password for pmm-client config.
    :param existing_services: List of existing PMM service dicts.
    :return: Tuple of (added_count, removed_count).
    """
    asg_name = asg_config["asg_name"]
    service_type = asg_config["service_type"]
    port = asg_config["port"]
    username = asg_config["username"]

    LOG.info("Reconciling ASG: %s (type=%s)", asg_name, service_type)

    # Get InService instances from ASG -- store ASGInstance objects
    asg = ASG(asg_name, region=AWS_REGION)
    instances = asg.instances
    instance_map: Dict[str, ASGInstance] = {}
    for inst in instances:
        expected_name = f"{asg_name}/{inst.hostname}"
        instance_map[expected_name] = inst

    LOG.info(
        "ASG %s has %d InService instances",
        asg_name,
        len(instance_map),
    )

    # Build set of existing PMM service names for this ASG
    # and map service_name -> service_id for removal
    existing_map: Dict[str, str] = {}
    for svc in existing_services:
        svc_name = svc.get("service_name", "")
        if svc_name.startswith(f"{asg_name}/"):
            existing_map[svc_name] = svc.get("service_id")

    LOG.info(
        "PMM has %d services for ASG %s",
        len(existing_map),
        asg_name,
    )

    # Ensure pmm-client is installed on all current instances.
    # The script is idempotent -- it skips steps already done.
    added = 0
    for svc_name, inst in instance_map.items():
        LOG.info(
            "Ensuring pmm-client: %s (%s)",
            svc_name,
            inst.private_ip,
        )
        if service_type == "mysql":
            ensure_pmm_client(
                instance=inst,
                pmm=pmm,
                pmm_host=pmm_host,
                pmm_password=pmm_password,
                db_username=username,
                port=port,
                service_name=svc_name,
                existing_service_id=existing_map.get(svc_name),
            )
            if svc_name not in existing_map:
                added += 1

    # Remove terminated instances via PMM API
    removed = 0
    to_remove = set(existing_map.keys()) - set(instance_map.keys())
    for svc_name in to_remove:
        service_id = existing_map[svc_name]
        LOG.info("Removing service: %s (id=%s)", svc_name, service_id)
        pmm.remove_service(service_id)
        removed += 1

    LOG.info(
        "ASG %s: added %d, removed %d services",
        asg_name,
        added,
        removed,
    )
    return added, removed


def lambda_handler(event: Dict, context: object) -> Dict:
    """
    Lambda entry point. Reconciles all configured ASGs with PMM.

    :param event: Lambda event (from EventBridge schedule).
    :param context: Lambda context object.
    :return: Dict with reconciliation results.
    """
    LOG.info("Starting PMM ASG reconciliation")
    LOG.info("PMM host: %s", PMM_HOST)

    asg_configs = json.loads(MONITORED_ASGS_CONFIG)
    if not asg_configs:
        LOG.info("No ASGs configured, nothing to do")
        return {"status": "ok", "message": "No ASGs configured"}

    # Get PMM admin password and create client
    pmm_password = Secret(PMM_ADMIN_SECRET_ARN, region=AWS_REGION).value
    pmm = PMMClient(
        base_url=f"http://{PMM_HOST}",
        username="admin",
        password=pmm_password,
    )

    # Get all existing services once
    existing_services = pmm.services

    total_added = 0
    total_removed = 0
    errors = []

    for asg_config in asg_configs:
        try:
            added, removed = reconcile_asg(
                asg_config,
                pmm,
                pmm_host=PMM_HOST,
                pmm_password=pmm_password,
                existing_services=existing_services,
            )
            total_added += added
            total_removed += removed
        except (requests.exceptions.RequestException, TimeoutError) as exc:
            LOG.error(
                "Failed to reconcile ASG %s: %s",
                asg_config["asg_name"],
                exc,
            )
            errors.append(f"{asg_config['asg_name']}: {str(exc)}")

    result = {
        "status": "error" if errors else "ok",
        "added": total_added,
        "removed": total_removed,
        "errors": errors,
    }
    LOG.info("Reconciliation complete: %s", json.dumps(result))

    if errors:
        raise RuntimeError(
            f"Reconciliation failed for {len(errors)} ASG(s): "
            + "; ".join(errors)
        )

    return result
