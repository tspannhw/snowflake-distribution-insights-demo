-- ============================================================================
-- 06_semantic_view_sql.sql
-- Distribution Insights — Semantic View as SQL DDL
--
-- Run:  snow sql -f scripts/06_semantic_view_sql.sql --connection your_connection
-- Pre:  01_setup_schema.sql + 04_dynamic_tables.sql must be complete
--
-- v2 changes vs v1:
--   - Added FACTS clause: row-level numeric columns must be FACTS (not just
--     METRICS) so VQR SQL can SELECT them without GROUP BY
--   - Fixed dimension semantic names to match physical column names exactly:
--       advisor_eng.advisor_tier AS advisor_tier  (was: tier AS advisor_tier)
--       territory.territory_name AS territory_name (was: terr_territory_name)
--       territory.territory_id AS territory_id     (was: terr_territory_id)
--       fund_flows.advisor_id AS advisor_id        (was: ff_advisor_id)
--       fund_flows.territory_id AS territory_id    (was: ff_territory_id)
--   - All 10 VQR SQL statements use logical table aliases (__advisor_eng,
--     __territory, __fund_flows) with correct semantic column names
--   - execution_environment added to ALTER AGENT tool_resources
-- ============================================================================
USE WAREHOUSE INGEST;
USE DATABASE ANALYTICS_DEV_DB;
USE SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

CREATE OR REPLACE SEMANTIC VIEW ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV

  -- ── LOGICAL TABLES ─────────────────────────────────────────────────────────
  TABLES (
    advisor_eng AS ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
      COMMENT = 'Rolling advisor engagement metrics — updated hourly via Dynamic Table',

    fund_flows AS ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION
      COMMENT = 'Daily fund flow transactions attributed by advisor and territory',

    territory AS ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
      COMMENT = 'Territory-level performance heat map — refreshed every 4 hours'
  )

  -- ── FACTS ──────────────────────────────────────────────────────────────────
  -- Row-level numeric values. FACTS are required for direct SELECT in VQR SQL
  -- (METRICS are aggregations and require GROUP BY). Each fact semantic name
  -- matches its physical column name so VQR SQL is readable without aliasing.
  FACTS (

    -- ── advisor_eng ───────────────────────────────────────────────────────
    advisor_eng.aum_amount            AS aum_amount
      COMMENT = 'Advisor AUM in USD (estimated from 12-month flow proxy)',
    advisor_eng.engagement_score      AS engagement_score
      COMMENT = 'Composite engagement score 0-100',
    advisor_eng.call_count_30d        AS call_count_30d
      COMMENT = 'Calls in the last 30 days',
    advisor_eng.meeting_count_30d     AS meeting_count_30d
      COMMENT = 'Meetings in the last 30 days',
    advisor_eng.open_opportunity_count AS open_opportunity_count
      COMMENT = 'Open Salesforce opportunity count',
    advisor_eng.open_opportunity_value AS open_opportunity_value
      COMMENT = 'Open opportunity dollar value',

    -- ── fund_flows ────────────────────────────────────────────────────────
    fund_flows.flow_amount    AS flow_amount
      COMMENT = 'Flow amount in USD (positive = inflow, negative = outflow)',
    fund_flows.capture_rate   AS capture_rate
      COMMENT = 'AUM capture rate as a percentage of benchmark',

    -- ── territory (pre-aggregated; one row per territory per date) ────────
    territory.total_aum             AS total_aum
      COMMENT = 'Total AUM across all advisors in the territory',
    territory.advisor_count         AS advisor_count
      COMMENT = 'Active advisor count in the territory',
    territory.avg_engagement_score  AS avg_engagement_score
      COMMENT = 'Average engagement score across the territory',
    territory.net_flows_30d         AS net_flows_30d
      COMMENT = 'Net fund flows over the last 30 days',
    territory.at_risk_advisor_count AS at_risk_advisor_count
      COMMENT = 'Advisors with engagement score < 30',
    territory.territory_heat_score  AS territory_heat_score
      COMMENT = 'Composite territory health score 0-100'
  )

  -- ── DIMENSIONS ─────────────────────────────────────────────────────────────
  -- Categorical / date attributes used for grouping, filtering, and slicing.
  -- Semantic names match physical column names throughout to avoid surprises
  -- when writing VQR SQL against logical table aliases.
  DIMENSIONS (

    -- ── advisor_eng ───────────────────────────────────────────────────────
    advisor_eng.advisor_id     AS advisor_id
      COMMENT = 'Unique advisor identifier',

    advisor_eng.advisor_name   AS advisor_name
      WITH SYNONYMS = ('wholesaler', 'rep', 'financial advisor', 'FA')
      COMMENT = 'Full name of the advisor',

    advisor_eng.territory_id   AS territory_id
      COMMENT = 'Territory assignment code',

    advisor_eng.territory_name AS territory_name
      WITH SYNONYMS = ('region', 'area', 'zone', 'district')
      COMMENT = 'Human-readable territory name (e.g. Northeast, Pacific)',

    -- Physical column is advisor_tier; semantic name = advisor_tier
    advisor_eng.advisor_tier   AS advisor_tier
      WITH SYNONYMS = ('tier', 'classification', 'segment', 'category')
      COMMENT = 'Advisor AUM tier: PLATINUM, GOLD, SILVER, BRONZE',

    advisor_eng.score_date     AS score_date
      COMMENT = 'Date the engagement score was calculated',

    -- ── fund_flows ────────────────────────────────────────────────────────
    fund_flows.fund_id         AS fund_id
      COMMENT = 'Fund identifier',

    fund_flows.fund_name       AS fund_name
      WITH SYNONYMS = ('fund', 'product', 'investment product', 'vehicle')
      COMMENT = 'Full fund name',

    fund_flows.fund_category   AS fund_category
      WITH SYNONYMS = ('asset class', 'category', 'type', 'fund type')
      COMMENT = 'Asset class category (Equity, Fixed Income, Multi-Asset)',

    -- advisor_id and territory_id exist in both advisor_eng and fund_flows;
    -- they are scoped to their respective logical tables so there is no conflict
    fund_flows.advisor_id      AS advisor_id
      COMMENT = 'Advisor who drove the fund flow',

    fund_flows.territory_id    AS territory_id
      COMMENT = 'Territory associated with the fund flow',

    fund_flows.flow_date       AS flow_date
      COMMENT = 'Date of the fund flow transaction',

    fund_flows.flow_type       AS flow_type
      WITH SYNONYMS = ('direction', 'flow direction', 'in or out')
      COMMENT = 'Direction of flow: INFLOW or OUTFLOW',

    -- ── territory ─────────────────────────────────────────────────────────
    territory.territory_id     AS territory_id
      COMMENT = 'Territory code',

    territory.territory_name   AS territory_name
      WITH SYNONYMS = ('region', 'area', 'district', 'territory')
      COMMENT = 'Territory display name',

    territory.region           AS region
      WITH SYNONYMS = ('super-region', 'geography', 'geo')
      COMMENT = 'Geographic super-region (East, Central, West)',

    territory.territory_mgr    AS territory_mgr
      WITH SYNONYMS = ('manager', 'wholesaler', 'territory owner', 'rep')
      COMMENT = 'Name of the territory manager',

    territory.as_of_date       AS as_of_date
      COMMENT = 'Date of the territory snapshot'
  )

  -- ── METRICS ────────────────────────────────────────────────────────────────
  -- Aggregations over FACTS. Metric expressions reference FACT semantic names.
  METRICS (

    -- ── advisor_eng ───────────────────────────────────────────────────────
    advisor_eng.avg_engagement_score   AS AVG(engagement_score)
      WITH SYNONYMS = ('engagement', 'activity score', 'interaction score', 'contact score')
      COMMENT = 'Average engagement score across selected advisors',

    advisor_eng.total_aum              AS SUM(aum_amount)
      WITH SYNONYMS = ('AUM', 'assets', 'assets under management', 'book size', 'total AUM')
      COMMENT = 'Total AUM in USD',

    advisor_eng.total_calls_30d        AS SUM(call_count_30d)
      WITH SYNONYMS = ('calls', 'phone calls', 'outbound calls')
      COMMENT = 'Total calls in the last 30 days',

    advisor_eng.total_meetings_30d     AS SUM(meeting_count_30d)
      WITH SYNONYMS = ('meetings', 'in-person meetings', 'appointments')
      COMMENT = 'Total meetings in the last 30 days',

    advisor_eng.total_open_opportunities AS SUM(open_opportunity_count)
      WITH SYNONYMS = ('open opportunities', 'pipeline count', 'deals')
      COMMENT = 'Total open Salesforce opportunity count',

    advisor_eng.total_pipeline_value   AS SUM(open_opportunity_value)
      WITH SYNONYMS = ('pipeline value', 'pipeline', 'opportunity amount', 'potential AUM')
      COMMENT = 'Total open opportunity value in USD',

    -- ── fund_flows ────────────────────────────────────────────────────────
    fund_flows.net_flow_amount         AS SUM(flow_amount)
      WITH SYNONYMS = ('flows', 'net flows', 'fund flows', 'money in', 'money out')
      COMMENT = 'Net flow amount in USD',

    fund_flows.avg_capture_rate        AS AVG(capture_rate)
      WITH SYNONYMS = ('capture', 'capture ratio', 'market share')
      COMMENT = 'Average AUM capture rate',

    -- ── territory ─────────────────────────────────────────────────────────
    territory.total_territory_aum      AS SUM(total_aum)
      WITH SYNONYMS = ('territory AUM', 'book', 'total assets')
      COMMENT = 'Total AUM in the territory (USD)',

    territory.total_advisor_count      AS SUM(advisor_count)
      WITH SYNONYMS = ('advisor count', 'number of advisors', 'headcount')
      COMMENT = 'Total active advisors in the territory',

    territory.avg_territory_engagement AS AVG(avg_engagement_score)
      WITH SYNONYMS = ('engagement', 'territory engagement', 'average score')
      COMMENT = 'Average engagement score across the territory',

    territory.total_net_flows_30d      AS SUM(net_flows_30d)
      WITH SYNONYMS = ('net flows', 'recent flows', 'flows this month', 'monthly flows')
      COMMENT = 'Total net flows in the territory over 30 days (USD)',

    territory.total_at_risk_advisors   AS SUM(at_risk_advisor_count)
      WITH SYNONYMS = ('at-risk advisors', 'churning advisors', 'low engagement', 'risk count')
      COMMENT = 'Total at-risk advisors (engagement score < 30)',

    territory.avg_heat_score           AS AVG(territory_heat_score)
      WITH SYNONYMS = ('heat score', 'territory score', 'health score')
      COMMENT = 'Average composite territory health score (0-100)'
  )

  -- ── COMMENT ────────────────────────────────────────────────────────────────
  COMMENT = 'Distribution analytics semantic view for ACME Investment Management. Covers advisor engagement, territory performance, fund flows, and sales pipeline. Powered by Cortex Analyst.'

  -- ── AI SQL GENERATION ──────────────────────────────────────────────────────
  AI_SQL_GENERATION 'Format AUM as $XM (millions) or $XB (billions). Percentages to 1 decimal place. advisor_tier values: PLATINUM, GOLD, SILVER, BRONZE. For current advisor scores: WHERE score_date = (SELECT MAX(score_date) FROM __advisor_eng). For current territory data: WHERE as_of_date = (SELECT MAX(as_of_date) FROM __territory). Inflows: flow_type = ''INFLOW''; outflows: flow_type = ''OUTFLOW''.'

  -- ── AI QUESTION CATEGORIZATION ─────────────────────────────────────────────
  AI_QUESTION_CATEGORIZATION 'Answer questions about advisor engagement, territory performance, fund flows, pipeline value, and attrition risk. Reject questions about individual investor PII or competitor data and ask the user to contact their compliance team.'

  -- ── VERIFIED QUERIES ───────────────────────────────────────────────────────
  -- VQR SQL uses logical table aliases: __advisor_eng, __fund_flows, __territory
  -- Semantic names (not physical column names) must be used inside these aliases.
  -- VERIFIED_AT = 1750636800 = 2026-06-23 00:00:00 UTC (Unix epoch seconds)
  AI_VERIFIED_QUERIES (

    top_advisors_by_aum AS (
      QUESTION 'Who are the top 10 advisors by AUM?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT advisor_name, territory_name, advisor_tier AS tier, aum_amount, engagement_score
      FROM __advisor_eng
      WHERE score_date = (SELECT MAX(score_date) FROM __advisor_eng)
      ORDER BY aum_amount DESC
      LIMIT 10'
    ),

    territory_performance_ranking AS (
      QUESTION 'Which territories have the highest net flows this month?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT territory_name, region, net_flows_30d, total_aum, avg_engagement_score, at_risk_advisor_count
      FROM __territory
      WHERE as_of_date = (SELECT MAX(as_of_date) FROM __territory)
      ORDER BY net_flows_30d DESC'
    ),

    at_risk_advisors AS (
      QUESTION 'Which advisors are at risk of attrition by territory?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT advisor_name, territory_name, advisor_tier AS tier, engagement_score, aum_amount, open_opportunity_value, call_count_30d, meeting_count_30d
      FROM __advisor_eng
      WHERE engagement_score < 30
        AND score_date = (SELECT MAX(score_date) FROM __advisor_eng)
      ORDER BY aum_amount DESC'
    ),

    fund_flows_by_category AS (
      QUESTION 'What are the net fund flows by fund category this quarter?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT fund_category, fund_name, SUM(flow_amount) AS net_flows, COUNT(DISTINCT advisor_id) AS advisor_count
      FROM __fund_flows
      WHERE flow_date >= DATE_TRUNC(''QUARTER'', CURRENT_DATE)
      GROUP BY fund_category, fund_name
      ORDER BY net_flows DESC'
    ),

    pipeline_by_territory AS (
      QUESTION 'Show me the open pipeline value by territory'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT territory_name, SUM(open_opportunity_count) AS total_opportunities, SUM(open_opportunity_value) AS total_pipeline_value, AVG(engagement_score) AS avg_engagement
      FROM __advisor_eng
      WHERE score_date = (SELECT MAX(score_date) FROM __advisor_eng)
      GROUP BY territory_name
      ORDER BY total_pipeline_value DESC'
    ),

    advisor_engagement_trend AS (
      QUESTION 'How has advisor engagement changed over the last 90 days?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT score_date, AVG(engagement_score) AS avg_score, COUNT(DISTINCT advisor_id) AS active_advisors, SUM(aum_amount) AS total_aum
      FROM __advisor_eng
      WHERE score_date >= DATEADD(DAY, -90, CURRENT_DATE)
      GROUP BY score_date
      ORDER BY score_date'
    ),

    top_funds_by_inflows AS (
      QUESTION 'Which funds have the highest inflows this quarter?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT fund_name, fund_category, SUM(CASE WHEN flow_type = ''INFLOW'' THEN flow_amount ELSE 0 END) AS total_inflows, SUM(CASE WHEN flow_type = ''OUTFLOW'' THEN flow_amount ELSE 0 END) AS total_outflows, SUM(flow_amount) AS net_flows, COUNT(DISTINCT advisor_id) AS contributing_advisors
      FROM __fund_flows
      WHERE flow_date >= DATE_TRUNC(''QUARTER'', CURRENT_DATE)
      GROUP BY fund_name, fund_category
      ORDER BY total_inflows DESC
      LIMIT 10'
    ),

    platinum_advisor_summary AS (
      QUESTION 'Give me a summary of our Platinum tier advisors'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT territory_name, COUNT(*) AS platinum_count, SUM(aum_amount) AS total_aum, AVG(engagement_score) AS avg_engagement, SUM(open_opportunity_value) AS total_pipeline
      FROM __advisor_eng
      WHERE advisor_tier = ''PLATINUM''
        AND score_date = (SELECT MAX(score_date) FROM __advisor_eng)
      GROUP BY territory_name
      ORDER BY total_aum DESC'
    ),

    low_activity_high_aum AS (
      QUESTION 'Which high-AUM advisors have had low activity recently?'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT advisor_name, territory_name, advisor_tier AS tier, aum_amount, engagement_score, call_count_30d, meeting_count_30d, open_opportunity_count
      FROM __advisor_eng
      WHERE aum_amount > 2000000
        AND (call_count_30d + meeting_count_30d) < 2
        AND score_date = (SELECT MAX(score_date) FROM __advisor_eng)
      ORDER BY aum_amount DESC
      LIMIT 20'
    ),

    territory_comparison AS (
      QUESTION 'Compare the Northeast and Pacific territories on key metrics'
      VERIFIED_AT 1750636800
      ONBOARDING_QUESTION FALSE
      VERIFIED_BY '(STEWARD = your_username)'
      SQL 'SELECT territory_name, total_aum, advisor_count, avg_engagement_score, net_flows_30d, at_risk_advisor_count, ROUND(net_flows_30d / NULLIF(total_aum, 0) * 100, 2) AS flow_rate_pct
      FROM __territory
      WHERE territory_name IN (''Northeast'', ''Pacific'')
        AND as_of_date = (SELECT MAX(as_of_date) FROM __territory)
      ORDER BY territory_name'
    )
  )
;

-- ============================================================================
-- VERIFY CREATION
-- ============================================================================
SHOW SEMANTIC VIEWS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;
SHOW SEMANTIC FACTS IN ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV;
SHOW SEMANTIC DIMENSIONS IN ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV;
SHOW SEMANTIC METRICS IN ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV;

-- ============================================================================
-- UPDATE CORTEX AGENT
-- ============================================================================
ALTER AGENT ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent
  MODIFY LIVE VERSION SET SPECIFICATION = $$
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
$$;
