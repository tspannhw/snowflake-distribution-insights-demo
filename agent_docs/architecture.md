# Distribution Insights Architecture

## Overview

This project delivers a complete AI-powered distribution analytics platform for ACME Investment Management using Snowflake as the unified data and AI platform.

## Core Components

### 1. Zero-Copy Integration (Salesforce → Snowflake)
- **Connector**: Snowflake for Salesforce native connector (GA)
- **Pattern**: Secure Data Sharing — no ETL, no data movement
- **Objects**: Opportunity, Account, Contact, Activity, Territory
- **Latency**: < 5 minutes (live sharing, not replication)

### 2. Ingest Layer
- **Primary**: Snowpipe Streaming V2 (High Performance)
- **SDK**: Java SDK for enterprise, REST API for edge devices
- **Auto-cluster**: On ingest, by territory_id and event_date
- **Row timestamps**: Applied automatically per project standard

### 3. Transform Layer
- **Framework**: Dynamic Tables (incremental, SQL-declarative)
- **Features**: Advisor engagement score, territory heat map, fund flow attribution
- **Orchestration**: Snowflake Tasks (serverless, DAG-based)
- **Language**: Snowpark Python for ML feature engineering

### 4. Serve Layer
- **Semantic View**: DISTRIBUTION_INSIGHTS_SV — advisor, territory, fund entities
- **Cortex Agent**: distribution_insights_agent with 5 skills
- **Cortex Analyst**: Self-service NL queries via semantic view
- **Streamlit**: dashboard/dashboard.py — role-aware analytics dashboard

### 5. Observability
- **DMFs**: Freshness, null rate, uniqueness on all critical tables
- **Alerts**: Slack (#edge-alerts) + Email on all DMF breaches
- **Cortex Guardrails**: Topic restrictions on all agent deployments
- **Resource Budgets**: Per-agent credit caps
- **Event Table**: Full telemetry for compliance audit

## Database Layout

```
ANALYTICS_DEV_DB
├── STAGING/
│   ├── sfdc_opportunity          -- Zero-copy from Salesforce
│   ├── sfdc_account              -- Zero-copy from Salesforce
│   ├── sfdc_activity             -- Zero-copy from Salesforce
│   ├── advisor_events_raw        -- Snowpipe V2 landing
│   └── fund_flows_raw            -- Snowpipe V2 landing
├── DISTRIBUTION/
│   ├── advisor_engagement_score  -- Dynamic Table (1h lag)
│   ├── territory_heat_map        -- Dynamic Table (4h lag)
│   ├── fund_flow_attribution     -- Dynamic Table (daily)
│   └── advisor_propensity_model  -- Model Registry UDF
└── SEMANTIC/
    └── DISTRIBUTION_INSIGHTS_SV  -- Semantic View (Cortex Analyst)
```

## Technology Choices

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Ingest | Snowpipe V2 | Sub-second latency, zero ops, auto-created pipes |
| Transform | Dynamic Tables | Declarative SQL, incremental by default, no Airflow |
| Orchestration | Snowflake Tasks | No external scheduler, serverless, DAG support |
| Analytics | Cortex Analyst + Semantic View | NL queries without SQL, governed business logic |
| Dashboard | Streamlit in Snowflake | Zero infrastructure, role-aware, Cortex integrated |
| Monitoring | DMFs + Alerts + Event Tables | Native, no third-party observability tools |
| AI Safety | Cortex Guardrails + Resource Budgets | Compliance-required, prevents runaway AI cost |

## References

- [Snowpipe V2](https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance)
- [Dynamic Tables](https://docs.snowflake.com/en/user-guide/dynamic-tables-intro)
- [Cortex Analyst](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [Semantic Views](https://docs.snowflake.com/en/user-guide/snowflake-cortex/semantic-views)
- [Cortex Agents](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents)
- [Cortex Guardrails](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-guardrails)
- [Resource Budgets](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-resource-budgets)
