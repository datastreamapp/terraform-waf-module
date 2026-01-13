# Testing Guide

This document describes how to test the terraform-waf-module before deployment.

## Prerequisites

| Tool | Version | Purpose | Install |
|------|---------|---------|---------|
| Terraform | >= 1.0 | Infrastructure validation | `brew install terraform` |
| AWS CLI | >= 2.0 | AWS credentials | `brew install awscli` |
| Docker | Latest | Lambda build environment | `brew install docker` |
| tfsec | Latest | Security scanning | `brew install tfsec` |
| checkov | Latest | Policy compliance | `pip install checkov` |
| tflint | Latest | Linting | `brew install tflint` |

## Quick Start

```bash
# Run all tests
make test

# Or manually:
terraform init
terraform validate
terraform fmt -check
tfsec .
```

---

## 1. Terraform Validation

### 1.1 Initialize

```bash
terraform init
```

**Expected output:** `Terraform has been successfully initialized!`

### 1.2 Validate Syntax

```bash
terraform validate
```

**Expected output:** `Success! The configuration is valid.`

### 1.3 Format Check

```bash
terraform fmt -check -recursive
```

**Expected output:** No output means all files are formatted correctly.

To auto-fix formatting:
```bash
terraform fmt -recursive
```

### 1.4 Plan (Dry Run)

Requires AWS credentials and variables:

```bash
terraform plan \
  -var="name=test-waf" \
  -var="scope=REGIONAL" \
  -var="logging_bucket=my-test-bucket" \
  -var="dead_letter_arn=arn:aws:sqs:us-east-1:123456789:dlq" \
  -var="dead_letter_policy_arn=arn:aws:iam::123456789:policy/dlq"
```

**Expected output:** Plan showing resources to be created.

---

## 2. Security Scanning

### 2.1 tfsec (Terraform Security)

```bash
tfsec .
```

**What it checks:**
- Hardcoded secrets
- Insecure configurations
- AWS best practices

**Expected output:** `No problems detected!` or list of issues with severity.

### 2.2 checkov (Policy Compliance)

```bash
checkov -d .
```

**What it checks:**
- CIS benchmarks
- AWS security best practices
- Compliance frameworks (SOC2, HIPAA, PCI-DSS)

### 2.3 tflint (Linting)

```bash
tflint --init
tflint .
```

**What it checks:**
- Deprecated syntax
- Invalid resource configurations
- AWS provider-specific issues

---

## 3. Lambda Build Tests

The Lambda build script (`scripts/build-lambda.sh`) includes comprehensive validation.

### 3.1 Run Build Locally

```bash
# Clone upstream source
git clone --depth 1 --branch v4.0.3 \
  https://github.com/aws-solutions/aws-waf-security-automations.git upstream

# Build Docker image
docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Build and test log_parser
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder log_parser /upstream /output

# Build and test reputation_lists_parser
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder reputation_lists_parser /upstream /output
```

### 3.2 Automated Tests (in build script)

The build script runs these tests automatically:

#### Positive Tests

| # | Test | File:Line | What it validates |
|---|------|-----------|-------------------|
| 1 | Zip exists & not empty | `scripts/build-lambda.sh:150` | Build completed successfully |
| 2 | Handler file in zip | `scripts/build-lambda.sh:158` | Lambda can find entry point |
| 3 | Size < 50MB | `scripts/build-lambda.sh:166` | Within Lambda deployment limit |
| 4 | Required libs included | `scripts/build-lambda.sh:177` | `waflibv2.py`, `solution_metrics.py` present |

#### Negative Tests

| # | Test | File:Line | What it catches |
|---|------|-----------|-----------------|
| 5 | Zip integrity | `scripts/build-lambda.sh:190` | Corrupted archive |
| 6 | No `__pycache__` | `scripts/build-lambda.sh:198` | Unclean build artifacts |
| 7 | No `.pyc` files | `scripts/build-lambda.sh:206` | Bytecode contamination |
| 8 | Import validation | `scripts/build-lambda.sh:224` | Missing dependencies |

### 3.3 Security Scan (pip-audit)

```bash
# Scan log_parser dependencies
cd upstream/source/log_parser
poetry export --without dev -f requirements.txt -o /tmp/reqs.txt
pip-audit -r /tmp/reqs.txt --desc

# Scan reputation_lists_parser dependencies
cd ../reputation_lists_parser
poetry export --without dev -f requirements.txt -o /tmp/reqs.txt
pip-audit -r /tmp/reqs.txt --desc
```

**Expected output:** `No known vulnerabilities found` or list of CVEs.

---

## 4. Manual Validation

### 4.1 Verify Zip Contents

```bash
# List contents
unzip -l lambda/log_parser.zip | head -30

# Check for required files
unzip -l lambda/log_parser.zip | grep -E "log-parser.py|lib/waflibv2.py"
```

### 4.2 Test Python Imports

```bash
# Extract and test
mkdir -p /tmp/test-lambda
unzip -q lambda/log_parser.zip -d /tmp/test-lambda
cd /tmp/test-lambda

# Test import
python3 -c "import sys; sys.path.insert(0, '.'); import log_parser"

# Cleanup
rm -rf /tmp/test-lambda
```

### 4.3 Verify File Sizes

```bash
ls -lh lambda/*.zip
```

**Expected:** Both zips should be < 50MB.

---

## 5. CI/CD Tests

Tests run automatically in GitHub Actions when the build workflow is triggered.

### 5.1 Workflow Location

`File:` `.github/workflows/build-lambda-packages.yml`

### 5.2 Tests Executed

| Step | Line | Test |
|------|------|------|
| Verify upstream checkout | :84-93 | Source directories exist |
| Build log_parser.zip | :102-108 | Build + validation tests |
| Build reputation_lists_parser.zip | :110-116 | Build + validation tests |
| pip-audit scan | :118-130 | Dependency vulnerabilities |
| Final validation | :132-146 | Zip listing and summary |

### 5.3 Trigger Workflow

```bash
# Via GitHub CLI
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.0.3 \
  -f version_bump=none
```

---

## 6. Test Matrix

### What We Test

| Category | Tool | Scope |
|----------|------|-------|
| Terraform syntax | `terraform validate` | All `.tf` files |
| Terraform format | `terraform fmt` | All `.tf` files |
| Terraform plan | `terraform plan` | Full module |
| Security (TF) | `tfsec` | All `.tf` files |
| Compliance | `checkov` | All `.tf` files |
| Linting | `tflint` | All `.tf` files |
| Lambda build | `build-lambda.sh` | Both Lambda packages |
| Lambda security | `pip-audit` | Python dependencies |
| Zip integrity | `unzip -t` | Both Lambda packages |

### What We Don't Test (Yet)

| Category | Reason | Future Work |
|----------|--------|-------------|
| Integration tests | Requires AWS deployment | Add terratest |
| End-to-end tests | Requires live WAF | Add staging environment |
| Performance tests | Requires traffic | Add load testing |

---

## 7. Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `terraform init` fails | Missing providers | Check internet connection |
| `terraform validate` fails | Syntax error | Check error message for file:line |
| Docker build fails | Missing Docker | Install and start Docker |
| pip-audit finds vulnerabilities | Outdated dependencies | Update upstream reference |
| Zip too large | Too many dependencies | Review and trim dependencies |

### Debug Commands

```bash
# Verbose terraform
TF_LOG=DEBUG terraform plan

# Docker build with no cache
docker build --no-cache -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Extract and inspect zip
unzip -l lambda/log_parser.zip
unzip lambda/log_parser.zip -d /tmp/inspect && ls -la /tmp/inspect
```

---

## 8. Makefile (Optional)

Create a `Makefile` for convenience:

```makefile
.PHONY: test validate fmt security build clean

test: validate fmt security

validate:
	terraform init -backend=false
	terraform validate

fmt:
	terraform fmt -check -recursive

security:
	tfsec .
	checkov -d . --quiet

build:
	docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

clean:
	rm -rf .terraform
	rm -rf /tmp/build_*
```

Usage:
```bash
make test      # Run all tests
make validate  # Terraform validation only
make security  # Security scans only
make build     # Build Docker image
```

---

## References

| Resource | Link |
|----------|------|
| Terraform Docs | https://developer.hashicorp.com/terraform/docs |
| tfsec | https://aquasecurity.github.io/tfsec |
| checkov | https://www.checkov.io/1.Welcome/Quick%20Start.html |
| pip-audit | https://pypi.org/project/pip-audit/ |
| AWS WAF Docs | https://docs.aws.amazon.com/waf/ |
