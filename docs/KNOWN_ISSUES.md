# Known Issues and Workarounds

## Resolved Issues (Fixed in Codebase)

| Issue | Status | Fix |
|---|---|---|
| Dashboard empty data — `= CURRENT_DATE()` filters miss yesterday's DT data | **Fixed** | All filters changed to `= (SELECT MAX(score_date) FROM ...)` |
| `NameError: name 'session' is not defined` in notebooks | **Fixed** | Setup cell moved to index 0; keypair auth pattern added |
| `invalid identifier 'ADVISOR_TIER'` in VQR SQL | **Fixed** | Semantic view rebuilt with FACTS clause; dim names aligned to physical columns |
| `Session.builder.config("connection_name", ...)` doesn't resolve `private_key_path` | **Fixed** | Manual `tomllib` read + `load_pem_private_key()` in dashboard and local notebooks |
| `INFORMATION_SCHEMA.DYNAMIC_TABLES` doesn't exist | **Fixed** | Direct `COUNT(*)` on each DT; `SHOW DYNAMIC TABLES` for metadata |
| `SNOWFLAKE.CORE.FRESHNESS` requires elevated privilege | **Fixed** | Replaced with `NULL_COUNT` on timestamp column |
| `SCHEDULE = '1 HOUR'` invalid in alerts | **Fixed** | Use `'60 MINUTE'`, `'240 MINUTE'`, or `USING CRON 0 6 * * * UTC` |
| VQR SQL referenced physical tables instead of logical aliases | **Fixed** | All VQR SQL uses `__advisor_eng`, `__fund_flows`, `__territory` |
| `CREATE TABLE ... EVENTS` for event table | **Fixed** | `CREATE OR REPLACE EVENT TABLE` required |
| `WEBHOOK_HEADERS` required when `WEBHOOK_BODY_TEMPLATE` set | **Fixed** | Added `WEBHOOK_HEADERS = ('Content-Type'='application/json')` |
| `ROWS` is a Snowflake reserved keyword | **Fixed** | Renamed to `row_count` everywhere |
| `CREATE CORTEX AGENT` invalid DDL | **Fixed** | Correct syntax: `CREATE AGENT` (no CORTEX prefix) |
| `WAREHOUSE` property invalid on agent | **Fixed** | Removed; warehouse goes in `tool_resources.execution_environment` |
| Agent spec: `execution_environment` missing from `tool_resources` | **Fixed** | Added `execution_environment: {type: warehouse, warehouse: INGEST}` |
| `SNOWFLAKE.CORTEX.ANALYST()` SQL function doesn't exist | **Fixed** | Replaced with REST API call via `_snowflake.send_snow_api_request()` or `urllib.request` |

---

## Active Known Issues

### 1. snowpipe-streaming SDK JWT failure on org-based accounts (390144)

**Symptom:** Consumer fails with `HTTP 401, error_code=390144, message=JWT token is invalid` on `get_subdomain_name`.

**Root cause:** The `snowpipe-streaming` Python SDK (all versions including v1.6.0) uses a Rust core that automatically **uppercases** the account identifier in the JWT `iss` claim (e.g. `SFSENORTHAMERICA-TSPANN-AWS1`). However, the Snowflake SSv2 `/v2/streaming/hostname` endpoint requires the account in **lowercase** (`sfsenorthamerica-tspann-aws1`) for org-based account identifiers. A manually-built Python JWT with lowercase account returns HTTP 200 to the same endpoint, confirming the auth mechanism is correct — only the SDK's account casing is wrong.

**Current fix:** The consumer uses `snowflake-connector-python` for SQL INSERT operations. The connector handles account case correctly (proven by normal `snow sql` usage), and delivers real-time MQTT→Snowflake inserts with sub-second latency.

**Future fix:** When the SDK's Rust core is updated to preserve lowercase account identifiers, re-enable the `StreamingIngestClient` path in `app/snowpipe_consumer.py` (currently commented out).

**Track:** https://github.com/snowflakedb/snowflake-ingest-python

**Symptom:** Alert History tab shows 0 rows even after alerts have run.

**Cause:** `SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY` has a 1-2 hour ingestion lag.

**Workaround:** Wait 1-2 hours after alerts fire, then re-check.

---

### 2. DMF First-Cycle Delay

**Symptom:** DMF Results tab is empty immediately after setup.

**Cause:** DMFs run on a schedule; results are not available until the first measurement cycle completes.

**Workaround:** Run `EXECUTE DATA METRIC FUNCTION` manually on the tables or wait for the first scheduled cycle.

---

### 3. Cortex Usage History Not Available in All Accounts

**Symptom:** Cortex AI Usage section in Data Health tab shows info banner instead of data.

**Cause:** `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY` requires a specific grant.

**Workaround:** Grant `IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO ROLE <your_role>` or check with your Snowflake admin.

---

### 4. Local Dashboard Requires `SNOWFLAKE_CONNECTION` Set

**Symptom:** Dashboard shows "No Snowflake session" error.

**Cause:** `SNOWFLAKE_DEFAULT_CONNECTION_NAME` env var not set before running Streamlit.

**Fix:**
```bash
# Use manage.sh which sets it automatically:
./manage.sh run-dashboard

# Or set manually:
export SNOWFLAKE_CONNECTION=your_connection
streamlit run dashboard/dashboard.py
```

---

### 5. Dynamic Table Lag Dependency Constraint

**Symptom:** `TERRITORY_HEAT_MAP` would fail if it depended on `FUND_FLOW_ATTRIBUTION` (1d lag) while having only 4h lag itself.

**Design decision:** `TERRITORY_HEAT_MAP` reads `FUND_FLOWS_RAW` (staging table, no lag) directly instead of `FUND_FLOW_ATTRIBUTION`. This avoids the constraint that child DT lag must be ≥ parent DT lag.
