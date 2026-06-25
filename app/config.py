"""
app/config.py — Central configuration loaded from environment variables.

All credentials come from a .env file or the process environment.
NEVER hardcode secrets here. See app/.env.example for the template.
"""
import os
from pathlib import Path
from dotenv import load_dotenv

# Load .env from the app/ directory (or the project root as fallback)
_app_dir = Path(__file__).parent
_env_file = _app_dir / ".env"
if _env_file.exists():
    load_dotenv(_env_file)
else:
    load_dotenv()  # fallback: look up the directory tree

# ── Snowflake ─────────────────────────────────────────────────────────────────
# SSv2 JWT requires: account=lowercase, user=UPPERCASE
# Ref: https://docs.snowflake.com/en/user-guide/key-pair-auth#configuring-key-pair-authentication
SNOWFLAKE_ACCOUNT       = os.environ["SNOWFLAKE_ACCOUNT"].lower().strip()
SNOWFLAKE_USER          = os.environ["SNOWFLAKE_USER"].upper().strip()
SNOWFLAKE_PRIVATE_KEY_PATH = os.path.expanduser(
    os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH", "~/.snowflake/keys/snowflake_private_key.p8")
)
# Dedicated SSv2 key — generated with openssl pkcs8 -nocrypt for Rust JWT compat.
# Falls back to SNOWFLAKE_PRIVATE_KEY_PATH if not set.
# IMPORTANT: resolved to absolute path — the SSv2 Rust SDK resolves private_key_file
# relative to the profile.json location (a temp dir), not the CWD.
_APP_DIR = os.path.dirname(os.path.abspath(__file__))

def _abs_key(raw: str) -> str:
    """Expand ~ and resolve relative paths relative to the app/ directory."""
    p = os.path.expanduser(raw)
    return p if os.path.isabs(p) else os.path.join(_APP_DIR, p)

_ssv2_raw = os.environ.get("SSV2_PRIVATE_KEY_PATH",
                            os.environ.get("SNOWFLAKE_PRIVATE_KEY_PATH",
                                           "~/.snowflake/keys/snowflake_private_key.p8"))
SSV2_PRIVATE_KEY_PATH = _abs_key(_ssv2_raw)
SNOWFLAKE_ROLE          = os.environ.get("SNOWFLAKE_ROLE", "SALES_ENGINEER")
SNOWFLAKE_WAREHOUSE     = os.environ.get("SNOWFLAKE_WAREHOUSE", "INGEST")
SNOWFLAKE_DATABASE      = os.environ.get("SNOWFLAKE_DATABASE", "ANALYTICS_DEV_DB")
SNOWFLAKE_SCHEMA        = os.environ.get("SNOWFLAKE_SCHEMA", "STAGING")

# Table and pipe (SSv2 default pipe = TABLE_NAME-streaming, hyphen not underscore)
SNOWFLAKE_TABLE         = os.environ.get("SNOWFLAKE_TABLE", "ADVISOR_EVENTS_RAW")
SNOWFLAKE_PIPE          = f"{SNOWFLAKE_TABLE}-streaming"

# ── MQTT ──────────────────────────────────────────────────────────────────────
MQTT_HOST               = os.environ.get("MQTT_HOST", "129.121.99.18")
MQTT_PORT               = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_TOPIC              = os.environ.get("MQTT_TOPIC", "distribution/advisor_events")
MQTT_CLIENT_ID_PRODUCER = os.environ.get("MQTT_CLIENT_ID_PRODUCER", "acme-dist-producer")
MQTT_CLIENT_ID_CONSUMER = os.environ.get("MQTT_CLIENT_ID_CONSUMER", "acme-dist-consumer")
MQTT_KEEPALIVE          = int(os.environ.get("MQTT_KEEPALIVE", "60"))
MQTT_USE_AUTH           = os.environ.get("MQTT_USE_AUTH", "true").lower() == "true"
MQTT_USERNAME           = os.environ.get("MQTT_USERNAME", "")
MQTT_PASSWORD           = os.environ.get("MQTT_PASSWORD", "")
MQTT_QOS                = int(os.environ.get("MQTT_QOS", "1"))

# ── Producer ──────────────────────────────────────────────────────────────────
PRODUCER_INTERVAL_SECONDS = float(os.environ.get("PRODUCER_INTERVAL_SECONDS", "5"))
PRODUCER_DURATION_MINUTES = float(os.environ.get("PRODUCER_DURATION_MINUTES", "10"))
