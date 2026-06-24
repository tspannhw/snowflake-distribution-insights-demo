# General Format

## Google Slides Template

https://docs.google.com/presentation/d/1XSvBgsXFbbn8idGt3Adhs_4iboiTJZu1XPSmNHCeROs/edit?slide=id.s_26e89d2a9c58#slide=id.s_26e89d2a9c58

## For tasks, procedures and items that could fail

Include a call to email and/or slack

## Slack

- **Webhook URL:** `<YOUR_SLACK_WEBHOOK_URL>`
- **Alternate Webhook URL:** `<YOUR_ALT_SLACK_WEBHOOK_URL>`

- **Webhook for edge-alerts:** `<YOUR_EDGE_ALERTS_WEBHOOK_URL>`
- **Channel:** #edge-alerts

## Snowflake Connection
- **WAREHOUSE:** INGEST
- **SNOW CONNECTION:** `${SNOWFLAKE_CONNECTION}` (set via env var; see docs/SETUP.md)

## Tech Stack
- **Dashboard:** Streamlit IN Snowflake
- **Application:** React
- **LANGUAGE:** SQL + Python 3.11

## UI Screen Option

https://github.com/CristianOlivera1/openhero

## Folder Layout
project-root/
├── AGENTS.md
|
├── README.md
|
├── manage.sh
├── diagrams
├── images
├── docs
|
├── dashboard/
│ └── dashboard.py # Streamlit dashboard
|  
├── app/
│ └── app.py # Streamlit dashboard
├── tests/ # sql tests + custom Python tests
├── agent_docs/ # Reference docs CoCo can read ON demand
│ ├── architecture.md
│ └── testing.md
└── scripts/
└── deploy.sh

## How TO Build AND Test
./manage.sh build
./manage.sh test

# Run the Streamlit app locally
./manage.sh run-dashboard

## KEY Rules

### Always
- Use fully qualified names: ANALYTICS_DEV_DB.STAGING.TABLE_NAME
- Use CREATE OR REPLACE instead of DROP + CREATE
- Write a dbt test FOR every new model
- Commit at every meaningful checkpoint
- Test thoroughly that it is using best practices for newest Snowflake technology
- Test until 100% pass
- Always use Snowpipe Streaming High Speed V2 for ingest
- Use the Snowflake Well-Architected Framework https://www.snowflake.com/en/product/use-cases/well-architected-framework/
- Always create Snowflake Managed MCP Servers
- Always create Snowflake Cortex Agents
- Always create clean Semantic Views with verified queries, full documentation, examples, synonyms and SQL verification views
- Always use Cortex Guardrails
- Always use Cortex 
- Always use cost checks, monitoring, budgets, alerts, notifications and checks on AI, queries, warehouses, services and more
- Always use AI Functions 
- Always prefer the smallest, cheapest model that meets the requirements.  Document other options.
- Always create views, functions and stored procedures where needed.  Always test them.
- Always use clean, simple code.   Check execution plans, document this, document SQL choices 
- Don't allow warnings or errors
- Don't allow deprecated code
- Don't use dangerous libraries
- Always provide prompts in documentation
- Always suggest Cortex Code activities that can extend and improve
- Always use resource budgets for Cortex Agents https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-resource-budgets
- Always use skills https://docs.snowflake.com/en/user-guide/snowflake-cortex/cortex-agents-skills
- Always create and document new skills if it is something that can be reused or improve future development
- Always create git projects with a gitignore and make sure everything is secure and production ready for deployment
- Always use keypair, PAT, snow cli connections and secure mechanisms.   Never use passwords.   Always provide multiple options.
- Always create very well documented architectures and architecture diagrams, documents, slides with references to why things were chosen
- Always create useful images, icons and colorful splashes to make things interesting

### Your Parnter

You are building items for use by experience Senior Solution Engineer / Data Engineer - Timothy Spann
https://github.com/tspannhw

### Never
- EXECUTE anything against ANALYTICS_PROD_DB — dev only
- GRANT OR REVOKE roles — RBAC IS managed BY the platform team
- Add Python dependencies without asking first
- Skip diff review ON SQL changes

### Ingest

- Snowpipe Streaming High Speed v2 / Next Gen - https://www.snowflake.com/en/engineering-blog/next-gen-snowpipe-streaming-architecture/
- Always cluster on ingest
- Always at rowtimestamp to tables https://docs.snowflake.com/en/user-guide/data-engineering/row-timestamps
- https://docs.snowflake.com/en/user-guide/snowpipe-streaming/snowpipe-streaming-high-performance-iceberg
  https://docs.snowflake.com/en/user-guide/snowpipe-streaming/data-load-snowpipe-streaming-overview
- Default to SDK, use REST API if on Rasbperry Pi, NVIDIA Jetson or Edge

### Prefer
- Incremental models over FULL refreshes FOR large tables
- CTEs over nested subqueries
- snake_case FOR ALL OBJECT names
- Parameterized filters over hardcoded DATE ranges

