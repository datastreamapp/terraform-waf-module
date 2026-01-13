# AWS WAF Terraform Module

A Terraform module for deploying AWS WAF (Web Application Firewall) with automated Lambda-based threat detection and IP reputation management.

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

## Overview

This module deploys a complete WAF solution including:
- **Web ACL** with OWASP Top 10 protection rules
- **Log Parser Lambda** - Analyzes WAF logs and blocks malicious IPs
- **Reputation Lists Parser Lambda** - Syncs external IP threat intelligence

```mermaid
flowchart LR
    subgraph Module["This Module"]
        WAF[AWS WAF]
        Lambda[Lambda Functions]
    end
    subgraph External["Consumer Creates"]
        Protected[CloudFront/ALB/API GW]
    end
    Internet((Internet)) --> Protected
    Protected -.->|Associate| WAF
    WAF -->|Logs| Lambda
    Lambda -->|Block IPs| WAF

    style Module fill:#d4edda,stroke:#28a745,color:#155724
    style External fill:#e2e3e5,stroke:#6c757d,color:#383d41
    classDef wafNode fill:#FF9900,stroke:#232F3E,color:white
    classDef extNode fill:#6c757d,stroke:#495057,color:white
    class WAF,Lambda wafNode
    class Protected extNode

    linkStyle default stroke:#333,stroke-width:2px
```

> **Note:** This module creates the WAF and outputs its ARN. You must create your own CloudFront/ALB/API Gateway and associate them using `aws_wafv2_web_acl_association`.

## Features

| Feature | Description |
|---------|-------------|
| **OWASP Protection** | SQL injection, XSS, path traversal, and more |
| **Automated Blocking** | Lambda functions automatically block malicious IPs |
| **Reputation Lists** | Integration with external IP blocklists |
| **Multi-Scope** | Works with CloudFront (edge) and regional resources |

## Quick Start

```hcl
module "waf" {
  source = "git@github.com:datastreamapp/terraform-waf-module?ref=v3.0.0"

  scope         = "REGIONAL"  # or "CLOUDFRONT"
  name          = "my-app"
  defaultAction = "ALLOW"

  logging_bucket = "my-app-waf-logs"
}
```

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for detailed architecture diagrams.

### System Overview

```mermaid
flowchart TB
    subgraph Module["This Module Creates"]
        subgraph WAF["AWS WAF"]
            ACL[Web ACL]
            Rules[WAF Rules]
        end

        subgraph Lambda["Lambda Functions"]
            LP[("log_parser<br/>Python 3.13")]
            RP[("reputation_lists_parser<br/>Python 3.13")]
        end

        subgraph Storage["Storage"]
            IPSet[(WAF IP Sets)]
        end

        subgraph Triggers["Triggers"]
            SNS[SNS Topic]
            CW[CloudWatch Events]
        end

        Output[/"Output: WAF ARN"/]
    end

    subgraph External["Consumer Responsibility"]
        S3[(S3 Logs Bucket)]
        CF[CloudFront]
        ALB[ALB]
        APIGW[API Gateway]
    end

    CF & ALB & APIGW -.->|"Associate WAF"| ACL
    ACL --> Rules
    S3 --> SNS
    SNS --> LP
    LP --> IPSet
    CW -->|Hourly| RP
    RP --> IPSet
    IPSet --> Rules
    ACL --> Output

    style Module fill:#d4edda,stroke:#28a745,color:#155724
    style External fill:#e2e3e5,stroke:#6c757d,color:#383d41
    style WAF fill:#fff3cd,stroke:#ffc107,color:#856404
    style Lambda fill:#fff3cd,stroke:#FF9900,color:#856404
    style Storage fill:#cce5ff,stroke:#004085,color:#004085
    style Triggers fill:#f8d7da,stroke:#721c24,color:#721c24

    classDef wafNode fill:#FF9900,stroke:#232F3E,color:white
    classDef lambdaNode fill:#FF9900,stroke:#232F3E,color:white
    classDef storageNode fill:#3B48CC,stroke:#232F3E,color:white
    classDef triggerNode fill:#E7157B,stroke:#232F3E,color:white
    classDef externalNode fill:#6c757d,stroke:#495057,color:white
    classDef outputNode fill:#28a745,stroke:#1e7e34,color:white

    class ACL,Rules wafNode
    class LP,RP lambdaNode
    class IPSet,S3 storageNode
    class SNS,CW triggerNode
    class CF,ALB,APIGW externalNode
    class Output outputNode

    linkStyle default stroke:#333,stroke-width:2px
```

> See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for code references proving each element.

### Lambda Functions

| Lambda | Trigger | Purpose |
|--------|---------|---------|
| `log_parser` | SNS (from S3 logs) | Parses WAF logs, blocks suspicious IPs |
| `reputation_lists_parser` | CloudWatch (hourly) | Syncs external IP reputation lists |

**Runtime:** Python 3.13 on Amazon Linux 2023

### Why Python 3.13 (not 3.14)?

| Factor | Python 3.13 | Python 3.14 |
|--------|-------------|-------------|
| Upstream Compatibility | Closer to upstream's 3.12 | Untested |
| Stability | Mature release | Bleeding edge |
| Dependency Risk | Lower | Higher |

The upstream [aws-waf-security-automations](https://github.com/aws-solutions/aws-waf-security-automations)
repository specifies `python = ~3.12` in their pyproject.toml. Using Python 3.13 provides a balance between
newer features and maintaining compatibility with upstream-tested dependencies.

See [CHANGELOG.md](CHANGELOG.md) for detailed rationale.

## WAF Rules

```
Web ACL
|- Blacklist Group
|  |- Bad Bot Rule
|  |- Blacklist Rule
|  |- HTTP Flood Rule
|  |- Reputation List Rule
|  |- Scanner Probes Rule
|- OWASP Group
|  |- Admin URL Rule
|  |- Auth Token Rule
|  |- CSRF Rule
|  |- Paths Rule
|  |- Server Side Include Rule
|  |- Size Restriction Rule
|  |- SQL Injection Rule
|  |- XSS Rule
|- Whitelist Rule
```

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `scope` | WAF scope (`REGIONAL` or `CLOUDFRONT`) | `string` | `"CLOUDFRONT"` |
| `name` | Application name | `string` | required |
| `defaultAction` | Default action (`ALLOW` or `DENY`) | `string` | `"DENY"` |
| `logging_bucket` | S3 bucket for logs | `string` | required |

See [variables.tf](variables.tf) for full list of inputs.

## Outputs

| Name | Description |
|------|-------------|
| `id` | WAF Web ACL ID |
| `arn` | WAF Web ACL ARN |

## Lambda Build Process

Lambda packages are built automatically from [aws-solutions/aws-waf-security-automations](https://github.com/aws-solutions/aws-waf-security-automations).

### Automated Build (Recommended)

```mermaid
flowchart LR
    A[Trigger Workflow] --> B[Build in Docker]
    B --> C[Run Tests]
    C --> D[Create PR]
    D --> E[Review & Merge]
    E --> F[Tag Release]

    linkStyle default stroke:#333,stroke-width:2px
```

1. Go to **Actions** > **Build WAF Lambda Packages**
2. Click **Run workflow**
3. Configure:
   - **Upstream ref**: Tag (e.g., `v4.0.3`)
   - **Version bump**: `none`, `patch`, `minor`, `major`
4. Review and merge the generated PR
5. Create release tag after merge

### Local Build

```bash
# Clone upstream source
git clone --depth 1 --branch v4.0.3 \
  https://github.com/aws-solutions/aws-waf-security-automations.git upstream

# Build Docker image
docker build -t lambda-builder -f scripts/Dockerfile.lambda-builder scripts/

# Build packages
docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder log_parser /upstream /output

docker run --rm \
  -v $(pwd)/upstream:/upstream:ro \
  -v $(pwd)/lambda:/output \
  lambda-builder reputation_lists_parser /upstream /output
```

### Build Validation

The build process includes comprehensive tests:

**Positive Tests:**
- Zip file exists and not empty
- Handler file present
- Size under 50MB Lambda limit
- Required shared libraries included
- Security scan (pip-audit)

**Negative Tests:**
- No `__pycache__` directories
- No `.pyc` bytecode files
- Zip integrity verified
- Import validation passes

## Versioning

This project follows [Semantic Versioning](https://semver.org/).

| Version Type | When to Use |
|--------------|-------------|
| **major** | Breaking changes (Python upgrade, API changes) |
| **minor** | New features, dependency updates |
| **patch** | Bug fixes, security patches |

Current version: See [CHANGELOG.md](CHANGELOG.md)

## Documentation

| Document | Description |
|----------|-------------|
| [README.md](README.md) | This file |
| [CHANGELOG.md](CHANGELOG.md) | Version history and decisions |
| [TODOLIST.md](TODOLIST.md) | Implementation tasks |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Architecture diagrams |
| [docs/TESTING.md](docs/TESTING.md) | Testing guide |

## File Structure

```
terraform-waf-module/
|- .github/
|  |- workflows/
|     |- build-lambda-packages.yml  # CI/CD pipeline
|- docs/
|  |- ARCHITECTURE.md               # Architecture diagrams
|  |- TESTING.md                    # Testing guide
|- lambda/
|  |- log_parser.zip                # Built artifact
|  |- reputation_lists_parser.zip   # Built artifact
|  |- LICENSE.txt
|- scripts/
|  |- Dockerfile.lambda-builder     # Build environment
|  |- build-lambda.sh               # Build script
|- lambda.log-parser.tf             # Lambda TF config
|- lambda.reputation-list.tf        # Lambda TF config
|- main.tf                          # WAF Web ACL
|- Makefile                         # Build and test automation
|- CHANGELOG.md                     # Version history
|- TODOLIST.md                      # Implementation tasks
|- README.md                        # Project documentation
```

## Contributing

1. Create feature branch from `master`
2. Make changes
3. Create PR for review
4. Merge after approval

## License

Apache 2.0 - See [LICENSE](LICENSE)

## References

- [AWS WAF Security Automations](https://github.com/aws-solutions/aws-waf-security-automations)
- [AWS WAF Documentation](https://docs.aws.amazon.com/waf/)
- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
