#!/usr/bin/env bash
# app/setup.sh — Create Python venv and install ingest pipeline dependencies.
#
# Usage:
#   cd <project-root>
#   ./app/setup.sh
#
# After this runs:
#   source app/.venv/bin/activate
#   python app/mqtt_producer.py
#   python app/snowpipe_consumer.py
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"
REQS="$SCRIPT_DIR/requirements.txt"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"
ENV_FILE="$SCRIPT_DIR/.env"

echo "=== Ingest Pipeline Setup ==="

# ── Python version check ──────────────────────────────────────────────────────
PYTHON=$(command -v python3 || command -v python)
PY_VER=$("$PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
MAJOR="${PY_VER%%.*}"
MINOR="${PY_VER#*.}"
if [[ "$MAJOR" -lt 3 || ( "$MAJOR" -eq 3 && "$MINOR" -lt 9 ) ]]; then
  echo "ERROR: Python 3.9+ required (found $PY_VER)" >&2
  exit 1
fi
echo "Python: $PY_VER ($PYTHON)"

# ── Create venv ───────────────────────────────────────────────────────────────
if [[ ! -d "$VENV" ]]; then
  echo "Creating virtualenv at $VENV..."
  "$PYTHON" -m venv "$VENV"
fi

# ── Install deps ──────────────────────────────────────────────────────────────
echo "Installing dependencies from $REQS..."
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$REQS"

# ── Verify imports ────────────────────────────────────────────────────────────
echo "Verifying imports..."
"$VENV/bin/python" -c "from snowflake.ingest.streaming import StreamingIngestClient; print('  SSv2 SDK: OK')"
"$VENV/bin/python" -c "import paho.mqtt.client; print('  paho-mqtt: OK')"
"$VENV/bin/python" -c "from faker import Faker; print('  faker:     OK')"
"$VENV/bin/python" -c "from dotenv import load_dotenv; print('  dotenv:    OK')"

# ── .env check ────────────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo ""
  echo "NOTICE: $ENV_FILE not found."
  echo "  Copy and fill in your credentials:"
  echo "    cp app/.env.example app/.env"
  echo "    vim app/.env   # fill in SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, MQTT_PASSWORD, etc."
  echo ""
else
  echo "  .env:      found ($ENV_FILE)"
fi

echo ""
echo "=== Setup complete ==="
echo "Activate venv:  source app/.venv/bin/activate"
echo "Run producer:   ./manage.sh run-producer"
echo "Run consumer:   ./manage.sh run-consumer"
echo "Run both:       ./manage.sh run-ingest"
