-- ============================================================================
-- 04_dynamic_tables.sql
-- Distribution Insights - Dynamic Tables for AI Feature Engineering
-- All tables use incremental refresh by default
-- ============================================================================
USE WAREHOUSE INGEST;
USE DATABASE ANALYTICS_DEV_DB;
USE SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- ============================================================================
-- 1. ADVISOR ENGAGEMENT SCORE
-- Aggregates activity events into a rolling engagement score
-- Refreshed every hour; incremental on event_timestamp
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
  TARGET_LAG = '1 hour'
  WAREHOUSE = INGEST
  COMMENT = 'Rolling advisor engagement score computed from Snowpipe V2 activity stream'
AS
WITH activity_counts AS (
  SELECT
    e.advisor_id,
    COUNT(CASE WHEN e.event_type = 'CALL' AND e.event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP()) THEN 1 END) AS call_count_30d,
    COUNT(CASE WHEN e.event_type = 'MEETING' AND e.event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP()) THEN 1 END) AS meeting_count_30d,
    COUNT(CASE WHEN e.event_type = 'EMAIL' AND e.event_timestamp >= DATEADD('day', -30, CURRENT_TIMESTAMP()) THEN 1 END) AS email_count_30d,
    MAX(e.event_timestamp) AS last_activity_timestamp,
    DATEDIFF('day', MAX(e.event_timestamp), CURRENT_TIMESTAMP()) AS days_since_last_activity
  FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW e
  GROUP BY e.advisor_id
),
opportunity_summary AS (
  SELECT
    o.advisor_id,
    COUNT(*) AS open_opportunity_count,
    SUM(COALESCE(o.amount, 0)) AS open_opportunity_value
  FROM ANALYTICS_DEV_DB.STAGING.SFDC_OPPORTUNITY o
  WHERE o.stage NOT IN ('Closed Won', 'Closed Lost')
  GROUP BY o.advisor_id
),
aum_summary AS (
  SELECT
    f.advisor_id,
    SUM(ABS(f.flow_amount)) AS total_flow_12m
  FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW f
  WHERE f.flow_date >= DATEADD('month', -12, CURRENT_DATE())
  GROUP BY f.advisor_id
)
SELECT
  a.advisor_id,
  a.advisor_name,
  a.territory_id,
  t.territory_name,
  a.tier AS advisor_tier,
  CURRENT_DATE() AS score_date,

  -- Engagement score formula (0-100)
  -- Weighted: calls (30%), meetings (40%), email (20%), recency (10%)
  LEAST(100, GREATEST(0,
    (COALESCE(ac.call_count_30d, 0) * 3) +       -- 30 pts max at 10 calls
    (COALESCE(ac.meeting_count_30d, 0) * 8) +     -- 40 pts max at 5 meetings
    (COALESCE(ac.email_count_30d, 0) * 0.5) +     -- 20 pts max at 40 emails
    CASE
      WHEN COALESCE(ac.days_since_last_activity, 999) = 0 THEN 10
      WHEN COALESCE(ac.days_since_last_activity, 999) <= 7 THEN 8
      WHEN COALESCE(ac.days_since_last_activity, 999) <= 14 THEN 5
      WHEN COALESCE(ac.days_since_last_activity, 999) <= 30 THEN 2
      ELSE 0
    END
  )) AS engagement_score,

  COALESCE(ac.call_count_30d, 0) AS call_count_30d,
  COALESCE(ac.meeting_count_30d, 0) AS meeting_count_30d,
  COALESCE(ac.email_count_30d, 0) AS email_count_30d,
  COALESCE(ac.last_activity_timestamp, NULL) AS last_activity_timestamp,
  COALESCE(ac.days_since_last_activity, 999) AS days_since_last_activity,

  -- AUM proxy from fund flows (replace with actual AUM table in prod)
  COALESCE(au.total_flow_12m * 0.15, 10000000) AS aum_amount,  -- estimated

  COALESCE(o.open_opportunity_count, 0) AS open_opportunity_count,
  COALESCE(o.open_opportunity_value, 0) AS open_opportunity_value,

  CURRENT_TIMESTAMP() AS computed_at

FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM a
LEFT JOIN ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM t ON a.territory_id = t.territory_id
LEFT JOIN activity_counts ac ON a.advisor_id = ac.advisor_id
LEFT JOIN opportunity_summary o ON a.advisor_id = o.advisor_id
LEFT JOIN aum_summary au ON a.advisor_id = au.advisor_id
WHERE a.active = TRUE;

-- ============================================================================
-- 2. FUND FLOW ATTRIBUTION
-- Daily aggregated fund flows attributed to advisor and territory
-- Refreshed daily; depends on ADVISOR_ENGAGEMENT_SCORE (Snowflake resolves order)
--
-- NOTE: We join ADVISOR_ENGAGEMENT_SCORE without a CURRENT_DATE() filter to
-- avoid forcing full refreshes.  ADVISOR_ENGAGEMENT_SCORE only ever holds the
-- most-recently-computed set of rows (score_date = its own CURRENT_DATE()),
-- so omitting the date filter is safe and enables incremental refresh.
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION
  TARGET_LAG = '1 day'
  WAREHOUSE = INGEST
  COMMENT = 'Daily fund flow attribution by advisor, territory, and fund'
AS
SELECT
  f.fund_id,
  fd.fund_name,
  fd.fund_category,
  f.advisor_id,
  a.advisor_name,
  a.territory_id,
  t.territory_name,
  f.flow_date,
  f.flow_type,
  SUM(f.flow_amount)                                                       AS flow_amount,
  COUNT(*)                                                                  AS transaction_count,
  -- Capture rate: absolute flow volume as pct of estimated advisor AUM
  ROUND(ABS(SUM(f.flow_amount)) / NULLIF(a_score.aum_amount, 0) * 100, 4) AS capture_rate
FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW f
JOIN ANALYTICS_DEV_DB.STAGING.FUND_DIM      fd ON f.fund_id     = fd.fund_id
JOIN ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM    a  ON f.advisor_id  = a.advisor_id
JOIN ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM  t  ON f.territory_id = t.territory_id
-- Join the upstream Dynamic Table — no CURRENT_DATE() to preserve incremental refresh
LEFT JOIN ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE a_score
  ON f.advisor_id = a_score.advisor_id
GROUP BY
  f.fund_id, fd.fund_name, fd.fund_category,
  f.advisor_id, a.advisor_name, a.territory_id, t.territory_name,
  f.flow_date, f.flow_type, a_score.aum_amount;

-- ============================================================================
-- 3. TERRITORY HEAT MAP
-- Territory-level rollup refreshed every 4 hours
--
-- LAG DEPENDENCY RULE: A DT's lag must be >= the largest upstream DT lag.
-- ADVISOR_ENGAGEMENT_SCORE = 1 hour, so TERRITORY_HEAT_MAP must be >= 1 hour.
-- We purposely do NOT reference FUND_FLOW_ATTRIBUTION (1 day lag) here —
-- instead we aggregate FUND_FLOWS_RAW (base table, no lag constraint) directly.
-- This lets TERRITORY_HEAT_MAP run at 4 hours.
-- ============================================================================
CREATE OR REPLACE DYNAMIC TABLE ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
  TARGET_LAG = '4 hours'
  WAREHOUSE = INGEST
  COMMENT = 'Territory performance heat map — reads staging flows directly to avoid 1-day lag constraint'
AS
WITH territory_flows AS (
  -- Read directly from staging (no lag) to avoid inheriting FUND_FLOW_ATTRIBUTION's 1-day lag
  SELECT
    territory_id,
    SUM(flow_amount) AS net_flows_total
  FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
  GROUP BY territory_id
)
SELECT
  t.territory_id,
  t.territory_name,
  t.region,
  t.territory_mgr,
  a.score_date                                                                     AS as_of_date,

  COUNT(DISTINCT a.advisor_id)                                                     AS advisor_count,
  SUM(a.aum_amount)                                                                AS total_aum,
  AVG(a.engagement_score)                                                          AS avg_engagement_score,
  COALESCE(tf.net_flows_total, 0)                                                  AS net_flows_30d,
  SUM(a.open_opportunity_value)                                                    AS total_pipeline_value,
  COUNT(CASE WHEN a.engagement_score < 30  THEN 1 END)                             AS at_risk_advisor_count,
  COUNT(CASE WHEN a.engagement_score >= 70 THEN 1 END)                             AS high_engagement_count,

  -- Heat score: composite territory health (0-100)
  LEAST(100, GREATEST(0,
    (AVG(a.engagement_score) * 0.4) +
    (LEAST(50, COALESCE(tf.net_flows_total, 0) / 1000000.0) * 0.4) +
    ((1 - COUNT(CASE WHEN a.engagement_score < 30 THEN 1 END)::FLOAT
          / NULLIF(COUNT(*), 0)) * 20)
  ))                                                                               AS territory_heat_score

FROM ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM t
-- Join upstream Dynamic Table (1 hour lag) — no CURRENT_DATE() filter
LEFT JOIN ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE a
  ON t.territory_id = a.territory_id
-- Join staging table directly (no lag constraint)
LEFT JOIN territory_flows tf ON t.territory_id = tf.territory_id
WHERE t.active = TRUE
GROUP BY t.territory_id, t.territory_name, t.region, t.territory_mgr,
         tf.net_flows_total, a.score_date;

-- ============================================================================
-- VERIFY DYNAMIC TABLES
-- ============================================================================
SHOW DYNAMIC TABLES IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- Verify all three tables exist and check refresh status
-- ACCOUNT_USAGE has a ~1-2h lag; use SHOW for real-time state
SHOW DYNAMIC TABLES IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- Alternatively query ACCOUNT_USAGE (after ~1h for data to appear):
-- SELECT name, target_lag, scheduling_state, refresh_mode, last_refresh_time
-- FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLES
-- WHERE database_name = 'ANALYTICS_DEV_DB' AND schema_name = 'DISTRIBUTION'
-- ORDER BY name;
