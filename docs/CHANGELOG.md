# Changelog

All notable changes to the terraform-waf-module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Fixed Poetry export failure in Lambda build script by adding `poetry lock` step before export (`scripts/build-lambda.sh:91-101`)

### Added
- `docs/QUICKSTART.md` - Step-by-step guide for updating Lambda packages
- `docs/RETROSPECTIVE.md` - Lessons learned and process improvements
- `docs/TODOLIST-801.md` - Implementation task tracking
- Upstream version selection documentation in README.md
- Version bump guidelines documentation
- Workflow inputs reference documentation
- Table of contents in README.md

### Changed
- Moved CHANGELOG.md to `docs/CHANGELOG.md`
- Moved TODOLIST.md to `docs/TODOLIST-801.md`

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
