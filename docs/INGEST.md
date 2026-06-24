# Ingest Pipeline — MQTT → Snowpipe Streaming V2

Real-time advisor event ingestion: a Python producer publishes synthetic
advisor events to an MQTT broker every 5 seconds; a Python consumer subscribes,
receives each message, and streams it into Snowflake via Snowpipe Streaming V2.

---

## Architecture

```
mqtt_producer.py            MQTT Broker              snowpipe_consumer.py
(synthetic events)    →   129.121.99.18          →   (subscribes, streams)
every 5s / 10 min        topic: distribution/              │
                           advisor_events                   │ SSv2 SDK
                                                            ▼
                                               ANALYTICS_DEV_DB.STAGING
                                               .ADVISOR_EVENTS_RAW
                                               (default pipe: auto-created)
```

**Snowflake docs:**
- [Snowpipe Streaming V2 Overview](https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview)
- [High-Performance Architecture](https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance-iceberg)
- [Row Timestamps](https://docs.snowflake.com/en/user-guide/data-engineering/row-timestamps)

---

## Files

| File | Purpose |
|---|---|
| `app/mqtt_producer.py` | Generates synthetic advisor events, publishes to MQTT |
| `app/snowpipe_consumer.py` | Subscribes to MQTT, streams to Snowflake via SSv2 |
| `app/config.py` | Loads all config from `.env` — no hardcoded credentials |
| `app/.env.example` | Credential template — copy to `app/.env` and fill in |
| `app/requirements.txt` | Python deps: `paho-mqtt`, `snowpipe-streaming`, `faker`, `python-dotenv` |
| `app/setup.sh` | Creates Python venv and installs deps |

---

## Setup

### 1. Install dependencies

```bash
./manage.sh setup-ingest
```

This creates `app/.venv/` with all required packages and verifies imports.

### 2. Configure credentials

```bash
cp app/.env.example app/.env
```

Fill in `app/.env`:

```bash
# Snowflake
SNOWFLAKE_ACCOUNT=your_account_identifier   # e.g. orgname-accountname
SNOWFLAKE_USER=your_snowflake_user
SNOWFLAKE_PRIVATE_KEY_PATH=~/.snowflake/keys/snowflake_private_key.p8

# MQTT
MQTT_HOST=129.121.99.18
MQTT_PORT=1883
MQTT_TOPIC=distribution/advisor_events
MQTT_USE_AUTH=true
MQTT_USERNAME=myuser
MQTT_PASSWORD=your_actual_password_here    # NEVER commit this
```

The `.env` file is gitignored — it never enters version control.

### 3. Verify the Snowflake table exists

```bash
./manage.sh test  # row count for ADVISOR_EVENTS_RAW should show ≥ 0
```

Or directly:

```sql
SELECT COUNT(*) FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW;
```

---

## Running

### Producer only (publish MQTT messages)

```bash
./manage.sh run-producer
```

Publishes one advisor event every 5 seconds for 10 minutes (120 events total).

### Consumer only (subscribe + stream to Snowflake)

```bash
./manage.sh run-consumer
```

Connects to MQTT, subscribes to `distribution/advisor_events`, and streams each
message into `ADVISOR_EVENTS_RAW` via SSv2. Runs until Ctrl+C.

### Both together

```bash
./manage.sh run-ingest
```

Starts the consumer in the background, waits 2 seconds, then starts the
producer in the foreground. When the producer finishes (after 10 minutes),
the consumer is stopped automatically.

---

## MQTT Payload Format

Each message is a JSON object matching the `ADVISOR_EVENTS_RAW` schema:

```json
{
  "event_id":        "c3f1b2a0-...",
  "advisor_id":      "ADV042",
  "territory_id":    "T003",
  "event_type":      "CALL",
  "event_timestamp": "2026-06-24T14:22:01.123456+00:00",
  "fund_id":         null,
  "aum_amount":      4200000.00,
  "opportunity_id":  null,
  "metadata": {
    "source":  "mqtt_producer",
    "version": "2.0",
    "host":    "local"
  },
  "row_timestamp":   "2026-06-24T14:22:01.234567+00:00"
}
```

**Event types:** `CALL`, `MEETING`, `EMAIL`, `FUND_PURCHASE`, `FUND_REDEMPTION`,
`AUM_UPDATE`, `OPPORTUNITY_CREATED`, `OPPORTUNITY_CLOSED`

---

## Snowpipe Streaming V2 — Key Concepts

### Default auto-created pipe

The SSv2 High-Performance Architecture automatically creates a default pipe
the first time data is ingested. **No `CREATE PIPE` SQL is required.**

The default pipe name follows the convention:
```
<TABLE_NAME>-streaming
```
For this project:
```
ADVISOR_EVENTS_RAW-streaming
```

### Authentication

Uses RSA keypair (JWT). The private key path is configured via
`SNOWFLAKE_PRIVATE_KEY_PATH` in `.env`. The consumer generates a temporary
`ssv2_profile.json` at startup (never committed).

### Idempotency

Each row uses `event_id` (UUID) as the SSv2 offset token. This ensures that
if the consumer restarts, duplicate events sent by the producer are deduplicated
at the channel level.

---

## Monitoring

Check rows arriving in real-time:

```sql
SELECT COUNT(*), MAX(row_timestamp)
FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW;
```

Check the pipe status:

```sql
SHOW PIPES IN SCHEMA ANALYTICS_DEV_DB.STAGING;
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `MQTT connect failed` | Broker unreachable | Check `MQTT_HOST`/`MQTT_PORT` in `.env`; verify network |
| `Authentication failed` | Wrong username/password | Check `MQTT_USERNAME`/`MQTT_PASSWORD` in `.env` |
| `SSv2: Authentication failed` | RSA key not registered | Run `ALTER USER <user> SET RSA_PUBLIC_KEY='...'` |
| `SSv2: Table not found` | Wrong DB/schema/table | Check `SNOWFLAKE_DATABASE`, `SNOWFLAKE_SCHEMA`, `SNOWFLAKE_TABLE` |
| `snowpipe-streaming` import fails | SDK not installed or wrong Python | Run `./manage.sh setup-ingest`; verify Python 3.9+ |
| 0 rows in table after running | SSv2 commit in flight | Wait 5-10 seconds and recheck |
