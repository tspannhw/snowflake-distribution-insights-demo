#!/usr/bin/env bash
# manage.sh — Distribution Insights Build, Test, and Deploy
# Usage: ./manage.sh [build|test|run-dashboard|deploy|clean|status]
# Run from anywhere — script always resolves its own directory as the project root.
set -euo pipefail

# ── Resolve project root regardless of where the script is invoked from ──────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PROJECT="distribution_insights"
DB="ANALYTICS_DEV_DB"
SCHEMA="DISTRIBUTION"
WAREHOUSE="INGEST"
CONNECTION="${SNOWFLAKE_CONNECTION:-your_connection}"
DASHBOARD="dashboard/dashboard.py"
STREAMLIT_NAME="DISTRIBUTION_INSIGHTS"
APP_DIR="app"

# Helper: run a SQL file and echo its name
run_sql_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "ERROR: SQL file not found: $f" >&2
    exit 1
  fi
  echo "  → executing $f"
  snow sql -f "$f" --connection "$CONNECTION"
}

# Helper: run a single SQL statement (avoids multiline shell quoting issues)
run_sql() {
  snow sql -q "$1" --connection "$CONNECTION"
}

case "${1:-help}" in

  # ── BUILD ─────────────────────────────────────────────────────────────────
  build)
    echo "=== Building $PROJECT ==="
    echo "Step 1/4: Schema and seed data"
    run_sql_file scripts/01_setup_schema.sql
    echo "Step 2/4: Dynamic Tables"
    run_sql_file scripts/04_dynamic_tables.sql
    echo "Step 3/4: Cortex Agent (requires stage upload first — see deploy)"
    run_sql_file scripts/03_cortex_agent.sql
    echo "Step 4/4: Alerts and Observability"
    run_sql_file scripts/05_alerts_observability.sql
    echo "=== Build complete ==="
    ;;

  # ── TEST ──────────────────────────────────────────────────────────────────
  test)
    echo "=== Testing $PROJECT ==="
    echo ""

    echo "[1] Staging table row counts"
    run_sql "SELECT 'TERRITORY_DIM' AS tbl, COUNT(*) AS row_count FROM ${DB}.STAGING.TERRITORY_DIM
             UNION ALL SELECT 'FUND_DIM',            COUNT(*) FROM ${DB}.STAGING.FUND_DIM
             UNION ALL SELECT 'ADVISOR_DIM',          COUNT(*) FROM ${DB}.STAGING.ADVISOR_DIM
             UNION ALL SELECT 'ADVISOR_EVENTS_RAW',   COUNT(*) FROM ${DB}.STAGING.ADVISOR_EVENTS_RAW
             UNION ALL SELECT 'FUND_FLOWS_RAW',        COUNT(*) FROM ${DB}.STAGING.FUND_FLOWS_RAW
             UNION ALL SELECT 'SFDC_OPPORTUNITY',       COUNT(*) FROM ${DB}.STAGING.SFDC_OPPORTUNITY
             ORDER BY 1;"
    echo ""

    echo "[2] Dynamic Table row counts (confirms tables exist and have data)"
    run_sql "SELECT 'ADVISOR_ENGAGEMENT_SCORE' AS dt, COUNT(*) AS row_count
             FROM ${DB}.${SCHEMA}.ADVISOR_ENGAGEMENT_SCORE
             UNION ALL
             SELECT 'FUND_FLOW_ATTRIBUTION', COUNT(*)
             FROM ${DB}.${SCHEMA}.FUND_FLOW_ATTRIBUTION
             UNION ALL
             SELECT 'TERRITORY_HEAT_MAP', COUNT(*)
             FROM ${DB}.${SCHEMA}.TERRITORY_HEAT_MAP
             ORDER BY 1;"
    echo ""

    echo "[3] Advisor Engagement Score sample"
    run_sql "SELECT advisor_name, advisor_tier, territory_name,
                    ROUND(engagement_score,1) AS score,
                    ROUND(aum_amount/1e6,2) AS aum_m
             FROM ${DB}.${SCHEMA}.ADVISOR_ENGAGEMENT_SCORE
             ORDER BY aum_amount DESC LIMIT 5;"
    echo ""

    echo "[4] Territory Heat Map"
    run_sql "SELECT territory_name, advisor_count,
                    ROUND(total_aum/1e6,1) AS total_aum_m,
                    ROUND(avg_engagement_score,1) AS avg_eng,
                    at_risk_advisor_count,
                    ROUND(territory_heat_score,1) AS heat_score
             FROM ${DB}.${SCHEMA}.TERRITORY_HEAT_MAP
             ORDER BY heat_score DESC;"
    echo ""

    echo "[5] Agent stage exists (deploy YAML here before Cortex Analyst works)"
    run_sql "SHOW STAGES IN SCHEMA ${DB}.${SCHEMA};"
    echo ""

    echo "[6] Alerts status (run 05_alerts_observability.sql first)"
    run_sql "SHOW ALERTS IN SCHEMA ${DB}.${SCHEMA};" || echo "  (no alerts yet — run ./manage.sh build first)"
    echo ""

    echo "=== All tests complete ==="
    ;;

  # ── STATUS ────────────────────────────────────────────────────────────────
  status)
    echo "=== Status: $PROJECT ==="
    echo ""
    echo "-- Dynamic Tables (direct count — refresh status via: SHOW DYNAMIC TABLES IN SCHEMA ${DB}.${SCHEMA}) --"
    run_sql "SELECT 'ADVISOR_ENGAGEMENT_SCORE' AS dt, COUNT(*) AS row_count
             FROM ${DB}.${SCHEMA}.ADVISOR_ENGAGEMENT_SCORE
             UNION ALL SELECT 'FUND_FLOW_ATTRIBUTION', COUNT(*) FROM ${DB}.${SCHEMA}.FUND_FLOW_ATTRIBUTION
             UNION ALL SELECT 'TERRITORY_HEAT_MAP', COUNT(*) FROM ${DB}.${SCHEMA}.TERRITORY_HEAT_MAP
             ORDER BY 1;"
    echo ""
    echo "-- Alert health (last 6h — ACCOUNT_USAGE has ~1h lag; 'No data' is normal if alerts haven't fired yet) --"
    run_sql "SELECT NAME, SCHEMA_NAME, SCHEDULED_TIME, STATE
             FROM SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY
             WHERE SCHEMA_NAME = '${SCHEMA}'
               AND SCHEDULED_TIME >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
             ORDER BY SCHEDULED_TIME DESC LIMIT 20;"
    echo ""
    echo "-- DMF results for DISTRIBUTION tables (last 4h — results appear after first measurement cycle) --"
    run_sql "SELECT TABLE_SCHEMA, TABLE_NAME, METRIC_NAME, VALUE, MEASUREMENT_TIME
             FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
             WHERE TABLE_DATABASE = '${DB}'
               AND TABLE_SCHEMA IN ('STAGING', 'DISTRIBUTION')
               AND MEASUREMENT_TIME >= DATEADD('hour', -4, CURRENT_TIMESTAMP())
             ORDER BY MEASUREMENT_TIME DESC LIMIT 20;"
    ;;

  # ── SETUP INGEST (install Python deps for MQTT + SSv2 pipeline) ─────────────
  setup-ingest)
    echo "=== Setting up ingest pipeline venv ==="
    bash "$APP_DIR/setup.sh"
    ;;

  # ── RUN PRODUCER (MQTT synthetic data generator) ─────────────────────────
  run-producer)
    echo "=== Starting MQTT Producer ==="
    if [[ ! -f "$APP_DIR/.env" ]]; then
      echo "ERROR: $APP_DIR/.env not found." >&2
      echo "  cp $APP_DIR/.env.example $APP_DIR/.env && vim $APP_DIR/.env" >&2
      exit 1
    fi
    if [[ ! -d "$APP_DIR/.venv" ]]; then
      echo "ERROR: venv not found. Run: ./manage.sh setup-ingest" >&2
      exit 1
    fi
    "$APP_DIR/.venv/bin/python" "$APP_DIR/mqtt_producer.py"
    ;;

  # ── RUN CONSUMER (MQTT → Snowpipe Streaming V2) ───────────────────────────
  run-consumer)
    echo "=== Starting MQTT → Snowpipe Streaming V2 Consumer ==="
    if [[ ! -f "$APP_DIR/.env" ]]; then
      echo "ERROR: $APP_DIR/.env not found." >&2
      echo "  cp $APP_DIR/.env.example $APP_DIR/.env && vim $APP_DIR/.env" >&2
      exit 1
    fi
    if [[ ! -d "$APP_DIR/.venv" ]]; then
      echo "ERROR: venv not found. Run: ./manage.sh setup-ingest" >&2
      exit 1
    fi
    "$APP_DIR/.venv/bin/python" "$APP_DIR/snowpipe_consumer.py"
    ;;

  # ── RUN INGEST (producer + consumer in parallel, Ctrl+C stops both) ──────
  run-ingest)
    echo "=== Starting full ingest pipeline ==="
    for f in "$APP_DIR/.env" ; do
      if [[ ! -f "$f" ]]; then
        echo "ERROR: $f not found. Run: cp $APP_DIR/.env.example $APP_DIR/.env" >&2
        exit 1
      fi
    done
    if [[ ! -d "$APP_DIR/.venv" ]]; then
      echo "ERROR: venv not found. Run: ./manage.sh setup-ingest" >&2
      exit 1
    fi
    echo "Starting consumer (background)..."
    "$APP_DIR/.venv/bin/python" "$APP_DIR/snowpipe_consumer.py" &
    CONSUMER_PID=$!
    echo "Consumer PID: $CONSUMER_PID"
    sleep 2  # give consumer time to connect before producer starts
    echo "Starting producer..."
    "$APP_DIR/.venv/bin/python" "$APP_DIR/mqtt_producer.py" || true
    echo "Producer finished. Stopping consumer (PID $CONSUMER_PID)..."
    kill "$CONSUMER_PID" 2>/dev/null || true
    wait "$CONSUMER_PID" 2>/dev/null || true
    echo "=== Ingest pipeline stopped ==="
    ;;

  # ── RUN DASHBOARD LOCALLY ─────────────────────────────────────────────────
  run-dashboard)
    echo "=== Running Streamlit Dashboard Locally ==="
    if [[ ! -f "$DASHBOARD" ]]; then
      echo "ERROR: $DASHBOARD not found" >&2
      exit 1
    fi
    SNOWFLAKE_DEFAULT_CONNECTION_NAME="$CONNECTION" streamlit run "$DASHBOARD"
    ;;

  # ── DEPLOY ────────────────────────────────────────────────────────────────
  deploy)
    echo "=== Deploying to Snowflake ==="

    echo "Uploading semantic view YAML to stage..."
    # Create stage if it doesn't exist yet
    run_sql "CREATE STAGE IF NOT EXISTS ${DB}.${SCHEMA}.AGENT_STAGE
               DIRECTORY = (ENABLE = TRUE)
               COMMENT = 'Agent artifacts stage';"
    snow stage copy scripts/02_semantic_view.yaml \
      "@${DB}.${SCHEMA}.AGENT_STAGE/" \
      --connection "$CONNECTION" \
      --overwrite

    echo "Deploying Streamlit dashboard..."
    snow streamlit deploy \
      --name "$STREAMLIT_NAME" \
      --database "$DB" \
      --schema "$SCHEMA" \
      --query-warehouse "$WAREHOUSE" \
      --main-file "$DASHBOARD" \
      --replace \
      --connection "$CONNECTION"

    echo ""
    echo "=== Deployment complete ==="
    snow streamlit describe "$STREAMLIT_NAME" \
      --database "$DB" --schema "$SCHEMA" \
      --connection "$CONNECTION"
    ;;

  # ── CLEAN ─────────────────────────────────────────────────────────────────
  clean)
    echo "=== Suspending alerts (safe teardown) ==="
    # Suspend each alert individually so one failure doesn't abort the rest
    for alert in \
      ALERT_ADVISOR_EVENTS_STALE \
      ALERT_HIGH_ATTRITION_RISK \
      ALERT_FUND_OUTFLOWS \
      ALERT_AI_BUDGET_BREACH \
      ALERT_DT_FULL_REFRESH
    do
      run_sql "ALTER ALERT IF EXISTS ${DB}.${SCHEMA}.${alert} SUSPEND;" || true
      echo "  suspended: $alert"
    done
    echo "=== Clean complete. Run './manage.sh build' to restart. ==="
    ;;

  # ── HELP ──────────────────────────────────────────────────────────────────
  help|*)
    cat << 'HELP'
Distribution Insights — manage.sh

Usage: ./manage.sh <command>

Commands:
  setup-ingest    Install Python venv for MQTT producer and SSv2 consumer.
                 Creates app/.venv with paho-mqtt, snowpipe-streaming, faker.

  run-producer   Publish synthetic advisor events to MQTT every 5 seconds
                 for 10 minutes. Requires app/.env to be configured.

  run-consumer   Subscribe to MQTT topic and stream rows into
                 ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW via
                 Snowpipe Streaming V2. Requires app/.env.

  run-ingest     Run producer + consumer together (producer in foreground,
                 consumer in background). Ctrl+C stops both.

  build          Create all schemas, tables, Dynamic Tables, Cortex Agent, and Alerts.
                 Safe to re-run (all statements use CREATE OR REPLACE).

  test           Validate row counts, Dynamic Table refresh state, semantic view,
                 and alert status. Exits non-zero on any failure.

  status         Quick health check: DT refresh lag, recent alert fires, DMF results.

  run-dashboard  Start the Streamlit dashboard locally (requires streamlit installed).

  deploy         Upload semantic view YAML to stage and deploy Streamlit to Snowflake.
                 Uses --replace so it is safe to re-run.

  clean          Suspend all alerts without dropping any objects.

Environment:
  Connection : your_connection  (set via SNOWFLAKE_CONNECTION env var or snow CLI config)
  Database   : ANALYTICS_DEV_DB  (never PROD)
  Schema     : DISTRIBUTION
  Warehouse  : INGEST

HELP
    ;;
esac
