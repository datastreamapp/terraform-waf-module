#!/bin/bash
set -euo pipefail

#######################################
# System Integrity Tests
# Validates cross-file consistency, Terraform ↔ Lambda ↔ build script
# coherence, and documentation accuracy.
#
# Usage: ./scripts/test-integrity.sh [repo_root]
#######################################

REPO_ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
warn() { echo "  WARN: $1"; WARN_COUNT=$((WARN_COUNT + 1)); }

echo "============================================"
echo "System Integrity Tests"
echo "Repo: ${REPO_ROOT}"
echo "============================================"
echo ""

#######################################
# 1. File existence tests
#######################################
echo "--- FILE EXISTENCE ---"

REQUIRED_FILES=(
    "lambda/log_parser.zip"
    "lambda/reputation_lists_parser.zip"
    "data.powertools-layer.tf"
    "lambda.log-parser.tf"
    "lambda.reputation-list.tf"
    "scripts/build-lambda.sh"
    "scripts/Dockerfile.lambda-builder"
    "Makefile"
    ".github/workflows/test.yml"
    ".github/workflows/build-lambda-packages.yml"
    "docs/TESTING.md"
    "docs/DECISIONS.md"
    "docs/RETROSPECTIVE.md"
    "docs/CHANGELOG.md"
    "docs/ARCHITECTURE.md"
    "docs/QUICKSTART.md"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [[ -f "${REPO_ROOT}/${file}" ]]; then
        pass "${file} exists"
    else
        fail "${file} missing"
    fi
done

#######################################
# 2. Terraform ↔ Lambda zip consistency
#######################################
echo ""
echo "--- TERRAFORM ↔ LAMBDA ZIP CONSISTENCY ---"

# Check that zip files referenced in .tf files exist
for tf_file in "${REPO_ROOT}"/lambda.*.tf; do
    ZIP_REFS=$(grep -oE 'lambda/[a-z_]+\.zip' "$tf_file" 2>/dev/null | sort -u)
    for zip_ref in $ZIP_REFS; do
        if [[ -f "${REPO_ROOT}/${zip_ref}" ]]; then
            pass "$(basename "$tf_file") → ${zip_ref} exists"
        else
            fail "$(basename "$tf_file") → ${zip_ref} missing"
        fi
    done
done

# Check that expected zip files are not empty (> 1MB indicates real dependencies)
EXPECTED_ZIPS=("log_parser.zip" "reputation_lists_parser.zip")
for zip_name in "${EXPECTED_ZIPS[@]}"; do
    zip="${REPO_ROOT}/lambda/${zip_name}"
    [[ -f "$zip" ]] || continue
    ZIP_SIZE=$(stat -c%s "$zip" 2>/dev/null || stat -f%z "$zip")
    MIN_SIZE=$((1 * 1024 * 1024))
    if [[ $ZIP_SIZE -gt $MIN_SIZE ]]; then
        SIZE_MB=$(echo "scale=2; $ZIP_SIZE / 1024 / 1024" | bc)
        pass "${zip_name} is ${SIZE_MB}MB (> 1MB minimum)"
    else
        SIZE_KB=$(echo "scale=0; $ZIP_SIZE / 1024" | bc)
        fail "${zip_name} is only ${SIZE_KB}KB — likely missing dependencies"
    fi
done

#######################################
# 3. Handler name consistency
#######################################
echo ""
echo "--- HANDLER NAME CONSISTENCY ---"

# Build script defines handler mappings — verify they match Terraform
# Format: tf_file|expected_handler|zip_file|handler_file
HANDLER_CHECKS=(
    "lambda.log-parser.tf|log-parser.lambda_handler|log_parser.zip|log-parser.py"
    "lambda.reputation-list.tf|reputation-lists.lambda_handler|reputation_lists_parser.zip|reputation-lists.py"
)

for entry in "${HANDLER_CHECKS[@]}"; do
    IFS='|' read -r TF_FILE EXPECTED_HANDLER ZIP_FILE HANDLER_FILE <<< "$entry"

    # Verify Terraform handler matches expected
    ACTUAL_HANDLER=$(grep -oE 'handler\s*=\s*"[^"]*"' "${REPO_ROOT}/${TF_FILE}" 2>/dev/null | grep -oE '"[^"]*"' | tr -d '"')
    if [[ "$ACTUAL_HANDLER" == "$EXPECTED_HANDLER" ]]; then
        pass "${TF_FILE} handler = \"${ACTUAL_HANDLER}\""
    else
        fail "${TF_FILE} handler mismatch: expected \"${EXPECTED_HANDLER}\", got \"${ACTUAL_HANDLER}\""
    fi

    # Verify handler file exists inside zip
    ZIP_PATH="${REPO_ROOT}/lambda/${ZIP_FILE}"
    if [[ -f "$ZIP_PATH" ]]; then
        ZIP_LISTING=$(unzip -l "$ZIP_PATH" 2>/dev/null)
        if grep -qF "$HANDLER_FILE" <<< "$ZIP_LISTING"; then
            pass "${ZIP_FILE} contains ${HANDLER_FILE}"
        else
            fail "${ZIP_FILE} missing ${HANDLER_FILE}"
        fi
    fi
done

#######################################
# 4. Python runtime version consistency
#######################################
echo ""
echo "--- PYTHON RUNTIME CONSISTENCY ---"

# All of these should reference the same Python version
EXPECTED_PYTHON="3.12"

# Terraform Lambda runtime
for tf_file in "${REPO_ROOT}"/lambda.*.tf; do
    TF_RUNTIME=$(grep -oE 'runtime\s*=\s*"python[0-9.]+"' "$tf_file" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+')
    if [[ "$TF_RUNTIME" == "$EXPECTED_PYTHON" ]]; then
        pass "$(basename "$tf_file") runtime = python${TF_RUNTIME}"
    elif [[ -n "$TF_RUNTIME" ]]; then
        fail "$(basename "$tf_file") runtime = python${TF_RUNTIME} (expected ${EXPECTED_PYTHON})"
    fi
done

# Dockerfile base image
DOCKERFILE="${REPO_ROOT}/scripts/Dockerfile.lambda-builder"
if [[ -f "$DOCKERFILE" ]]; then
    DOCKER_PYTHON=$(grep -oE 'python:[0-9]+\.[0-9]+' "$DOCKERFILE" | grep -oE '[0-9]+\.[0-9]+')
    if [[ "$DOCKER_PYTHON" == "$EXPECTED_PYTHON" ]]; then
        pass "Dockerfile base image = python:${DOCKER_PYTHON}"
    else
        fail "Dockerfile base image = python:${DOCKER_PYTHON} (expected ${EXPECTED_PYTHON})"
    fi
fi

# SSM parameter path
SSM_FILE="${REPO_ROOT}/data.powertools-layer.tf"
if [[ -f "$SSM_FILE" ]]; then
    SSM_PYTHON=$(grep -oE 'python[0-9]+\.[0-9]+' "$SSM_FILE" | grep -oE '[0-9]+\.[0-9]+')
    if [[ "$SSM_PYTHON" == "$EXPECTED_PYTHON" ]]; then
        pass "SSM Powertools path = python${SSM_PYTHON}"
    else
        fail "SSM Powertools path = python${SSM_PYTHON} (expected ${EXPECTED_PYTHON})"
    fi
fi

#######################################
# 5. Upstream version consistency
#######################################
echo ""
echo "--- UPSTREAM VERSION CONSISTENCY ---"

EXPECTED_UPSTREAM="v4.1.2"

VERSION_LOCATIONS=(
    ".github/workflows/test.yml"
    ".github/workflows/build-lambda-packages.yml"
    "Makefile"
)

for file in "${VERSION_LOCATIONS[@]}"; do
    FILEPATH="${REPO_ROOT}/${file}"
    [[ -f "$FILEPATH" ]] || continue
    # Look for git clone --branch or default: lines with version tags
    if grep -qE "(--branch|default:).*${EXPECTED_UPSTREAM}" "$FILEPATH"; then
        pass "${file} references ${EXPECTED_UPSTREAM}"
    else
        FOUND=$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$FILEPATH" | head -1)
        fail "${file} references ${FOUND:-unknown} (expected ${EXPECTED_UPSTREAM})"
    fi
done

#######################################
# 6. Terraform configuration integrity
#######################################
echo ""
echo "--- TERRAFORM INTEGRITY ---"

# Check terraform validate (if terraform is available)
if command -v terraform &>/dev/null; then
    cd "${REPO_ROOT}"
    if terraform init -backend=false -no-color >/dev/null 2>&1; then
        pass "terraform init succeeds"
    else
        fail "terraform init failed"
    fi

    VALIDATE_OUTPUT=$(terraform validate -no-color 2>&1)
    if echo "$VALIDATE_OUTPUT" | grep -q "Success"; then
        pass "terraform validate succeeds"
    else
        fail "terraform validate failed: ${VALIDATE_OUTPUT}"
    fi

    FMT_OUTPUT=$(terraform fmt -check -recursive -no-color 2>&1)
    if [[ -z "$FMT_OUTPUT" ]]; then
        pass "terraform fmt check passes"
    else
        fail "terraform fmt check failed — unformatted files: ${FMT_OUTPUT}"
    fi
else
    warn "terraform not found — skipping terraform validation"
fi

#######################################
# 7. Lambda Layer configuration
#######################################
echo ""
echo "--- LAMBDA LAYER CONFIGURATION ---"

# Verify both Lambda functions reference the powertools layer
for tf_file in "${REPO_ROOT}"/lambda.*.tf; do
    TF_NAME=$(basename "$tf_file")
    if grep -q 'data.aws_ssm_parameter.powertools_layer.value' "$tf_file"; then
        pass "${TF_NAME} has powertools layer configured"
    else
        fail "${TF_NAME} missing powertools layer"
    fi
done

# Verify SSM data source exists
if [[ -f "${REPO_ROOT}/data.powertools-layer.tf" ]]; then
    if grep -q 'aws_ssm_parameter.*powertools_layer' "${REPO_ROOT}/data.powertools-layer.tf"; then
        pass "data.powertools-layer.tf defines SSM data source"
    else
        fail "data.powertools-layer.tf missing SSM data source"
    fi
fi

# Verify SSM path format
SSM_PATH=$(grep -oE '/aws/service/powertools/[^"]+' "${REPO_ROOT}/data.powertools-layer.tf" 2>/dev/null)
if [[ "$SSM_PATH" =~ ^/aws/service/powertools/python/(x86_64|arm64)/python[0-9]+\.[0-9]+/latest$ ]]; then
    pass "SSM path format valid: ${SSM_PATH}"
else
    fail "SSM path format unexpected: ${SSM_PATH}"
fi

#######################################
# 8. Build script consistency
#######################################
echo ""
echo "--- BUILD SCRIPT CONSISTENCY ---"

BUILD_SCRIPT="${REPO_ROOT}/scripts/build-lambda.sh"

# Verify build script does NOT have marker stripping (not needed with Python 3.12)
if grep -q 'sed.*python_version' "$BUILD_SCRIPT"; then
    fail "build-lambda.sh has python_version sed workaround (unnecessary with Python 3.12)"
else
    pass "build-lambda.sh has no python_version sed workaround"
fi

# Verify build script has pip install verification
if grep -q 'dist-info' "$BUILD_SCRIPT"; then
    pass "build-lambda.sh has pip install verification"
else
    fail "build-lambda.sh missing pip install verification"
fi

# Verify build script has --without-hashes
if grep -q '\-\-without-hashes' "$BUILD_SCRIPT"; then
    pass "build-lambda.sh uses --without-hashes in poetry export"
else
    warn "build-lambda.sh may produce hash warnings without --without-hashes"
fi

# Verify handler mappings match Terraform expectations
if grep -q '"log_parser".*"log-parser.py"' "$BUILD_SCRIPT"; then
    pass "build-lambda.sh log_parser handler mapping correct"
else
    fail "build-lambda.sh log_parser handler mapping mismatch"
fi

if grep -q '"reputation_lists_parser".*"reputation-lists.py"' "$BUILD_SCRIPT"; then
    pass "build-lambda.sh reputation_lists_parser handler mapping correct"
else
    fail "build-lambda.sh reputation_lists_parser handler mapping mismatch"
fi

# Verify required shared libs match what upstream provides
REQUIRED_LIBS=$(grep -oE '"(waflibv2|solution_metrics)\.py"' "$BUILD_SCRIPT" | tr -d '"' | sort)
EXPECTED_LIBS=$'solution_metrics.py\nwaflibv2.py'
if [[ "$REQUIRED_LIBS" == "$EXPECTED_LIBS" ]]; then
    pass "build-lambda.sh required libs list correct"
else
    fail "build-lambda.sh required libs mismatch"
fi

#######################################
# 9. CI/CD workflow consistency
#######################################
echo ""
echo "--- CI/CD WORKFLOW CONSISTENCY ---"

TEST_YML="${REPO_ROOT}/.github/workflows/test.yml"
BUILD_YML="${REPO_ROOT}/.github/workflows/build-lambda-packages.yml"

# test.yml should test both packages
if grep -q 'log_parser' "$TEST_YML" && grep -q 'reputation_lists_parser' "$TEST_YML"; then
    pass "test.yml tests both Lambda packages"
else
    fail "test.yml missing Lambda package tests"
fi

# build workflow should build both packages
if grep -q 'log_parser' "$BUILD_YML" && grep -q 'reputation_lists_parser' "$BUILD_YML"; then
    pass "build-lambda-packages.yml builds both packages"
else
    fail "build-lambda-packages.yml missing package builds"
fi

# test.yml and build.yml should use same Dockerfile
TEST_DOCKERFILE=$(grep -oE 'Dockerfile\.[a-z-]+' "$TEST_YML" 2>/dev/null | head -1)
BUILD_DOCKERFILE=$(grep -oE 'Dockerfile\.[a-z-]+' "$BUILD_YML" 2>/dev/null | head -1)
if [[ "$TEST_DOCKERFILE" == "$BUILD_DOCKERFILE" && -n "$TEST_DOCKERFILE" ]]; then
    pass "Both workflows use same Dockerfile: ${TEST_DOCKERFILE}"
else
    # test.yml may not reference the Dockerfile directly (uses make build)
    if grep -q 'docker build.*lambda-builder' "$TEST_YML"; then
        pass "test.yml builds lambda-builder Docker image"
    else
        warn "Could not verify Dockerfile consistency between workflows"
    fi
fi

# Verify workflows have security permissions set
if grep -q 'permissions:' "$TEST_YML"; then
    pass "test.yml has permissions configured"
else
    fail "test.yml missing permissions block"
fi

if grep -q 'permissions:' "$BUILD_YML"; then
    pass "build-lambda-packages.yml has permissions configured"
else
    fail "build-lambda-packages.yml missing permissions block"
fi

#######################################
# 10. Documentation cross-references
#######################################
echo ""
echo "--- DOCUMENTATION CROSS-REFERENCES ---"

# Verify docs reference correct upstream version
for doc in "${REPO_ROOT}/docs/CHANGELOG.md" "${REPO_ROOT}/docs/QUICKSTART.md"; do
    [[ -f "$doc" ]] || continue
    DOC_NAME=$(basename "$doc")
    if grep -q "${EXPECTED_UPSTREAM}" "$doc"; then
        pass "${DOC_NAME} references ${EXPECTED_UPSTREAM}"
    else
        warn "${DOC_NAME} may need upstream version update"
    fi
done

# Verify DECISIONS.md references the SSM path
if grep -q '/aws/service/powertools' "${REPO_ROOT}/docs/DECISIONS.md" 2>/dev/null; then
    pass "DECISIONS.md documents SSM parameter path"
else
    fail "DECISIONS.md missing SSM parameter documentation"
fi

# Verify RETROSPECTIVE.md has version dependencies table
if grep -q 'Version Dependencies' "${REPO_ROOT}/docs/RETROSPECTIVE.md" 2>/dev/null; then
    pass "RETROSPECTIVE.md has Version Dependencies table"
else
    fail "RETROSPECTIVE.md missing Version Dependencies table"
fi

# Verify TESTING.md documents current test counts
if grep -qE '25/25' "${REPO_ROOT}/docs/TESTING.md" 2>/dev/null && \
   grep -qE '24/24' "${REPO_ROOT}/docs/TESTING.md" 2>/dev/null; then
    pass "TESTING.md documents current test counts (25/25, 24/24)"
else
    warn "TESTING.md test count may be outdated"
fi

#######################################
# 11. Git hygiene
#######################################
echo ""
echo "--- GIT HYGIENE ---"

# Lambda zips should be tracked
if git -C "${REPO_ROOT}" ls-files --error-unmatch lambda/log_parser.zip >/dev/null 2>&1; then
    pass "lambda/log_parser.zip is git-tracked"
else
    fail "lambda/log_parser.zip is NOT git-tracked"
fi

if git -C "${REPO_ROOT}" ls-files --error-unmatch lambda/reputation_lists_parser.zip >/dev/null 2>&1; then
    pass "lambda/reputation_lists_parser.zip is git-tracked"
else
    fail "lambda/reputation_lists_parser.zip is NOT git-tracked"
fi

# Upstream directory should NOT be tracked
if git -C "${REPO_ROOT}" ls-files --error-unmatch upstream/ >/dev/null 2>&1; then
    fail "upstream/ is git-tracked (should be in .gitignore)"
else
    pass "upstream/ is not git-tracked"
fi

# No secrets in tracked files
SECRETS_PATTERN='(AWS_ACCESS_KEY|AWS_SECRET_KEY|AKIA[0-9A-Z]{16}|password\s*=\s*"[^"]+"|secret\s*=\s*"[^"]+")'
SECRET_HITS=$(git -C "${REPO_ROOT}" grep -lE "$SECRETS_PATTERN" -- ':!upstream/' ':!*.md' ':!*.lock' ':!scripts/test-integrity.sh' 2>/dev/null || true)
if [[ -z "$SECRET_HITS" ]]; then
    pass "No secrets detected in tracked files"
else
    fail "Possible secrets in: ${SECRET_HITS}"
fi

#######################################
# Summary
#######################################
echo ""
echo "============================================"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo "RESULTS: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings (${TOTAL} total)"
echo "============================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "STATUS: FAILED"
    exit 1
else
    echo "STATUS: PASSED"
    exit 0
fi
