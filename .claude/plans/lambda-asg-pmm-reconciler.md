# Plan: Lambda-Based ASG-to-PMM Reconciler

## Context

Database instances are currently added to PMM manually (via test code or API calls).
The user wants to automate this: given ASG names (e.g., from Percona Server clusters),
a Lambda function should periodically reconcile ASG membership with PMM monitored
services -- adding new instances and removing terminated ones.

## Architecture

```
EventBridge (rate: 5 min) --> Lambda (in VPC) --HTTP:80--> PMM EC2 Instance
                                |
                                +--> ASG API (describe instances)
                                +--> Secrets Manager (PMM password + DB credentials)
```

The Lambda runs in private subnets, calls PMM directly on port 80 (no ALB).
All infrastructure is conditionally created only when `var.monitored_asgs` is non-empty.

## New Variable

```hcl
variable "monitored_asgs" {
  type = list(object({
    asg_name               = string   # ASG name (not ARN)
    credentials_secret_arn = string   # Secrets Manager ARN with DB creds (JSON)
    service_type           = string   # "mysql" (extensible later)
    port                   = number   # e.g., 3306
    username               = string   # Key in credentials JSON for password lookup
  }))
  default = []
}
```

## New Files

### 1. `lambda/pmm_reconciler/main.py` -- Lambda handler

Uses `infrahouse-core` (`ASG` class) and `requests` for HTTP.

**Reconciliation logic per ASG:**
1. List InService instances from ASG -> get private IPs
2. List PMM services matching naming pattern `{asg_name}-{instance_id}`
3. Add services for new instances (POST `/v1/management/services`)
4. Remove services for terminated instances (DELETE `/v1/inventory/services/{service_id}`)

**Key functions:**
- `lambda_handler(event, context)` -- entry point, iterates configured ASGs
- `reconcile_asg(asg_config, auth_header, pmm_agent_id, existing_services)`
- `add_mysql_service(...)` -- POST to PMM management API
- `remove_pmm_service(service_id)` -- DELETE from PMM inventory API
- `list_pmm_services()`, `get_pmm_agent_id()` -- query PMM state
- `get_pmm_password()`, `get_credentials_from_secret()` -- read Secrets Manager

**Service naming convention:** `{asg_name}-{instance_id}` (deterministic, unique)

### 2. `lambda/pmm_reconciler/requirements.txt`

```
infrahouse-core ~= 0.17
requests ~= 2.32
```

### 3. `lambda.tf` -- All Lambda Terraform infrastructure

Contains (all with `count = length(var.monitored_asgs) > 0 ? 1 : 0`):

- **`module "pmm_reconciler"`** -- uses `registry.infrahouse.com/infrahouse/lambda-monitored/aws` v1.0.4
  - `function_name = "${local.service_name}-asg-reconciler"`
  - `lambda_source_dir = "${path.module}/lambda/pmm_reconciler"`
  - `handler = "main.lambda_handler"`, timeout=120, memory=256
  - `environment_variables`: PMM_HOST (EC2 private IP), PMM_ADMIN_SECRET_ARN,
    MONITORED_ASGS_CONFIG (JSON), AWS region
  - VPC: `lambda_subnet_ids = var.private_subnet_ids`, custom security group
  - `additional_iam_policy_arns` for custom permissions
  - `alarm_emails = var.alarm_emails`

- **`aws_security_group.reconciler_lambda`** -- Lambda SG
  - Egress to PMM instance SG on port 80
  - Egress to 0.0.0.0/0 on port 443 (AWS APIs via NAT)

- **`aws_security_group_rule.pmm_from_reconciler`** -- ingress on PMM instance SG
  from Lambda SG on port 80

- **IAM policy** (`data "aws_iam_policy_document"` per coding standards):
  - `autoscaling:DescribeAutoScalingGroups` (resource: `*`)
  - `ec2:DescribeInstances` (resource: `*`)
  - `secretsmanager:GetSecretValue` on admin password secret + all configured
    credential secret ARNs

- **EventBridge**: `aws_cloudwatch_event_rule` with `rate(5 minutes)`, target pointing
  to Lambda, plus `aws_lambda_permission` for EventBridge invoke

**Note on secret access:** The Lambda's IAM policy grants `secretsmanager:GetSecretValue`
directly. We do NOT add the Lambda role to `module.admin_password_secret.readers` to avoid
a circular dependency (Lambda depends on the secret ARN, secret readers would depend on
Lambda role).

## Modified Files

### 4. `variables.tf`
- Add `monitored_asgs` variable with validations (service_type in ["mysql"], port 1-65535)

### 5. `outputs.tf`
- Add `reconciler_lambda_function_arn` (null if no ASGs configured)

### 6. `test_data/test_basic/main.tf`
- Pass `monitored_asgs` to module using `var.mysql_asg_name` and
  `var.mysql_credentials_secret_arn`

### 7. `test_data/test_basic/variables.tf`
- Add `mysql_asg_name` (string, default "") and `mysql_credentials_secret_arn`
  (string, default "")

### 8. `test_data/test_basic/outputs.tf`
- Add `reconciler_lambda_function_arn` output

### 9. `tests/conftest.py`
- Add `asg_name` and `credentials_secret_arn` to the `percona_pmm` fixture result dict
  (already available from `percona_server` fixture outputs)

### 10. `tests/test_basic.py`
- Pass `mysql_asg_name` and `mysql_credentials_secret_arn` in terraform.tfvars generation
- Add reconciler test section: invoke Lambda via `boto3.client("lambda").invoke()`,
  wait briefly, list PMM services, verify instances appear with `{asg_name}-i-...` naming

## Implementation Sequence

1. Create `lambda/pmm_reconciler/` directory with `main.py` and `requirements.txt`
2. Create `lambda.tf` with all Terraform infrastructure
3. Add `monitored_asgs` variable to `variables.tf`
4. Add outputs to `outputs.tf`
5. Update test data (`test_data/test_basic/`) with new variables, outputs, module params
6. Update test fixtures (`conftest.py`) and test code (`test_basic.py`)
7. Run `make format` and `make lint`

## Verification

1. `terraform fmt -check -recursive` -- formatting
2. `terraform validate` (in test_data/test_basic) -- syntax
3. `make test-keep` -- full integration test: deploy PMM + Percona Server, Lambda
   reconciles, verify MySQL instances appear in PMM with correct naming, verify removal
4. Check CloudWatch Logs for Lambda execution output