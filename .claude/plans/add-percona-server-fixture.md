# Plan: Add Percona Server Fixture and MySQL Monitoring to PMM Tests

## Context

The user released `infrahouse/percona-server/aws` v0.4.0 and wants to:
1. Deploy a Percona Server cluster as a test fixture alongside the existing PostgreSQL fixture
2. Add MySQL monitoring to PMM in the test (similar to how PostgreSQL is already added)
3. Update the PMM module's security group rules to also allow MySQL (port 3306)

## Changes

### 1. PMM Module: Add MySQL port 3306 to `rds_security_group_ids` rules

**File**: `security.tf`

Currently `aws_security_group_rule.pmm_to_rds_postgres` only creates ingress on port 5432.
Add a second `aws_security_group_rule` for port 3306 using the same `rds_security_group_ids`:

```hcl
resource "aws_security_group_rule" "pmm_to_rds_mysql" {
  count = length(var.rds_security_group_ids)

  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.pmm_instance.id
  security_group_id        = var.rds_security_group_ids[count.index]
  description              = "Allow PMM server to connect to MySQL"
}
```

### 1b. PMM Module: Add MySQL custom query variables

**File**: `variables.tf`

Add three new variables mirroring the existing PostgreSQL custom query variables:
- `mysql_custom_queries_high_resolution`
- `mysql_custom_queries_medium_resolution`
- `mysql_custom_queries_low_resolution`

Same type (`string`), default (`null`), and description pattern as the PostgreSQL ones.

**File**: `locals.tf`

Add MySQL entries to `custom_query_files` and `custom_query_volume_mounts`:
- Host path: `/opt/pmm/custom-queries/mysql-{resolution}.yml`
- Container path: `/usr/local/percona/pmm/collectors/custom-queries/mysql/{resolution}/custom-queries.yml`

### 2. Test Fixture: Create Percona Server in `conftest.py`

**File**: `tests/conftest.py`

Add a `percona_server` session-scoped fixture that:
- Creates Terraform config in `test_data/percona_server/` (new directory)
- Deploys `infrahouse/percona-server/aws` v0.4.0
- Uses `service_network` private subnets
- Passes `client_security_group_ids` (will include PMM's SG later, but for now
  the Percona SG will be added to `rds_security_group_ids` so PMM gets ingress)
- Yields the Terraform outputs (NLB endpoints, security_group_id,
  mysql_credentials_secret_arn, etc.)

### 3. Test Data: New Terraform config for Percona Server fixture

**New directory**: `test_data/percona_server/`

Files:
- `main.tf` — calls `infrahouse/percona-server/aws` v0.4.0
- `variables.tf` — region, role_arn, subnet_ids, environment
- `outputs.tf` — writer_endpoint, reader_endpoint, security_group_id,
  mysql_credentials_secret_arn, nlb_dns_name

The module source: `registry.terraform.io/infrahouse/percona-server/aws` v0.4.0
Required inputs: `cluster_id`, `environment`, `subnet_ids`, `alarm_emails`
Optional: `s3_force_destroy = true` (for test cleanup)

### 4. Test Data: Update `test_data/test_basic/` to pass MySQL info

**File**: `test_data/test_basic/variables.tf` — add MySQL variables:
- `mysql_security_group_id`
- `mysql_writer_endpoint` (NLB DNS + port from percona module)
- `mysql_address` (NLB DNS name)
- `mysql_port` (3306)
- `mysql_username` (hardcoded "monitor")
- `mysql_password` (sensitive)

**File**: `test_data/test_basic/main.tf` — add the Percona SG to
`rds_security_group_ids` list alongside the PostgreSQL SG.

**File**: `test_data/test_basic/outputs.tf` — add MySQL outputs to pass through.

### 5. Test: Update `conftest.py` with `percona_pmm` fixture

**File**: `tests/conftest.py`

Add a `percona_pmm` fixture (similar to `postgres_pmm`) that:
- Depends on `percona_server` fixture
- Reads MySQL credentials from Secrets Manager using `boto3_session`
  (reads `mysql_credentials_secret_arn`, parses JSON, extracts `monitor` password)
- Yields a dict with connection details (address, port, username, password)

### 6. Test: Add MySQL to PMM in `test_basic.py`

**File**: `tests/test_basic.py`

- Add `percona_pmm` to `test_module` fixture list
- Add `add_mysql_to_pmm()` function (modeled on `add_postgres_to_pmm`):
  - POST to `/v1/management/services` with `"mysql"` key
  - Uses `monitor` user credentials
  - Enables `qan_mysql_perfschema_agent` for query analytics
  - Uses NLB writer endpoint as address, port 3306
- Add `check_mysql_in_pmm()` function (modeled on `check_postgres_in_pmm`):
  - Checks for `MYSQL_SERVICE` type in services list
- Add MySQL monitoring test section after PostgreSQL section
- Pass `mysql_*` variables in `terraform.tfvars` generation
- Update `terraform.tfvars` writer to include MySQL connection info

### 7. Update test_module signature

Add `percona_pmm` parameter to `test_module()`. The fixture provides
MySQL connection details (address, port, username, password) extracted
from Secrets Manager.

## File Summary

| File                                 | Action                                          |
|--------------------------------------|-------------------------------------------------|
| `variables.tf`                       | Add MySQL custom query variables (3 resolutions)|
| `locals.tf`                          | Add MySQL custom query file/mount entries        |
| `security.tf`                        | Add `pmm_to_rds_mysql` SG rule (port 3306)      |
| `tests/conftest.py`                  | Add `percona_server` and `percona_pmm` fixtures  |
| `test_data/percona_server/main.tf`   | New — Percona Server module call                 |
| `test_data/percona_server/variables.tf` | New — input variables                         |
| `test_data/percona_server/outputs.tf`| New — outputs                                    |
| `test_data/test_basic/main.tf`       | Add Percona SG to `rds_security_group_ids`       |
| `test_data/test_basic/variables.tf`  | Add MySQL variables                              |
| `test_data/test_basic/outputs.tf`    | Add MySQL outputs                                |
| `tests/test_basic.py`               | Add MySQL monitoring functions and test logic     |

## Verification

1. `make lint` — ensure Terraform formatting is correct
2. `make test` — full integration test deploys PMM + PostgreSQL + Percona Server,
   adds both to PMM monitoring, validates via API