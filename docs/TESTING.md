# Testing Guide

This document describes how to test the terraform-waf-module before deployment.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Test Summary](#test-summary)
- [Test Catalog](#test-catalog)
  - [Build Validation Tests](#build-validation-tests)
  - [Terraform Tests](#terraform-tests)
  - [Security Tests](#security-tests)
- [Test Data (v4.0.0 / upstream v4.1.2)](#test-data-v400--upstream-v412)
- [Make Targets](#make-targets)
- [Terraform Validation](#terraform-validation)
- [Linting](#linting-docker)
- [Security Scanning](#security-scanning-docker)
- [Lambda Build Tests](#lambda-build-tests-docker)
- [CI/CD Tests](#cicd-tests)
- [Local Pipeline Testing](#local-pipeline-testing)
  - [LocalStack (AWS Emulation)](#localstack-aws-emulation)
  - [Act (GitHub Actions Local Runner)](#act-github-actions-local-runner)
  - [Combined: End-to-End Local Pipeline](#combined-end-to-end-local-pipeline)
- [Manual Validation](#manual-validation)
- [Test Gaps and Limitations](#test-gaps-and-limitations)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Prerequisites

| Tool | Required | Purpose | Install |
|------|----------|---------|---------|
| Terraform | Yes | Infrastructure validation | `brew install terraform` |
| Docker | Yes | All tests run in containers | `brew install docker` |
| AWS CLI | Optional | AWS credentials for plan | `brew install awscli` |
| act | Optional | Run GitHub Actions locally | `brew install act` |

**Note:** tflint, tfsec, and checkov are NOT required locally — they run in Docker containers for parity with CI.

---

## Quick Start

```bash
# Quick test (no Docker, just Terraform)
make test

# Local test suite with Docker (recommended)
make test-local

# Full test suite including Lambda builds
make test-all
```

---

## Test Summary

| Target | Tests | Docker | Description |
|--------|-------|--------|-------------|
| `make test` | validate, fmt | No | Quick syntax check |
| `make test-local` | validate, fmt, lint, security | Yes | Full validation without Lambda |
| `make test-all` | All above + Lambda builds | Yes | Complete suite |
| `make test-lambda` | Lambda build + 50 validation tests | Yes | Build and validate Lambda zips |

### Important: validate vs plan

| Command | Purpose | Requires AWS? | Requires Variables? |
|---------|---------|---------------|---------------------|
| `terraform validate` | Syntax & config check | No | No |
| `terraform plan` | Pre-deployment preview | Yes | Yes (all required vars) |

**Why this matters:**
- `make test` and `make test-all` use `terraform validate` — no AWS credentials or variable values needed
- `terraform plan` prompts for required variables like `dead_letter_arn` — run this in your deployment environment with a `.tfvars` file
- For local development and CI, `make test-all` is sufficient

---

## Test Catalog

### Build Validation Tests

Tests run inside `scripts/build-lambda.sh` during Docker Lambda builds. Each package runs all tests independently.

#### Positive Tests (12 per package)

| # | Test | What it validates | Catches |
|---|------|-------------------|---------|
| 1 | Zip exists & not empty | Build completed successfully | Failed zip creation |
| 2 | Handler file in zip | Lambda can find entry point | Missing/misnamed handler |
| 3 | Size < 50MB | Within Lambda deployment limit | Bloated packages |
| 4 | `lib/waflibv2.py` in zip | Core WAF library included | Missing shared lib |
| 5 | `lib/solution_metrics.py` in zip | Metrics library included | Missing shared lib |
| 6 | All upstream deps in zip | Every dependency from `pyproject.toml` bundled | **pip silently skipping packages (issue #801)** |
| 7 | Size > 1MB minimum | Zip contains real dependencies | Empty install due to env markers |
| 16 | Handler imports | Handler module loads without syntax errors | Syntax errors, broken imports |
| 17a | `import backoff` | backoff package importable | Corrupt/incomplete install |
| 17b | `import jinja2` | jinja2 package importable | Missing template engine |
| 17c | `import aws_xray_sdk` | X-Ray SDK importable | Missing tracing |
| 17d | `import urllib3` | urllib3 importable | Missing HTTP lib |
| 17e | `import pyparsing` (log_parser only) | pyparsing importable | Missing parser |

#### Negative Tests (9 per package)

| # | Test | What it catches | Why it matters |
|---|------|-----------------|----------------|
| 8 | Zip integrity (`unzip -t`) | Corrupted archive | Deploy would fail |
| 9 | No `__pycache__` | Build artifacts in zip | Unnecessary bloat, potential conflicts |
| 10 | No `.pyc` files | Bytecode contamination | Wrong Python version bytecode |
| 11 | No `.dist-info` | pip metadata in zip | Unnecessary bloat |
| 12 | No `test/` or `tests/` dirs | Test code in zip | Security risk, bloat |
| 13 | No `.egg-info` | Build metadata in zip | Unnecessary bloat |
| 14 | No dev dependencies | pytest/moto/freezegun not bundled | `--without dev` working correctly |
| 15 | Handler renamed correctly | `log_parser.py` → `log-parser.py` | Terraform expects hyphenated name |
| 15b | `lib/` has Python files | Shared lib directory not empty | Broken copy step |

#### Import Tests (4-5 per package)

| # | Test | What it validates | Error handling |
|---|------|-------------------|----------------|
| 18a | `from lib import waflibv2` | Shared WAF lib importable | Allows botocore runtime errors (no AWS env) |
| 18b | `from lib import solution_metrics` | Shared metrics lib importable | Allows botocore runtime errors |
| 16 | Handler module import | Handler loads successfully | Categorizes errors: runtime (PASS), known runtime pkg (WARN), unknown (FAIL) |

#### Import Error Classification

| Error Type | Result | Example |
|------------|--------|---------|
| Clean import | PASS | All deps resolved |
| `botocore.exceptions.NoRegionError` | PASS | Module-level boto3 client, no AWS region in build |
| `botocore.exceptions.NoCredentialError` | PASS | Module-level AWS call, no credentials in build |
| `No module named 'boto3'` | WARN | Runtime-provided package |
| `No module named 'botocore'` | WARN | Runtime-provided package |
| `No module named 'aws_lambda_powertools'` | **FAIL** | Missing dependency — must be in zip or Layer |
| `No module named '<anything_else>'` | **FAIL** | Incomplete build |
| Any other error | **FAIL** | Unexpected failure |

### Terraform Tests

| Test | Tool | What it validates |
|------|------|-------------------|
| Init | `terraform init -backend=false` | Provider configuration, module structure |
| Validate | `terraform validate` | HCL syntax, resource references, type checking |
| Format | `terraform fmt -check -recursive` | Consistent formatting |
| Lint | tflint | Variable declarations, deprecated syntax, AWS-specific issues |

### Security Tests

| Test | Tool | Severity | What it validates |
|------|------|----------|-------------------|
| tfsec | aquasec/tfsec | HIGH+ | Hardcoded secrets, insecure configs, AWS best practices |
| checkov | bridgecrew/checkov | Soft-fail | CIS benchmarks, compliance frameworks |
| pip-audit | pip-audit | Advisory | Known CVEs in Python dependencies |

---

## Test Data (v4.0.0 / upstream v4.1.2)

Recorded 2026-01-28 from local Docker builds on `feature/801-add-required-dependencies`.

### log_parser

| Metric | Value |
|--------|-------|
| **Zip size** | 19.63 MB |
| **Installed packages** | 13 |
| **Tests passed** | 25/25 |
| **Handler** | `log-parser.py` (renamed from `log_parser.py`) |
| **Dependencies** | backoff, pyparsing, aws-lambda-powertools, jinja2, aws-xray-sdk, urllib3 |
| **Import result** | PASS (runtime environment error — expected, no AWS region in Docker) |

#### Full test output

```
--- POSITIVE TESTS ---
  PASS: Zip file exists and is not empty
  PASS: Handler log-parser.py found in zip
  PASS: Size 19.63MB (< 50MB limit)
  PASS: Required lib/waflibv2.py found
  PASS: Required lib/solution_metrics.py found
  PASS: Dependency 'backoff' found in zip
  PASS: Dependency 'pyparsing' found in zip
  PASS: Dependency 'aws-lambda-powertools' found in zip
  PASS: Dependency 'jinja2' found in zip
  PASS: Dependency 'aws-xray-sdk' found in zip
  PASS: Dependency 'urllib3' found in zip
  PASS: Size 19.63MB exceeds 1MB minimum (dependencies present)

--- NEGATIVE TESTS ---
  PASS: Zip integrity verified (not corrupted)
  PASS: No __pycache__ in zip
  PASS: No .pyc files in zip
  PASS: No .dist-info in zip
  PASS: No test directories in zip
  PASS: No .egg-info in zip
  PASS: No dev dependencies in zip
  PASS: Handler correctly renamed from 'log_parser.py' to 'log-parser.py'
  PASS: lib/ directory contains 9 Python files

--- IMPORT TESTS ---
  PASS: Handler imports resolve (runtime environment error expected during build)
  PASS: import backoff succeeds
  PASS: import jinja2 succeeds
  PASS: import aws_xray_sdk succeeds
  PASS: import urllib3 succeeds
  PASS: import pyparsing succeeds
  PASS: lib/waflibv2 imports resolve (runtime environment error expected)
  PASS: from lib import solution_metrics succeeds
```

### reputation_lists_parser

| Metric | Value |
|--------|-------|
| **Zip size** | 19.29 MB |
| **Installed packages** | 12 |
| **Tests passed** | 24/24 |
| **Handler** | `reputation-lists.py` (renamed from `reputation_lists.py`) |
| **Dependencies** | backoff, aws-lambda-powertools, jinja2, aws-xray-sdk, urllib3 |
| **Import result** | PASS (runtime environment error — expected, no AWS region in Docker) |

#### Full test output

```
--- POSITIVE TESTS ---
  PASS: Zip file exists and is not empty
  PASS: Handler reputation-lists.py found in zip
  PASS: Size 19.29MB (< 50MB limit)
  PASS: Required lib/waflibv2.py found
  PASS: Required lib/solution_metrics.py found
  PASS: Dependency 'backoff' found in zip
  PASS: Dependency 'aws-lambda-powertools' found in zip
  PASS: Dependency 'jinja2' found in zip
  PASS: Dependency 'aws-xray-sdk' found in zip
  PASS: Dependency 'urllib3' found in zip
  PASS: Size 19.29MB exceeds 1MB minimum (dependencies present)

--- NEGATIVE TESTS ---
  PASS: Zip integrity verified (not corrupted)
  PASS: No __pycache__ in zip
  PASS: No .pyc files in zip
  PASS: No .dist-info in zip
  PASS: No test directories in zip
  PASS: No .egg-info in zip
  PASS: No dev dependencies in zip
  PASS: Handler correctly renamed from 'reputation_lists.py' to 'reputation-lists.py'
  PASS: lib/ directory contains 9 Python files

--- IMPORT TESTS ---
  PASS: Handler imports resolve (runtime environment error expected during build)
  PASS: import backoff succeeds
  PASS: import jinja2 succeeds
  PASS: import aws_xray_sdk succeeds
  PASS: import urllib3 succeeds
  PASS: lib/waflibv2 imports resolve (runtime environment error expected)
  PASS: from lib import solution_metrics succeeds
```

### Terraform validation

| Test | Result |
|------|--------|
| `terraform validate` | Success (with expected deprecation warning for `data.aws_region.current.name`) |
| `terraform fmt -check` | Pass (no formatting issues) |
| tflint | Pass (no issues) |

---

## Make Targets

### Core Targets

| Target | Description | Requirements |
|--------|-------------|--------------|
| `make test` | Quick tests (validate + fmt) | Terraform only |
| `make test-local` | Full tests except Lambda | Terraform + Docker |
| `make test-all` | Complete test suite | Terraform + Docker |

### Individual Targets

| Target | Description | Docker |
|--------|-------------|--------|
| `make validate` | Terraform init + validate | No |
| `make fmt` | Check formatting | No |
| `make lint` | Run tflint | Yes |
| `make security` | Run tfsec + checkov | Yes |
| `make test-lambda` | Build & test Lambda packages | Yes |
| `make build` | Build Docker image only | Yes |
| `make clean` | Remove .terraform | No |
| `make clean-all` | Remove .terraform + upstream | No |

---

## Terraform Validation

### Initialize

```bash
terraform init -backend=false
```

**Expected:** `Terraform has been successfully initialized!`

### Validate Syntax

```bash
terraform validate
```

**Expected:** `Success! The configuration is valid.`

**Note:** Deprecation warnings for `data.aws_region.current.name` are expected and harmless.

### Format Check

```bash
terraform fmt -check -recursive
```

**Expected:** No output means all files are formatted correctly.

To auto-fix formatting:
```bash
terraform fmt -recursive
```

---

## Linting (Docker)

### Run tflint

```bash
make lint
```

Or manually:
```bash
docker run --rm -v $(pwd):/data -t ghcr.io/terraform-linters/tflint:latest --init
docker run --rm -v $(pwd):/data -t ghcr.io/terraform-linters/tflint:latest
```

**What it checks:**
- Variable type declarations
- Unused declarations
- Deprecated syntax
- AWS provider-specific issues

---

## Security Scanning (Docker)

### Run Security Scans

```bash
make security
```

This runs both tfsec and checkov in Docker containers.

### Known Accepted Issues

| Check | Severity | Reason |
|-------|----------|--------|
| CKV_AWS_158 | LOW | CloudWatch log encryption — uses default encryption |
| CKV_AWS_115 | LOW | Lambda concurrency — not required for this use case |
| CKV_AWS_117 | LOW | Lambda VPC — not required for this use case |
| CKV_DOCKER_2/3 | INFO | Build container only, not production |

### Expected Warnings (Safe to Ignore)

| Warning | Source | Reason |
|---------|--------|--------|
| `data.aws_region.current.name` deprecated | Terraform validate | Pre-existing in module, uses deprecated AWS provider attribute |
| `dulwich requires urllib3>=2.2.2` | Lambda pip install | Upstream dependency conflict in build container |
| `Running pip as root user` | Lambda pip install | Expected in Docker build container |
| `pip's dependency resolver` conflict | Lambda pip install | boto3/botocore version conflict in base image, not in zip |

---

## Lambda Build Tests (Docker)

### Run Lambda Tests

```bash
make test-lambda
```

Or step by step:

```bash
# Clone upstream source
make clone-upstream

# Build Docker image
make build

# Build specific package with verbose output
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder log_parser /upstream /output

docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder reputation_lists_parser /upstream /output
```

---

## CI/CD Tests

Tests run automatically in GitHub Actions on every PR and push to `master`.

> **Diagram:** See `docs/ARCHITECTURE.md` → "CI/CD Test Workflow (test.yml)" for visual workflow diagram with code references.

### Test Workflow (`test.yml`)

**Triggers:** Push to `master`, Pull request to `master`

| Job | Step | Tool | Exit on Fail |
|-----|------|------|--------------|
| terraform | Init | terraform init | Yes |
| terraform | Validate | terraform validate | Yes |
| terraform | Format | terraform fmt -check | Yes |
| terraform | Lint | tflint | Yes |
| terraform | Security | tfsec | Yes (HIGH/CRITICAL) |
| terraform | Compliance | checkov | No (soft-fail) |
| lambda | Build log_parser | Docker + build-lambda.sh | Yes |
| lambda | Build reputation_lists | Docker + build-lambda.sh | Yes |

### Build Workflow (`build-lambda-packages.yml`)

**Trigger:** Manual (`workflow_dispatch`)

```bash
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.1.2 \
  -f version_bump=patch
```

---

## Local Pipeline Testing

### The Challenge

The current test suite validates:
- Terraform syntax and formatting (local)
- Lambda zip packaging and imports (Docker)

But it **cannot** validate:
- Terraform `plan` / `apply` against real AWS resources
- SSM Parameter Store lookups (e.g., Powertools Layer ARN)
- Lambda invocation in an actual runtime
- GitHub Actions workflow execution
- End-to-end: build → deploy → invoke → verify

Two tools address these gaps: **LocalStack** for AWS emulation and **act** for GitHub Actions.

---

### LocalStack (AWS Emulation)

[github.com/localstack/localstack](https://github.com/localstack/localstack)

LocalStack emulates AWS services in a Docker container, allowing `terraform apply` and Lambda invocation without an AWS account.

#### Relevant Services

| AWS Service | LocalStack Free | LocalStack Pro | Our Use |
|-------------|-----------------|----------------|---------|
| Lambda | Yes | Yes | Invoke handlers, test runtime |
| SSM Parameter Store | Yes | Yes | Test Powertools Layer ARN lookup |
| S3 | Yes | Yes | Log bucket for WAF |
| CloudWatch Logs | Yes | Yes | Verify Lambda logging |
| WAFv2 | No | Yes | Test WAF rule creation |
| IAM | Yes | Yes | Lambda execution roles |

#### Setup

```bash
# Install
brew install localstack/tap/localstack-cli
pip install localstack

# Start LocalStack
localstack start -d

# Verify running
localstack status services

# Install AWS CLI local wrapper
pip install awscli-local
```

#### Configure Terraform for LocalStack

Create `terraform.localstack.tfvars`:

```hcl
# Override provider to point to LocalStack
# Used with: terraform plan -var-file=terraform.localstack.tfvars
```

Create `provider.localstack.tf` (do NOT commit):

```hcl
provider "aws" {
  access_key                  = "test"
  secret_key                  = "test"
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    lambda         = "http://localhost:4566"
    ssm            = "http://localhost:4566"
    s3             = "http://localhost:4566"
    cloudwatchlogs = "http://localhost:4566"
    iam            = "http://localhost:4566"
    sts            = "http://localhost:4566"
    wafv2          = "http://localhost:4566"
  }
}
```

#### Test SSM Parameter Store Lookup

```bash
# Seed the SSM parameter that Terraform expects
awslocal ssm put-parameter \
  --name "/aws/service/powertools/python/x86_64/python3.13/latest" \
  --type "String" \
  --value "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python313-x86_64:28"

# Verify
awslocal ssm get-parameter \
  --name "/aws/service/powertools/python/x86_64/python3.13/latest"
```

#### Test Lambda Invocation

```bash
# Upload zip to LocalStack Lambda
awslocal lambda create-function \
  --function-name test-log-parser \
  --runtime python3.13 \
  --handler log-parser.lambda_handler \
  --zip-file fileb://lambda/log_parser.zip \
  --role arn:aws:iam::000000000000:role/lambda-role \
  --layers "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python313-x86_64:28"

# Invoke
awslocal lambda invoke \
  --function-name test-log-parser \
  --payload '{}' \
  /tmp/lambda-output.json

cat /tmp/lambda-output.json
```

#### Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| WAFv2 requires Pro tier | Cannot test WAF rule creation locally | Use `terraform plan` against real AWS |
| Lambda Layers are stubs | Powertools Layer won't have real code | Seed with real Layer ARN, test import separately |
| No real AWS managed rules | Cannot test AWS managed rule group versions | Validate in dev environment |
| Networking differences | Docker networking ≠ AWS VPC | Acceptance test in real AWS |

---

### Act (GitHub Actions Local Runner)

[github.com/nektos/act](https://github.com/nektos/act)

`act` reads `.github/workflows/*.yml` and runs jobs locally in Docker containers, simulating the GitHub Actions runner.

#### Setup

```bash
# Install
brew install act

# First run — select image size (recommend "Medium")
act --list
```

#### Run Test Workflow Locally

```bash
# List available workflows
act --list

# Run the test workflow (push trigger)
act push

# Run with verbose output
act push --verbose

# Run specific job
act push -j terraform
act push -j lambda
```

#### Run Build Workflow Locally

```bash
# workflow_dispatch with inputs
act workflow_dispatch \
  --input upstream_ref=v4.1.2 \
  --input version_bump=none \
  -W .github/workflows/build-lambda-packages.yml
```

#### Provide Secrets

```bash
# Create .secrets file (do NOT commit — already in .gitignore)
echo "GITHUB_TOKEN=ghp_your_token_here" > .secrets

# Run with secrets
act push --secret-file .secrets
```

#### Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Docker-in-Docker fragile | Lambda Docker builds may fail | Use `--bind` flag or pre-build image |
| No macOS/Windows runners | Only ubuntu containers | Our workflows use ubuntu — no issue |
| `GITHUB_TOKEN` not real | PR creation step will fail | Skip with `-j build` (run only build job) |
| `GITHUB_STEP_SUMMARY` not supported | Summary step errors | Ignore or add `continue-on-error` |
| Large Docker images | First run downloads ~2GB | Use medium image: `act -P ubuntu-latest=catthehacker/ubuntu:act-latest` |

#### Recommended `.actrc`

Create `.actrc` in repo root (do NOT commit):

```
-P ubuntu-latest=catthehacker/ubuntu:act-latest
--bind
```

---

### Combined: End-to-End Local Pipeline

For full local validation before pushing:

```bash
# 1. Start LocalStack
localstack start -d

# 2. Seed SSM parameter
awslocal ssm put-parameter \
  --name "/aws/service/powertools/python/x86_64/python3.13/latest" \
  --type "String" \
  --value "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python313-x86_64:28"

# 3. Run existing test suite (Terraform + Lambda builds)
make test-all

# 4. Run GitHub Actions workflow locally
act push -j terraform
act push -j lambda

# 5. Test Terraform plan against LocalStack
# (requires provider.localstack.tf — see above)
terraform plan

# 6. Test Lambda invocation against LocalStack
awslocal lambda create-function \
  --function-name test-log-parser \
  --runtime python3.13 \
  --handler log-parser.lambda_handler \
  --zip-file fileb://lambda/log_parser.zip \
  --role arn:aws:iam::000000000000:role/lambda-role

awslocal lambda invoke \
  --function-name test-log-parser \
  --payload '{}' \
  /tmp/output.json

# 7. Cleanup
localstack stop
```

### Testing Maturity Model

| Level | What's Tested | Tools | Status |
|-------|---------------|-------|--------|
| 1. Static | Terraform syntax, formatting, lint | terraform, tflint | **Implemented** |
| 2. Security | Hardcoded secrets, misconfigurations | tfsec, checkov, pip-audit | **Implemented** |
| 3. Build | Lambda zip packaging, dependencies, imports | Docker, build-lambda.sh | **Implemented** |
| 4. Integration | Terraform plan, SSM lookups, Lambda invoke | LocalStack | **Not yet** |
| 5. Pipeline | GitHub Actions workflow execution | act | **Not yet** |
| 6. Acceptance | Deploy to dev, invoke Lambda, check CloudWatch | Real AWS | **Manual** |

---

## Manual Validation

### Verify Zip Contents

```bash
# List contents
unzip -l lambda/log_parser.zip | head -30

# Check for required files
unzip -l lambda/log_parser.zip | grep -E "log-parser.py|lib/waflibv2.py"
```

### Test Python Imports

```bash
# Extract and test
mkdir -p /tmp/test-lambda
unzip -q lambda/log_parser.zip -d /tmp/test-lambda
cd /tmp/test-lambda
python3 -c "import sys; sys.path.insert(0, '.'); import backoff; import jinja2; print('OK')"
rm -rf /tmp/test-lambda
```

### Verify File Sizes

```bash
ls -lh lambda/*.zip
```

**Expected:** Both zips should be ~19MB (includes aws_lambda_powertools and all dependencies).

---

## Test Gaps and Limitations

| Gap | Risk | Mitigation |
|-----|------|-----------|
| No `terraform plan` in CI | Broken references not caught until deploy | Manual plan before merge; add LocalStack |
| No Lambda invocation test | Handler may crash at runtime despite imports passing | LocalStack Lambda invoke; dev deploy |
| Import test allows botocore runtime errors | Module-level AWS calls mask real import failures | Categorized error handling (PASS/WARN/FAIL) |
| ~~CI upstream version hardcoded to v4.0.3~~ | ~~Test workflow doesn't match build workflow~~ | Fixed: updated to v4.1.2 |
| `grep -oP` (Perl regex) may not exist | Fallback to `grep -oE` + `sed` | Both patterns implemented in build script |
| `set -o pipefail` + large `echo \| grep` | SIGPIPE causes false failures | Fixed: use `grep <<< "$var"` (here-strings) or file-based grep |

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `terraform init` fails | Missing providers | Check internet connection |
| `terraform validate` fails | Syntax error | Check error message for file:line |
| Docker build fails | Docker not running | Start Docker Desktop |
| tflint warnings | Variable issues | Fix or ignore if intentional |
| tfsec HIGH issues | Security concern | Fix before merge |
| Lambda build fails | Missing upstream | Run `make clone-upstream` |
| Dependency missing from zip | Python version markers | Build script strips markers (fixed in #801) |
| Import test SIGPIPE | `set -o pipefail` + `echo \| grep` | Use here-strings `grep <<< "$var"` |
| `act` Docker-in-Docker fails | Nested Docker not supported | Use `--bind` flag or pre-build image |

### Debug Commands

```bash
# Verbose terraform
TF_LOG=DEBUG terraform plan

# Docker build with no cache
docker build --no-cache -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Inspect Lambda zip
unzip -l lambda/log_parser.zip
unzip lambda/log_parser.zip -d /tmp/inspect && ls -la /tmp/inspect

# Check Docker logs
docker logs $(docker ps -lq)

# Debug build script inside Docker
docker run --rm --entrypoint bash \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder -c "bash -x /build/build-lambda.sh log_parser /upstream /output"
```

---

## References

| Resource | Link |
|----------|------|
| Terraform Docs | https://developer.hashicorp.com/terraform/docs |
| tfsec | https://aquasecurity.github.io/tfsec |
| checkov | https://www.checkov.io/1.Welcome/Quick%20Start.html |
| tflint | https://github.com/terraform-linters/tflint |
| AWS WAF Docs | https://docs.aws.amazon.com/waf/ |
| LocalStack | https://github.com/localstack/localstack |
| LocalStack Docs | https://docs.localstack.cloud/ |
| act | https://github.com/nektos/act |
| AWS Lambda Powertools | https://docs.aws.amazon.com/powertools/python/latest/ |

---

Last Updated: 2026-01-28
