"""
app/snowpipe_consumer.py — MQTT subscriber + Snowflake ingest via connector.

Subscribes to the MQTT topic defined in .env / config.py.
Each MQTT message is a JSON advisor event inserted into
ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW via snowflake-connector-python.

Why connector instead of snowpipe-streaming SDK?
  The snowpipe-streaming SDK v1.x has a bug for org-based Snowflake accounts
  (format: <org>-<account>). The Rust JWT generator always uppercases the
  account identifier in the JWT `iss` claim
  (e.g. SFSENORTHAMERICA-TSPANN-AWS1 instead of sfsenorthamerica-tspann-aws1),
  but the SSv2 /v2/streaming/hostname endpoint requires lowercase, causing
  HTTP 401 error_code=390144 "JWT token is invalid" on every request.
  A manually-built Python JWT with lowercase account returns HTTP 200 to the
  same endpoint — confirming the auth mechanism is correct, only the SDK's
  account casing is wrong. Until the SDK Rust core is fixed, we use the
  snowflake-connector-python (which handles account case correctly) for inserts.

Functional behaviour is identical: MQTT messages are consumed in real-time and
inserted into Snowflake within milliseconds.

Usage:
    cd huddledatascience/
    ./manage.sh run-consumer

Docs:
    https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview
    https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect
"""
import json
import signal
import sys
import threading
import time
import tomllib
import os
from pathlib import Path

import paho.mqtt.client as mqtt
from cryptography.hazmat.primitives.serialization import load_pem_private_key
import snowflake.connector

import config  # loads .env automatically

# ── Global state ──────────────────────────────────────────────────────────────
_stop     = False
_sf_conn  = None
_lock     = threading.Lock()
_stats    = {"received": 0, "inserted": 0, "errors": 0}

INSERT_SQL = (
    f"INSERT INTO {config.SNOWFLAKE_DATABASE}.{config.SNOWFLAKE_SCHEMA}.{config.SNOWFLAKE_TABLE} "
    "(EVENT_ID, ADVISOR_ID, TERRITORY_ID, EVENT_TYPE, EVENT_TIMESTAMP, "
    " FUND_ID, AUM_AMOUNT, OPPORTUNITY_ID, METADATA, ROW_TIMESTAMP) "
    "SELECT %s, %s, %s, %s, %s::TIMESTAMP_NTZ, %s, %s, %s, PARSE_JSON(%s), %s::TIMESTAMP_NTZ"
)


def _handle_signal(signum, frame):
    global _stop
    print(f"\n[consumer] Signal {signum} received. Shutting down...")
    _stop = True


# ── Snowflake connector ───────────────────────────────────────────────────────

def _init_snowflake():
    """Create a Snowflake connector connection using keypair auth."""
    global _sf_conn

    # Load keypair from connections.toml (same one that snow CLI uses successfully)
    toml_path = os.path.expanduser("~/.snowflake/connections.toml")
    conn_name = os.environ.get("SNOWFLAKE_CONNECTION", "tspann1")

    print(f"[consumer] Connecting to Snowflake via connector (conn={conn_name})")
    print(f"[consumer] Target: {config.SNOWFLAKE_DATABASE}.{config.SNOWFLAKE_SCHEMA}.{config.SNOWFLAKE_TABLE}")

    try:
        with open(toml_path, "rb") as f:
            toml_cfg = tomllib.load(f)
        sf_cfg = dict(toml_cfg.get(conn_name, {}))
        key_path = os.path.expanduser(sf_cfg.pop("private_key_path", ""))
        with open(key_path, "rb") as f:
            private_key = load_pem_private_key(f.read(), password=None)
        sf_cfg["private_key"] = private_key
        sf_cfg.setdefault("warehouse", config.SNOWFLAKE_WAREHOUSE)
        _sf_conn = snowflake.connector.connect(**sf_cfg)
    except Exception:
        # Fallback: build connection params from .env vars
        print(f"[consumer] connections.toml not found/usable, falling back to .env config")
        key_path = config.SSV2_PRIVATE_KEY_PATH
        with open(key_path, "rb") as f:
            private_key = load_pem_private_key(f.read(), password=None)
        _sf_conn = snowflake.connector.connect(
            account=os.environ["SNOWFLAKE_ACCOUNT"],
            user=os.environ["SNOWFLAKE_USER"],
            private_key=private_key,
            role=config.SNOWFLAKE_ROLE,
            warehouse=config.SNOWFLAKE_WAREHOUSE,
        )

    print(f"[consumer] Connected: {_sf_conn.account}")


def _insert_row(event: dict):
    """Insert one advisor event row into Snowflake. Thread-safe."""
    global _stats
    row = (
        event.get("event_id"),
        event.get("advisor_id"),
        event.get("territory_id"),
        event.get("event_type"),
        event.get("event_timestamp"),
        event.get("fund_id"),
        event.get("aum_amount"),
        event.get("opportunity_id"),
        json.dumps(event.get("metadata", {})),
        event.get("row_timestamp"),
    )
    try:
        with _lock:
            cur = _sf_conn.cursor()
            cur.execute(INSERT_SQL, row)
            cur.close()
        _stats["inserted"] += 1
    except Exception as exc:
        _stats["errors"] += 1
        print(f"[consumer] Insert error: {exc}")


# ── MQTT callbacks ────────────────────────────────────────────────────────────

def on_connect(client, userdata, flags, reason_code, properties=None):
    if reason_code == 0:
        print(f"[consumer] Connected to MQTT broker {config.MQTT_HOST}:{config.MQTT_PORT}")
        client.subscribe(config.MQTT_TOPIC, qos=config.MQTT_QOS)
        print(f"[consumer] Subscribed to topic: {config.MQTT_TOPIC}")
    else:
        print(f"[consumer] MQTT connect failed: reason_code={reason_code}")
        sys.exit(1)


def on_message(client, userdata, msg):
    global _stats
    _stats["received"] += 1
    try:
        event = json.loads(msg.payload.decode("utf-8"))
    except Exception as exc:
        print(f"[consumer] Bad JSON on {msg.topic}: {exc}")
        _stats["errors"] += 1
        return

    _insert_row(event)

    if _stats["received"] % 10 == 0 or _stats["received"] == 1:
        print(f"[consumer] received={_stats['received']}"
              f"  inserted={_stats['inserted']}"
              f"  errors={_stats['errors']}"
              f"  event_type={event.get('event_type')}"
              f"  advisor={event.get('advisor_id')}")


def on_disconnect(client, userdata, disconnect_flags=None, reason_code=None, properties=None):
    if reason_code != 0:
        print(f"[consumer] Unexpected MQTT disconnect (reason={reason_code}). Will reconnect.")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global _stop

    signal.signal(signal.SIGINT,  _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    # ── Init Snowflake ────────────────────────────────────────────────────────
    print("[consumer] Initialising Snowflake connector...")
    try:
        _init_snowflake()
    except Exception as exc:
        print(f"[consumer] Failed to connect to Snowflake: {exc}")
        return 1

    # ── Init MQTT ─────────────────────────────────────────────────────────────
    mqtt_client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=config.MQTT_CLIENT_ID_CONSUMER,
        clean_session=True,
    )
    mqtt_client.on_connect    = on_connect
    mqtt_client.on_message    = on_message
    mqtt_client.on_disconnect = on_disconnect

    if config.MQTT_USE_AUTH:
        mqtt_client.username_pw_set(config.MQTT_USERNAME, config.MQTT_PASSWORD)

    print(f"[consumer] Connecting to MQTT broker {config.MQTT_HOST}:{config.MQTT_PORT}...")
    mqtt_client.connect(config.MQTT_HOST, config.MQTT_PORT, keepalive=config.MQTT_KEEPALIVE)
    mqtt_client.loop_start()

    # ── Event loop ────────────────────────────────────────────────────────────
    print("[consumer] Listening. Press Ctrl+C to stop.")
    print()
    status_interval = 30
    last_status = time.monotonic()

    while not _stop:
        time.sleep(0.5)
        if time.monotonic() - last_status >= status_interval:
            # Quick row count to confirm data is landing
            try:
                with _lock:
                    cur = _sf_conn.cursor()
                    cur.execute(
                        f"SELECT COUNT(*) FROM {config.SNOWFLAKE_DATABASE}"
                        f".{config.SNOWFLAKE_SCHEMA}.{config.SNOWFLAKE_TABLE}"
                    )
                    total = cur.fetchone()[0]
                    cur.close()
                print(f"[consumer] STATUS  received={_stats['received']}"
                      f"  inserted={_stats['inserted']}"
                      f"  errors={_stats['errors']}"
                      f"  table_rows={total}")
            except Exception as exc:
                print(f"[consumer] STATUS error: {exc}")
            last_status = time.monotonic()

    # ── Shutdown ──────────────────────────────────────────────────────────────
    mqtt_client.loop_stop()
    mqtt_client.disconnect()
    if _sf_conn:
        _sf_conn.close()

    print(f"\n[consumer] Shutdown complete.")
    print(f"           received={_stats['received']}"
          f"  inserted={_stats['inserted']}"
          f"  errors={_stats['errors']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
