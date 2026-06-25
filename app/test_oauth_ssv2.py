"""Test: use connector session token as oauth_token for SSv2 SDK."""
import os, sys, tomllib
from pathlib import Path
from dotenv import load_dotenv
load_dotenv(Path(__file__).parent / ".env")
sys.path.insert(0, str(Path(__file__).parent))
import config
from cryptography.hazmat.primitives.serialization import load_pem_private_key
import snowflake.connector, os

# Get session token from existing keypair connection (tspann1)
print("Getting session token from snowflake-connector-python...")
with open(os.path.expanduser("~/.snowflake/connections.toml"), "rb") as f:
    cfg = tomllib.load(f)["tspann1"]
kpath = os.path.expanduser(cfg["private_key_path"])
with open(kpath, "rb") as f:
    orig_pk = load_pem_private_key(f.read(), password=None)
p2 = {k: v for k, v in cfg.items() if k != "private_key_path"}
p2["private_key"] = orig_pk
conn = snowflake.connector.connect(**p2)
session_token = conn.rest.token
conn.close()
print(f"Session token (first 40): {session_token[:40]}...")

# Try SSv2 SDK with oauth_token
from snowflake.ingest.streaming import StreamingIngestClient
print("\nTrying SSv2 SDK with oauth_token property...")
try:
    c = StreamingIngestClient(
        "ACME_DIST_CLIENT",
        config.SNOWFLAKE_DATABASE,
        config.SNOWFLAKE_SCHEMA,
        config.SNOWFLAKE_PIPE,
        profile_json=None,
        properties={
            "user":        config.SNOWFLAKE_USER,
            "account":     config.SNOWFLAKE_ACCOUNT,
            "url":         f"https://{config.SNOWFLAKE_ACCOUNT}.snowflakecomputing.com:443",
            "role":        config.SNOWFLAKE_ROLE,
            "oauth_token": session_token,
        },
    )
    print("SUCCESS — client created with oauth_token!")
    c.close()
except Exception as e:
    print(f"FAILED: {str(e)[:300]}")
