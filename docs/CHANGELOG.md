# Changelog

All notable changes to the terraform-waf-module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Added AWS Lambda Powertools Layer (via SSM Parameter Store) to both Lambda functions as defense-in-depth for `aws_lambda_powertools` dependency ([ADR-002](DECISIONS.md#adr-002-lambda-powertools-via-layer-ssm-as-defense-in-depth))
- Fixed Poetry export Python version marker mismatch — `sed` now strips all `python_version` environment markers (any operator) so pip installs dependencies regardless of build Python version
- Added `--without-hashes` to Poetry export to prevent orphaned `--hash` lines after marker stripping
- Added pip install verification — build fails if no packages are actually installed after `pip install`
- Rebuilt Lambda zips with all upstream dependencies (~19MB, previously ~1.7MB with missing deps)

### Added
- `scripts/test-integrity.sh` — system integrity test suite (58 checks): file existence, Terraform ↔ Lambda zip consistency, handler name consistency, Python runtime version consistency, upstream version consistency, Lambda Layer configuration, build script consistency, CI/CD workflow consistency, documentation cross-references, git hygiene
- `make test-integrity` target — runs system integrity tests (included in `make test-all`)
- `docs/DECISIONS.md` — Architecture Decision Records (ADR-001: Python 3.13, ADR-002: Lambda Powertools Layer, ADR-003: Build validation)

### Changed
- Updated default upstream version from `v4.0.3` to `v4.1.2` across all workflows, Makefile, and documentation
- CI test workflow (`test.yml`) now clones upstream `v4.1.2` — tests the Poetry export code path instead of the old `requirements.txt` path

### Improved
- Build validation expanded from 9 to 25 tests per package (50 total): upstream dependency verification, minimum size check, dev dependency leak detection, `.dist-info`/`.egg-info`/test directory cleanup verification, handler rename verification, shared lib import tests, key dependency import tests
- Build validation import test now categorizes errors: runtime environment (PASS), known runtime packages like boto3 (WARN), unknown missing modules (FAIL)
- Fixed `pipefail` + `echo | grep` SIGPIPE bug — replaced with `grep <<< "$var"` (here-strings) and file-based grep

## [4.0.0] - 2026-01-26

### Changed
- Synced with upstream [aws-waf-security-automations v4.1.2](https://github.com/aws-solutions/aws-waf-security-automations)
- Modernized CI/CD pipeline with Docker-based Lambda builds
- Workflow now uses current branch ref instead of hardcoded master for flexibility during development
- Simplified Validate step in CI/CD pipeline diagram to show "Tests - Positive and Negative" (tests run inside Docker build)
- Updated all documentation diagrams to show complete pipeline flow including human review step
- Moved CHANGELOG.md to `docs/CHANGELOG.md`

### Added
- `docs/QUICKSTART.md` - Step-by-step guide for updating Lambda packages
- `docs/RETROSPECTIVE.md` - Lessons learned and process improvements
- Upstream version selection documentation in README.md
- Version bump guidelines documentation
- Workflow inputs reference documentation
- Table of contents in README.md
- Test to verify `poetry-plugin-export` is installed in Docker image
- Verbose output and fallback for poetry export in build script

### Fixed
- Fixed Poetry export failure in Lambda build script by adding `poetry lock` step before export
- Fixed Poetry export failure in Docker build by adding `poetry-plugin-export` (required for Poetry 1.2+)
- Fixed sparse checkout not getting all files by adding `sparse-checkout-cone-mode: false`
- Fixed workflow using wrong branch by changing hardcoded `ref: master` to `ref: ${{ github.ref }}`
- Fixed Mermaid diagram rendering issues by removing `<br/>` tags and numbered prefixes

## [3.2.0] - 2026-01-24

### Changed
- Minor documentation and workflow improvements

## [3.1.0] - 2026-01-20

### Changed
- Downgraded AWS provider from `>= 6.0` to `>= 5.0` for compatibility with current Terraform version on production and lower environments (`versions.tf:7`)

## [3.0.0] - 2026-01-14

### Added
- Automated CI/CD pipeline for building Lambda packages (GitHub Actions)
- Docker-based build environment for Lambda compatibility
- Comprehensive build validation tests (positive and negative)
- Security scanning with pip-audit
- Architecture documentation with Mermaid diagrams (docs/ARCHITECTURE.md)
- Testing documentation (docs/TESTING.md)
- Build documentation in README.md

### Changed
- **BREAKING**: Python runtime upgraded from 3.9 to 3.13
- Lambda packages now built from upstream source automatically
- Build process creates PR for review instead of direct commits
- README.md completely rewritten with architecture overview

### Technical Decision: Python 3.13 vs 3.14

We chose **Python 3.13** over Python 3.14 for the following reasons:

| Factor | Python 3.14 | Python 3.13 | Decision |
|--------|-------------|-------------|----------|
| AWS Lambda Support | Supported | Supported | Both viable |
| Upstream Compatibility | Untested (upstream uses ~3.12) | Closer to upstream's 3.12 | **3.13 wins** |
| Release Maturity | Bleeding edge | More stable, better tested | **3.13 wins** |
| Dependency Risk | Higher risk with aws-lambda-powertools, backoff | Lower risk | **3.13 wins** |

**Rationale**: The upstream [aws-waf-security-automations](https://github.com/aws-solutions/aws-waf-security-automations)
repository specifies `python = ~3.12` in their pyproject.toml. Using Python 3.13 provides a balance between
newer features and maintaining compatibility with upstream-tested dependencies.

**Future Upgrade Path**: Once upstream updates their Python version requirement, we can safely upgrade to 3.14.

### Security
- Dependencies now scanned with pip-audit during build
- Build validation ensures no cached bytecode in packages

## [2.5.0] - Previous Release

- Provider update
- Various bug fixes

## [2.4.0] - Earlier Release

- S3 upload path whitelist updates
- KMS permissions fixes for log delivery
