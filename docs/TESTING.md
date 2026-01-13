# Testing Guide

This document describes how to test the terraform-waf-module before deployment.

## Prerequisites

| Tool | Required | Purpose | Install |
|------|----------|---------|---------|
| Terraform | Yes | Infrastructure validation | `brew install terraform` |
| Docker | Yes | All tests run in containers | `brew install docker` |
| AWS CLI | Optional | AWS credentials for plan | `brew install awscli` |

**Note:** tflint, tfsec, and checkov are NOT required locally - they run in Docker containers for parity with CI.

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

| Target | Tests | Docker | Time |
|--------|-------|--------|------|
| `make test` | validate, fmt | No | ~5s |
| `make test-local` | validate, fmt, lint, security | Yes | ~60s |
| `make test-all` | All above + Lambda builds | Yes | ~120s |

### Important: validate vs plan

| Command | Purpose | Requires AWS? | Requires Variables? |
|---------|---------|---------------|---------------------|
| `terraform validate` | Syntax & config check | No | No |
| `terraform plan` | Pre-deployment preview | Yes | Yes (all required vars) |

**Why this matters:**
- `make test` and `make test-all` use `terraform validate` - no AWS credentials or variable values needed
- `terraform plan` prompts for required variables like `dead_letter_arn` - run this in your deployment environment with a `.tfvars` file
- For local development and CI, `make test-all` is sufficient

---

## 1. Available Make Targets

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

## 2. Terraform Validation

### 2.1 Initialize

```bash
terraform init -backend=false
```

**Expected:** `Terraform has been successfully initialized!`

### 2.2 Validate Syntax

```bash
terraform validate
```

**Expected:** `Success! The configuration is valid.`

**Note:** Deprecation warnings for `data.aws_region.current.name` are expected and harmless.

### 2.3 Format Check

```bash
terraform fmt -check -recursive
```

**Expected:** No output means all files are formatted correctly.

To auto-fix formatting:
```bash
terraform fmt -recursive
```

---

## 3. Linting (Docker)

### 3.1 Run tflint

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

**Expected:** No output means no issues found.

---

## 4. Security Scanning (Docker)

### 4.1 Run Security Scans

```bash
make security
```

This runs both tfsec and checkov in Docker containers.

### 4.2 tfsec (Terraform Security)

```bash
docker run --rm -v $(pwd):/data -t aquasec/tfsec:latest /data --minimum-severity HIGH
```

**What it checks:**
- Hardcoded secrets
- Insecure configurations
- AWS security best practices

**Configuration:**
- Minimum severity: HIGH (LOW issues are soft-fail)
- Excludes: `upstream/` (third-party code)

### 4.3 checkov (Policy Compliance)

```bash
docker run --rm -v $(pwd):/data -t bridgecrew/checkov:latest -d /data --quiet --compact
```

**What it checks:**
- CIS benchmarks
- AWS security best practices
- Compliance frameworks

**Configuration:**
- Excludes: `upstream/`, `lambda/` directories
- Soft-fail on: Lambda VPC config, log encryption (documented trade-offs)

### 4.4 Known Accepted Issues

| Check | Severity | Reason |
|-------|----------|--------|
| CKV_AWS_158 | LOW | CloudWatch log encryption - uses default encryption |
| CKV_AWS_115 | LOW | Lambda concurrency - not required for this use case |
| CKV_AWS_117 | LOW | Lambda VPC - not required for this use case |
| CKV_DOCKER_2/3 | INFO | Build container only, not production |

### 4.5 Expected Warnings (Safe to Ignore)

These warnings appear during tests but are expected and don't indicate problems:

| Warning | Source | Reason |
|---------|--------|--------|
| `data.aws_region.current.name` deprecated | Terraform validate | Pre-existing in module, uses deprecated AWS provider attribute. Does not affect functionality. |
| `dulwich requires urllib3>=2.2.2` | Lambda pip install | Upstream dependency conflict in build container. Does not affect Lambda runtime. |
| `Running pip as root user` | Lambda pip install | Expected in Docker build container. Isolated environment, not a security risk. |

---

## 5. Lambda Build Tests (Docker)

### 5.1 Run Lambda Tests

```bash
make test-lambda
```

Or step by step:

```bash
# Clone upstream source
make clone-upstream

# Build Docker image
make build

# Run builds
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder log_parser /upstream /output

docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder reputation_lists_parser /upstream /output
```

### 5.2 Automated Tests (18 total, 9 per package)

#### Positive Tests

| # | Test | What it validates |
|---|------|-------------------|
| 1 | Zip exists & not empty | Build completed successfully |
| 2 | Handler file in zip | Lambda can find entry point |
| 3 | Size < 50MB | Within Lambda deployment limit |
| 4 | waflibv2.py present | Core library included |
| 5 | solution_metrics.py present | Metrics library included |

#### Negative Tests

| # | Test | What it catches |
|---|------|-----------------|
| 6 | Zip integrity | Corrupted archive |
| 7 | No `__pycache__` | Unclean build artifacts |
| 8 | No `.pyc` files | Bytecode contamination |
| 9 | Import validation | Syntax errors in handler |

### 5.3 Expected Output

```
============================================
BUILD SUCCESSFUL: log_parser.zip
Size: 1.61MB
Location: /output/log_parser.zip
============================================
```

---

## 6. CI/CD Tests

Tests run automatically in GitHub Actions on every PR and push to `master`.

> **Diagram:** See `docs/ARCHITECTURE.md` → "CI/CD Test Workflow (test.yml)" for visual workflow diagram with code references.

### 6.1 Test Workflow

**File:** `.github/workflows/test.yml`

**Triggers:**
- Push to `master`
- Pull request to `master`

### 6.2 CI Test Matrix

| Job | Step | Tool | Exit on Fail |
|-----|------|------|--------------|
| terraform | Init | terraform init | Yes |
| terraform | Validate | terraform validate | Yes |
| terraform | Format | terraform fmt -check | Yes |
| terraform | Lint | tflint | Yes |
| terraform | Security | tfsec | Yes (HIGH/CRITICAL) |
| terraform | Compliance | checkov | No (soft-fail) |
| lambda | Build log_parser | Docker | Yes |
| lambda | Build reputation_lists | Docker | Yes |

### 6.3 Build Workflow

**File:** `.github/workflows/build-lambda-packages.yml`

Triggered manually to rebuild Lambda packages:

```bash
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.0.3 \
  -f version_bump=none
```

---

## 7. Manual Validation

### 7.1 Verify Zip Contents

```bash
# List contents
unzip -l lambda/log_parser.zip | head -30

# Check for required files
unzip -l lambda/log_parser.zip | grep -E "log-parser.py|lib/waflibv2.py"
```

### 7.2 Test Python Imports

```bash
# Extract and test
mkdir -p /tmp/test-lambda
unzip -q lambda/log_parser.zip -d /tmp/test-lambda
cd /tmp/test-lambda
python3 -c "import sys; sys.path.insert(0, '.'); exec(open('log-parser.py').read().split('def lambda_handler')[0])"
rm -rf /tmp/test-lambda
```

### 7.3 Verify File Sizes

```bash
ls -lh lambda/*.zip
```

**Expected:** Both zips should be ~1.6MB, well under 50MB limit.

---

## 8. Test Commands Summary

```bash
# === RECOMMENDED WORKFLOW ===

# 1. Quick check (developers, no Docker)
make test

# 2. Full local validation (before commit)
make test-local

# 3. Complete suite (before PR)
make test-all

# === INDIVIDUAL COMMANDS ===

# Terraform only
terraform init -backend=false && terraform validate && terraform fmt -check -recursive

# Lint only
docker run --rm -v $(pwd):/data -t ghcr.io/terraform-linters/tflint:latest

# Security only
docker run --rm -v $(pwd):/data -t aquasec/tfsec:latest /data --minimum-severity HIGH

# Lambda builds only
make test-lambda

# Clean rebuild
make clean-all && make test-all
```

---

## 9. Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| `terraform init` fails | Missing providers | Check internet connection |
| `terraform validate` fails | Syntax error | Check error message for file:line |
| Docker build fails | Docker not running | Start Docker Desktop |
| tflint warnings | Variable issues | Fix or ignore if intentional |
| tfsec HIGH issues | Security concern | Fix before merge |
| Lambda build fails | Missing upstream | Run `make clone-upstream` |

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
```

---

## 10. Test Verification Checklist

Before creating a PR, verify:

- [ ] `make test` passes (quick validation)
- [ ] `make test-local` passes (full validation)
- [ ] `make test-all` passes (Lambda builds)
- [ ] No HIGH/CRITICAL security issues
- [ ] Git status shows only intended changes

```bash
# Run this before PR
make test-all && echo "ALL TESTS PASSED"
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
