# Architecture Documentation

This document describes the architecture of the terraform-waf-module and its CI/CD pipeline.

## System Overview

```mermaid
flowchart TB
    subgraph Module["This Module Creates"]
        subgraph WAF["AWS WAF"]
            ACL["Web ACL"]
            Rules["WAF Rules"]
        end

        subgraph Lambda["Lambda Functions"]
            LP[("log_parser")]
            RP[("reputation_lists_parser")]
        end

        subgraph Storage["Storage"]
            IPSet[("WAF IP Sets")]
        end

        subgraph Triggers["Triggers"]
            SNS["SNS Topic"]
            CW["CloudWatch Events"]
        end

        Output[/"Output: WAF ARN"/]
    end

    subgraph External["External - Consumer Responsibility"]
        S3[("S3 Logs Bucket")]
        CF[CloudFront]
        ALB[ALB]
        APIGW[API Gateway]
        Note["Associate via aws_wafv2_web_acl_association"]
    end

    CF & ALB & APIGW -.->|"Consumer associates"| ACL
    ACL --> Rules
    S3 -->|"Log prefixes: CloudFront, ALB, WAF"| SNS
    SNS --> LP
    LP --> IPSet
    CW -->|"rate 1 hour"| RP
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
    class CF,ALB,APIGW,Note externalNode
    class Output outputNode

    linkStyle default stroke:#333,stroke-width:2px
```

> **Note:** This module creates the WAF Web ACL and outputs its ARN. The consumer must create their own CloudFront, ALB, or API Gateway and associate them with the WAF using `aws_wafv2_web_acl_association`.

## CI/CD Build Pipeline

```mermaid
flowchart LR
    subgraph Trigger["Trigger"]
        Manual[/"workflow_dispatch"/]
    end

    subgraph Checkout["Checkout"]
        Repo[terraform-waf-module]
        Upstream[aws-waf-security-automations]
    end

    subgraph Build["Docker Build"]
        direction TB
        Docker[("Python 3.13 Amazon Linux 2023")]
        LP_Build[log_parser.zip]
        RP_Build[reputation_lists_parser.zip]
        Docker --> LP_Build --> RP_Build
    end

    subgraph Validate["Validate"]
        direction TB
        Tests[/"Tests - Positive and Negative"/]
        Sec[/"Security Scan - pip-audit"/]
    end

    subgraph Output["Output"]
        direction TB
        Commit["Commit zips to lambda/"]
        PR[("Create PR")]
        Review{{"Review PR and Approve to Merge Packages"}}
        Commit --> PR --> Review
    end

    Manual --> Repo
    Manual --> Upstream
    Repo --> Docker
    Upstream --> Docker
    RP_Build --> Tests --> Sec --> Commit

    style Docker fill:#FF9900,stroke:#232F3E,color:white
    style Commit fill:#0366d6,stroke:#0366d6,color:white
    style PR fill:#238636,stroke:#238636,color:white
    style Review fill:#6f42c1,stroke:#6f42c1,color:white
    style Tests fill:#28a745,stroke:#28a745,color:white
    style Sec fill:#6f42c1,stroke:#6f42c1,color:white

    linkStyle default stroke:#333,stroke-width:2px
```

## CI/CD Test Workflow (test.yml)

This workflow runs automatically on every push to `master` and on pull requests.

```mermaid
flowchart LR
    subgraph Trigger["Triggers"]
        Push["Push to master"]
        PR["Pull Request"]
    end

    subgraph TerraformJob["Job: terraform"]
        direction TB
        T1["Checkout"]
        T2["terraform init"]
        T3["terraform validate"]
        T4["terraform fmt -check"]
        T5["tflint"]
        T6["tfsec"]
        T7["checkov"]
        T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7
    end

    subgraph LambdaJob["Job: lambda"]
        direction TB
        L1["Checkout"]
        L2["Clone upstream"]
        L3["Build Docker"]
        L4["Test log_parser"]
        L5["Test reputation_lists"]
        L1 --> L2 --> L3 --> L4 --> L5
    end

    Push & PR --> TerraformJob
    Push & PR --> LambdaJob

    style Trigger fill:#f8d7da,stroke:#721c24,color:#721c24
    style TerraformJob fill:#d4edda,stroke:#28a745,color:#155724
    style LambdaJob fill:#cce5ff,stroke:#004085,color:#004085

    linkStyle default stroke:#333,stroke-width:2px
```

## Build Process Detail

```mermaid
flowchart TD
    subgraph Input["Input"]
        US[("Upstream aws-waf-security-automations")]
        PP["pyproject.toml"]
        LIB["source/lib/*.py"]
    end

    subgraph Process["Build Process - Docker"]
        direction TB
        A["Poetry export to requirements.txt"]
        B["pip install to build dir"]
        C["Copy handler *.py files"]
        D["Copy shared lib/ files"]
        E["Clean __pycache__ and .pyc"]
        F["Create zip archive"]
        A --> B --> C --> D --> E --> F
    end

    subgraph Tests["Validation Tests"]
        direction TB
        T1["Zip exists and not empty"]
        T2["Handler file exists"]
        T3["Size under 50MB"]
        T4["Required libs included"]
        T5["No __pycache__"]
        T6["No .pyc files"]
        T7["Zip not corrupted"]
        T8["Import validation"]
    end

    subgraph Output["Output"]
        ZIP[("log_parser.zip and reputation_lists_parser.zip")]
    end

    US --> PP --> A
    US --> LIB --> D
    F --> T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7 --> T8 --> ZIP

    style ZIP fill:#28a745,stroke:#28a745,color:white

    linkStyle default stroke:#333,stroke-width:2px
```

## Lambda Function Flow

### Log Parser

```mermaid
sequenceDiagram
    participant S3 as S3 Logs Bucket
    participant SNS as SNS Topic
    participant LP as log_parser Lambda
    participant IPSet as WAF IP Set

    S3->>SNS: New log file notification
    SNS->>LP: Trigger Lambda
    LP->>S3: Read log file
    LP->>LP: Parse for suspicious IPs
    LP->>IPSet: Update blocked IPs
    Note over LP,IPSet: Adds malicious IPs to blocklist
```

### Reputation Lists Parser

```mermaid
sequenceDiagram
    participant CW as CloudWatch Events
    participant RP as reputation_lists_parser Lambda
    participant Web as Reputation List URLs
    participant IPSet as WAF IP Set

    CW->>RP: Hourly trigger
    RP->>Web: Fetch reputation lists
    Web-->>RP: IP blocklists
    RP->>RP: Parse and deduplicate
    RP->>IPSet: Update IP sets
    Note over RP,IPSet: Syncs external threat intelligence
```

## Python Version Decision

```mermaid
flowchart LR
    subgraph Options["Available Options"]
        P312["Python 3.12 - Upstream tested"]
        P313["Python 3.13 - Stable Modern"]
        P314["Python 3.14 - Bleeding edge"]
    end

    subgraph Decision["Decision Factors"]
        Compat["Upstream Compatibility"]
        Stable["Release Maturity"]
        Risk["Dependency Risk"]
    end

    subgraph Result["Selected"]
        Winner["Python 3.13"]
    end

    P312 --> Compat
    P313 --> Compat
    P313 --> Stable
    P313 --> Risk
    P314 --> Risk

    Compat --> Winner
    Stable --> Winner
    Risk --> Winner

    style P313 fill:#28a745,stroke:#28a745,color:white
    style Winner fill:#28a745,stroke:#28a745,color:white
    style P314 fill:#ffc107,stroke:#ffc107,color:black

    linkStyle default stroke:#333,stroke-width:2px
```

## File Structure

```
terraform-waf-module/
├── .github/
│   └── workflows/
│       └── build-lambda-packages.yml  # CI/CD pipeline
├── docs/
│   ├── ARCHITECTURE.md                # This file
│   └── TESTING.md                     # Testing guide
├── lambda/
│   ├── log_parser.zip                 # Built artifact
│   ├── reputation_lists_parser.zip    # Built artifact
│   └── LICENSE.txt
├── scripts/
│   ├── Dockerfile.lambda-builder      # Build environment
│   └── build-lambda.sh                # Build script
├── lambda.log-parser.tf               # Lambda TF config
├── lambda.reputation-list.tf          # Lambda TF config
├── main.tf                            # WAF Web ACL
├── Makefile                           # Build and test automation
├── CHANGELOG.md                       # Version history
├── TODOLIST.md                        # Implementation tasks
└── README.md                          # Project documentation
```

---

## Code References

This section provides traceability for all diagram elements to their source code locations.

### System Overview Diagram

#### Resources Created by This Module

| Diagram Element | File:Line | Evidence |
|-----------------|-----------|----------|
| WAF Web ACL | `main.tf:3` | `resource "aws_wafv2_web_acl" "main"` |
| WAF scope (CLOUDFRONT/REGIONAL) | `main.tf:5`, `variables.tf:6-8` | `scope = var.scope` |
| Output WAF ARN | `output.tf:2` | `value = aws_wafv2_web_acl.main.arn` |
| log_parser Lambda | `lambda.log-parser.tf:169` | `resource "aws_lambda_function" "log-parser"` |
| reputation_lists_parser Lambda | `lambda.reputation-list.tf:86` | `resource "aws_lambda_function" "reputation-list"` |
| SNS Topic | `lambda.log-parser.tf:259` | `resource "aws_sns_topic" "log-parser"` |
| CloudWatch Event Rule | `lambda.reputation-list.tf:131` | `resource "aws_cloudwatch_event_rule" "reputation-list"` |
| IP Sets | `ipset.tf:6,17,28,39,50,61,73,84,95,106,117,128` | Multiple `aws_wafv2_ip_set` resources |

#### Trigger Configuration

| Diagram Element | File:Line | Evidence |
|-----------------|-----------|----------|
| log_parser triggered by SNS | `lambda.log-parser.tf:287-291` | `aws_sns_topic_subscription.log-parser` |
| S3 notifications to SNS | `lambda.log-parser.tf:227-257` | `aws_s3_bucket_notification.log-parser` |
| S3 prefixes: CloudFront, ALB, WAF | `lambda.log-parser.tf:236,245,254` | `filter_prefix` for each log type |
| reputation_lists_parser hourly trigger | `lambda.reputation-list.tf:131-136` | `schedule_expression = "rate(1 hour)"` |

#### IP Set Updates

| Diagram Element | File:Line | Evidence |
|-----------------|-----------|----------|
| log_parser updates HTTP Flood IP Sets | `lambda.log-parser.tf:153-154` | `HTTPFloodSetIPV4.arn`, `HTTPFloodSetIPV6.arn` |
| log_parser updates Scanners/Probes IP Sets | `lambda.log-parser.tf:106-107` | `ScannersProbesSetIPV4.arn`, `ScannersProbesSetIPV6.arn` |
| reputation_lists_parser updates Reputation IP Sets | `lambda.reputation-list.tf:50-51` | `IPReputationListsSetIPV4.arn`, `IPReputationListsSetIPV6.arn` |
| Python 3.13 runtime | `lambda.log-parser.tf:176`, `lambda.reputation-list.tf:94` | `runtime = "python3.13"` |

#### External Resources (NOT Created by This Module)

| Element | Status | Consumer Action Required |
|---------|--------|--------------------------|
| CloudFront Distribution | **NOT IN MODULE** | Consumer creates and associates using `aws_wafv2_web_acl_association` |
| Application Load Balancer | **NOT IN MODULE** | Consumer creates and associates using `aws_wafv2_web_acl_association` |
| API Gateway | **NOT IN MODULE** | Consumer creates and associates using `aws_wafv2_web_acl_association` |
| S3 Logs Bucket | **NOT IN MODULE** | Consumer provides via `var.logging_bucket` |

### Reputation Lists - External URLs

| URL | File:Line |
|-----|-----------|
| `https://www.spamhaus.org/drop/drop.txt` | `lambda.reputation-list.tf:119` |
| `https://www.spamhaus.org/drop/edrop.txt` | `lambda.reputation-list.tf:119` |
| `https://check.torproject.org/exit-addresses` | `lambda.reputation-list.tf:119` |
| `https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt` | `lambda.reputation-list.tf:119` |

### Build Process Diagram

| Step | File:Line | Command |
|------|-----------|---------|
| 1. Poetry export | `scripts/build-lambda.sh:79` | `poetry export --without dev -f requirements.txt` |
| 2. pip install | `scripts/build-lambda.sh:84` | `pip install -r ... -t "${BUILD_DIR}"` |
| 3. Copy handler files | `scripts/build-lambda.sh:94` | `cp -r "${SOURCE_DIR}"/*.py` |
| 4. Copy shared libs | `scripts/build-lambda.sh:105` | `cp "${LIB_DIR}"/*.py "${BUILD_DIR}/lib/"` |
| 5. Clean __pycache__ | `scripts/build-lambda.sh:123,126` | `find ... -name "__pycache__"` |
| 6. Create zip | `scripts/build-lambda.sh:136` | `zip -r -q "${OUTPUT_DIR}/${ZIP_NAME}"` |

### Validation Tests

| Test | File:Line | Check |
|------|-----------|-------|
| Test 1: Zip exists & not empty | `scripts/build-lambda.sh:150` | `-f ... && -s ...` |
| Test 2: Handler in zip | `scripts/build-lambda.sh:158` | `unzip -l ... \| grep -q "${HANDLER}"` |
| Test 3: Size < 50MB | `scripts/build-lambda.sh:166` | `stat` + size comparison |
| Test 4: Required libs | `scripts/build-lambda.sh:177-178` | Loop over `REQUIRED_LIBS` |
| Test 5: Zip integrity | `scripts/build-lambda.sh:190` | `unzip -t` |
| Test 6: No __pycache__ | `scripts/build-lambda.sh:198` | `grep -q "__pycache__"` (expect fail) |
| Test 7: No .pyc files | `scripts/build-lambda.sh:206` | `grep -q "\.pyc"` (expect fail) |
| Test 8: Import validation | `scripts/build-lambda.sh:224` | `python3 -c "import ..."` |

### CI/CD Pipeline Diagram

| Step | File:Line | Evidence |
|------|-----------|----------|
| workflow_dispatch trigger | `.github/workflows/build-lambda-packages.yml:4` | `on: workflow_dispatch:` |
| Checkout this repo | `.github/workflows/build-lambda-packages.yml:39-43` | `uses: actions/checkout@v4` |
| Checkout upstream | `.github/workflows/build-lambda-packages.yml:73-82` | `repository: aws-solutions/...` |
| Build Docker image | `.github/workflows/build-lambda-packages.yml:98-100` | `docker build -t lambda-builder` |
| Build log_parser.zip | `.github/workflows/build-lambda-packages.yml:102-108` | `docker run ... log_parser` |
| Build reputation_lists_parser.zip | `.github/workflows/build-lambda-packages.yml:110-116` | `docker run ... reputation_lists_parser` |
| pip-audit security scan | `.github/workflows/build-lambda-packages.yml:118-130` | `pip-audit -r ...` |
| Create PR | `.github/workflows/build-lambda-packages.yml:148-206` | `peter-evans/create-pull-request@v6` |

### CI/CD Test Workflow (test.yml)

| Step | File:Line | Evidence |
|------|-----------|----------|
| Workflow triggers | `.github/workflows/test.yml:3-7` | `on: push, pull_request` |
| Security permissions | `.github/workflows/test.yml:9-11` | `permissions: contents: read` |
| Terraform Init | `.github/workflows/test.yml:24-25` | `terraform init -backend=false` |
| Terraform Validate | `.github/workflows/test.yml:27-28` | `terraform validate` |
| Terraform fmt | `.github/workflows/test.yml:30-31` | `terraform fmt -check -recursive` |
| tflint setup | `.github/workflows/test.yml:33-34` | `setup-tflint@v4` |
| tflint run | `.github/workflows/test.yml:36-39` | `tflint --init && tflint` |
| tfsec | `.github/workflows/test.yml:41-44` | `tfsec-action@v1.0.0, --minimum-severity HIGH` |
| checkov | `.github/workflows/test.yml:46-52` | `checkov-action@v12, soft_fail: true` |
| Clone upstream | `.github/workflows/test.yml:60-63` | `git clone ... v4.1.2` |
| Docker build | `.github/workflows/test.yml:65-66` | `docker build -t lambda-builder` |
| Test log_parser | `.github/workflows/test.yml:68-73` | `lambda-builder log_parser` |
| Test reputation_lists | `.github/workflows/test.yml:75-80` | `lambda-builder reputation_lists_parser` |
| Summary output | `.github/workflows/test.yml:82-92` | `GITHUB_STEP_SUMMARY` |
