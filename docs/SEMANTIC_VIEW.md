# Semantic View Reference — DISTRIBUTION_INSIGHTS_SV

`ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV`

Cortex Analyst semantic view covering advisor engagement, territory performance,
fund flows, and sales pipeline for ACME Investment Management distribution analytics.

---

## Logical Tables

| Alias | Physical Table | Refresh |
|---|---|---|
| `advisor_eng` | `ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE` | Hourly (Dynamic Table) |
| `fund_flows` | `ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION` | Daily (Dynamic Table) |
| `territory` | `ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP` | Every 4 hours (Dynamic Table) |

---

## Dimensions (19)

| Semantic Name | Logical Table | Physical Column | Synonyms |
|---|---|---|---|
| `advisor_id` | advisor_eng | advisor_id | — |
| `advisor_name` | advisor_eng | advisor_name | wholesaler, rep, financial advisor, FA |
| `territory_id` | advisor_eng | territory_id | — |
| `territory_name` | advisor_eng | territory_name | region, area, zone, district |
| `advisor_tier` | advisor_eng | advisor_tier | tier, classification, segment, category |
| `score_date` | advisor_eng | score_date | — |
| `fund_id` | fund_flows | fund_id | — |
| `fund_name` | fund_flows | fund_name | fund, product, investment product, vehicle |
| `fund_category` | fund_flows | fund_category | asset class, category, type, fund type |
| `advisor_id` | fund_flows | advisor_id | — |
| `territory_id` | fund_flows | territory_id | — |
| `flow_date` | fund_flows | flow_date | — |
| `flow_type` | fund_flows | flow_type | direction, flow direction, in or out |
| `territory_id` | territory | territory_id | — |
| `territory_name` | territory | territory_name | region, area, district, territory |
| `region` | territory | region | super-region, geography, geo |
| `territory_mgr` | territory | territory_mgr | manager, wholesaler, territory owner, rep |
| `as_of_date` | territory | as_of_date | — |

---

## Facts (14)

Facts are row-level numeric values. Use directly in VQR SQL against `__advisor_eng`, `__fund_flows`, `__territory` logical table aliases.

| Semantic Name | Logical Table | Physical Column | Description |
|---|---|---|---|
| `aum_amount` | advisor_eng | aum_amount | Advisor AUM in USD |
| `engagement_score` | advisor_eng | engagement_score | Composite score 0-100 |
| `call_count_30d` | advisor_eng | call_count_30d | Calls in last 30 days |
| `meeting_count_30d` | advisor_eng | meeting_count_30d | Meetings in last 30 days |
| `open_opportunity_count` | advisor_eng | open_opportunity_count | Open Salesforce opps |
| `open_opportunity_value` | advisor_eng | open_opportunity_value | Open opp value (USD) |
| `flow_amount` | fund_flows | flow_amount | Flow amount USD |
| `capture_rate` | fund_flows | capture_rate | AUM capture % |
| `total_aum` | territory | total_aum | Territory total AUM |
| `advisor_count` | territory | advisor_count | Active advisors |
| `avg_engagement_score` | territory | avg_engagement_score | Avg territory engagement |
| `net_flows_30d` | territory | net_flows_30d | 30-day net flows USD |
| `at_risk_advisor_count` | territory | at_risk_advisor_count | Advisors with score < 30 |
| `territory_heat_score` | territory | territory_heat_score | Composite health score |

---

## Metrics (15)

Aggregations over facts. Use in queries with GROUP BY.

| Metric Name | Logical Table | Expression | Synonyms |
|---|---|---|---|
| `avg_engagement_score` | advisor_eng | AVG(engagement_score) | engagement, activity score |
| `total_aum` | advisor_eng | SUM(aum_amount) | AUM, assets under management, book size |
| `total_calls_30d` | advisor_eng | SUM(call_count_30d) | calls, phone calls |
| `total_meetings_30d` | advisor_eng | SUM(meeting_count_30d) | meetings, appointments |
| `total_open_opportunities` | advisor_eng | SUM(open_opportunity_count) | open opportunities, pipeline count |
| `total_pipeline_value` | advisor_eng | SUM(open_opportunity_value) | pipeline value, opportunity amount |
| `net_flow_amount` | fund_flows | SUM(flow_amount) | flows, net flows, fund flows |
| `avg_capture_rate` | fund_flows | AVG(capture_rate) | capture, capture ratio |
| `total_territory_aum` | territory | SUM(total_aum) | territory AUM, total assets |
| `total_advisor_count` | territory | SUM(advisor_count) | advisor count, headcount |
| `avg_territory_engagement` | territory | AVG(avg_engagement_score) | territory engagement |
| `total_net_flows_30d` | territory | SUM(net_flows_30d) | net flows, monthly flows |
| `total_at_risk_advisors` | territory | SUM(at_risk_advisor_count) | at-risk advisors |
| `avg_heat_score` | territory | AVG(territory_heat_score) | heat score, health score |

---

## Verified Queries (VQRs)

All 10 VQRs are registered as onboarding or reference queries. Cortex Analyst matches these first before generating new SQL.

| Name | Onboarding | Question |
|---|---|---|
| `TOP_ADVISORS_BY_AUM` | Yes | Who are the top 10 advisors by AUM? |
| `TERRITORY_PERFORMANCE_RANKING` | Yes | Which territories have the highest net flows this month? |
| `AT_RISK_ADVISORS` | Yes | Which advisors are at risk of attrition by territory? |
| `FUND_FLOWS_BY_CATEGORY` | Yes | What are the net fund flows by fund category this quarter? |
| `PIPELINE_BY_TERRITORY` | Yes | Show me the open pipeline value by territory |
| `ADVISOR_ENGAGEMENT_TREND` | No | How has advisor engagement changed over the last 90 days? |
| `TOP_FUNDS_BY_INFLOWS` | No | Which funds have the highest inflows this quarter? |
| `PLATINUM_ADVISOR_SUMMARY` | No | Give me a summary of our Platinum tier advisors |
| `LOW_ACTIVITY_HIGH_AUM` | No | Which high-AUM advisors have had low activity recently? |
| `TERRITORY_COMPARISON` | No | Compare the Northeast and Pacific territories on key metrics |

---

## REST API Usage

```python
import json, urllib.request

payload = {
    "messages": [{"role": "user", "content": [{"type": "text", "text": "Who are the top 5 advisors by AUM?"}]}],
    "semantic_view": "ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV"
}
req = urllib.request.Request(
    f"https://<account>.snowflakecomputing.com/api/v2/cortex/analyst/message",
    data=json.dumps(payload).encode(),
    headers={"Authorization": 'Snowflake Token="<jwt_token>"', "Content-Type": "application/json"},
    method="POST"
)
with urllib.request.urlopen(req) as r:
    print(json.loads(r.read()))
```

---

## Useful Commands

```sql
-- List all semantic views in schema
SHOW SEMANTIC VIEWS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- Inspect dimensions
SHOW SEMANTIC DIMENSIONS IN ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV;

-- Inspect metrics
SHOW SEMANTIC METRICS IN ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV;

-- Get DDL
SELECT GET_DDL('SEMANTIC_VIEW', 'ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV', TRUE);

-- Get YAML equivalent
SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW('ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV');
```
