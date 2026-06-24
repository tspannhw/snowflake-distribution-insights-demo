"""
app/snowpipe_consumer.py — MQTT subscriber + Snowpipe Streaming V2 ingest.

Subscribes to the MQTT topic defined in .env / config.py.
Each MQTT message is a JSON advisor event that is streamed into
ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW via the Snowpipe
Streaming V2 High-Performance Architecture.

Key SSv2 concepts:
  - No CREATE PIPE needed. The default pipe "ADVISOR_EVENTS_RAW-streaming"
    is auto-created by Snowflake on the first ingest call.
  - Auth: RSA keypair (JWT). Private key path comes from .env.
  - Channel: one persistent channel per consumer process.
  - Offsets: we use the event_id UUID as the offset token so retries
    are idempotent.

Usage:
    cd app/
    source .venv/bin/activate
    python snowpipe_consumer.py

Or via manage.sh:
    ./manage.sh run-consumer

Snowflake docs:
    https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview
    https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance
"""
import json
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path

import paho.mqtt.client as mqtt

import config  # loads .env automatically

# ── Lazy import of SSv2 SDK ───────────────────────────────────────────────────
try:
    os_env = None  # suppress SDK INFO logging
    import os as _os
    _os.environ.setdefault("SS_LOG_LEVEL", "warn")
    from snowflake.ingest.streaming import StreamingIngestClient
except ImportError:
    print("[consumer] ERROR: snowpipe-streaming SDK not found.")
    print("           Run: pip install snowpipe-streaming")
    print("           Or:  ./manage.sh setup-ingest")
    sys.exit(1)

# ── Global state ──────────────────────────────────────────────────────────────
_stop     = False
_channel  = None
_client_sf = None
_lock     = threading.Lock()
_stats    = {"received": 0, "streamed": 0, "errors": 0}


def _handle_signal(signum, frame):
    global _stop
    print(f"\n[consumer] Signal {signum} received. Draining and shutting down...")
    _stop = True


# ── SSv2 helpers ──────────────────────────────────────────────────────────────

def _build_profile_json() -> str:
    """
    Write a temporary profile.json for the SSv2 SDK.
    The file is placed in a tempdir so it is never committed.
    Returns the path as a string.
    """
    profile = {
        "user":             config.SNOWFLAKE_USER,
        "account":          config.SNOWFLAKE_ACCOUNT,
        "url":              f"https://{config.SNOWFLAKE_ACCOUNT}.snowflakecomputing.com:443",
        "private_key_file": config.SNOWFLAKE_PRIVATE_KEY_PATH,
        "role":             config.SNOWFLAKE_ROLE,
    }
    tmp = tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False, prefix="ssv2_profile_"
    )
    json.dump(profile, tmp)
    tmp.flush()
    tmp.close()
    return tmp.name


def _init_snowflake():
    """Create the SSv2 client and open a channel."""
    global _channel, _client_sf

    profile_path = _build_profile_json()
    print(f"[consumer] SSv2 profile written to {profile_path}")
    print(f"[consumer] Connecting to Snowflake account: {config.SNOWFLAKE_ACCOUNT}")
    print(f"[consumer] Target: {config.SNOWFLAKE_DATABASE}.{config.SNOWFLAKE_SCHEMA}.{config.SNOWFLAKE_TABLE}")
    print(f"[consumer] Pipe:   {config.SNOWFLAKE_PIPE}  (auto-created on first row)")

    _client_sf = StreamingIngestClient(
        "ACME_DIST_CLIENT",
        config.SNOWFLAKE_DATABASE,
        config.SNOWFLAKE_SCHEMA,
        config.SNOWFLAKE_PIPE,
        profile_json=profile_path,
        properties=None,
    )

    channel, status = _client_sf.open_channel("ACME_DIST_CHANNEL")
    _channel = channel
    print(f"[consumer] Channel opened: {status.channel_name}  status={status.status_code}")
    print(f"[consumer] Latest committed offset: {status.latest_committed_offset_token}")


def _row_from_event(event: dict) -> dict:
    """
    Map MQTT event JSON to the ADVISOR_EVENTS_RAW column schema.

    Columns: EVENT_ID, ADVISOR_ID, TERRITORY_ID, EVENT_TYPE,
             EVENT_TIMESTAMP, FUND_ID, AUM_AMOUNT, OPPORTUNITY_ID,
             METADATA, ROW_TIMESTAMP
    """
    return {
        "EVENT_ID":        event.get("event_id"),
        "ADVISOR_ID":      event.get("advisor_id"),
        "TERRITORY_ID":    event.get("territory_id"),
        "EVENT_TYPE":      event.get("event_type"),
        "EVENT_TIMESTAMP": event.get("event_timestamp"),
        "FUND_ID":         event.get("fund_id"),
        "AUM_AMOUNT":      event.get("aum_amount"),
        "OPPORTUNITY_ID":  event.get("opportunity_id"),
        "METADATA":        json.dumps(event.get("metadata", {})),
        "ROW_TIMESTAMP":   event.get("row_timestamp"),
    }


def _stream_row(event: dict):
    """Append one row to Snowflake via SSv2. Thread-safe."""
    global _channel, _stats
    row = _row_from_event(event)
    offset_token = event.get("event_id", str(_stats["received"]))
    try:
        with _lock:
            _channel.append_row(row, offset_token=offset_token)
        _stats["streamed"] += 1
    except Exception as exc:
        _stats["errors"] += 1
        print(f"[consumer] SSv2 error: {exc}")


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
        print(f"[consumer] Bad JSON on topic {msg.topic}: {exc}")
        _stats["errors"] += 1
        return

    _stream_row(event)

    if _stats["received"] % 10 == 0 or _stats["received"] == 1:
        print(f"[consumer] received={_stats['received']}"
              f"  streamed={_stats['streamed']}"
              f"  errors={_stats['errors']}"
              f"  event_type={event.get('event_type')}"
              f"  advisor={event.get('advisor_id')}")


def on_disconnect(client, userdata, disconnect_flags=None, reason_code=None, properties=None):
    if reason_code != 0:
        print(f"[consumer] Unexpected disconnect (reason={reason_code}). Will reconnect.")


def on_subscribe(client, userdata, mid, reason_code_list, properties=None):
    if all(rc == 1 for rc in (reason_code_list or [])):
        print(f"[consumer] Subscription confirmed (mid={mid})")


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global _stop

    signal.signal(signal.SIGINT,  _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    # ── Init Snowflake SSv2 ───────────────────────────────────────────────────
    print("[consumer] Initialising Snowpipe Streaming V2...")
    try:
        _init_snowflake()
    except Exception as exc:
        print(f"[consumer] Failed to initialise SSv2: {exc}")
        print("[consumer] Check your .env credentials and private key path.")
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
    mqtt_client.on_subscribe  = on_subscribe

    if config.MQTT_USE_AUTH:
        mqtt_client.username_pw_set(config.MQTT_USERNAME, config.MQTT_PASSWORD)

    print(f"[consumer] Connecting to MQTT broker {config.MQTT_HOST}:{config.MQTT_PORT}...")
    mqtt_client.connect(config.MQTT_HOST, config.MQTT_PORT, keepalive=config.MQTT_KEEPALIVE)
    mqtt_client.loop_start()

    # ── Event loop ────────────────────────────────────────────────────────────
    print("[consumer] Listening for events. Press Ctrl+C to stop.")
    print()
    status_interval = 30  # print stats every 30 seconds
    last_status     = time.monotonic()

    while not _stop:
        time.sleep(0.5)
        now = time.monotonic()
        if now - last_status >= status_interval:
            s = _channel.get_channel_status() if _channel else None
            committed = s.latest_committed_offset_token if s else "?"
            print(f"[consumer] STATUS  received={_stats['received']}"
                  f"  streamed={_stats['streamed']}"
                  f"  errors={_stats['errors']}"
                  f"  committed_offset={committed}")
            last_status = now

    # ── Drain: wait for SSv2 to commit all in-flight rows ────────────────────
    print("[consumer] Draining SSv2 channel (waiting for committed offset)...")
    try:
        if _channel and _stats["streamed"] > 0:
            _channel.wait_for_commit(
                lambda token: token is not None,
                timeout_seconds=30,
            )
            s = _channel.get_channel_status()
            print(f"[consumer] Final committed offset: {s.latest_committed_offset_token}")
    except Exception as exc:
        print(f"[consumer] Drain warning: {exc}")

    # ── Shutdown ──────────────────────────────────────────────────────────────
    mqtt_client.loop_stop()
    mqtt_client.disconnect()
    if _channel:
        _channel.close()
    if _client_sf:
        _client_sf.close()

    print(f"\n[consumer] Shutdown complete.")
    print(f"           received={_stats['received']}"
          f"  streamed={_stats['streamed']}"
          f"  errors={_stats['errors']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
