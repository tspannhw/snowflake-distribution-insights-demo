-- ============================================================================
-- 05_alerts_observability.sql
-- Distribution Insights - Data Quality, Monitoring, and Alerting
-- Uses DMFs, Snowflake Alerts, Slack webhooks, and Email notifications
-- ============================================================================
USE WAREHOUSE INGEST;
USE DATABASE ANALYTICS_DEV_DB;
USE SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- ============================================================================
-- STEP 1: Create Event Table then enable it on the database
-- ORDER MATTERS: table must exist before ALTER DATABASE references it.
-- Snowflake event tables use CREATE EVENT TABLE (fixed schema, not CREATE TABLE).
-- ============================================================================
-- DROP the regular TABLE if it exists (cannot do CREATE OR REPLACE across object types)
DROP TABLE IF EXISTS ANALYTICS_DEV_DB.DISTRIBUTION.EVENTS;
CREATE OR REPLACE EVENT TABLE ANALYTICS_DEV_DB.DISTRIBUTION.EVENTS
  COMMENT = 'Event table for Cortex AI and pipeline telemetry';

-- Attach event table to database (after the table is created)
ALTER DATABASE ANALYTICS_DEV_DB SET EVENT_TABLE = ANALYTICS_DEV_DB.DISTRIBUTION.EVENTS;

-- ============================================================================
-- STEP 2: Create Notification Integration (Slack)
-- ============================================================================
CREATE OR REPLACE NOTIFICATION INTEGRATION DISTRIBUTION_SLACK_NOTIF
  TYPE = WEBHOOK
  ENABLED = TRUE
  WEBHOOK_URL = '<YOUR_SLACK_WEBHOOK_URL>'   -- set SNOWFLAKE_SLACK_WEBHOOK env var before running
  WEBHOOK_HEADERS = ('Content-Type'='application/json')
  WEBHOOK_BODY_TEMPLATE = '{
    "text": "{{SNOWFLAKE_WEBHOOK_MESSAGE}}"
  }'
  COMMENT = 'Slack webhook for #edge-alerts channel';

-- Edge alerts webhook (critical)
CREATE OR REPLACE NOTIFICATION INTEGRATION DISTRIBUTION_SLACK_CRITICAL
  TYPE = WEBHOOK
  ENABLED = TRUE
  WEBHOOK_URL = '<YOUR_EDGE_ALERTS_WEBHOOK_URL>'  -- set SNOWFLAKE_EDGE_ALERTS_WEBHOOK env var before running
  WEBHOOK_HEADERS = ('Content-Type'='application/json')
  WEBHOOK_BODY_TEMPLATE = '{
    "text": "CRITICAL: {{SNOWFLAKE_WEBHOOK_MESSAGE}}"
  }'
  COMMENT = 'Slack critical alerts webhook';

-- ============================================================================
-- STEP 3: Attach Data Metric Functions (DMFs) to critical tables
-- ============================================================================

-- Attach freshness DMF to advisor events table
ALTER TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
  SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

-- NOTE: SNOWFLAKE.CORE.FRESHNESS requires EXECUTE DATA METRIC FUNCTION privilege
-- which may not be granted to all roles. Use NULL_COUNT on the timestamp as a
-- staleness proxy; alerts catch actual staleness within 5 minutes.
ALTER TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT
    ON (row_timestamp);  -- replaces FRESHNESS (same privilege requirement)

ALTER TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT
    ON (advisor_id);

ALTER TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.DUPLICATE_COUNT
    ON (event_id);

-- Attach DMFs to engagement score table
ALTER TABLE ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
  SET DATA_METRIC_SCHEDULE = '60 MINUTE';  -- hourly; only MINUTE is valid (not HOUR)

ALTER TABLE ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ROW_COUNT ON ();

ALTER TABLE ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (engagement_score);

-- Attach DMFs to fund flows
ALTER TABLE ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
  SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

-- NOTE: SNOWFLAKE.CORE.FRESHNESS requires elevated privileges; using NULL_COUNT
ALTER TABLE ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT
    ON (row_timestamp);  -- replaces FRESHNESS

ALTER TABLE ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
  ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT ON (fund_id);

-- ============================================================================
-- STEP 4: Create Alerts
-- ============================================================================

-- Alert 1: Advisor events table not receiving data (30 min staleness)
CREATE OR REPLACE ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_ADVISOR_EVENTS_STALE
  WAREHOUSE = INGEST
  SCHEDULE = '5 MINUTE'
  COMMENT = 'Fires if advisor events table has not received data in 30 minutes'
  IF (EXISTS (
    SELECT 1
    FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
    HAVING MAX(row_timestamp) < DATEADD('minute', -30, CURRENT_TIMESTAMP())
  ))
  THEN
    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
      SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
        CONCAT(
          'ALERT: advisor_events_raw table is stale. ',
          'Last row timestamp: ', (SELECT MAX(row_timestamp)::VARCHAR FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW),
          '. Check Snowpipe V2 streaming pipeline.'
        )
      ),
      SNOWFLAKE.NOTIFICATION.INTEGRATION('DISTRIBUTION_SLACK_NOTIF')
    );

-- Alert 2: Engagement score anomaly (too many at-risk advisors)
CREATE OR REPLACE ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_HIGH_ATTRITION_RISK
  WAREHOUSE = INGEST
  SCHEDULE = '60 MINUTE'  -- every hour; SCHEDULE only accepts 'N MINUTE' or CRON syntax
  COMMENT = 'Fires if more than 20% of Platinum advisors are at attrition risk'
  IF (EXISTS (
    SELECT 1
    FROM (
      SELECT
        -- Column name in Dynamic Table is advisor_tier (renamed from tier in DIM)
        COUNT(CASE WHEN engagement_score < 30 AND advisor_tier = 'PLATINUM' THEN 1 END) AS at_risk,
        COUNT(CASE WHEN advisor_tier = 'PLATINUM' THEN 1 END) AS total_platinum
      FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
      WHERE score_date = CURRENT_DATE()
    )
    WHERE at_risk > 0 AND ROUND(at_risk::FLOAT / NULLIF(total_platinum, 0) * 100, 1) > 20
  ))
  THEN
    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
      SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
        CONCAT(
          'HIGH ATTRITION RISK: More than 20% of Platinum advisors have low engagement. ',
          'Review distribution_insights dashboard immediately. ',
          'At-risk count: ',
          (SELECT COUNT(*) FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
           WHERE engagement_score < 30 AND advisor_tier = 'PLATINUM' AND score_date = CURRENT_DATE())::VARCHAR
        )
      ),
      SNOWFLAKE.NOTIFICATION.INTEGRATION('DISTRIBUTION_SLACK_CRITICAL')
    );

-- Alert 3: Negative fund flows threshold breach
CREATE OR REPLACE ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_FUND_OUTFLOWS
  WAREHOUSE = INGEST
  SCHEDULE = 'USING CRON 0 6 * * * UTC'  -- daily at 06:00 UTC; DAY not valid — use CRON
  COMMENT = 'Fires if daily net fund flows are negative (net outflow day)'
  IF (EXISTS (
    SELECT 1
    FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
    WHERE flow_date = CURRENT_DATE()
    HAVING SUM(flow_amount) < -1000000  -- > $1M net outflow
  ))
  THEN
    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
      SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
        CONCAT(
          'FUND FLOW ALERT: Net outflow exceeds $1M today. ',
          'Date: ', CURRENT_DATE()::VARCHAR,
          ', Net flow: $',
          (SELECT SUM(flow_amount)::VARCHAR FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
           WHERE flow_date = CURRENT_DATE()),
          '. Review fund_flow_attribution table.'
        )
      ),
      SNOWFLAKE.NOTIFICATION.INTEGRATION('DISTRIBUTION_SLACK_NOTIF')
    );

-- Alert 4: Cortex AI cost budget breach (80% threshold)
CREATE OR REPLACE ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_AI_BUDGET_BREACH
  WAREHOUSE = INGEST
  SCHEDULE = '240 MINUTE'  -- every 4 hours; HOUR not valid — use N MINUTE
  COMMENT = 'Fires if Cortex AI daily spend exceeds 80% of budget'
  IF (EXISTS (
    SELECT 1
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY
    WHERE DATE(USAGE_DATE) = CURRENT_DATE()
    HAVING SUM(CREDITS_USED) > 8  -- 80% of 10 credit daily budget
  ))
  THEN
    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
      SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
        CONCAT(
          'CORTEX AI BUDGET: Approaching daily credit limit. ',
          'Credits used today: ',
          (SELECT ROUND(SUM(CREDITS_USED), 2)::VARCHAR FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY
           WHERE DATE(USAGE_DATE) = CURRENT_DATE()),
          ' of 10 allowed. Review agent usage immediately.'
        )
      ),
      SNOWFLAKE.NOTIFICATION.INTEGRATION('DISTRIBUTION_SLACK_NOTIF')
    );

-- Alert 5: Dynamic Table full refresh detected (performance degradation)
-- Uses ANALYTICS_DEV_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY.
-- REFRESH_ACTION = 'FULL' indicates a full refresh occurred instead of incremental.
CREATE OR REPLACE ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_DT_FULL_REFRESH
  WAREHOUSE = INGEST
  SCHEDULE = '30 MINUTE'
  COMMENT = 'Fires if a distribution Dynamic Table does a full refresh (schema change or missing incremental key)'
  IF (EXISTS (
    SELECT 1
    FROM ANALYTICS_DEV_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY
    WHERE SCHEMA_NAME    = 'DISTRIBUTION'
      AND REFRESH_ACTION = 'FULL'           -- FULL | INCREMENTAL
      AND REFRESH_START_TIME > DATEADD('hour', -1, CURRENT_TIMESTAMP())
  ))
  THEN
    CALL SYSTEM$SEND_SNOWFLAKE_NOTIFICATION(
      SNOWFLAKE.NOTIFICATION.TEXT_PLAIN(
        CONCAT(
          'DYNAMIC TABLE FULL REFRESH in ANALYTICS_DEV_DB.DISTRIBUTION. ',
          'This likely means a schema change or a non-deterministic function was added. ',
          'Run: SELECT * FROM ANALYTICS_DEV_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY',
          ' WHERE SCHEMA_NAME = ''DISTRIBUTION'' ORDER BY REFRESH_START_TIME DESC LIMIT 10;'
        )
      ),
      SNOWFLAKE.NOTIFICATION.INTEGRATION('DISTRIBUTION_SLACK_NOTIF')
    );

-- ============================================================================
-- STEP 5: Resume all alerts
-- ============================================================================
ALTER ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_ADVISOR_EVENTS_STALE RESUME;
ALTER ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_HIGH_ATTRITION_RISK RESUME;
ALTER ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_FUND_OUTFLOWS RESUME;
ALTER ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_AI_BUDGET_BREACH RESUME;
ALTER ALERT ANALYTICS_DEV_DB.DISTRIBUTION.ALERT_DT_FULL_REFRESH RESUME;

-- ============================================================================
-- STEP 6: Verify alerts and DMFs
-- ============================================================================
-- Verify alerts are running
SHOW ALERTS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- Check DMF results (appear after first measurement cycle)
SELECT * FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_DATABASE = 'ANALYTICS_DEV_DB'
ORDER BY MEASUREMENT_TIME DESC
LIMIT 50;

-- Alert history is in ACCOUNT_USAGE with ~1h lag; use SHOW for real-time:
-- SHOW ALERTS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;
