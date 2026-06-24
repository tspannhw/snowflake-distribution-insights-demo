# Contributing

Thank you for your interest in contributing to the Distribution Insights demo.

---

## Getting Started

1. Fork the repo and clone locally.
2. Follow [docs/SETUP.md](docs/SETUP.md) to configure your Snowflake connection and build the project.
3. Create a feature branch: `git checkout -b feature/my-change`

---

## Connection Setup

Set your connection name before running any scripts:

```bash
export SNOWFLAKE_CONNECTION=your_connection
```

**Never commit credentials.** The `.gitignore` blocks `connections.toml`, `*.pem`, `*.p8`, and `.snowflake/`.

---

## Development Rules

- Use fully qualified table names: `ANALYTICS_DEV_DB.STAGING.TABLE_NAME`
- Never target `ANALYTICS_PROD_DB` — dev only
- Use `CREATE OR REPLACE` instead of `DROP + CREATE`
- Always use `CURRENT_DATE()` with caution inside Dynamic Tables and dashboards — use `MAX(date_col)` subquery instead for queries that run after the DT refresh date
- SQL: snake_case for all identifiers, CTEs over nested subqueries
- Python: follow existing patterns in `dashboard/dashboard.py`

---

## Before Opening a PR

- Run `./manage.sh test` — all checks must pass
- Run `./tests/validate.sh` — smoke tests must pass
- Ensure no hardcoded credentials, webhook URLs, or connection names
- Update relevant docs in `docs/` if you change behavior

---

## Slack Webhook Setup

If you add or modify alert integrations in `scripts/05_alerts_observability.sql`, replace webhook placeholder strings with your own URLs before running. Do not commit real webhook URLs.

```sql
-- Replace before running:
WEBHOOK_URL = '<YOUR_SLACK_WEBHOOK_URL>'
```

---

## Reporting Issues

Open a GitHub Issue with:
- What you expected
- What actually happened
- Relevant error messages or logs (scrub any credentials first)
