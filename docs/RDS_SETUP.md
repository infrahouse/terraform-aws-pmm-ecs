# RDS Monitoring Setup Guide

This guide explains how to configure PMM to monitor Amazon RDS PostgreSQL instances.

## Prerequisites

- PMM server deployed using this module
- RDS PostgreSQL instance running
- Network connectivity between PMM and RDS (same VPC or VPC peering)

## Architecture Overview

```
PMM Server (ECS) ──┐
                   │
                   ├──> RDS Security Group (Port 5432)
                   │         │
                   │         └──> RDS PostgreSQL Instance
                   │
                   └──> Secrets Manager (PMM Password)
```

## Step 1: Configure Module for RDS Monitoring

Add RDS security group IDs to the PMM module:

```hcl
module "pmm" {
  source = "infrahouse/pmm-ecs/aws"

  # ... other configuration ...

  # Grant PMM access to RDS instances
  rds_security_group_ids = [
    aws_security_group.rds_postgres.id,
  ]

  # Optional: Grant RDS IAM role read access to PMM password
  secret_readers = [
    aws_iam_role.rds_monitoring.arn,
  ]
}
```

This automatically creates security group ingress rules allowing PMM to connect to RDS on port 5432.

## Step 2: Create Monitoring User in PostgreSQL

Connect to your RDS instance and create a dedicated monitoring user:

```sql
-- Create monitoring user
CREATE USER pmm_user WITH PASSWORD 'secure_password_here';

-- Grant necessary permissions for PMM
ALTER USER pmm_user SET SEARCH_PATH TO pmm_user,pg_catalog,public;

-- Grant required privileges
GRANT SELECT ON ALL TABLES IN SCHEMA public TO pmm_user;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO pmm_user;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO pmm_user;

-- For Query Analytics (requires pg_stat_statements)
GRANT pg_read_all_stats TO pmm_user;
GRANT pg_monitor TO pmm_user;

-- Create extension (if not already exists)
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
```

### RDS Parameter Group Configuration

For optimal monitoring, modify your RDS parameter group:

```
shared_preload_libraries = 'pg_stat_statements'
pg_stat_statements.track = all
pg_stat_statements.max = 10000
track_io_timing = on
track_functions = all
```

**Important**: Changing `shared_preload_libraries` requires instance reboot.

## Step 3: Retrieve PMM Admin Password

```bash
# Get admin password from Secrets Manager
PMM_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id pmm-server-admin-password \
    --query SecretString \
    --output text)

# Or use the Terraform output
PMM_SECRET_ARN=$(terraform output -raw admin_password_secret_arn)
PMM_PASSWORD=$(aws secretsmanager get-secret-value \
    --secret-id "$PMM_SECRET_ARN" \
    --query SecretString \
    --output text)
```

## Step 4: Add RDS Instance to PMM

### Option A: Using PMM Web UI

1. Navigate to `https://pmm.your-domain.com`
2. Login with username `admin` and password from Step 3
3. Go to **Configuration** → **Inventory** → **Add Instance**
4. Select **PostgreSQL**
5. Fill in the details:
   - **Hostname**: Your RDS endpoint (e.g., `mydb.cluster-abc123.us-west-1.rds.amazonaws.com`)
   - **Port**: `5432`
   - **Username**: `pmm_user`
   - **Password**: The password you created in Step 2
   - **Service Name**: Descriptive name (e.g., `production-postgres`)
6. Click **Add Service**

### Option B: Using PMM API

```bash
# Set variables
PMM_URL="https://pmm.your-domain.com"
RDS_ENDPOINT="mydb.cluster-abc123.us-west-1.rds.amazonaws.com"
DB_USERNAME="pmm_user"
DB_PASSWORD="secure_password_here"

# Add PostgreSQL service
curl -k -X POST \
    -u "admin:$PMM_PASSWORD" \
    "$PMM_URL/v1/inventory/Services/AddPostgreSQLService" \
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
```

### Option C: Using the Provided Script

```bash
# Use the helper script
./scripts/setup-pmm-client.sh \
    https://pmm.your-domain.com \
    mydb.cluster-abc123.us-west-1.rds.amazonaws.com \
    pmm_user
```

The script will:
1. Retrieve PMM admin password from Secrets Manager
2. Prompt for database password
3. Register the RDS instance with PMM

## Step 5: Verify Monitoring

1. Navigate to PMM web interface
2. Go to **Dashboards** → **PostgreSQL** → **PostgreSQL Instance Summary**
3. Select your RDS instance from the dropdown
4. Verify metrics are being collected

You should see:
- Connection statistics
- Query performance metrics
- Buffer cache statistics
- Replication lag (if applicable)

## Advanced Configuration

### Enable Slow Query Log

Modify RDS parameter group:

```
log_min_duration_statement = 100  # Log queries slower than 100ms
```

PMM will automatically parse and display slow queries in Query Analytics.

### Configure Query Analytics

In PMM UI:
1. Go to **Configuration** → **Query Analytics**
2. Enable for your PostgreSQL service
3. Set sampling rate (default: 100%)

### Monitor Multiple Databases

Repeat Step 4 for each RDS instance, using the same `rds_security_group_ids` configuration.

## Security Best Practices

1. **Least Privilege**: Only grant necessary permissions to `pmm_user`
2. **Strong Passwords**: Use complex passwords for monitoring users
3. **Network Isolation**: Keep PMM in private subnets
4. **Audit Logging**: Enable RDS audit logs for monitoring user access
5. **Regular Rotation**: Consider rotating monitoring user passwords periodically

## Troubleshooting

### Connection Refused

**Symptom**: PMM cannot connect to RDS

**Causes**:
1. Security group rules not configured
2. VPC/subnet configuration issues
3. RDS publicly_accessible setting

**Resolution**:
```bash
# Verify security group rules
aws ec2 describe-security-groups \
    --group-ids sg-your-rds-sg \
    --query 'SecurityGroups[0].IpPermissions'

# Verify PMM can reach RDS
# (from EC2 instance in same VPC)
telnet mydb.cluster-abc123.us-west-1.rds.amazonaws.com 5432
```

### Authentication Failed

**Symptom**: "password authentication failed for user pmm_user"

**Causes**:
1. Incorrect password
2. User doesn't exist
3. pg_hba.conf restrictions (RDS default is permissive)

**Resolution**:
```sql
-- Verify user exists
SELECT usename FROM pg_user WHERE usename = 'pmm_user';

-- Reset password
ALTER USER pmm_user WITH PASSWORD 'new_password';
```

### Missing Metrics

**Symptom**: Some metrics not appearing in PMM

**Causes**:
1. Missing extensions (pg_stat_statements)
2. Insufficient permissions
3. Parameter group not applied

**Resolution**:
```sql
-- Check extensions
SELECT * FROM pg_extension WHERE extname = 'pg_stat_statements';

-- Verify permissions
\du pmm_user

-- Check parameter values
SHOW shared_preload_libraries;
SHOW pg_stat_statements.track;
```

### Query Analytics Not Working

**Symptom**: No queries appear in Query Analytics

**Causes**:
1. pg_stat_statements not configured
2. Queries too fast (below threshold)
3. Monitoring user lacks permissions

**Resolution**:
```sql
-- Verify pg_stat_statements is active
SELECT * FROM pg_stat_statements LIMIT 1;

-- Grant pg_monitor role
GRANT pg_monitor TO pmm_user;
```

## Example: Complete Terraform Configuration

See [examples/with-rds-monitoring](../examples/with-rds-monitoring/main.tf) for a complete example including:
- PMM deployment
- RDS instance
- Security group configuration
- IAM roles

## Additional Resources

- [PMM Documentation](https://docs.percona.com/percona-monitoring-and-management/)
- [PostgreSQL Monitoring Best Practices](https://www.percona.com/blog/postgresql-monitoring-best-practices/)
- [RDS PostgreSQL Best Practices](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_BestPractices.html)