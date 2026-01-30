# Architecture Decision Records

This document captures key technical and architectural decisions for the terraform-waf-module, along with context and rationale.

## Table of Contents

- [ADR-001: Python 3.12 to match upstream constraint](#adr-001-python-312-to-match-upstream-constraint)
- [ADR-002: Lambda Powertools via Layer (SSM) instead of bundling in zip](#adr-002-lambda-powertools-via-layer-ssm-instead-of-bundling-in-zip)
- [ADR-003: Build validation with Layer/Runtime package allowlists](#adr-003-build-validation-with-layerruntime-package-allowlists)
- [ADR-004: Poetry export without hashes](#adr-004-poetry-export-without-hashes)

---

## ADR-001: Python 3.12 to match upstream constraint

**Date:** 2026-01-14 (revised 2026-01-28)
**Status:** Accepted (supersedes original 3.13 decision)
**Issue:** [#801](https://github.com/datastreamapp/issues/issues/801)

### Context

The Lambda runtime needed upgrading from Python 3.9 (EOL). The upstream [aws-waf-security-automations](https://github.com/aws-solutions/aws-waf-security-automations) specifies `python = "~3.12"` in their `pyproject.toml`, meaning `>=3.12.0, <3.13.0`.

Initially we chose Python 3.13 as a balance between upstream compatibility and newer features. However, this created a version mismatch: Poetry export produced `python_version` markers tied to 3.12, and pip on 3.13 skipped all packages. We worked around this with a `sed` regex to strip markers — a fragile hack.

### Decision

Use Python 3.12 across the entire stack (Dockerfile, Lambda runtime, SSM Powertools path) to match upstream's constraint exactly.

### Rationale

| Approach | Pros | Cons |
|----------|------|------|
| Python 3.13 + sed workaround | Newer runtime | Fragile hack, version mismatch, could break on future deps |
| **Python 3.12 (match upstream)** | Zero workarounds, matches tested config | Slightly older runtime |
| Python 3.14 | Latest features | Untested by upstream, highest risk |

Matching upstream eliminates:
- The `sed` marker-stripping workaround
- The `--without-hashes` workaround for orphaned hash lines after stripping
- Risk of installing packages incompatible with the runtime version

### Consequences

- Python 3.12 is fully supported by AWS Lambda (EOL ~2028)
- Upgrade to 3.13+ when upstream updates their `python = "~3.12"` constraint
- No workarounds needed in the build pipeline

---

## ADR-002: Lambda Powertools via Layer (SSM) as defense-in-depth

**Date:** 2026-01-28
**Status:** Accepted
**Issue:** [#801](https://github.com/datastreamapp/issues/issues/801)

### Context

Upstream [aws-waf-security-automations v4.0.5](https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md) replaced the native Python logger with `aws_lambda_powertools` Logger, and [v4.1.0](https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md) added Powertools Tracer for X-Ray tracing. Both Lambda handlers (`log_parser`, `reputation_lists_parser`) now import Logger and Tracer at the top level.

The package is listed in the upstream `pyproject.toml` ([`aws-lambda-powertools = "~3.2.0"`](https://github.com/aws-solutions/aws-waf-security-automations/blob/main/source/reputation_lists_parser/pyproject.toml)) and should be bundled in the zip by the CI/CD build pipeline via Poetry export → pip install.

However, the build initially produced incomplete zips due to a Python version mismatch (see [ADR-001](#adr-001-python-312-to-match-upstream-constraint)). This has been resolved by aligning the build to Python 3.12. See [RETROSPECTIVE.md](RETROSPECTIVE.md#2026-01-28-incomplete-lambda-zip-packages-issue-801) for the full investigation.

AWS publishes Powertools as a [managed Lambda Layer](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/#lambda-layer) and recommends this as an installation method. The official documentation provides a [Terraform example using SSM Parameter Store](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/#using-ssm-parameter-store) to dynamically resolve the Layer ARN.

### Decision

Add the AWS Lambda Powertools Layer via SSM Parameter Store as **defense-in-depth**, in addition to the zip containing the dependency. The zips must also be rebuilt by CI/CD to include all dependencies.

### Rationale

| Approach | Pros | Cons |
|----------|------|------|
| Zip only (fix build) | Self-contained, no extra infra | Single point of failure if build breaks again |
| Layer only | AWS-managed, always up-to-date | Doesn't fix the incomplete build problem, other deps still missing |
| **Both (zip + Layer)** | Defense-in-depth, Layer takes precedence, catches build gaps | Slight redundancy for powertools |

Why the Layer specifically:

- AWS publishes Powertools layers to all regions under account [`017000801446`](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/#lambda-layer) (China: `498634801083`, GovCloud: `165087284144` / `165093116878`)
- The [official Powertools install documentation](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/) provides the Layer as one of the primary installation methods alongside pip, with IaC examples for SAM, CDK, Serverless Framework, Terraform, and Pulumi
- SSM path format [`/aws/service/powertools/python/{arch}/{python_version}/latest`](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/#using-ssm-parameter-store) resolves the correct ARN for the current region — no hardcoded ARNs needed
- The Layer also includes `aws-xray-sdk`, providing coverage for Tracer without needing it separately in the zip
- Using `latest` in the SSM path ensures automatic updates when AWS publishes new Layer versions
- The zips still need rebuilding to include `jinja2`, `backoff`, `pyparsing`, and other deps not covered by the Layer

### Implementation

Based on the [Terraform example from official Powertools documentation](https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/#using-ssm-parameter-store):

```hcl
# data.powertools-layer.tf
data "aws_ssm_parameter" "powertools_layer" {
  name = "/aws/service/powertools/python/x86_64/python3.12/latest"
}

# In each Lambda resource (lambda.log-parser.tf, lambda.reputation-list.tf)
layers = [data.aws_ssm_parameter.powertools_layer.value]
```

### Consequences

- Layer version changes happen on `terraform apply` — review plan output to catch unexpected updates
- If AWS deprecates the SSM path format, we'll need to update the lookup mechanism
- The CI/CD pipeline must also be fixed to produce complete zips — the Layer is defense-in-depth, not a substitute for a working build
- Layer does not provide `jinja2`, `backoff`, `pyparsing`, or `urllib3` — zips must be rebuilt with all deps
- Added to Version Dependencies table in [RETROSPECTIVE.md](RETROSPECTIVE.md#version-dependencies) for periodic review

### References

| Source | Link |
|--------|------|
| Powertools Install Docs (Layer + SSM + Terraform) | https://docs.aws.amazon.com/powertools/python/latest/getting-started/install/ |
| Powertools GitHub (source, releases) | https://github.com/aws-powertools/powertools-lambda-python |
| Powertools PyPI | https://pypi.org/project/aws-lambda-powertools/ |
| Upstream CHANGELOG (v4.0.5: Logger, v4.1.0: Tracer) | https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md |
| Upstream pyproject.toml (dependency declaration) | https://github.com/aws-solutions/aws-waf-security-automations/blob/main/source/reputation_lists_parser/pyproject.toml |

---

## ADR-003: Build validation with strict import checking

**Date:** 2026-01-28
**Status:** Accepted
**Issue:** [#801](https://github.com/datastreamapp/issues/issues/801)

### Context

The build validation in `scripts/build-lambda.sh` tests handler imports after packaging. When `aws_lambda_powertools` was missing, the import test silently fell through to a syntax check and reported PASS, masking the real failure. The incomplete zip shipped to production.

### Decision

Replace the permissive fallback with strict validation:

- **`RUNTIME_PACKAGES`** (e.g., `boto3`, `botocore`) — WARN only. These are provided by the Lambda runtime and are legitimately unavailable during the Docker build.
- **Any other missing module** — HARD FAIL. This means the build did not install all dependencies from `pyproject.toml` and the zip is incomplete.

### Rationale

- The previous fallback to syntax check (`py_compile`) masked real import failures — the build passed but the Lambda crashed at runtime
- `boto3` and `botocore` are the only packages guaranteed by the Lambda runtime; everything else must be in the zip or a Layer
- Any unresolved import beyond the runtime packages indicates an incomplete build that should block the pipeline

### Consequences

- If upstream adds new runtime-provided dependencies, they need to be added to the `RUNTIME_PACKAGES` array
- This is documented in the Upstream Update Checklist in RETROSPECTIVE.md

---

## ADR-004: Poetry export without hashes

**Date:** 2026-01-28
**Status:** Accepted
**Issue:** [#801](https://github.com/datastreamapp/issues/issues/801)

### Context

Poetry's `export` command includes `--hash` lines by default in the generated `requirements.txt`. These hashes enable pip to verify package integrity during install (supply chain security).

However, `--without-hashes` is used in our build pipeline.

### Decision

Use `--without-hashes` in `poetry export`. Accept the tradeoff.

### Rationale

| Factor | With hashes | Without hashes |
|--------|-------------|----------------|
| Supply chain security | pip verifies package integrity | No verification |
| Build reliability | Can fail if hash changes (e.g., PyPI re-upload) | More resilient |
| Compatibility | Hash mode requires ALL deps to have hashes or none | No constraint |

Why this is acceptable:

1. **Controlled build environment** — builds run inside a Docker container (`public.ecr.aws/lambda/python:3.12`) pulled from AWS ECR, not an arbitrary environment
2. **Pinned upstream** — we clone from a specific git tag (`v4.1.2`), so `pyproject.toml` and `poetry.lock` are fixed
3. **Network isolation is not a goal** — pip already fetches from PyPI over HTTPS during the build; hashes add integrity checking but not confidentiality
4. **pip-audit runs during CI** — known CVEs in dependencies are caught by `pip-audit` in the build workflow

### Consequences

- If supply chain verification becomes a requirement, re-enable hashes and ensure `poetry.lock` is present and up-to-date
- The Docker base image and PyPI HTTPS transport provide baseline integrity
- This decision should be revisited if the build moves to a less controlled environment

---

## Template

```markdown
## ADR-NNN: [Title]

**Date:** YYYY-MM-DD
**Status:** Proposed | Accepted | Deprecated | Superseded by ADR-NNN
**Issue:** [#NNN](url)

### Context
[What is the issue? What forces are at play?]

### Decision
[What was decided]

### Rationale
[Why this option over alternatives]

### Consequences
[What are the trade-offs and follow-up items]
```
