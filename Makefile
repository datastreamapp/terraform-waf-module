.PHONY: test test-all test-local test-lambda test-integrity validate fmt lint security build clean clone-upstream tag

# Default test (quick - no Docker)
test: validate fmt

# Local test suite (Docker-based, no local tool installs needed)
test-local: validate fmt lint security

# Full test suite (includes Docker lambda builds + integrity)
test-all: validate fmt lint security test-lambda test-integrity

# Terraform validation
validate:
	@echo "==> Terraform validate..."
	terraform init -backend=false
	terraform validate

# Format check
fmt:
	@echo "==> Terraform fmt check..."
	terraform fmt -check -recursive

# Linting (Docker-based - no local install needed)
lint:
	@echo "==> Running tflint..."
	docker run --rm -v $(PWD):/data -t ghcr.io/terraform-linters/tflint:latest --init
	docker run --rm -v $(PWD):/data -t ghcr.io/terraform-linters/tflint:latest

# Security scanning (Docker-based - no local install needed)
# Note: Configured to fail only on HIGH/CRITICAL, excludes upstream (third-party)
security:
	@echo "==> Running tfsec..."
	docker run --rm -v $(PWD):/data -t aquasec/tfsec:latest /data --minimum-severity HIGH --exclude-path upstream
	@echo ""
	@echo "==> Running checkov..."
	docker run --rm -v $(PWD):/data -t bridgecrew/checkov:latest \
		-d /data \
		--skip-path /data/upstream \
		--skip-path /data/lambda \
		--quiet --compact \
		--soft-fail-on CKV_AWS_115,CKV_AWS_117,CKV_AWS_173,CKV_AWS_272,CKV_AWS_158,CKV_AWS_116,CKV_DOCKER_2,CKV_DOCKER_3,CKV2_GHA_1,CKV_GHA_7

# Clone upstream source (if not exists)
clone-upstream:
	@if [ ! -d "upstream" ]; then \
		echo "==> Cloning upstream source..."; \
		git clone --depth 1 --branch v4.1.2 \
			https://github.com/aws-solutions/aws-waf-security-automations.git upstream; \
	else \
		echo "==> Upstream already exists, skipping clone"; \
	fi

# Build Docker image
build:
	@echo "==> Building Docker image..."
	docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Test lambda builds (requires Docker)
test-lambda: clone-upstream build
	@echo "==> Building and testing log_parser..."
	docker run --rm \
		-v $(PWD)/upstream:/upstream:ro \
		-v $(PWD)/lambda:/output \
		lambda-builder log_parser /upstream /output
	@echo ""
	@echo "==> Building and testing reputation_lists_parser..."
	docker run --rm \
		-v $(PWD)/upstream:/upstream:ro \
		-v $(PWD)/lambda:/output \
		lambda-builder reputation_lists_parser /upstream /output
	@echo ""
	@echo "==> All lambda tests passed!"

# System integrity tests (cross-file consistency, no Docker needed)
test-integrity:
	@echo "==> Running system integrity tests..."
	@bash scripts/test-integrity.sh

# Clean up
clean:
	rm -rf .terraform
	rm -rf .terraform.lock.hcl
	rm -rf /tmp/build_*

# Deep clean (including upstream)
clean-all: clean
	rm -rf upstream

# Create release tag (usage: make tag v=4.1.0)
tag:
	@if [ -z "$(v)" ]; then echo "Usage: make tag v=4.1.0"; exit 1; fi
	git checkout master && git pull
	git tag -a "v$(v)" -m "Release v$(v)"
	git push origin "v$(v)"
	@echo "Tagged and pushed v$(v)"
