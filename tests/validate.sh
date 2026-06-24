#!/usr/bin/env bash
# tests/validate.sh — Smoke tests for Distribution Insights demo
#
# Usage:  ./tests/validate.sh
# Prereq: SNOWFLAKE_CONNECTION env var set, ./manage.sh build already run
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

CONN="${SNOWFLAKE_CONNECTION:-your_connection}"
PASS=0
FAIL=0
RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m'

check() {
  local label="$1"
  local sql="$2"
  if snow sql --query "$sql" --connection "$CONN" > /dev/null 2>&1; then
    echo -e "${GRN}PASS${NC}  $label"
    ((PASS++)) || true
  else
    echo -e "${RED}FAIL${NC}  $label"
    ((FAIL++)) || true
  fi
}

check_rows() {
  local label="$1"
  local sql="$2"
  local count
  count=$(snow sql --query "$sql" --connection "$CONN" 2>/dev/null | grep -Eo '[0-9]+' | tail -1 || true)
  if [[ "${count:-0}" -gt 0 ]]; then
    echo -e "${GRN}PASS${NC}  $label (${count} rows)"
    ((PASS++)) || true
  else
    echo -e "${RED}FAIL${NC}  $label (0 rows)"
    ((FAIL++)) || true
  fi
}

echo "=== Distribution Insights — Smoke Tests ==="
echo "Connection: $CONN"
echo ""

# ── Schema objects ────────────────────────────────────────────────────────────
echo "--- Schema Objects ---"
check "ANALYTICS_DEV_DB exists" "SHOW DATABASES LIKE 'ANALYTICS_DEV_DB'"
check "STAGING schema exists"   "SHOW SCHEMAS LIKE 'STAGING' IN DATABASE ANALYTICS_DEV_DB"
check "DISTRIBUTION schema"     "SHOW SCHEMAS LIKE 'DISTRIBUTION' IN DATABASE ANALYTICS_DEV_DB"

# ── Staging tables ────────────────────────────────────────────────────────────
echo ""
echo "--- Staging Tables ---"
check_rows "ADVISOR_DIM"        "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM"
check_rows "TERRITORY_DIM"      "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM"
check_rows "FUND_DIM"           "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.FUND_DIM"
check_rows "ADVISOR_EVENTS_RAW" "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW"
check_rows "SFDC_OPPORTUNITY"   "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.SFDC_OPPORTUNITY"

# ── Dynamic Tables ────────────────────────────────────────────────────────────
echo ""
echo "--- Dynamic Tables ---"
check_rows "ADVISOR_ENGAGEMENT_SCORE" "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE"
check_rows "FUND_FLOW_ATTRIBUTION"    "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION"
check_rows "TERRITORY_HEAT_MAP"       "SELECT COUNT(*) FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP"

# ── Semantic View ─────────────────────────────────────────────────────────────
echo ""
echo "--- Semantic View ---"
check "DISTRIBUTION_INSIGHTS_SV exists" "SHOW SEMANTIC VIEWS LIKE 'DISTRIBUTION_INSIGHTS_SV' IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION"

# ── Cortex Agent ─────────────────────────────────────────────────────────────
echo ""
echo "--- Cortex Agent ---"
check "distribution_insights_agent exists" "SHOW AGENTS LIKE 'DISTRIBUTION_INSIGHTS_AGENT' IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION"

# ── Python syntax check (dashboard + ingest app) ─────────────────────────────
echo ""
echo "--- Code ---"
if python3 -m py_compile dashboard/dashboard.py 2>/dev/null; then
  echo -e "${GRN}PASS${NC}  dashboard/dashboard.py compiles"
  ((PASS++)) || true
else
  echo -e "${RED}FAIL${NC}  dashboard/dashboard.py has syntax errors"
  ((FAIL++)) || true
fi

# ── Python syntax (ingest app) ───────────────────────────────────────────────
echo ""
echo "--- Ingest App ---"
for pyfile in app/config.py app/mqtt_producer.py app/snowpipe_consumer.py; do
  if python3 -m py_compile "$pyfile" 2>/dev/null; then
    echo -e "${GRN}PASS${NC}  $pyfile compiles"
    ((PASS++)) || true
  else
    echo -e "${RED}FAIL${NC}  $pyfile has syntax errors"
    ((FAIL++)) || true
  fi
done
if [[ -f "app/.env.example" ]]; then
  echo -e "${GRN}PASS${NC}  app/.env.example present"
  ((PASS++)) || true
else
  echo -e "${RED}FAIL${NC}  app/.env.example missing"
  ((FAIL++)) || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
