"""
app/mqtt_producer.py — Synthetic advisor event generator.

Generates one advisor event every PRODUCER_INTERVAL_SECONDS (default 5s)
for PRODUCER_DURATION_MINUTES (default 10 min) and publishes each as a
JSON payload to the MQTT topic defined in .env / config.py.

Usage:
    cd app/
    source .venv/bin/activate
    python mqtt_producer.py

Or via manage.sh:
    ./manage.sh run-producer

Snowflake docs:
    https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview
"""
import json
import random
import signal
import sys
import time
import uuid
from datetime import datetime, timezone

import paho.mqtt.client as mqtt

import config  # loads .env automatically

# ── Synthetic data constants ──────────────────────────────────────────────────
ADVISOR_IDS    = [f"ADV{str(i).zfill(3)}" for i in range(1, 201)]
TERRITORY_IDS  = ["T001", "T002", "T003", "T004", "T005"]
FUND_IDS       = ["FUND001", "FUND002", "FUND003", "FUND004", "FUND005"]
EVENT_TYPES    = ["CALL", "MEETING", "EMAIL", "FUND_PURCHASE", "FUND_REDEMPTION",
                  "AUM_UPDATE", "OPPORTUNITY_CREATED", "OPPORTUNITY_CLOSED"]

# ── State ─────────────────────────────────────────────────────────────────────
_stop = False


def _handle_signal(signum, frame):
    global _stop
    print(f"\n[producer] Caught signal {signum}. Stopping after current message...")
    _stop = True


def make_event() -> dict:
    """Generate one synthetic advisor event matching ADVISOR_EVENTS_RAW schema."""
    event_type = random.choice(EVENT_TYPES)
    advisor_id = random.choice(ADVISOR_IDS)
    territory_id = random.choice(TERRITORY_IDS)
    fund_id = random.choice(FUND_IDS) if event_type in ("FUND_PURCHASE", "FUND_REDEMPTION") else None
    aum_amount = round(random.uniform(500_000, 50_000_000), 2)
    opp_id = f"OPP-{uuid.uuid4().hex[:8].upper()}" if event_type in ("OPPORTUNITY_CREATED", "OPPORTUNITY_CLOSED") else None

    return {
        "event_id":        str(uuid.uuid4()),
        "advisor_id":      advisor_id,
        "territory_id":    territory_id,
        "event_type":      event_type,
        "event_timestamp": datetime.now(timezone.utc).isoformat(),
        "fund_id":         fund_id,
        "aum_amount":      aum_amount,
        "opportunity_id":  opp_id,
        "metadata": {
            "source":    "mqtt_producer",
            "version":   "2.0",
            "host":      "local",
        },
        "row_timestamp":   datetime.now(timezone.utc).isoformat(),
    }


def on_connect(client, userdata, flags, reason_code, properties=None):
    if reason_code == 0:
        print(f"[producer] Connected to MQTT broker {config.MQTT_HOST}:{config.MQTT_PORT}")
    else:
        print(f"[producer] Connection failed: reason_code={reason_code}")
        sys.exit(1)


def on_publish(client, userdata, mid, reason_code=None, properties=None):
    pass  # mid tracking happens in main loop


def on_disconnect(client, userdata, disconnect_flags=None, reason_code=None, properties=None):
    if reason_code != 0:
        print(f"[producer] Unexpected disconnect (reason={reason_code}). Will reconnect.")


def main():
    global _stop

    signal.signal(signal.SIGINT,  _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    # ── Connect ───────────────────────────────────────────────────────────────
    client = mqtt.Client(
        mqtt.CallbackAPIVersion.VERSION2,
        client_id=config.MQTT_CLIENT_ID_PRODUCER,
        clean_session=True,
    )
    client.on_connect    = on_connect
    client.on_publish    = on_publish
    client.on_disconnect = on_disconnect

    if config.MQTT_USE_AUTH:
        client.username_pw_set(config.MQTT_USERNAME, config.MQTT_PASSWORD)

    client.connect(config.MQTT_HOST, config.MQTT_PORT, keepalive=config.MQTT_KEEPALIVE)
    client.loop_start()

    # ── Produce ───────────────────────────────────────────────────────────────
    duration_s  = config.PRODUCER_DURATION_MINUTES * 60
    interval_s  = config.PRODUCER_INTERVAL_SECONDS
    total_expected = int(duration_s / interval_s)
    sent        = 0
    start       = time.monotonic()

    print(f"[producer] Publishing to topic '{config.MQTT_TOPIC}'")
    print(f"[producer] Interval: {interval_s}s  Duration: {config.PRODUCER_DURATION_MINUTES}min"
          f"  Expected messages: {total_expected}")
    print(f"[producer] Press Ctrl+C to stop early.")
    print()

    while not _stop:
        elapsed = time.monotonic() - start
        if elapsed >= duration_s:
            print(f"[producer] Duration reached ({config.PRODUCER_DURATION_MINUTES} min). Stopping.")
            break

        event   = make_event()
        payload = json.dumps(event)
        result  = client.publish(config.MQTT_TOPIC, payload, qos=config.MQTT_QOS)

        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            sent += 1
            if sent % 10 == 0 or sent == 1:
                print(f"[producer] sent={sent}/{total_expected}"
                      f"  elapsed={elapsed:.0f}s"
                      f"  event_type={event['event_type']}"
                      f"  advisor={event['advisor_id']}")
        else:
            print(f"[producer] Publish error: rc={result.rc}")

        # Sleep, but wake early if stop signal received
        stop_at = time.monotonic() + interval_s
        while time.monotonic() < stop_at and not _stop:
            time.sleep(0.1)

    # ── Shutdown ──────────────────────────────────────────────────────────────
    print(f"\n[producer] Done. Total messages sent: {sent}")
    client.loop_stop()
    client.disconnect()
    return 0


if __name__ == "__main__":
    sys.exit(main())
