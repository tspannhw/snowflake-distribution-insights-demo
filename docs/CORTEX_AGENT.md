# Cortex Agent Configuration Guide

## Agent Object

```
ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent
```

---

## Tools

| Tool | Type | Purpose |
|---|---|---|
| `DistributionAnalyst` | `cortex_analyst_text_to_sql` | NL → SQL via semantic view |
| `FundSearch` | `cortex_search` | Fund documentation search |
| `data_to_chart` | `data_to_chart` | Visualize query results |

---

## Full Agent Specification

```yaml
tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: DistributionAnalyst
      description: "Answer questions about advisor engagement, territory performance, fund flows, and pipeline using verified SQL"
  - tool_spec:
      type: cortex_search
      name: FundSearch
      description: "Search fund names, categories, benchmarks, and asset class documentation"
  - tool_spec:
      type: data_to_chart
      name: data_to_chart
      description: "Generate visualizations from query results"

tool_resources:
  DistributionAnalyst:
    semantic_view: "ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV"
    execution_environment:
      type: warehouse
      warehouse: INGEST
  FundSearch:
    name: ANALYTICS_DEV_DB.DISTRIBUTION.FUND_DOCS_SEARCH
    max_results: "5"

instructions:
  response: "Be concise and data-driven. Format AUM in dollars (M or B), flows in M, percentages with 1 decimal."
  orchestration: "For advisor, territory, pipeline, and fund questions use DistributionAnalyst. For fund documentation use FundSearch."
```

---

## Updating the Agent

To update the agent spec (e.g. after recreating the semantic view):

```sql
ALTER AGENT ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent
  MODIFY LIVE VERSION SET SPECIFICATION = $$
  <yaml spec here>
$$;
```

---

## Testing the Agent

### Via SQL

```sql
-- Check agent exists
SHOW AGENTS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;
```

### Via REST API

```bash
curl -X POST https://<account>.snowflakecomputing.com/api/v2/cortex/agent/runs \
  -H "Authorization: Snowflake Token=\"<jwt>\"" \
  -H "Content-Type: application/json" \
  -d '{
    "agent": "ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent",
    "messages": [{"role": "user", "content": [{"type": "text", "text": "Who are the top 5 advisors by AUM?"}]}]
  }'
```

### Via Snowsight

AI & ML → Cortex Agents → `distribution_insights_agent` → Open in playground

---

## System Prompt

The agent uses this system prompt (see `docs/prompts.md` for the full version):

```
You are a distribution analytics assistant for ACME Investment Management.
You have access to a semantic model covering advisor engagement, territory
performance, fund flows, and pipeline data.

RULES:
- Always ground answers in data; never speculate
- Format AUM in $B or $M, flows in $M, percentages to 1 decimal
- Flag at-risk advisors (engagement score < 30) proactively
- Do NOT discuss competitor pricing or individual salaries
- For compliance questions, recommend consulting the compliance team
```

---

## Cortex Search Service

Fund documentation is indexed in:

```
ANALYTICS_DEV_DB.DISTRIBUTION.FUND_DOCS_SEARCH
```

Recreate with:

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE ANALYTICS_DEV_DB.DISTRIBUTION.FUND_DOCS_SEARCH
  ON content
  ATTRIBUTES fund_name, fund_category
  WAREHOUSE = INGEST
  TARGET_LAG = '1 hour'
AS
  SELECT content, fund_name, fund_category, doc_type
  FROM ANALYTICS_DEV_DB.STAGING.FUND_DIM;
```

---

## Resource Budget

Add a credit cap to prevent runaway agent costs:

```sql
-- Create a resource budget (requires ACCOUNTADMIN)
CREATE RESOURCE BUDGET distribution_agent_budget
  CREDIT_QUOTA = 10
  FREQUENCY = MONTHLY
  START_TIMESTAMP = CURRENT_TIMESTAMP();

ALTER AGENT ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent
  SET RESOURCE_BUDGET = distribution_agent_budget;
```
