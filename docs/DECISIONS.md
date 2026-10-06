# Architecture Decision Records

This document captures key technical and architectural decisions for the terraform-waf-module, along with context and rationale.

## Table of Contents

- [ADR-001: Python 3.12 to match upstream constraint](#adr-001-python-312-to-match-upstream-constraint)
- [ADR-002: Lambda Powertools via Layer (SSM) instead of bundling in zip](#adr-002-lambda-powertools-via-layer-ssm-instead-of-bundling-in-zip)
- [ADR-003: Build validation with Layer/Runtime package allowlists](#adr-003-build-validation-with-layerruntime-package-allowlists)
- [ADR-004: Poetry export without hashes](#adr-004-poetry-export-without-hashes)
- [ADR-005: Per-address path rate rules, Count mode only](#adr-005-per-address-path-rate-rules-count-mode-only)

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

## ADR-005: Per-address path rate rules, Count mode only

**Date:** 2026-10-06
**Status:** Accepted
**Issue:** [datastreamapp/issues#2252](https://github.com/datastreamapp/issues/issues/2252)

### Context

The app has a per-email attempt counter on the recovery-code form. It has nothing per source address, so an attacker who rotates emails is never slowed down. Each recovery-code request holds a Lambda for at least 500 ms, and the onboard recovery send action for at least 1500 ms. The only rate rule in this module (`wafHttpFloodRateBasedRule`, priority 5) covers every path at 2000 requests per 5 minutes, far too high to protect one form. The module had no input that lets a caller add a rule.

### Decision

Add the `path_rate_rules` input (`variables.tf`). Each entry adds one rate-based rule (`main.tf`, the `dynamic "rule"` after the flood rule):

- Aggregated by source IP (`aggregate_key_type = "IP"`). Not `FORWARDED_IP`: a client can set that header and pick its own key.
- Scope-down: method EXACTLY `method`, AND the URI path matches `uri_path_regex` after `URL_DECODE`, `NORMALIZE_PATH`, `LOWERCASE` (the app accepts an upper-case locale and a percent-encoded path), AND, when set, the query string CONTAINS `query_contains` after `URL_DECODE`.
- Priority 10 to 19 only, so a caller cannot collide with the module's own rules (0, 1, 3, 4, 5, 20, 30).
- Action `count`.

The first caller (the `edge` root in the infrastructure repo) covers only two forms: the recovery-code POST (`/{locale}/login/recovery-code`) and the `sendRecoveryCode` action on `/{locale}/onboard`. The other `/onboard` actions stay with datastreamapp/issues#1737.

### Rationale

**Count only.** Both rules use Count. Count stops nothing. AWS documents that a rate-based rule in Count mode "doesn't limit the rate of requests. It just counts the requests that are over the limit." So Count also does not show the normal peak per address; real peaks come from the WAF logs in Athena (`waf_logs`). Block is a later slice with its own plan review, where the human approves the limit and the English-only JSON 429 page (`RateLimitJsonBody`).

**Why `action` accepts only `"count"`.** No block code ships without its own tests. The field exists now so the Block slice widens the validation instead of changing the type. Adding a required field later would break callers, and an optional field needs `optional()`, which needs a newer Terraform floor.

**Fixed 300-second window.** The rule does not set `evaluation_window_sec`. The window is the AWS default, 300 seconds. That field was added during the AWS provider 5.x line (exact release not checked), and the module allows `aws >= 5.0`, so leaving it out avoids raising the provider floor.

**Limit values.** The values are set by the caller, not this module. Starting values are guesses with no traffic data: 30 requests per 300 seconds per address in production and testing, and 10 (the AWS minimum) in development, so a short live probe shows over-limit hits. In the Block slice they are replaced by values from real WAF-log peaks (about 3 times the highest normal peak). Changing a limit resets the rule's counts.

**Terraform version.** The module floor stays `required_version = ">= 1.0"`: nothing in the module code needs more. The new test (`tests/path_rate_rules.tftest.hcl`) uses `mock_provider`, which needs Terraform 1.7 or newer, so CI pins `terraform_version` in `.github/workflows/test.yml`.

| Option | Pros | Cons |
|--------|------|------|
| Raise `requestThreshold` defaults per path | No new input | Not possible: the flood rule has no scope-down |
| Two fixed rules in the module | Simple | Paths and limits are app-specific; every route change needs a module release |
| **Generic `path_rate_rules` map** | One map entry per route, no module change for new routes | Callers must pick a free priority (validated 10 to 19) |

### Consequences

- **Function URL known limit.** The public app-ssr Lambda Function URL (authorization `NONE`, no origin access control on CloudFront) is reachable without CloudFront. Anyone with that URL skips the whole WAF, including these rules. Accepted by the human as a known limit; a follow-up ticket covers it.
- **Slow lock-out gap.** About 1 request per 80 seconds per victim email stays far below any per-address limit, so this rule does not stop a slow lock-out of one account. It bounds Lambda abuse and mass email testing from one address. It does not replace the app's per-email counter.
- **One ACL feeds five CloudFront resources** in the `edge` root. The rules count across all of them, and a mistake in the ACL affects all of them.
- **Not checked offline:** WCU capacity (each rule is roughly 50 to 80 WCU, an estimate; a capacity error appears at apply, not plan), and whether AWS accepts each regex. Both show on the first apply.
- Rollback: remove the entries from `path_rate_rules`. The rules disappear in one in-place ACL update. Count never stopped a request, so users see no change.

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
