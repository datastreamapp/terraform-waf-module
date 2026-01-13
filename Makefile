.PHONY: test validate fmt security build clean

test: validate fmt security

validate:
	terraform init -backend=false
	terraform validate

fmt:
	terraform fmt -check -recursive

security:
	tfsec .
	checkov -d . --quiet

build:
	docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

clean:
	rm -rf .terraform
	rm -rf /tmp/build_*
