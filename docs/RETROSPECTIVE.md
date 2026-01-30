# Retrospective & Governance

This document captures lessons learned, process improvements, and team checklists for the terraform-waf-module.

## Table of Contents

- [Retrospectives](#retrospectives)
  - [2026-01-23: Upstream Update & CI/CD Fix](#2026-01-23-upstream-update--cicd-fix)
- [Checklists](#checklists)
  - [Development Checklist](#development-checklist)
  - [Deployment Checklist](#deployment-checklist)
  - [Documentation Checklist](#documentation-checklist)
  - [Code Review Checklist](#code-review-checklist)
  - [Upstream Update Checklist](#upstream-update-checklist)
  - [Release Checklist](#release-checklist)
- [Maintenance Schedule](#maintenance-schedule)
- [Version Dependencies](#version-dependencies)
- [Templates](#templates)

---

## Retrospectives

### 2026-01-28: Incomplete Lambda Zip Packages (Issue #801)

#### What Happened

After deploying v4.0.0 (upstream v4.1.2) to development, the reputation-list Lambda failed with:
`Runtime.ImportModuleError: No module named 'aws_lambda_powertools'`

Both log-parser and reputation-list Lambdas are affected.

#### Root Causes

| Issue | Root Cause | Why It Was Missed |
|-------|------------|-------------------|
| pip skipped all dependencies due to Python version markers | Upstream `pyproject.toml` specifies `python = "~3.12"` (>=3.12.0, <3.13.0). Poetry export produces a requirements file where **every dependency** has the marker `; python_version == "3.12"`. When pip runs on Python 3.13, it evaluates these markers and skips every package. pip exits 0 because it successfully processed the file — it just installed nothing. | Poetry is doing the right thing by adding markers. The mismatch is the Docker image running Python 3.13 while upstream requires ~3.12. The build script doesn't verify pip actually installed any packages. |
| Build validation import test silently passes | Test in build-lambda.sh falls through to a syntax check when imports fail, marking it as PASS even when critical runtime dependencies are missing | The fallback was designed for packages only available in the Lambda runtime (e.g., boto3), but it didn't distinguish between expected and unexpected import failures |
| No Lambda Layer configured as defense-in-depth | AWS recommends providing `aws_lambda_powertools` via Lambda Layer as best practice, which would have caught this at runtime | Previous upstream versions didn't use `aws_lambda_powertools` |

#### Investigation

1. Error on dev: `Runtime.ImportModuleError: No module named 'aws_lambda_powertools'`
2. Zip analysis: `aws_lambda_powertools`, `jinja2`, `aws-xray-sdk` all missing despite being listed in upstream `pyproject.toml`
3. CI/CD logs (run #21362768728): Poetry export ran, pip install ran, both exited 0 — but pip never installed `aws-lambda-powertools` or `jinja2` (no `Collecting aws-lambda-powertools` in logs)
4. Timing: pip install completed in <1 second — far too fast for real dependency installation
5. **Root cause**: Poetry export produces requirements with `; python_version == "3.12"` markers on every dependency. pip on Python 3.13 evaluates these markers and skips all packages. The file is 18KB and non-empty — but pip installs nothing because `3.13 != 3.12`
6. The build script doesn't verify pip actually installed any packages after running

#### Fix Applied

1. **Lambda Layer (defense-in-depth):** Added `data.powertools-layer.tf` using SSM Parameter Store to dynamically resolve the latest AWS Lambda Powertools Layer ARN. This provides `aws_lambda_powertools` and `aws-xray-sdk` as a managed Layer, which is AWS best practice regardless of what's in the zip.
2. **Build validation improvement:** Import test now categorizes missing modules into runtime-provided (warn) and unknown (hard fail) instead of silently falling back to a syntax check.
3. **Zip rebuild required:** The CI/CD pipeline must be re-triggered to produce complete zip artifacts with all dependencies from upstream `pyproject.toml`.

#### Action Items

- [x] Add AWS Lambda Powertools Layer via SSM data source
- [x] Update both Lambda function resources with `layers` attribute
- [x] Improve build validation to detect missing dependencies
- [x] Update CHANGELOG.md, DECISIONS.md
- [x] Add to Version Dependencies table
- [ ] Rebuild Lambda zips via CI/CD pipeline
- [ ] Deploy fix to dev and verify
- [ ] Comment on issue #801 with corrected findings

#### Process Improvements

1. **Build script must verify pip installed packages** — after `pip install`, check that the build directory contains installed packages (not just handler files). The requirements file may be non-empty but pip can skip everything due to environment markers
2. **Python version in Docker must match upstream constraint** — if upstream requires `python ~3.12`, either use Python 3.12.x in Docker, or strip environment markers from the exported requirements before pip install
3. **Build validation must fail on missing dependencies** — the import test now fails on any unresolved import that isn't a known runtime-provided package (boto3, botocore)
4. **Added to Upstream Update Checklist** — verify Python version compatibility between upstream `pyproject.toml` and Docker build image

---

### 2026-01-23: Upstream Update & CI/CD Fix

### What Happened

1. **CI/CD Build Failure** - The "Build WAF Lambda Packages" workflow failed with "Poetry export failed" error when attempting to build with upstream version v4.1.2.

2. **Missing Documentation** - Users had no clear instructions on:
   - How to trigger Lambda updates via GitHub Actions
   - How to select which upstream version to use
   - Where to check for new upstream versions

### Root Causes

#### 1. Poetry Export Bug

| Issue | Why It Was Missed |
|-------|-------------------|
| `poetry lock` not called before `poetry export` | Original implementation tested with upstream v4.0.3 which had a `requirements.txt` file. Newer versions (v4.1.0+) removed `requirements.txt` and rely solely on `pyproject.toml`, triggering the untested Poetry code path. |

**The bug in `scripts/build-lambda.sh`:**
```bash
# Old code - assumed poetry.lock existed
poetry export --without dev -f requirements.txt ...

# Fixed code - generates lock file if missing
if [[ ! -f "poetry.lock" ]]; then
    poetry lock --no-interaction
fi
poetry export --without dev -f requirements.txt ...
```

**Lesson:** Test all code paths, not just the happy path. The `requirements.txt` fallback masked the Poetry issue during initial development.

#### 2. Missing Workflow Documentation

| Issue | Why It Was Missed |
|-------|-------------------|
| No instructions on how to trigger workflow | Assumed developers would understand GitHub Actions workflow_dispatch |
| No guidance on version selection | Focused on "how to build" not "how to decide what to build" |
| No link to upstream changelog | Treated upstream version as implementation detail, not user-facing config |

**Lesson:** Documentation should answer "how do I use this?" not just "how does this work?" Include the decision-making process, not just the mechanics.

#### 3. Version Pinned Without Explanation

| Issue | Why It Was Missed |
|-------|-------------------|
| Default `v4.0.3` with no context | Version was chosen during development and hardcoded without documenting why or how to change it |

**Lesson:** Any hardcoded value that users might need to change should be documented with:
- What it is
- Why this value was chosen
- How to change it
- Where to find alternatives

---

### Action Items Completed

- [x] Fixed Poetry export bug in `scripts/build-lambda.sh`
- [x] Added "Upstream Version Selection" section to README
- [x] Added "Triggering Lambda Updates" step-by-step guide
- [x] Added "Version Bump Guidelines" table
- [x] Added "Workflow Inputs Reference" section
- [x] Linked to upstream CHANGELOG for version discovery
- [x] Reorganized docs (CHANGELOG.md, TODOLIST-801.md moved to docs/)

---

### Process Improvements

#### For Future CI/CD Development

1. **Test all code branches** - If there's an `if/elif/else`, test each path
2. **Test with multiple upstream versions** - Don't assume current version represents all versions
3. **Add integration tests** - The unit tests passed but integration with real upstream failed
4. **Establish upstream update cadence** - Schedule regular checks for upstream updates (e.g., monthly)

#### For Future Documentation

1. **Include "How to Use" sections** - Not just architecture and implementation details
2. **Document all configurable values** - Especially defaults that users might change
3. **Link to external dependencies** - If we depend on upstream, link to their docs/changelog
4. **Write from user perspective** - Ask "what would someone new to this repo need to know?"
5. **Keep docs organized from the start** - All documentation should live in `docs/` folder, not scattered in root

#### File Organization Lessons

1. **TODOLIST.md and CHANGELOG.md were in root** - Should have been in `docs/` from the beginning
2. **Inconsistent naming** - Use consistent patterns like `TODOLIST-{issue}.md` for traceability
3. **No single source of truth** - README referenced files that could drift out of sync

#### Checklist for New Features

```markdown
## Documentation Checklist
- [ ] How do users trigger/use this feature?
- [ ] What inputs/configuration are available?
- [ ] What are the defaults and why?
- [ ] Where can users find more information (external links)?
- [ ] What decisions might users need to make?
```

---

### Additional Lessons Learned

#### 4. No Process for Tracking Upstream Updates

| Issue | Why It Was Missed |
|-------|-------------------|
| Module was 4 versions behind upstream (v4.0.3 vs v4.1.2) | No scheduled review of upstream releases. Set-and-forget mentality. |

**Lesson:** Dependencies on external repositories need a maintenance process:
- Subscribe to upstream release notifications
- Schedule periodic (monthly/quarterly) dependency reviews
- Document the current pinned version AND when it was last reviewed

#### 5. Multiple Hardcoded Versions Without Visibility

| Issue | Why It Was Missed |
|-------|-------------------|
| AWS Managed Rule Group version `Version_1.4` hardcoded in `main.tf:82` | Treated as implementation detail, not surfaced to users |
| Upstream ref `v4.0.3` hardcoded in workflow | Same as above |

**Lesson:** Create a "Version Dependencies" section documenting ALL external version pins:
- Lambda upstream version
- AWS Managed Rule versions
- Provider versions
- Python runtime version

#### 6. Lack of Operational Runbooks

| Issue | Why It Was Missed |
|-------|-------------------|
| No documentation on "how to update Lambda packages" | Assumed tribal knowledge would suffice |
| No troubleshooting guide for CI/CD failures | Focus was on building, not operating |

**Lesson:** For any automated process, document:
- How to trigger it manually
- How to troubleshoot common failures
- How to rollback if something goes wrong

#### 7. Testing in Isolation vs Integration

| Issue | Why It Was Missed |
|-------|-------------------|
| Local tests passed but CI/CD failed | Tests used mocked/controlled inputs, not real upstream |

**Lesson:** Include at least one integration test that uses real external dependencies to catch environment-specific issues.

---

### Summary

| Category | Gap | Fix |
|----------|-----|-----|
| Testing | Only tested happy path (requirements.txt) | Test all code paths including Poetry fallback |
| Testing | No integration test with real upstream | Add CI test with actual upstream checkout |
| Documentation | Missing "how to use" workflow guide | Added step-by-step trigger instructions |
| Documentation | No version selection guidance | Added upstream changelog link and version table |
| Documentation | Files scattered in root | Moved CHANGELOG, TODOLIST to docs/ |
| Configuration | Hardcoded version without explanation | Documented default and how to change |
| Process | No upstream update cadence | Establish monthly review schedule |
| Process | No operational runbook | Added troubleshooting and rollback docs |

---

## Checklists

The following checklists are derived from lessons learned and serve as governance standards for the team.

### Development Checklist

Before submitting a PR:

#### Code Quality
- [ ] All code paths tested (if/elif/else branches)
- [ ] No hardcoded values without documentation
- [ ] Error handling for all external calls
- [ ] Follows existing code patterns and style

#### Testing
- [ ] Unit tests pass locally (`make test`)
- [ ] Integration tests pass (`make test-local`)
- [ ] Tested with multiple input variations
- [ ] Edge cases considered and tested

#### Security
- [ ] No secrets or credentials in code
- [ ] No sensitive data in logs
- [ ] Security scan passes (`tfsec`, `checkov`)
- [ ] Dependencies scanned (`pip-audit`)

---

### Deployment Checklist

Before deploying changes to production:

#### Pre-Deployment
- [ ] All CI/CD checks pass (green build)
- [ ] PR reviewed and approved
- [ ] `terraform plan` reviewed - no unexpected changes
- [ ] Rollback procedure documented and tested
- [ ] Stakeholders notified of deployment

#### Validation
- [ ] Lambda zip files are reasonable size (~1-2MB)
- [ ] No security vulnerabilities flagged
- [ ] Build validation tests passed (18 tests)
- [ ] Import validation successful

#### Post-Deployment
- [ ] Verify deployment succeeded
- [ ] Check CloudWatch logs for errors
- [ ] Monitor for 15-30 minutes
- [ ] Update CHANGELOG.md with release notes
- [ ] Create release tag

---

### Documentation Checklist

When adding or modifying features:

- [ ] How do users trigger/use this feature?
- [ ] What inputs/configuration are available?
- [ ] What are the defaults and why?
- [ ] Where can users find more information (external links)?
- [ ] What decisions might users need to make?
- [ ] How to troubleshoot common issues?
- [ ] How to rollback if something fails?
- [ ] README.md updated with new features
- [ ] CHANGELOG.md updated

---

### Code Review Checklist

When reviewing PRs:

#### Functionality
- [ ] Code does what it claims to do
- [ ] All acceptance criteria met
- [ ] No unintended side effects

#### Quality
- [ ] Code is readable and maintainable
- [ ] No code duplication
- [ ] Appropriate error handling

#### Testing
- [ ] All code paths have test coverage
- [ ] Tests are meaningful (not just for coverage)
- [ ] Edge cases tested

#### Security
- [ ] No hardcoded secrets
- [ ] Input validation present
- [ ] No injection vulnerabilities

---

### Upstream Update Checklist

When updating Lambda packages from upstream:

#### Pre-Update
- [ ] Check upstream CHANGELOG for breaking changes
- [ ] Review upstream release notes
- [ ] Identify security patches vs feature updates
- [ ] Determine appropriate version bump (patch/minor/major)

#### During Update
- [ ] Trigger workflow with correct `upstream_ref`
- [ ] Select appropriate `version_bump`
- [ ] Monitor workflow execution
- [ ] Review generated PR
- [ ] Verify rebuilt zips contain all dependencies from upstream `pyproject.toml`
- [ ] Check if new upstream imports require Lambda Layers (e.g., `aws_lambda_powertools`)

#### Post-Update
- [ ] Verify Lambda zip sizes are reasonable
- [ ] Check for new dependencies
- [ ] Run security scan on new packages
- [ ] Update documentation with new version info

---

### Release Checklist

When creating a new release:

#### Pre-Release
- [ ] All features for release are merged
- [ ] All tests passing
- [ ] CHANGELOG.md updated with release notes
- [ ] Version number determined (semver)

#### Release Process
- [ ] Merge to master
- [ ] Create annotated git tag
- [ ] Push tag to remote
- [ ] Verify tag appears in GitHub

```bash
git checkout master && git pull
git tag -a "vX.Y.Z" -m "Release vX.Y.Z"
git push origin "vX.Y.Z"
```

---

## Maintenance Schedule

| Frequency | Task |
|-----------|------|
| Weekly | Review CI/CD failures and address issues |
| Monthly | Check upstream for new releases |
| Monthly | Review security advisories |
| Quarterly | Full dependency audit |
| Quarterly | Review and update documentation |

---

## Version Dependencies

Track these pinned versions and review periodically:

| Dependency | Current | Location | Check Frequency |
|------------|---------|----------|-----------------|
| Upstream WAF | v4.1.2 | `.github/workflows/build-lambda-packages.yml` | Monthly |
| AWS Managed Rules | Version_1.4 | `main.tf:82` | Quarterly |
| AWS Provider | >= 5.0 | `versions.tf` | Quarterly |
| Python Runtime | 3.12 | `Dockerfile.lambda-builder` | Annually |
| Lambda Powertools Layer | v3 (SSM latest) | `data.powertools-layer.tf` | Monthly |

**Upstream Changelog:** https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md

---

## Templates

### Retrospective Template

```markdown
### YYYY-MM-DD: [Title]

#### What Happened
[Brief description of the issue or incident]

#### Root Causes
[Why did this happen? What was missed?]

#### Action Items
- [ ] Item 1
- [ ] Item 2

#### Process Improvements
[What changes will prevent this in the future?]
```

---

Last Updated: 2026-01-28
