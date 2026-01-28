#!/bin/bash
set -euo pipefail

#######################################
# WAF Lambda Package Builder
# Builds and validates Lambda zip packages
#######################################

# Arguments
PACKAGE_NAME="${1:?Usage: $0 <package_name> <upstream_dir> <output_dir>}"
UPSTREAM_DIR="${2:?Upstream source directory required}"
OUTPUT_DIR="${3:?Output directory required}"

# Configuration
SOURCE_DIR="${UPSTREAM_DIR}/source/${PACKAGE_NAME}"
LIB_DIR="${UPSTREAM_DIR}/source/lib"
BUILD_DIR="/tmp/build_${PACKAGE_NAME}"
ZIP_NAME="${PACKAGE_NAME}.zip"
MAX_SIZE_MB=50

# Handler mapping (upstream file -> terraform expected file)
declare -A HANDLERS=(
    ["log_parser"]="log-parser.py"
    ["reputation_lists_parser"]="reputation-lists.py"
)

# Source file mapping (what upstream calls the main handler)
declare -A SOURCE_HANDLERS=(
    ["log_parser"]="log_parser.py"
    ["reputation_lists_parser"]="reputation_lists.py"
)

HANDLER="${HANDLERS[$PACKAGE_NAME]:-}"
SOURCE_HANDLER="${SOURCE_HANDLERS[$PACKAGE_NAME]:-}"

# Required shared libs
REQUIRED_LIBS=("waflibv2.py" "solution_metrics.py")

echo "============================================"
echo "Building ${PACKAGE_NAME}"
echo "============================================"

#######################################
# STEP 1: Validate inputs
#######################################
echo "[1/8] Validating inputs..."

if [[ -z "$HANDLER" ]]; then
    echo "ERROR: Unknown package name: ${PACKAGE_NAME}"
    echo "Valid packages: ${!HANDLERS[*]}"
    exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory not found: ${SOURCE_DIR}"
    exit 1
fi

if [[ ! -d "$LIB_DIR" ]]; then
    echo "ERROR: Lib directory not found: ${LIB_DIR}"
    exit 1
fi

echo "  Package: ${PACKAGE_NAME}"
echo "  Source handler: ${SOURCE_HANDLER}"
echo "  Target handler: ${HANDLER}"
echo "  Source: ${SOURCE_DIR}"

#######################################
# STEP 2: Setup build directory
#######################################
echo "[2/8] Setting up build directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
echo "  Build dir: ${BUILD_DIR}"

#######################################
# STEP 3: Install dependencies
#######################################
echo "[3/8] Installing dependencies..."
cd "${SOURCE_DIR}"

# Check for requirements.txt (upstream uses this)
if [[ -f "requirements.txt" ]]; then
    echo "  Using requirements.txt"
    pip install -r "requirements.txt" -t "${BUILD_DIR}" --quiet --no-cache-dir || {
        echo "ERROR: pip install failed"
        exit 1
    }
# Fallback to pyproject.toml if exists
elif [[ -f "pyproject.toml" ]]; then
    echo "  Using pyproject.toml (poetry export)"
    # Verify poetry-plugin-export is available
    echo "  Checking poetry plugins..."
    poetry self show plugins 2>/dev/null || echo "  (plugin check not available)"

    # Generate lock file if missing (required for poetry export)
    if [[ ! -f "poetry.lock" ]]; then
        echo "  Generating poetry.lock file..."
        poetry lock --no-interaction 2>&1 || {
            echo "ERROR: Poetry lock failed"
            exit 1
        }
    fi
    echo "  Running poetry export..."
    poetry export --without dev --without-hashes -f requirements.txt -o "${BUILD_DIR}/requirements.txt" 2>&1 || {
        echo "ERROR: Poetry export failed"
        echo "  Trying alternative: poetry export without --without flag..."
        poetry export -f requirements.txt -o "${BUILD_DIR}/requirements.txt" --without-hashes 2>&1 || {
            echo "ERROR: Poetry export failed (both attempts)"
            exit 1
        }
    }
    pip install -r "${BUILD_DIR}/requirements.txt" -t "${BUILD_DIR}" --quiet --no-cache-dir || {
        echo "ERROR: pip install failed"
        exit 1
    }
    # Verify pip actually installed packages (not just handler files)
    INSTALLED_COUNT=$(ls -d "${BUILD_DIR}"/*.dist-info 2>/dev/null | wc -l)
    if [[ "$INSTALLED_COUNT" -eq 0 ]]; then
        echo "ERROR: pip install completed but no packages were installed"
        echo "  Check requirements.txt for environment markers or empty content"
        exit 1
    fi
    echo "  Installed ${INSTALLED_COUNT} packages"
    rm -f "${BUILD_DIR}/requirements.txt"
else
    echo "ERROR: No requirements.txt or pyproject.toml found in ${SOURCE_DIR}"
    exit 1
fi
echo "  Dependencies installed"

#######################################
# STEP 4: Copy Lambda handler files
#######################################
echo "[4/8] Copying handler files..."
cp -r "${SOURCE_DIR}"/*.py "${BUILD_DIR}/" 2>/dev/null || {
    echo "ERROR: No Python files found in ${SOURCE_DIR}"
    exit 1
}

# Rename handler to match Terraform expectation (underscore -> hyphen)
if [[ -f "${BUILD_DIR}/${SOURCE_HANDLER}" && "${SOURCE_HANDLER}" != "${HANDLER}" ]]; then
    mv "${BUILD_DIR}/${SOURCE_HANDLER}" "${BUILD_DIR}/${HANDLER}"
    echo "  Renamed ${SOURCE_HANDLER} -> ${HANDLER}"
fi
echo "  Handler files copied"

#######################################
# STEP 5: Copy shared library files
#######################################
echo "[5/8] Copying shared libraries..."
mkdir -p "${BUILD_DIR}/lib"
cp "${LIB_DIR}"/*.py "${BUILD_DIR}/lib/" || {
    echo "ERROR: Failed to copy lib files"
    exit 1
}

# Verify required libs exist
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "${BUILD_DIR}/lib/${lib}" ]]; then
        echo "ERROR: Required lib missing: ${lib}"
        exit 1
    fi
done
echo "  Shared libraries copied"

#######################################
# STEP 6: Clean up unnecessary files
#######################################
echo "[6/8] Cleaning build artifacts..."
# Remove pycache, dist-info, and other build artifacts
# Use -prune to avoid descending into deleted directories
cd "${BUILD_DIR}"
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
find . -type f -name "*.pyo" -delete 2>/dev/null || true
find . -type d -name "test" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
rm -f requirements.txt requirements_dev.txt
echo "  Cleaned up build artifacts"

#######################################
# STEP 7: Create zip file
#######################################
echo "[7/8] Creating zip archive..."
cd "${BUILD_DIR}"
zip -r -q "${OUTPUT_DIR}/${ZIP_NAME}" . || {
    echo "ERROR: Failed to create zip"
    exit 1
}
echo "  Zip created: ${OUTPUT_DIR}/${ZIP_NAME}"

#######################################
# STEP 8: Comprehensive validation
#######################################
echo "[8/8] Running validation tests..."
echo ""
echo "--- POSITIVE TESTS ---"

# Test 1: Zip file exists and is not empty
if [[ -f "${OUTPUT_DIR}/${ZIP_NAME}" && -s "${OUTPUT_DIR}/${ZIP_NAME}" ]]; then
    echo "  PASS: Zip file exists and is not empty"
else
    echo "  FAIL: Zip file missing or empty"
    exit 1
fi

# Test 2: Handler file exists in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -F "${HANDLER}" | grep -qv "/"; then
    echo "  PASS: Handler ${HANDLER} found in zip"
else
    echo "  FAIL: Handler ${HANDLER} not found in zip"
    echo "  Root-level .py files:"
    unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -E "\.py$" | grep -v "/" | head -10
    exit 1
fi

# Test 3: Size check (< 50MB for Lambda)
ZIP_SIZE=$(stat -c%s "${OUTPUT_DIR}/${ZIP_NAME}" 2>/dev/null || stat -f%z "${OUTPUT_DIR}/${ZIP_NAME}")
MAX_SIZE_BYTES=$((MAX_SIZE_MB * 1024 * 1024))
if [[ $ZIP_SIZE -lt $MAX_SIZE_BYTES ]]; then
    SIZE_MB=$(echo "scale=2; $ZIP_SIZE / 1024 / 1024" | bc)
    echo "  PASS: Size ${SIZE_MB}MB (< ${MAX_SIZE_MB}MB limit)"
else
    echo "  FAIL: Size ${ZIP_SIZE} bytes exceeds ${MAX_SIZE_MB}MB limit"
    exit 1
fi

# Test 4: Required shared libs in zip
for lib in "${REQUIRED_LIBS[@]}"; do
    if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" 2>/dev/null | grep "lib/${lib}" >/dev/null 2>&1; then
        echo "  PASS: Required lib/${lib} found"
    else
        echo "  FAIL: Required lib/${lib} missing"
        echo "  Lib files in zip:"
        unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep "lib/" | head -10
        exit 1
    fi
done

# Test 5: All upstream dependencies present in zip
# Parse non-dev dependencies from pyproject.toml and verify they were installed.
# Translates PyPI names to Python import names (hyphens→underscores, case-lowered).
echo "  Checking upstream dependencies..."
UPSTREAM_DEPS=()
if [[ -f "${SOURCE_DIR}/pyproject.toml" ]]; then
    IN_DEPS=false
    while IFS= read -r line; do
        if [[ "$line" == "[tool.poetry.dependencies]" ]]; then
            IN_DEPS=true
            continue
        fi
        if [[ "$IN_DEPS" == true && "$line" =~ ^\[.* ]]; then
            break
        fi
        if [[ "$IN_DEPS" == true && "$line" =~ ^([a-zA-Z0-9_-]+)\ *=.* ]]; then
            DEP_NAME="${BASH_REMATCH[1]}"
            # Skip python itself
            [[ "$DEP_NAME" == "python" ]] && continue
            UPSTREAM_DEPS+=("$DEP_NAME")
        fi
    done < "${SOURCE_DIR}/pyproject.toml"
fi

ZIP_LISTING="${OUTPUT_DIR}/${PACKAGE_NAME}_listing.txt"
unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" > "${ZIP_LISTING}" 2>/dev/null
for dep in "${UPSTREAM_DEPS[@]}"; do
    # Normalize: PyPI uses hyphens, Python/pip uses underscores in dist-info
    DEP_NORMALIZED=$(echo "$dep" | tr '[:upper:]-' '[:lower:]_')
    if grep -qi "${DEP_NORMALIZED}" "${ZIP_LISTING}"; then
        echo "  PASS: Dependency '${dep}' found in zip"
    else
        echo "  FAIL: Dependency '${dep}' missing from zip"
        echo "        Expected from upstream pyproject.toml"
        rm -f "${ZIP_LISTING}"
        exit 1
    fi
done
rm -f "${ZIP_LISTING}"

# Test 6: Minimum size sanity check (zip should be > 1MB with real dependencies)
MIN_SIZE_BYTES=$((1 * 1024 * 1024))
if [[ $ZIP_SIZE -gt $MIN_SIZE_BYTES ]]; then
    echo "  PASS: Size ${SIZE_MB}MB exceeds 1MB minimum (dependencies present)"
else
    echo "  FAIL: Size ${SIZE_MB}MB is suspiciously small (<1MB) — dependencies may be missing"
    exit 1
fi

echo ""
echo "--- NEGATIVE TESTS ---"

# Test 7: Zip integrity check
if unzip -t "${OUTPUT_DIR}/${ZIP_NAME}" > /dev/null 2>&1; then
    echo "  PASS: Zip integrity verified (not corrupted)"
else
    echo "  FAIL: Zip file is corrupted"
    exit 1
fi

# Test 8: No __pycache__ in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "__pycache__"; then
    echo "  FAIL: __pycache__ found in zip (should be cleaned)"
    exit 1
else
    echo "  PASS: No __pycache__ in zip"
fi

# Test 9: No .pyc files in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "\.pyc"; then
    echo "  FAIL: .pyc files found in zip"
    exit 1
else
    echo "  PASS: No .pyc files in zip"
fi

# Test 10: No .dist-info directories in zip (should be cleaned)
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "\.dist-info/"; then
    echo "  FAIL: .dist-info directories found in zip (should be cleaned)"
    exit 1
else
    echo "  PASS: No .dist-info in zip"
fi

# Test 11: No test directories in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -qE "(^|\s)(tests?)/"; then
    echo "  FAIL: test directories found in zip (should be cleaned)"
    exit 1
else
    echo "  PASS: No test directories in zip"
fi

# Test 12: No .egg-info directories in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "\.egg-info/"; then
    echo "  FAIL: .egg-info directories found in zip (should be cleaned)"
    exit 1
else
    echo "  PASS: No .egg-info in zip"
fi

# Test 13: No dev dependencies leaked into zip
DEV_PACKAGES=("pytest" "moto" "pytest_mock" "pytest_runner" "pytest_cov" "pytest_env" "freezegun")
for dev_pkg in "${DEV_PACKAGES[@]}"; do
    if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -qi "^.*${dev_pkg}.*\.py"; then
        echo "  FAIL: Dev dependency '${dev_pkg}' found in zip (should not be bundled)"
        exit 1
    fi
done
echo "  PASS: No dev dependencies in zip"

# Test 14: No source handler with wrong name (underscore version should be renamed to hyphen)
if [[ -n "$SOURCE_HANDLER" && "$SOURCE_HANDLER" != "$HANDLER" ]]; then
    if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -qF "$SOURCE_HANDLER"; then
        echo "  FAIL: Original handler '${SOURCE_HANDLER}' still in zip (should be renamed to '${HANDLER}')"
        exit 1
    else
        echo "  PASS: Handler correctly renamed from '${SOURCE_HANDLER}' to '${HANDLER}'"
    fi
fi

# Test 15: lib/ directory has __init__.py or all required modules are importable
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "lib/"; then
    LIB_PY_COUNT=$(unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -c "lib/.*\.py$" || true)
    if [[ "$LIB_PY_COUNT" -gt 0 ]]; then
        echo "  PASS: lib/ directory contains ${LIB_PY_COUNT} Python files"
    else
        echo "  FAIL: lib/ directory exists but contains no Python files"
        exit 1
    fi
fi

# Test 16: Import validation (extract and test imports)
echo ""
echo "--- IMPORT TESTS ---"
echo "  Testing imports..."
TEMP_EXTRACT="/tmp/validate_${PACKAGE_NAME}"
rm -rf "${TEMP_EXTRACT}"
mkdir -p "${TEMP_EXTRACT}"
unzip -q "${OUTPUT_DIR}/${ZIP_NAME}" -d "${TEMP_EXTRACT}"

cd "${TEMP_EXTRACT}"
HANDLER_MODULE="${HANDLER%.py}"

# Known packages provided by Lambda runtime (WARN only — not available during build)
RUNTIME_PACKAGES=("boto3" "botocore")

# If handler has hyphens, copy it with underscores for import test
IMPORT_MODULE="${HANDLER_MODULE//-/_}"
if [[ "$HANDLER_MODULE" != "$IMPORT_MODULE" && -f "${HANDLER}" ]]; then
    cp "${HANDLER}" "${IMPORT_MODULE}.py"
fi
if IMPORT_ERROR=$(python3 -c "import sys; sys.path.insert(0, '.'); import ${IMPORT_MODULE}" 2>&1); then
    IMPORT_EXIT=0
else
    IMPORT_EXIT=1
fi
# Clean up copy
if [[ "$HANDLER_MODULE" != "$IMPORT_MODULE" ]]; then
    rm -f "${IMPORT_MODULE}.py" 2>/dev/null || true
fi

if [[ $IMPORT_EXIT -eq 0 ]]; then
    echo "  PASS: Handler module imports successfully"
else
    # Check if this is a runtime environment error (e.g., missing AWS region, credentials)
    # These errors mean the code imported fine but hit AWS SDK calls at module level
    if grep -qE "NoRegionError|NoCredentialError|EndpointConnectionError|botocore\.exceptions" <<< "$IMPORT_ERROR"; then
        echo "  PASS: Handler imports resolve (runtime environment error expected during build)"
    # Check for missing module errors
    elif grep -q "No module named" <<< "$IMPORT_ERROR"; then
        MISSING_MODULE=$(grep -oP "No module named '\K[^']+" <<< "$IMPORT_ERROR") || \
        MISSING_MODULE=$(grep -oE "No module named '[^']+'$" <<< "$IMPORT_ERROR" | sed "s/No module named '//;s/'//")

        if [[ -n "$MISSING_MODULE" ]]; then
            # Check against known runtime packages
            IS_RUNTIME=false
            for pkg in "${RUNTIME_PACKAGES[@]}"; do
                if [[ "$MISSING_MODULE" == "$pkg" || "$MISSING_MODULE" == "$pkg".* ]]; then
                    IS_RUNTIME=true
                    break
                fi
            done

            if [[ "$IS_RUNTIME" == true ]]; then
                echo "  WARN: '${MISSING_MODULE}' is provided by Lambda runtime (not available during build)"
            else
                echo "  FAIL: Handler has unresolved import '${MISSING_MODULE}'"
                echo "        This dependency must be installed in the zip package."
                echo "        Check pyproject.toml and the Poetry export step."
                echo "        Error: ${IMPORT_ERROR}"
                rm -rf "${TEMP_EXTRACT}"
                exit 1
            fi
        fi
    else
        echo "  FAIL: Handler import failed with unexpected error"
        echo "        Error: ${IMPORT_ERROR}"
        rm -rf "${TEMP_EXTRACT}"
        exit 1
    fi
fi

# Test 17: Verify key upstream dependencies are importable (not just present in zip)
echo "  Testing dependency imports..."
KEY_IMPORTS=("backoff" "jinja2" "aws_xray_sdk" "urllib3")
# Add package-specific imports
if [[ "$PACKAGE_NAME" == "log_parser" ]]; then
    KEY_IMPORTS+=("pyparsing")
fi
for dep_import in "${KEY_IMPORTS[@]}"; do
    if python3 -c "import sys; sys.path.insert(0, '.'); import ${dep_import}" 2>/dev/null; then
        echo "  PASS: import ${dep_import} succeeds"
    else
        echo "  FAIL: import ${dep_import} failed — dependency may be corrupt or incomplete"
        rm -rf "${TEMP_EXTRACT}"
        exit 1
    fi
done

# Test 18: Verify shared lib files are importable
echo "  Testing shared lib imports..."
for lib in "${REQUIRED_LIBS[@]}"; do
    LIB_MODULE="${lib%.py}"
    if python3 -c "import sys; sys.path.insert(0, '.'); from lib import ${LIB_MODULE}" 2>/dev/null; then
        echo "  PASS: from lib import ${LIB_MODULE} succeeds"
    else
        # Shared libs may import boto3 at module level — check for runtime errors
        if LIB_ERR=$(python3 -c "import sys; sys.path.insert(0, '.'); from lib import ${LIB_MODULE}" 2>&1); then
            : # should not reach here since the if above already failed
        fi
        if grep -qE "NoRegionError|NoCredentialError|EndpointConnectionError|botocore\.exceptions" <<< "$LIB_ERR"; then
            echo "  PASS: lib/${LIB_MODULE} imports resolve (runtime environment error expected)"
        elif grep -q "No module named" <<< "$LIB_ERR"; then
            LIB_MISSING=$(grep -oE "No module named '[^']+'$" <<< "$LIB_ERR" | sed "s/No module named '//;s/'//" | head -1)
            IS_RUNTIME=false
            for pkg in "${RUNTIME_PACKAGES[@]}"; do
                if [[ "$LIB_MISSING" == "$pkg" || "$LIB_MISSING" == "$pkg".* ]]; then
                    IS_RUNTIME=true
                    break
                fi
            done
            if [[ "$IS_RUNTIME" == true ]]; then
                echo "  WARN: lib/${LIB_MODULE} needs '${LIB_MISSING}' (Lambda runtime)"
            else
                echo "  FAIL: lib/${LIB_MODULE} has unresolved import '${LIB_MISSING}'"
                rm -rf "${TEMP_EXTRACT}"
                exit 1
            fi
        else
            echo "  FAIL: lib/${LIB_MODULE} import failed unexpectedly"
            echo "        Error: ${LIB_ERR}"
            rm -rf "${TEMP_EXTRACT}"
            exit 1
        fi
    fi
done

# Cleanup temp extraction
rm -rf "${TEMP_EXTRACT}"

echo ""
echo "============================================"
echo "BUILD SUCCESSFUL: ${ZIP_NAME}"
echo "Size: ${SIZE_MB}MB"
echo "Location: ${OUTPUT_DIR}/${ZIP_NAME}"
echo "============================================"
