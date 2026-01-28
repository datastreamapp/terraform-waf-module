# GitHub Actions Workflows

This directory contains CI/CD automation for the terraform-waf-module.

## Workflows Overview

| Workflow | File | Trigger | Purpose |
|----------|------|---------|---------|
| Test | `test.yml` | PR/Push to master | Validate Terraform and Lambda builds |
| Build Lambda Packages | `build-lambda-packages.yml` | Manual | Rebuild Lambda zips from upstream |

---

## test.yml - CI Test Pipeline

Runs automatically on every pull request and push to master. Validates Terraform configuration and tests Lambda build process.

### Trigger Configuration (Lines 3-7)

```yaml
on:
  push:
    branches: [master]
  pull_request:
    branches: [master]
```

| Event | When It Runs |
|-------|--------------|
| `push` | Direct push to master (after merge) |
| `pull_request` | When PR is created or updated targeting master |

### Permissions (Lines 9-11)

```yaml
permissions:
  contents: read
```

**Why**: Restricts workflow to read-only access. Required by security check `CKV2_GHA_1` (checkov). Follows principle of least privilege.

### Job: terraform (Lines 14-51)

Validates Terraform configuration and runs security scans.

#### Step: Checkout (Lines 18-19)

```yaml
- name: Checkout
  uses: actions/checkout@v4
```

Clones the repository into the runner.

#### Step: Setup Terraform (Lines 21-22)

```yaml
- name: Setup Terraform
  uses: hashicorp/setup-terraform@v3
```

Installs latest Terraform CLI using HashiCorp's official action.

#### Step: Terraform Init (Lines 24-25)

```yaml
- name: Terraform Init
  run: terraform init -backend=false
```

Initializes Terraform providers without configuring a backend. The `-backend=false` flag:
- Skips backend configuration (no state storage needed for validation)
- Doesn't require AWS credentials
- Only downloads required providers

#### Step: Terraform Validate (Lines 27-28)

```yaml
- name: Terraform Validate
  run: terraform validate
```

Validates Terraform syntax and configuration. Checks:
- HCL syntax is valid
- Required arguments are provided
- Resource references are valid
- Variable types match

**Note**: May show deprecation warning for `data.aws_region.current.name` - this is expected and harmless.

#### Step: Terraform Format Check (Lines 30-31)

```yaml
- name: Terraform Format Check
  run: terraform fmt -check -recursive
```

Verifies all `.tf` files are properly formatted. Flags:
- `-check` - Exit with error if files need formatting (don't modify)
- `-recursive` - Check all subdirectories

#### Step: Setup tflint (Lines 33-34)

```yaml
- name: Setup tflint
  uses: terraform-linters/setup-tflint@v4
```

Installs tflint linter using the official action.

#### Step: Run tflint (Lines 36-39)

```yaml
- name: Run tflint
  run: |
    tflint --init
    tflint
```

Runs Terraform linter. Two commands:
1. `tflint --init` - Download and install plugins (AWS ruleset)
2. `tflint` - Run linting checks

**Note**: As of tflint v0.47, the old syntax `tflint .` is deprecated. Use `tflint` without arguments.

Checks for:
- Missing variable types
- Unused declarations
- AWS-specific best practices
- Deprecated syntax

#### Step: Run tfsec (Lines 41-44)

```yaml
- name: Run tfsec
  uses: aquasecurity/tfsec-action@v1.0.0
  with:
    additional_args: --minimum-severity HIGH
```

Runs Terraform security scanner. Configuration:
- `--minimum-severity HIGH` - Only fail on HIGH/CRITICAL issues
- LOW/MEDIUM issues are reported but don't fail the build

Checks for:
- Hardcoded secrets
- Insecure configurations
- Missing encryption
- AWS security best practices

**Accepted LOW issues** (documented in TODOLIST.md):
- CloudWatch logs not KMS encrypted (uses default encryption)
- Lambda not in VPC (not required for this use case)

#### Step: Run checkov (Lines 46-51)

```yaml
- name: Run checkov
  uses: bridgecrewio/checkov-action@v12
  with:
    directory: .
    quiet: true
    soft_fail: true
```

Runs compliance scanner. Configuration:
- `directory: .` - Scan current directory
- `quiet: true` - Reduced output
- `soft_fail: true` - Don't fail build on findings (informational only)

Checks for:
- CIS benchmark compliance
- AWS Well-Architected Framework
- SOC2 controls

---

### Job: lambda (Lines 53-91)

Tests Lambda build process using Docker.

#### Step: Clone upstream source (Lines 60-63)

```yaml
- name: Clone upstream source
  run: |
    git clone --depth 1 --branch v4.1.2 \
      https://github.com/aws-solutions/aws-waf-security-automations.git upstream
```

Clones AWS's official WAF security automations repository. Options:
- `--depth 1` - Shallow clone (only latest commit, faster)
- `--branch v4.1.2` - Pin to specific version for reproducibility

**Why v4.1.2?** This matches the upstream version our module is synced with (v4.0.0 release). See [upstream CHANGELOG](https://github.com/aws-solutions/aws-waf-security-automations/blob/main/CHANGELOG.md).

#### Step: Build Docker image (Lines 65-66)

```yaml
- name: Build Docker image
  run: docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/
```

Builds the Lambda builder Docker image:
- `-t lambda-builder` - Tag image as "lambda-builder"
- `-f scripts/Dockerfile.lambda-builder` - Use our Dockerfile
- `scripts/` - Build context directory

#### Step: Test log_parser build (Lines 68-73)

```yaml
- name: Test log_parser build
  run: |
    docker run --rm \
      -v ${{ github.workspace }}/upstream:/upstream:ro \
      -v ${{ github.workspace }}/lambda:/output \
      lambda-builder log_parser /upstream /output
```

Builds log_parser Lambda package. Docker run options:
- `--rm` - Remove container after execution
- `-v .../upstream:/upstream:ro` - Mount upstream as read-only
- `-v .../lambda:/output` - Mount lambda directory for output

Arguments to build script:
1. `log_parser` - Package name
2. `/upstream` - Source directory (mounted)
3. `/output` - Output directory (mounted)

This runs 9 validation tests (see scripts/README.md).

#### Step: Test reputation_lists_parser build (Lines 75-80)

```yaml
- name: Test reputation_lists_parser build
  run: |
    docker run --rm \
      -v ${{ github.workspace }}/upstream:/upstream:ro \
      -v ${{ github.workspace }}/lambda:/output \
      lambda-builder reputation_lists_parser /upstream /output
```

Same process for reputation_lists_parser package.

#### Step: Summary (Lines 82-91)

```yaml
- name: Summary
  run: |
    echo "## Lambda Build Results" >> $GITHUB_STEP_SUMMARY
    echo "" >> $GITHUB_STEP_SUMMARY
    echo "| Package | Size | Status |" >> $GITHUB_STEP_SUMMARY
    echo "|---------|------|--------|" >> $GITHUB_STEP_SUMMARY
    for zip in lambda/*.zip; do
      size=$(ls -lh "$zip" | awk '{print $5}')
      echo "| $(basename $zip) | $size | ✅ PASS |" >> $GITHUB_STEP_SUMMARY
    done
```

Writes build results to GitHub's job summary (visible in Actions UI). Shows:
- Package name
- File size
- Pass/fail status

---

## build-lambda-packages.yml - Manual Lambda Build

Manually triggered workflow to rebuild Lambda packages from upstream.

### Trigger Configuration (Lines 3-20)

```yaml
on:
  workflow_dispatch:
    inputs:
      upstream_ref:
        description: 'Upstream repo tag (e.g., v4.1.2)'
        default: 'v4.1.2'
        required: true
        type: string
      version_bump:
        description: 'Version bump type for this release'
        required: true
        type: choice
        options:
          - 'none'
          - 'patch'
          - 'minor'
          - 'major'
        default: 'none'
```

**workflow_dispatch**: Manual trigger only (via GitHub UI or CLI).

**Inputs**:

| Input | Type | Description |
|-------|------|-------------|
| `upstream_ref` | string | Git tag from upstream repo to build from |
| `version_bump` | choice | How to bump version (none/patch/minor/major) |

### Permissions (Lines 22-24)

```yaml
permissions:
  contents: write
  pull-requests: write
```

Requires write access because this workflow:
- Creates commits with new Lambda packages
- Opens pull requests automatically

### Environment Variables (Lines 26-28)

```yaml
env:
  UPSTREAM_REPO: aws-solutions/aws-waf-security-automations
  PYTHON_VERSION: '3.13'
```

Centralized configuration for the workflow.

### Job Outputs (Lines 34-36)

```yaml
outputs:
  current_version: ${{ steps.version.outputs.current }}
  next_version: ${{ steps.version.outputs.next }}
```

Exposes version information for use in PR body.

### Step: Calculate version (Lines 45-71)

```yaml
- name: Calculate version
  id: version
  run: |
    CURRENT=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    echo "current=${CURRENT}" >> $GITHUB_OUTPUT

    VERSION=${CURRENT#v}
    IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"

    case "${{ inputs.version_bump }}" in
      major) NEXT="v$((MAJOR + 1)).0.0" ;;
      minor) NEXT="v${MAJOR}.$((MINOR + 1)).0" ;;
      patch) NEXT="v${MAJOR}.${MINOR}.$((PATCH + 1))" ;;
      none)  NEXT="none" ;;
    esac

    echo "next=${NEXT}" >> $GITHUB_OUTPUT
```

Semantic versioning calculation:
1. Gets current version from latest git tag
2. Parses into MAJOR.MINOR.PATCH
3. Calculates next version based on bump type
4. Outputs both for use in PR

Example:
- Current: `v2.5.0`
- Bump: `major`
- Next: `v3.0.0`

### Step: Checkout upstream (Lines 73-82)

```yaml
- name: Checkout upstream WAF repo
  uses: actions/checkout@v4
  with:
    repository: ${{ env.UPSTREAM_REPO }}
    ref: ${{ inputs.upstream_ref }}
    path: upstream
    sparse-checkout: |
      source/log_parser
      source/reputation_lists_parser
      source/lib
```

Clones only needed directories from upstream (sparse checkout):
- `source/log_parser/` - Log parser Lambda source
- `source/reputation_lists_parser/` - Reputation parser source
- `source/lib/` - Shared libraries

This is faster than full clone.

### Step: Verify upstream checkout (Lines 84-93)

```yaml
- name: Verify upstream checkout
  run: |
    for dir in log_parser reputation_lists_parser lib; do
      if [[ ! -d "upstream/source/${dir}" ]]; then
        echo "ERROR: upstream/source/${dir} not found"
        exit 1
      fi
    done
```

Validates all required directories exist before building.

### Step: Build Docker image (Lines 98-100)

```yaml
- name: Build Docker image
  run: |
    docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/
```

Same as test.yml - builds the Lambda builder image.

### Steps: Build Lambda packages (Lines 102-116)

```yaml
- name: Build log_parser.zip
  run: |
    docker run --rm \
      -v ${{ github.workspace }}/upstream:/upstream:ro \
      -v ${{ github.workspace }}/lambda:/output \
      lambda-builder log_parser /upstream /output
```

Builds each Lambda package using Docker.

### Step: Security scan (Lines 118-130)

```yaml
- name: Security scan - pip-audit
  continue-on-error: true
  run: |
    pip install pip-audit poetry
    cd upstream/source/log_parser
    poetry export --without dev -f requirements.txt -o /tmp/log_parser_reqs.txt
    pip-audit -r /tmp/log_parser_reqs.txt --desc || true
```

Optional security scan of dependencies:
- `continue-on-error: true` - Don't fail build on vulnerabilities
- Uses pip-audit to check for known CVEs
- Reports issues but doesn't block (informational)

### Step: Final validation summary (Lines 132-146)

```yaml
- name: Final validation summary
  run: |
    echo "Packages built:"
    ls -lh lambda/*.zip
    echo "Zip contents preview:"
    for zip in lambda/*.zip; do
      unzip -l "$zip" | head -20
    done
```

Outputs build summary showing:
- Package sizes
- First 20 files in each zip

### Step: Create Pull Request (Lines 148-206)

```yaml
- name: Create Pull Request
  uses: peter-evans/create-pull-request@v6
  with:
    token: ${{ secrets.GITHUB_TOKEN }}
    commit-message: |
      feat: rebuild WAF Lambda packages from upstream ${{ inputs.upstream_ref }}
    branch: automated/lambda-build-${{ github.run_number }}
    delete-branch: true
    title: "feat: Update WAF Lambda packages from upstream ${{ inputs.upstream_ref }}"
    body: |
      ## Automated Lambda Package Build
      ...
```

Automatically creates a PR with:
- New Lambda zip files committed
- Detailed PR body with build info
- Version recommendation
- Verification checklist
- Instructions for creating release tag

PR features:
- `delete-branch: true` - Clean up branch after merge
- Labels: `automated`, `lambda`, `security`
- Includes version info and next steps

---

## Workflow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         test.yml                                 │
│                   (Automatic on PR/Push)                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────────────┐     ┌─────────────────────┐          │
│   │  Job: terraform     │     │   Job: lambda       │          │
│   │  (runs in parallel) │     │  (runs in parallel) │          │
│   ├─────────────────────┤     ├─────────────────────┤          │
│   │ 1. Checkout         │     │ 1. Checkout         │          │
│   │ 2. Setup Terraform  │     │ 2. Clone upstream   │          │
│   │ 3. terraform init   │     │ 3. Build Docker     │          │
│   │ 4. terraform valid  │     │ 4. Build log_parser │          │
│   │ 5. terraform fmt    │     │ 5. Build rep_lists  │          │
│   │ 6. Setup tflint     │     │ 6. Summary          │          │
│   │ 7. Run tflint       │     └─────────────────────┘          │
│   │ 8. Run tfsec        │                                       │
│   │ 9. Run checkov      │                                       │
│   └─────────────────────┘                                       │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│               build-lambda-packages.yml                          │
│                    (Manual Trigger)                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   Inputs: upstream_ref, version_bump                             │
│                    │                                             │
│                    ▼                                             │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  1. Checkout terraform-waf-module                        │   │
│   │  2. Calculate version (from git tags)                    │   │
│   │  3. Checkout upstream (sparse)                           │   │
│   │  4. Verify directories exist                             │   │
│   │  5. Build Docker image                                   │   │
│   │  6. Build log_parser.zip (includes tests)                │   │
│   │  7. Build reputation_lists_parser.zip (includes tests)   │   │
│   │  8. Security scan (pip-audit)                            │   │
│   │  9. Validation summary                                   │   │
│   │ 10. Commit zips to lambda/                               │   │
│   │ 11. Create Pull Request                                  │   │
│   └─────────────────────────────────────────────────────────┘   │
│                    │                                             │
│                    ▼                                             │
│   Output: PR with new Lambda packages                            │
│           (Human reviews and approves to merge)                  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## How to Use

### Run Tests (Automatic)

Tests run automatically when you:
- Create a PR targeting master
- Push to master

### Trigger Lambda Rebuild (Manual)

**Via GitHub UI:**
1. Go to Actions tab
2. Select "Build WAF Lambda Packages"
3. Click "Run workflow"
4. Fill in inputs:
   - `upstream_ref`: Tag to build from (e.g., `v4.1.2`)
   - `version_bump`: Version increment type
5. Click "Run workflow"

**Via CLI:**
```bash
gh workflow run "Build WAF Lambda Packages" \
  -f upstream_ref=v4.1.2 \
  -f version_bump=patch
```

### After Lambda Build PR Merges

If you requested a version bump:
```bash
git checkout master && git pull
git tag -a "v3.0.0" -m "Release v3.0.0"
git push origin "v3.0.0"
```

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| tflint fails with "Command line arguments" error | tflint v0.47+ syntax change | Use `tflint` not `tflint .` |
| tfsec fails on LOW severity | `additional_args` not set | Add `--minimum-severity HIGH` |
| Lambda build fails | Upstream structure changed | Check upstream repo for changes |
| PR creation fails | Missing permissions | Ensure `contents: write` and `pull-requests: write` |
| Sparse checkout fails | Directory doesn't exist | Verify upstream ref has required directories |
| Poetry export failed | Poetry 1.2+ requires plugin | Add `poetry-plugin-export` to Dockerfile |
| Poetry export failed (no lock) | Missing poetry.lock file | Add `poetry lock --no-interaction` before export |
| Sparse checkout missing files | Cone mode enabled by default | Add `sparse-checkout-cone-mode: false` |
| Workflow uses wrong branch | Hardcoded `ref: master` | Use `ref: ${{ github.ref }}` for current branch |
| PR creation permission denied | GitHub Actions setting disabled | Enable "Allow GitHub Actions to create pull requests" in repo settings |
