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
