# Setup Guide — Distribution Insights Demo

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Snowflake account | Any edition | ANALYTICS_DEV_DB must exist |
| Snowflake CLI (`snow`) | ≥ 3.0 | `brew install snowflake-cli` |
| Python | 3.11+ | For notebooks and local dashboard |
| `uv` | latest | `pip install uv` |
| Keypair auth | — | See below |

---

## Step 1: Keypair Authentication

```bash
# Generate RSA keypair
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.snowflake/keys/snowflake_private_key.p8 -nocrypt
openssl rsa -in ~/.snowflake/keys/snowflake_private_key.p8 -pubout -out ~/.snowflake/keys/snowflake_public_key.pub

# Register public key with Snowflake
# Copy the key content (without header/footer lines)
cat ~/.snowflake/keys/snowflake_public_key.pub

# In Snowsight or SnowSQL:
# ALTER USER <your_user> SET RSA_PUBLIC_KEY='<paste public key here>';
```

---

## Step 2: Configure snow CLI Connection

Add to `~/.snowflake/connections.toml`:

```toml
[your_connection]
account = "<ACCOUNT_IDENTIFIER>"       # e.g. orgname-accountname
user = "<SNOWFLAKE_USER>"
authenticator = "SNOWFLAKE_JWT"
private_key_path = "~/.snowflake/keys/snowflake_private_key.p8"
warehouse = "INGEST"
database = "ANALYTICS_DEV_DB"
schema = "DISTRIBUTION"
```

Test:
```bash
snow connection test --connection your_connection
```

---

## Step 3: Set Environment Variable

```bash
export SNOWFLAKE_CONNECTION=your_connection
```

Add to your shell profile (`~/.zshrc` or `~/.bashrc`) to persist.

---

## Step 4: Build Infrastructure

```bash
# Clone the repo
git clone https://github.com/tspannhw/snowflake-distribution-insights-demo
cd snowflake-distribution-insights-demo

# Build all objects: schemas, tables, Dynamic Tables, Cortex Agent, alerts
./manage.sh build
```

This runs the SQL scripts in order:
1. `scripts/01_setup_schema.sql` — schemas, tables, 200 synthetic advisors
2. `scripts/04_dynamic_tables.sql` — 3 Dynamic Tables
3. `scripts/03_cortex_agent.sql` — Cortex Agent + Cortex Search Service
4. `scripts/06_semantic_view_sql.sql` — Semantic View + Cortex Analyst VQRs
5. `scripts/05_alerts_observability.sql` — DMFs, Alerts (configure webhooks first)

---

## Step 5: Configure Slack Webhooks (Optional)

Before running `05_alerts_observability.sql`, replace the webhook placeholders with your actual webhook URLs:

```bash
# In scripts/05_alerts_observability.sql, find and replace:
# <YOUR_SLACK_WEBHOOK_URL> → your Slack incoming webhook URL
# <YOUR_EDGE_ALERTS_WEBHOOK_URL> → your critical alerts webhook URL

# Get a Slack webhook: https://api.slack.com/messaging/webhooks
```

---

## Step 6: Validate

```bash
./manage.sh test
```

Expected output: all SQL checks pass, Dynamic Tables show non-zero row counts.

---

## Step 7: Run Dashboard Locally

```bash
./manage.sh run-dashboard
# Opens http://localhost:8501
```

---

## Step 8: Deploy to Snowsight (Optional)

```bash
./manage.sh deploy
```

Opens in Snowsight: **Projects → Streamlit → DISTRIBUTION_INSIGHTS**

---

## Step 9: Open Snowflake Notebook (Optional)

```bash
./manage.sh deploy-notebook
```

Opens in Snowsight: **Projects → Notebooks → DISTRIBUTION_INSIGHTS_DEMO**

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| Dashboard shows empty data | DT refreshed yesterday, `= CURRENT_DATE()` filter | Fixed — dashboard uses `MAX(score_date)` |
| `NameError: session` in notebook | Setup cell not first | Run cells top-to-bottom |
| `invalid identifier 'ADVISOR_TIER'` in VQR | Semantic name mismatch | Recreate SV with `06_semantic_view_sql.sql` |
| Alert history empty | `ACCOUNT_USAGE` has 1-2h lag | Wait and re-check |
| DMF results not appearing | First DMF cycle not complete | Schedule DMF and wait one cycle |

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for full list.
