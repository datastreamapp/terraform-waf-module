# WAF Module Task Tracking

Reference: [Issue #801](https://github.com/datastreamapp/issues/issues/801)

This file tracks implementation tasks for the terraform-waf-module.

---

## Current: Upstream Lambda Update

**Status:** In Progress
**Date:** 2026-01-23

### Objective

Update WAF Lambda packages to latest upstream version and fix CI/CD build issues.

### Current State

| Item | Current | Target |
|------|---------|--------|
| Upstream Version | v4.0.3 | v4.1.2 |
| Module Version | v3.1.0 | v3.2.0 |
| Build Status | ~~FAILING~~ PASSING | PASSING |

### Tasks

- [x] Diagnose CI/CD build failure (Poetry export issue)
- [x] Fix `scripts/build-lambda.sh` - add `poetry lock` before export
- [x] Update README.md with version trigger documentation
- [x] Reorganize docs (move CHANGELOG.md, TODOLIST.md)
- [x] Test build workflow with fixed script
- [ ] Trigger workflow with `upstream_ref=v4.1.2`
- [ ] Review and merge generated PR
- [ ] Create release tag v3.2.0

### Issues Fixed

**1. Poetry Export Failure (Initial)**
- **Problem:** CI/CD build fails with "Poetry export failed"
- **Root Cause:** Build script runs `poetry export` without first generating a lock file
- **Fix:** Added `poetry lock --no-interaction` before `poetry export` in `scripts/build-lambda.sh`

**2. Poetry Plugin Export Missing**
- **Problem:** Poetry 1.2+ removed `export` command from core
- **Root Cause:** `poetry-plugin-export` not installed in Docker image
- **Fix:** Added `poetry-plugin-export` to `scripts/Dockerfile.lambda-builder`

**3. Sparse Checkout Not Getting All Files**
- **Problem:** `requirements.txt` not checked out, falling back to pyproject.toml
- **Root Cause:** `actions/checkout@v4` sparse-checkout needs `sparse-checkout-cone-mode: false`
- **Fix:** Added `sparse-checkout-cone-mode: false` in `.github/workflows/build-lambda-packages.yml`

**4. Workflow Using Wrong Branch**
- **Problem:** Build fixes on release branch not being used
- **Root Cause:** Workflow hardcoded `ref: master` instead of current branch
- **Fix:** Changed to `ref: ${{ github.ref }}` in `.github/workflows/build-lambda-packages.yml`

**5. Mermaid Diagram Rendering Issues**
- **Problem:** "Unsupported markdown: list" warnings in diagrams
- **Root Cause:** `<br/>` tags and numbered prefixes (1., 2.) parsed as markdown lists
- **Fix:** Removed `<br/>` tags and numbered prefixes from all diagrams in `docs/ARCHITECTURE.md`

**6. Documentation Missing Pipeline Details**
- **Problem:** Diagrams didn't show where zip files go or human review step
- **Root Cause:** Incomplete pipeline documentation
- **Fix:** Added "Commit zips to lambda/" and "Human Review PR and Approve to Merge Packages" steps

### Upstream Versions Reference

| Version | Date | Key Changes |
|---------|------|-------------|
| v4.1.2 | 2026-01-14 | Security updates (urllib3, werkzeug) |
| v4.1.1 | 2025-12-29 | Security patches (urllib3, js-yaml, werkzeug) |
| v4.1.0 | 2025-07-30 | CDK support, rate-based rules, lambda power tools |
| v4.0.3 | - | Current default (known-good) |

Source: https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md

---

## Completed: CI/CD Implementation (Issue #801)

**Status:** COMPLETED
**Released:** v3.0.0

### Deliverables

- [x] `scripts/Dockerfile.lambda-builder` - Docker build environment
- [x] `scripts/build-lambda.sh` - Build script with validation tests
- [x] `.github/workflows/build-lambda-packages.yml` - Lambda build workflow
- [x] `.github/workflows/test.yml` - CI/CD test workflow
- [x] `docs/ARCHITECTURE.md` - Mermaid architecture diagrams
- [x] `docs/TESTING.md` - Comprehensive testing guide
- [x] `Makefile` - Build and test automation
- [x] Python runtime upgraded from 3.9 to 3.13

### Technical Decision: Python 3.13

| Factor | Python 3.14 | Python 3.13 | Winner |
|--------|-------------|-------------|--------|
| Upstream Compatibility | Untested (uses ~3.12) | Closer to 3.12 | 3.13 |
| Release Maturity | Bleeding edge | More stable | 3.13 |
| Dependency Risk | Higher | Lower | 3.13 |

---

## Known Accepted Issues

| Issue | Severity | Reason |
|-------|----------|--------|
| CloudWatch logs not KMS encrypted | LOW | Uses default encryption |
| Lambda not in VPC | LOW | Not required for WAF log parsing |
| Lambda no concurrency limit | LOW | Self-limiting via triggers |
