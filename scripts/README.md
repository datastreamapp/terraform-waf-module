# Scripts Directory

This directory contains the build infrastructure for creating Lambda deployment packages.

## Files

| File | Purpose |
|------|---------|
| `Dockerfile.lambda-builder` | Docker image definition for build environment |
| `build-lambda.sh` | Build script with validation tests |

---

## Dockerfile.lambda-builder

Defines the Docker container used to build Lambda packages. Uses the official AWS Lambda Python image to ensure binary compatibility.

### Code Breakdown

```dockerfile
FROM public.ecr.aws/lambda/python:3.13
```
**Line 1**: Base image from AWS ECR - the official Lambda Python 3.13 runtime image. This ensures all compiled dependencies (like C extensions) are compatible with the Lambda execution environment.

```dockerfile
RUN dnf install -y zip unzip bc && \
    pip install --upgrade pip && \
    pip install poetry pip-audit
```
**Lines 4-6**: Install build tools:
- `zip` / `unzip` - Creating and inspecting Lambda packages
- `bc` - Calculator for size calculations in tests
- `poetry` - Dependency management (if upstream uses pyproject.toml)
- `pip-audit` - Security vulnerability scanning (optional)

```dockerfile
WORKDIR /build
```
**Line 8**: Set working directory inside container.

```dockerfile
COPY build-lambda.sh /build/
RUN chmod +x /build/build-lambda.sh
```
**Lines 10-11**: Copy and make executable the build script.

```dockerfile
ENTRYPOINT ["/build/build-lambda.sh"]
```
**Line 13**: Set entrypoint so container runs the build script automatically.

### Usage

```bash
# Build the Docker image
docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Run a build
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder log_parser /upstream /output
```

---

## build-lambda.sh

The main build script that creates Lambda deployment packages with comprehensive validation.

### Arguments

```bash
./build-lambda.sh <package_name> <upstream_dir> <output_dir>
```

| Argument | Description | Example |
|----------|-------------|---------|
| `package_name` | Which Lambda to build | `log_parser` or `reputation_lists_parser` |
| `upstream_dir` | Path to cloned upstream repo | `/upstream` |
| `output_dir` | Where to write the zip | `/output` |

### Code Breakdown by Section

#### Section 1: Configuration (Lines 9-37)

```bash
PACKAGE_NAME="${1:?Usage: $0 <package_name> <upstream_dir> <output_dir>}"
UPSTREAM_DIR="${2:?Upstream source directory required}"
OUTPUT_DIR="${3:?Output directory required}"
```
**Lines 10-12**: Parse required arguments with error messages if missing.

```bash
SOURCE_DIR="${UPSTREAM_DIR}/source/${PACKAGE_NAME}"
LIB_DIR="${UPSTREAM_DIR}/source/lib"
BUILD_DIR="/tmp/build_${PACKAGE_NAME}"
ZIP_NAME="${PACKAGE_NAME}.zip"
MAX_SIZE_MB=50
```
**Lines 15-19**: Define paths. Upstream repo structure has `source/<package>/` and shared `source/lib/`.

```bash
declare -A HANDLERS=(
    ["log_parser"]="log-parser.py"
    ["reputation_lists_parser"]="reputation-lists.py"
)
```
**Lines 22-25**: Handler mapping - Terraform expects hyphenated names but upstream uses underscores.

```bash
declare -A SOURCE_HANDLERS=(
    ["log_parser"]="log_parser.py"
    ["reputation_lists_parser"]="reputation_lists.py"
)
```
**Lines 28-31**: Source file mapping for renaming during build.

```bash
REQUIRED_LIBS=("waflibv2.py" "solution_metrics.py")
```
**Line 37**: Shared libraries that must be included in every package.

---

#### Section 2: Input Validation (Lines 43-68)

```bash
if [[ -z "$HANDLER" ]]; then
    echo "ERROR: Unknown package name: ${PACKAGE_NAME}"
    exit 1
fi
```
**Lines 48-52**: Verify package name is valid (must be in HANDLERS array).

```bash
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Source directory not found: ${SOURCE_DIR}"
    exit 1
fi
```
**Lines 54-62**: Verify source directories exist before proceeding.

---

#### Section 3: Build Directory Setup (Lines 69-75)

```bash
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
```
**Lines 73-74**: Clean slate - remove any previous build artifacts and create fresh directory.

---

#### Section 4: Dependency Installation (Lines 77-106)

```bash
if [[ -f "requirements.txt" ]]; then
    pip install -r "requirements.txt" -t "${BUILD_DIR}" --quiet --no-cache-dir
elif [[ -f "pyproject.toml" ]]; then
    poetry export --without dev -f requirements.txt -o "${BUILD_DIR}/requirements.txt"
    pip install -r "${BUILD_DIR}/requirements.txt" -t "${BUILD_DIR}"
fi
```
**Lines 84-105**: Install dependencies. Handles two formats:
1. **requirements.txt** (primary) - Direct pip install
2. **pyproject.toml** (fallback) - Export via Poetry first

Key flags:
- `-t "${BUILD_DIR}"` - Install into build directory (not system)
- `--quiet` - Reduce output noise
- `--no-cache-dir` - Don't use pip cache (ensures fresh downloads)

---

#### Section 5: Copy Handler Files (Lines 108-122)

```bash
cp -r "${SOURCE_DIR}"/*.py "${BUILD_DIR}/"
```
**Line 112**: Copy all Python files from package source.

```bash
if [[ -f "${BUILD_DIR}/${SOURCE_HANDLER}" && "${SOURCE_HANDLER}" != "${HANDLER}" ]]; then
    mv "${BUILD_DIR}/${SOURCE_HANDLER}" "${BUILD_DIR}/${HANDLER}"
fi
```
**Lines 118-121**: Rename handler if needed (e.g., `log_parser.py` → `log-parser.py`). This matches what Terraform expects based on the Lambda function configuration.

---

#### Section 6: Copy Shared Libraries (Lines 124-141)

```bash
mkdir -p "${BUILD_DIR}/lib"
cp "${LIB_DIR}"/*.py "${BUILD_DIR}/lib/"
```
**Lines 128-129**: Copy shared libraries to `lib/` subdirectory.

```bash
for lib in "${REQUIRED_LIBS[@]}"; do
    if [[ ! -f "${BUILD_DIR}/lib/${lib}" ]]; then
        echo "ERROR: Required lib missing: ${lib}"
        exit 1
    fi
done
```
**Lines 135-140**: Verify required libraries were copied. Fails build if any are missing.

---

#### Section 7: Cleanup (Lines 143-158)

```bash
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
find . -type f -name "*.pyc" -delete 2>/dev/null || true
```
**Lines 150-157**: Remove unnecessary files:
- `__pycache__/` - Python bytecode cache directories
- `*.dist-info/` - Package metadata (not needed at runtime)
- `*.egg-info/` - Egg metadata
- `*.pyc`, `*.pyo` - Compiled bytecode files
- `test/`, `tests/` - Test directories

This reduces package size and removes potential information leakage.

---

#### Section 8: Create Zip (Lines 160-169)

```bash
cd "${BUILD_DIR}"
zip -r -q "${OUTPUT_DIR}/${ZIP_NAME}" .
```
**Lines 164-165**: Create the deployment package:
- `-r` - Recursive (include all subdirectories)
- `-q` - Quiet (suppress file listing)
- Creates zip at root level (no parent directories)

---

#### Section 9: Validation Tests (Lines 171-277)

##### Positive Tests (verify correct behavior)

**Test 1: Zip Exists (Lines 179-184)**
```bash
if [[ -f "${OUTPUT_DIR}/${ZIP_NAME}" && -s "${OUTPUT_DIR}/${ZIP_NAME}" ]]; then
```
Verifies zip file exists (`-f`) and is not empty (`-s`).

**Test 2: Handler in Zip (Lines 187-194)**
```bash
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -F "${HANDLER}" | grep -qv "/"; then
```
Lists zip contents and checks handler exists at root level (not in subdirectory).

**Test 3: Size Check (Lines 197-205)**
```bash
ZIP_SIZE=$(stat -c%s "${OUTPUT_DIR}/${ZIP_NAME}" 2>/dev/null || stat -f%z "${OUTPUT_DIR}/${ZIP_NAME}")
MAX_SIZE_BYTES=$((MAX_SIZE_MB * 1024 * 1024))
```
Checks size is under 50MB (Lambda deployment limit). Uses `stat` with fallback for different OS.

**Test 4: Required Libraries (Lines 208-217)**
```bash
for lib in "${REQUIRED_LIBS[@]}"; do
    if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" 2>/dev/null | grep "lib/${lib}" >/dev/null 2>&1; then
```
Verifies each required library is present in `lib/` directory inside zip.

##### Negative Tests (catch problems)

**Test 5: Zip Integrity (Lines 223-228)**
```bash
if unzip -t "${OUTPUT_DIR}/${ZIP_NAME}" > /dev/null 2>&1; then
```
Tests zip archive integrity - catches corrupted files.

**Test 6: No __pycache__ (Lines 231-236)**
```bash
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "__pycache__"; then
```
Fails if bytecode cache directories weren't cleaned.

**Test 7: No .pyc Files (Lines 239-244)**
```bash
if unzip -l "${OUTPUT_DIR}/${ZIP_NAME}" | grep -q "\.pyc"; then
```
Fails if compiled bytecode files are present.

**Test 8: Import Validation (Lines 247-267)**
```bash
unzip -q "${OUTPUT_DIR}/${ZIP_NAME}" -d "${TEMP_EXTRACT}"
python3 -c "import sys; sys.path.insert(0, '.'); import ${IMPORT_MODULE}"
```
Extracts zip and attempts to import the handler module. This catches:
- Syntax errors
- Missing imports
- Basic structural problems

---

### Test Summary

| # | Test | Type | What It Catches |
|---|------|------|-----------------|
| 1 | Zip exists & not empty | Positive | Build failed |
| 2 | Handler in zip | Positive | Missing entry point |
| 3 | Size < 50MB | Positive | Exceeds Lambda limit |
| 4 | Required libs present | Positive | Missing dependencies |
| 5 | Zip integrity | Negative | Corrupted archive |
| 6 | No __pycache__ | Negative | Unclean build |
| 7 | No .pyc files | Negative | Bytecode contamination |
| 8 | Handler imports | Negative | Syntax errors |

---

## Build Process Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     build-lambda.sh                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  [1] Validate Inputs                                         │
│       └── Check package name, directories exist              │
│                           │                                  │
│                           ▼                                  │
│  [2] Setup Build Dir                                         │
│       └── Clean /tmp/build_<package>                         │
│                           │                                  │
│                           ▼                                  │
│  [3] Install Dependencies                                    │
│       └── pip install -t build_dir                           │
│                           │                                  │
│                           ▼                                  │
│  [4] Copy Handler Files                                      │
│       └── Copy *.py, rename if needed                        │
│                           │                                  │
│                           ▼                                  │
│  [5] Copy Shared Libraries                                   │
│       └── Copy lib/*.py to build_dir/lib/                    │
│                           │                                  │
│                           ▼                                  │
│  [6] Clean Artifacts                                         │
│       └── Remove __pycache__, .pyc, dist-info                │
│                           │                                  │
│                           ▼                                  │
│  [7] Create Zip                                              │
│       └── zip -r output/<package>.zip                        │
│                           │                                  │
│                           ▼                                  │
│  [8] Run 9 Validation Tests                                  │
│       ├── 5 Positive tests                                   │
│       └── 4 Negative tests                                   │
│                           │                                  │
│                           ▼                                  │
│  OUTPUT: lambda/<package>.zip                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| "Unknown package name" | Invalid first argument | Use `log_parser` or `reputation_lists_parser` |
| "Source directory not found" | Upstream not cloned | Run `make clone-upstream` first |
| "pip install failed" | Network or dependency issue | Check internet, try `--no-cache-dir` |
| "Handler not found in zip" | Rename logic failed | Check SOURCE_HANDLERS mapping |
| "Size exceeds limit" | Too many dependencies | Review dependencies for bloat |
| "Zip is corrupted" | Disk full or I/O error | Check disk space, retry build |
