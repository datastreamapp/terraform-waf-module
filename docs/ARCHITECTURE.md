# Architecture Documentation

This document describes the architecture of the terraform-waf-module and its CI/CD pipeline.

## System Overview

```mermaid
flowchart TB
    subgraph AWS["AWS Cloud"]
        subgraph WAF["AWS WAF"]
            ACL[Web ACL]
            Rules[WAF Rules]
        end

        subgraph Lambda["Lambda Functions"]
            LP[("log_parser<br/>Python 3.13")]
            RP[("reputation_lists_parser<br/>Python 3.13")]
        end

        subgraph Storage["Storage"]
            S3[(S3 Logs Bucket)]
            IPSet[(WAF IP Sets)]
        end

        subgraph Triggers["Triggers"]
            SNS[SNS Topic]
            CW[CloudWatch Events]
        end
    end

    subgraph Protected["Protected Resources"]
        CF[CloudFront]
        ALB[ALB]
        APIGW[API Gateway]
    end

    Internet((Internet)) --> CF & ALB & APIGW
    CF & ALB & APIGW --> ACL
    ACL --> Rules
    Rules --> S3
    S3 --> SNS
    SNS --> LP
    LP --> IPSet
    CW -->|Hourly| RP
    RP --> IPSet
    IPSet --> Rules

    classDef aws fill:#FF9900,stroke:#232F3E,color:#232F3E
    classDef lambda fill:#FF9900,stroke:#232F3E,color:white
    classDef storage fill:#3B48CC,stroke:#232F3E,color:white

    class ACL,Rules aws
    class LP,RP lambda
    class S3,IPSet storage
```

## CI/CD Build Pipeline

```mermaid
flowchart LR
    subgraph Trigger["1. Trigger"]
        Manual[/"workflow_dispatch<br/>(Manual)"/]
    end

    subgraph Checkout["2. Checkout"]
        Repo[terraform-waf-module]
        Upstream[aws-waf-security-<br/>automations]
    end

    subgraph Build["3. Docker Build"]
        direction TB
        Docker[("Docker Container<br/>Python 3.13<br/>Amazon Linux 2023")]
        LP_Build[Build log_parser.zip]
        RP_Build[Build reputation_lists_parser.zip]
        Docker --> LP_Build --> RP_Build
    end

    subgraph Validate["4. Validate"]
        direction TB
        Pos[/"Positive Tests"/]
        Neg[/"Negative Tests"/]
        Sec[/"Security Scan"/]
    end

    subgraph Output["5. Output"]
        PR[("Create PR<br/>for Review")]
    end

    Manual --> Repo
    Manual --> Upstream
    Repo --> Docker
    Upstream --> Docker
    RP_Build --> Pos --> Neg --> Sec --> PR

    style Docker fill:#FF9900,stroke:#232F3E,color:white
    style PR fill:#238636,stroke:#238636,color:white
    style Pos fill:#28a745,stroke:#28a745,color:white
    style Neg fill:#dc3545,stroke:#dc3545,color:white
    style Sec fill:#6f42c1,stroke:#6f42c1,color:white
```

## Build Process Detail

```mermaid
flowchart TD
    subgraph Input["Input"]
        US[("Upstream Source<br/>aws-waf-security-automations")]
        PP["pyproject.toml"]
        LIB["source/lib/*.py"]
    end

    subgraph Process["Build Process (Docker)"]
        direction TB
        A[1. Poetry export to requirements.txt]
        B[2. pip install to build dir]
        C[3. Copy handler *.py files]
        D[4. Copy shared lib/ files]
        E[5. Clean __pycache__, .pyc]
        F[6. Create zip archive]
        A --> B --> C --> D --> E --> F
    end

    subgraph Tests["Validation Tests"]
        direction TB
        T1["Zip exists & not empty"]
        T2["Handler file exists"]
        T3["Size < 50MB"]
        T4["Required libs included"]
        T5["No __pycache__"]
        T6["No .pyc files"]
        T7["Zip not corrupted"]
        T8["Import validation"]
    end

    subgraph Output["Output"]
        ZIP[("log_parser.zip<br/>reputation_lists_parser.zip")]
    end

    US --> PP --> A
    US --> LIB --> D
    F --> T1 --> T2 --> T3 --> T4 --> T5 --> T6 --> T7 --> T8 --> ZIP

    style ZIP fill:#28a745,stroke:#28a745,color:white
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
        P312["Python 3.12<br/>Upstream tested"]
        P313["Python 3.13<br/>Stable + Modern"]
        P314["Python 3.14<br/>Bleeding edge"]
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
```

## File Structure

```
terraform-waf-module/
├── .github/
│   └── workflows/
│       └── build-lambda-packages.yml  # CI/CD pipeline
├── docs/
│   └── ARCHITECTURE.md                # This file
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
├── CHANGELOG.md                       # Version history
├── TODOLIST.md                        # Implementation tasks
└── README.md                          # Project documentation
```

---

## Code References

This section provides traceability for all diagram elements to their source code locations.

### System Overview Diagram

| Diagram Element | File:Line | Evidence |
|-----------------|-----------|----------|
| log_parser triggered by SNS | `lambda.log-parser.tf:287-291` | `aws_sns_topic_subscription.log-parser` |
| S3 notifications to SNS | `lambda.log-parser.tf:227-257` | `aws_s3_bucket_notification.log-parser` |
| S3 prefixes: CloudFront, ALB, WAF | `lambda.log-parser.tf:236,245,254` | `filter_prefix` for each log type |
| reputation_lists_parser hourly trigger | `lambda.reputation-list.tf:131-136` | `schedule_expression = "rate(1 hour)"` |
| log_parser updates HTTP Flood IP Sets | `lambda.log-parser.tf:153-154` | `HTTPFloodSetIPV4.arn`, `HTTPFloodSetIPV6.arn` |
| log_parser updates Scanners/Probes IP Sets | `lambda.log-parser.tf:106-107` | `ScannersProbesSetIPV4.arn`, `ScannersProbesSetIPV6.arn` |
| reputation_lists_parser updates Reputation IP Sets | `lambda.reputation-list.tf:50-51` | `IPReputationListsSetIPV4.arn`, `IPReputationListsSetIPV6.arn` |
| Python 3.13 runtime | `lambda.log-parser.tf:176`, `lambda.reputation-list.tf:94` | `runtime = "python3.13"` |

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
