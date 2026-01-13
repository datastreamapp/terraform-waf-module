# WAF Lambda CI/CD Implementation Tasks

Reference: [Issue #801](https://github.com/datastreamapp/issues/issues/801)

## Python Version Decision

**Chosen: Python 3.13** (not 3.14)

| Factor | Python 3.14 | Python 3.13 | Winner |
|--------|-------------|-------------|--------|
| AWS Lambda Support | Yes | Yes | Tie |
| Upstream Compatibility | Untested (uses ~3.12) | Closer to 3.12 | 3.13 |
| Release Maturity | Bleeding edge | More stable | 3.13 |
| Dependency Risk | Higher | Lower | 3.13 |

**Rationale**: Upstream specifies `python = ~3.12`. Python 3.13 balances newer features with compatibility.

---

## Deliverables

### Files to Create (6)

- [x] `scripts/Dockerfile.lambda-builder` - Docker build environment
- [x] `scripts/build-lambda.sh` - Build script with validation tests
- [x] `.github/workflows/build-lambda-packages.yml` - CI/CD workflow
- [x] `docs/ARCHITECTURE.md` - Mermaid architecture diagrams
- [x] `TODOLIST.md` - This file
- [x] `CHANGELOG.md` - Version history with Python rationale

### Files to Modify (3)

- [x] `lambda.log-parser.tf` - Update runtime to python3.13
- [x] `lambda.reputation-list.tf` - Update runtime to python3.13
- [x] `README.md` - Complete rewrite with Mermaid diagrams

---

## Acceptance Criteria

*Functional requirements - what the system must do*

- [ ] Workflow triggered via `workflow_dispatch`
- [ ] Clones upstream repo (pinned to specific tag)
- [ ] Builds in Docker (Amazon Linux 2023, Python 3.13)
- [ ] Builds `log_parser.zip` and `reputation_lists_parser.zip`
- [ ] Includes shared libs from `source/lib/*.py`
- [ ] Runs positive tests (zip exists, handler, size < 50MB, libs)
- [ ] Runs negative tests (no __pycache__, no .pyc, integrity, imports)
- [ ] Runs pip-audit security scan
- [ ] Creates PR (not direct commit)
- [ ] PR includes version recommendation
- [ ] Terraform runtimes updated to python3.13
- [ ] Docs include Mermaid architecture diagrams

---

## Definition of Done

*Quality gates - process verification before release*

- [ ] All deliverables created/modified
- [ ] All acceptance criteria met
- [ ] Build tests pass
- [ ] PR reviewed and approved
- [ ] `terraform plan` shows no unexpected changes
- [ ] Documentation complete
- [ ] Release tag v3.0.0 created

---

## Version History

| Version | Change |
|---------|--------|
| v2.5.0 | Current |
| v3.0.0 | Python 3.9 -> 3.13, CI/CD automation |
