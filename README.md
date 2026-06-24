# Distribution Insights — ACME IM

End-to-end Snowflake AI demo covering Salesforce Zero-Copy integration, AI pipeline management, Cortex observability, and self-service analytics via Cortex Analyst.

---

## Quick Start

```bash
# 1. Clone and enter project
cd /path/to/huddledatascience

# 2. Build all infrastructure (schemas, tables, Dynamic Tables, agent, alerts)
./manage.sh build

# 3. Upload semantic view YAML to stage (required for Cortex Analyst)
snow stage copy scripts/02_semantic_view.yaml \
  @ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/ --connection your_connection --overwrite

# 4. Validate everything is working
./manage.sh test

# 5. Deploy Streamlit dashboard to Snowflake
./manage.sh deploy
```

---

## Project Layout

```
huddledatascience/
├── manage.sh                          # Build / test / deploy orchestration
├── AGENTS.md                          # Project rules and conventions
│
├── scripts/
│   ├── 01_setup_schema.sql            # Schemas, tables, synthetic demo data (200 advisors)
│   ├── 02_semantic_view.yaml          # Cortex Analyst semantic model (10 VQRs, 3 tables)
│   ├── 03_cortex_agent.sql            # Cortex Agent + Search Service + functional tests
│   ├── 04_dynamic_tables.sql          # 3 Dynamic Tables (engagement score, flows, heat map)
│   └── 05_alerts_observability.sql    # Event table, Slack integrations, 5 alerts, DMFs
│
├── dashboard/
│   └── dashboard.py                   # Streamlit in Snowflake (6 tabs, role-aware)
│
├── notebooks/
│   ├── 01_zero_copy_demo.ipynb        # Salesforce Zero-Copy integration walkthrough
│   ├── 02_ai_pipeline_demo.ipynb      # Snowpipe V2, Dynamic Tables, propensity scoring
│   ├── 03_observability_demo.ipynb    # DMFs, alert history, event tables
│   └── 04_cortex_analyst_demo.ipynb   # Natural language to SQL via Cortex Analyst
│
├── agent_docs/
│   └── architecture.md                # Architecture decisions and technology choices
│
└── docs/
    └── prompts.md                     # Agent prompts, verified queries, CoCo prompts, demo script
```

---

## Architecture

### Database layout

```
ANALYTICS_DEV_DB
├── STAGING/             Raw landing zone
│   ├── ADVISOR_DIM                 Reference: 200 synthetic advisors
│   ├── TERRITORY_DIM               Reference: 5 territories (NE, SE, MW, SW, Pacific)
│   ├── FUND_DIM                    Reference: 5 ACME funds
│   ├── ADVISOR_EVENTS_RAW          Snowpipe V2 target (CALL, EMAIL, MEETING, EVENT)
│   ├── FUND_FLOWS_RAW              Daily fund flow transactions
│   ├── SFDC_OPPORTUNITY            Salesforce Opportunity (Zero-Copy mock in dev)
│   └── SFDC_ACCOUNT                Salesforce Account (Zero-Copy mock in dev)
│
└── DISTRIBUTION/        Curated analytics
    ├── ADVISOR_ENGAGEMENT_SCORE    Dynamic Table — 1h lag, 200 rows (one per advisor)
    ├── FUND_FLOW_ATTRIBUTION        Dynamic Table — 1d lag, ~4000 rows
    ├── TERRITORY_HEAT_MAP           Dynamic Table — 4h lag, 5 rows (one per territory)
    ├── FUND_DOCS_SEARCH             Cortex Search Service (fund documentation)
    ├── AGENT_STAGE                  Stage for semantic view YAML + agent artifacts
    ├── distribution_insights_agent  Cortex Agent (2 tools: analyst + search)
    └── EVENTS                       Event Table (Cortex AI telemetry)
```

### Dynamic Table dependency chain

```
STAGING tables (base, no lag)
    │
    ├─▶ ADVISOR_ENGAGEMENT_SCORE  (1h lag)
    │       │
    │       └─▶ FUND_FLOW_ATTRIBUTION  (1d lag)
    │
    └─▶ TERRITORY_HEAT_MAP  (4h lag) — reads ADVISOR_ENGAGEMENT_SCORE + STAGING flows
```

> **Lag constraint**: A downstream DT's lag must be ≥ its upstream DT's lag.
> `TERRITORY_HEAT_MAP` reads `FUND_FLOWS_RAW` (staging) directly to avoid inheriting
> `FUND_FLOW_ATTRIBUTION`'s 1-day lag, keeping the heat map at 4 hours.

### Technology choices

| Layer | Technology | Why |
|-------|-----------|-----|
| Ingest | Snowpipe V2 (streaming) | Sub-second latency, zero ops, auto-created pipes |
| Transform | Dynamic Tables | Declarative SQL, incremental by default, no Airflow |
| Analytics | Cortex Analyst + Semantic View YAML | NL queries without SQL for business users |
| AI | `SNOWFLAKE.CORTEX.COMPLETE('mistral-7b', ...)` | Smallest capable model → lowest cost |
| Dashboard | Streamlit in Snowflake | Zero infrastructure, role-aware, Cortex integrated |
| Search | Cortex Search Service | Semantic fund document retrieval |
| Agent | `CREATE AGENT ... FROM SPECIFICATION $$yaml$$` | GA DDL for multi-tool Cortex Agent |
| Observability | DMFs (`NULL_COUNT`, `ROW_COUNT`, `DUPLICATE_COUNT`) + Alerts | Native, no third-party tools |
| Notifications | Snowflake Webhook Notification Integration | Slack delivery in <30s |

---

## Scripts Reference

### `01_setup_schema.sql`

Creates all schemas, staging tables, and synthetic demo data.

| Object | Rows |
|--------|------|
| TERRITORY_DIM | 5 |
| FUND_DIM | 5 |
| ADVISOR_DIM | 200 |
| ADVISOR_EVENTS_RAW | ~3000 |
| FUND_FLOWS_RAW | ~4000 |
| SFDC_OPPORTUNITY | ~500 |

**Safe to re-run.** All tables use `CREATE OR REPLACE`. Data is re-inserted each run (no deduplication in dev).

### `02_semantic_view.yaml`

YAML semantic model for Cortex Analyst. Contains:
- 3 entities: `ADVISOR_ENGAGEMENT_SCORE`, `FUND_FLOW_ATTRIBUTION`, `TERRITORY_HEAT_MAP`
- 5 metrics: `total_distribution_aum`, `avg_engagement_score`, `total_net_flows`, `at_risk_advisors`, `total_pipeline_value`
- 3 filters, 10 verified queries (VQRs)

**Must be uploaded to stage before the agent can answer questions:**
```bash
snow stage copy scripts/02_semantic_view.yaml \
  @ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/ --connection your_connection --overwrite
```

### `03_cortex_agent.sql`

Creates:
1. `AGENT_STAGE` — stage for YAML artifacts
2. `FUND_DOCS_SEARCH` — Cortex Search on fund documentation (TARGET_LAG = 1h)
3. `distribution_insights_agent` — Cortex Agent with 2 tools + system prompt
4. Tests via `SNOWFLAKE.CORTEX.COMPLETE('mistral-7b', ...)`

**Note:** The agent's `DistributionAnalyst` tool references the YAML via `semantic_model_file`. Upload the YAML to stage first.

### `04_dynamic_tables.sql`

Creates 3 Dynamic Tables in dependency order. All use `WAREHOUSE = INGEST`.

| Table | Target Lag | Sources |
|-------|-----------|---------|
| `ADVISOR_ENGAGEMENT_SCORE` | 1 hour | STAGING tables only |
| `FUND_FLOW_ATTRIBUTION` | 1 day | STAGING + ADVISOR_ENGAGEMENT_SCORE |
| `TERRITORY_HEAT_MAP` | 4 hours | STAGING + ADVISOR_ENGAGEMENT_SCORE |

**Note on refresh mode:** All 3 tables currently run in FULL refresh mode because:
1. They reference `CURRENT_DATE()` in the SELECT clause (labeling only, not in WHERE)
2. Change tracking on Dynamic Tables requires the `IMMUTABLE` constraint

FULL refresh is fine for demo; for production add `CLUSTER BY` on source tables and remove any non-deterministic functions.

### `05_alerts_observability.sql`

Creates in order:
1. `EVENTS` event table (using `CREATE OR REPLACE EVENT TABLE`)
2. 2 Slack Webhook Notification Integrations
3. DMFs on `ADVISOR_EVENTS_RAW` and `FUND_FLOWS_RAW`
4. 5 Snowflake Alerts (all set to RESUME)

| Alert | Schedule | Condition |
|-------|----------|-----------|
| `ALERT_ADVISOR_EVENTS_STALE` | 5 MIN | Events table hasn't received data in 30 min |
| `ALERT_HIGH_ATTRITION_RISK` | 60 MIN | >20% of Platinum advisors have engagement <30 |
| `ALERT_FUND_OUTFLOWS` | CRON 0 6 UTC | Net fund flows < -$1M today |
| `ALERT_AI_BUDGET_BREACH` | 240 MIN | Cortex AI daily credits > 8 (80% of 10 limit) |
| `ALERT_DT_FULL_REFRESH` | 30 MIN | Any DT in DISTRIBUTION did a FULL refresh last hour |

**Note on FRESHNESS DMF:** `SNOWFLAKE.CORE.FRESHNESS` requires `EXECUTE DATA METRIC FUNCTION` privilege not available on all roles. Script uses `NULL_COUNT` on timestamp columns as a proxy. Grant the privilege via ACCOUNTADMIN to enable FRESHNESS in production.

---

## Deployment

### Streamlit in Snowflake

```bash
./manage.sh deploy
```

Or manually:
```bash
snow streamlit deploy \
  --name DISTRIBUTION_INSIGHTS \
  --database ANALYTICS_DEV_DB \
  --schema DISTRIBUTION \
  --query-warehouse INGEST \
  --main-file dashboard/dashboard.py \
  --replace \
  --connection your_connection
```

The dashboard uses `_snowflake.send_snow_api_request()` to call the Cortex Analyst REST API — this only works inside Streamlit in Snowflake (not `streamlit run` locally).

For **local development**, the dashboard falls back gracefully with an error message in the "Ask Cortex Analyst" tab.

---

## Configuration

All settings live in `manage.sh` and `AGENTS.md`:

| Setting | Value |
|---------|-------|
| Connection | `your_connection` |
| Database | `ANALYTICS_DEV_DB` (never PROD) |
| Schema | `DISTRIBUTION` |
| Warehouse | `INGEST` |
| Slack webhook | `#edge-alerts` channel |
| AI model | `mistral-7b` (smallest model, lowest cost) |

---

## Known Issues and Limitations

### Dynamic Tables — FULL refresh mode
All 3 Dynamic Tables run in FULL refresh mode. They print a note on creation:
> *"FULL refresh mode was selected because Change tracking is not supported on dynamic tables..."*

This is expected in this account configuration. FULL refresh still works correctly — it just recomputes the entire table on each refresh cycle rather than incrementally processing new rows. For production, add `DATA_RETENTION_TIME_IN_DAYS` and enable change tracking on source tables.

### SNOWFLAKE.CORE.FRESHNESS DMF
The FRESHNESS DMF requires elevated privileges (`EXECUTE DATA METRIC FUNCTION`) not available on the `SALES_ENGINEER` role in SNOWHOUSE. The script uses `NULL_COUNT` on timestamp columns instead. To use FRESHNESS in production, run as ACCOUNTADMIN:
```sql
GRANT EXECUTE DATA METRIC FUNCTION ON ACCOUNT TO ROLE <your_role>;
```

### DMF results — first measurement cycle delay
`SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS` appears empty after initial setup. DMFs need one measurement cycle to fire. Results appear within the configured schedule (`TRIGGER_ON_CHANGES` or `60 MINUTE`).

### Alert history — ACCOUNT_USAGE lag
`SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY` has a 1-2 hour ingestion lag. `manage.sh status` and the dashboard will show "No data" for recently fired alerts. The correct columns are `NAME`, `SCHEMA_NAME`, `SCHEDULED_TIME`, `STATE` (not `ALERT_NAME`, `CONDITION_QUERY_STATUS`, `ALERT_SCHEMA_NAME`).

### CORTEX_USAGE_HISTORY not available in all accounts
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY` requires a specific ACCOUNTADMIN grant. The dashboard handles this gracefully — the Cortex AI usage section shows an info message instead of a data table when the view is unavailable.

### Cortex Analyst — YAML must be staged
The agent's `DistributionAnalyst` tool requires the semantic view YAML to be uploaded to `@ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/`. If the YAML is not staged, the tool returns a file-not-found error when queried. See Quick Start step 3.

### Dashboard — Cortex Analyst only works in Streamlit in Snowflake
The `_snowflake.send_snow_api_request()` function used to call the Cortex Analyst REST API is only available inside Streamlit in Snowflake. Running `streamlit run dashboard/dashboard.py` locally shows an error in the "Ask Cortex Analyst" tab. All other tabs work locally if you have a valid Snowflake connection.

### Dashboard — local development requires keypair auth setup
`Session.builder.config("connection_name", ...)` does not resolve `private_key_path` from connections.toml. The dashboard reads connections.toml manually using `tomllib` and resolves the key file directly. Launch locally via:
```bash
./manage.sh run-dashboard   # sets SNOWFLAKE_DEFAULT_CONNECTION_NAME=your_connection
```
Requires `cryptography` package: `pip install cryptography`.

### Synthetic data — advisor AUM is estimated
The `aum_amount` column in `ADVISOR_ENGAGEMENT_SCORE` is estimated from fund flow volume (`total_flow_12m * 0.15`). Replace with actual AUM data in production by joining to a real AUM source table.

---

## Validated Test Results

Run `./manage.sh test` to verify. Expected output:

```
[1] Staging table row counts
ADVISOR_DIM          | 200
ADVISOR_EVENTS_RAW   | 3000
FUND_DIM             | 5
FUND_FLOWS_RAW       | 4000
SFDC_OPPORTUNITY     | 500
TERRITORY_DIM        | 5

[2] Dynamic Table row counts
ADVISOR_ENGAGEMENT_SCORE | 200
FUND_FLOW_ATTRIBUTION    | ~4000
TERRITORY_HEAT_MAP       | 5

[3] Advisor Engagement Score sample (top 5 by AUM — all have engagement scores)
[4] Territory Heat Map (5 territories with heat scores)
[5] Agent stage exists
[6] Alerts status (5 alerts, all STARTED)
```

---

## Extending the Demo

### Add real Salesforce Zero-Copy

Replace the mock `SFDC_OPPORTUNITY` and `SFDC_ACCOUNT` tables with actual Snowflake for Salesforce shares:
1. Enable Snowflake for Salesforce connector in both orgs (Snowsight UI)
2. Map Salesforce objects to Snowflake share
3. Update references in `04_dynamic_tables.sql` from `ANALYTICS_DEV_DB.STAGING.SFDC_*` to the share path
4. No code changes needed in Dynamic Tables — same column names

### Add Snowpipe V2 real streaming

Replace the batch-inserted `ADVISOR_EVENTS_RAW` with live Snowpipe V2:
```bash
# See the ssv2-quickstart skill for a complete setup
# SDK reference: docs.snowflake.com/en/user-guide/snowpipe-streaming
```

### Add more Cortex Analyst VQRs

Edit `scripts/02_semantic_view.yaml`, add entries to the `verified_queries` section, re-upload to stage, and the agent will immediately use the new queries:
```bash
snow stage copy scripts/02_semantic_view.yaml \
  @ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/ --connection your_connection --overwrite
```

No agent redeployment needed — the agent reads the YAML from stage at query time.

---

## References

- [Snowpipe Streaming V2](https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance)
- [Dynamic Tables](https://docs.snowflake.com/en/user-guide/dynamic-tables-intro)
- [Cortex Analyst](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-analyst)
- [Cortex Agents (CREATE AGENT)](https://docs.snowflake.com/en/sql-reference/sql/create-agent)
- [Cortex Search](https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-search/cortex-search-overview)
- [Data Metric Functions](https://docs.snowflake.com/en/user-guide/data-quality-intro)
- [Snowflake Alerts](https://docs.snowflake.com/en/user-guide/alerts)
- [Streamlit in Snowflake](https://docs.snowflake.com/en/developer-guide/streamlit/about-streamlit)
- [Notification Integrations (Webhook)](https://docs.snowflake.com/en/sql-reference/sql/create-notification-integration)
