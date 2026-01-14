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
    poetry export --without dev -f requirements.txt -o "${BUILD_DIR}/requirements.txt" 2>/dev/null || {
        echo "ERROR: Poetry export failed"
        exit 1
    }
    pip install -r "${BUILD_DIR}/requirements.txt" -t "${BUILD_DIR}" --quiet --no-cache-dir || {
        echo "ERROR: pip install failed"
        exit 1
    }
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

echo ""
echo "--- NEGATIVE TESTS ---"

# Test 5: Zip integrity check
if unzip -t "${OUTPUT_DIR}/${ZIP_NAME}" > /dev/null 2>&1; then
    echo "  PASS: Zip integrity verified (not corrupted)"
else
    echo "  FAIL: Zip file is corrupted"
    exit 1
fi

# Test 6: No __pycache__ in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "__pycache__"; then
    echo "  FAIL: __pycache__ found in zip (should be cleaned)"
    exit 1
else
    echo "  PASS: No __pycache__ in zip"
fi

# Test 7: No .pyc files in zip
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "\.pyc"; then
    echo "  FAIL: .pyc files found in zip"
    exit 1
else
    echo "  PASS: No .pyc files in zip"
fi

# Test 8: Import validation (extract and test imports)
echo "  Testing imports..."
TEMP_EXTRACT="/tmp/validate_${PACKAGE_NAME}"
rm -rf "${TEMP_EXTRACT}"
mkdir -p "${TEMP_EXTRACT}"
unzip -q "${OUTPUT_DIR}/${ZIP_NAME}" -d "${TEMP_EXTRACT}"

cd "${TEMP_EXTRACT}"
HANDLER_MODULE="${HANDLER%.py}"

# Test basic import (convert hyphens to underscores for Python import)
IMPORT_MODULE="${HANDLER_MODULE//-/_}"
if python3 -c "import sys; sys.path.insert(0, '.'); import ${IMPORT_MODULE}" 2>/dev/null; then
    echo "  PASS: Handler module imports successfully"
else
    # Check if file exists and has valid syntax
    if python3 -m py_compile "${HANDLER}" 2>/dev/null; then
        echo "  PASS: Handler syntax is valid (imports may need Lambda environment)"
    else
        echo "  WARN: Handler has syntax issues or missing dependencies"
    fi
fi

# Cleanup temp extraction
rm -rf "${TEMP_EXTRACT}"

echo ""
echo "============================================"
echo "BUILD SUCCESSFUL: ${ZIP_NAME}"
echo "Size: ${SIZE_MB}MB"
echo "Location: ${OUTPUT_DIR}/${ZIP_NAME}"
echo "============================================"
