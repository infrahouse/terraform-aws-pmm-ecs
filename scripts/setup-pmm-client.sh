#!/bin/bash
# Setup PMM client for monitoring RDS instances
#
# Usage: ./setup-pmm-client.sh <pmm-server-url> <rds-endpoint> <db-username>
#
# Example:
#   ./setup-pmm-client.sh https://pmm.example.com \
#     mydb.cluster-abc123.us-west-1.rds.amazonaws.com \
#     pmm_user

set -e

PMM_SERVER_URL=${1}
RDS_ENDPOINT=${2}
DB_USERNAME=${3}

if [ -z "$PMM_SERVER_URL" ] || [ -z "$RDS_ENDPOINT" ] || [ -z "$DB_USERNAME" ]; then
    echo "Usage: $0 <pmm-server-url> <rds-endpoint> <db-username>"
    exit 1
fi

# Retrieve admin password from Secrets Manager
SECRET_ID="pmm-server-admin-password"
ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_ID" \
    --query SecretString \
    --output text)

# Prompt for database password
read -sp "Enter database password for $DB_USERNAME: " DB_PASSWORD
echo

# Add PostgreSQL instance to PMM
curl -k -X POST \
    -u "admin:$ADMIN_PASSWORD" \
    "$PMM_SERVER_URL/v1/inventory/Services/AddPostgreSQLService" \
    -H "Content-Type: application/json" \
    -d '{
        "node_name": "'"$RDS_ENDPOINT"'",
        "service_name": "postgresql-'"$RDS_ENDPOINT"'",
        "address": "'"$RDS_ENDPOINT"'",
        "port": 5432,
        "username": "'"$DB_USERNAME"'",
        "password": "'"$DB_PASSWORD"'",
        "add_node": {
            "node_name": "'"$RDS_ENDPOINT"'"
        }
    }'

echo ""
echo "PostgreSQL instance $RDS_ENDPOINT added to PMM successfully!"
echo "View metrics at: $PMM_SERVER_URL/graph/d/postgresql-instance-summary/postgresql-instance-summary"