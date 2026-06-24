-- ============================================================================
-- 01_setup_schema.sql
-- Distribution Insights — Schema, Dimension Tables, and Synthetic Demo Data
--
-- Usage:  snow sql -f scripts/01_setup_schema.sql --connection your_connection
-- Pre:    ANALYTICS_DEV_DB must exist; user must have CREATE SCHEMA privilege
-- Post:   Schemas, tables, and ~200 synthetic advisor rows ready for Dynamic Tables
-- ============================================================================
USE WAREHOUSE INGEST;
USE DATABASE ANALYTICS_DEV_DB;

-- ============================================================================
-- SCHEMAS
-- ============================================================================
CREATE SCHEMA IF NOT EXISTS ANALYTICS_DEV_DB.STAGING
  COMMENT = 'Raw landing zone — Snowpipe V2, Zero-Copy Salesforce shares, ref data';

CREATE SCHEMA IF NOT EXISTS ANALYTICS_DEV_DB.DISTRIBUTION
  COMMENT = 'Curated distribution analytics — Dynamic Tables, Cortex Agent, Semantic View';

-- ============================================================================
-- DIMENSION TABLES (reference data, updated infrequently)
-- ============================================================================

CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM (
  territory_id    VARCHAR(36)    NOT NULL,
  territory_name  VARCHAR(100)   NOT NULL,
  region          VARCHAR(50),
  territory_mgr   VARCHAR(100),
  active          BOOLEAN        DEFAULT TRUE,
  row_timestamp   TIMESTAMP_NTZ  NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Territory reference dimension';

CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.FUND_DIM (
  fund_id       VARCHAR(36)   NOT NULL,
  fund_name     VARCHAR(200)  NOT NULL,
  fund_category VARCHAR(100),
  asset_class   VARCHAR(50),
  benchmark     VARCHAR(100),
  inception_date DATE,
  row_timestamp TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Fund reference dimension';

CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM (
  advisor_id    VARCHAR(36)   NOT NULL,
  advisor_name  VARCHAR(200)  NOT NULL,
  territory_id  VARCHAR(36)   NOT NULL,
  tier          VARCHAR(20),
  hire_date     DATE,
  email         VARCHAR(200),
  active        BOOLEAN       DEFAULT TRUE,
  row_timestamp TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Advisor reference dimension';

-- ============================================================================
-- STAGING / LANDING TABLES
-- ============================================================================

-- Advisor events — Snowpipe V2 target table
CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW (
  event_id        VARCHAR(64)    NOT NULL,
  advisor_id      VARCHAR(36)    NOT NULL,
  territory_id    VARCHAR(36)    NOT NULL,
  event_type      VARCHAR(50)    NOT NULL,   -- CALL | EMAIL | MEETING | EVENT_ATTENDANCE
  event_timestamp TIMESTAMP_NTZ  NOT NULL,
  fund_id         VARCHAR(36),
  aum_amount      NUMBER(18,2),
  opportunity_id  VARCHAR(36),
  metadata        VARIANT,
  row_timestamp   TIMESTAMP_NTZ  NOT NULL DEFAULT SYSDATE()  -- required per AGENTS.md
)
CLUSTER BY (territory_id, DATE_TRUNC('day', event_timestamp))
COMMENT = 'Raw advisor activity events — Snowpipe V2 streaming target';

-- Fund flows — daily transactions
CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW (
  flow_id       VARCHAR(64)    NOT NULL,
  fund_id       VARCHAR(36)    NOT NULL,
  advisor_id    VARCHAR(36)    NOT NULL,
  territory_id  VARCHAR(36)    NOT NULL,
  flow_amount   NUMBER(18,2)   NOT NULL,   -- positive = inflow, negative = outflow
  flow_date     DATE           NOT NULL,
  flow_type     VARCHAR(20)    NOT NULL,   -- INFLOW | OUTFLOW | TRANSFER
  share_class   VARCHAR(10),
  row_timestamp TIMESTAMP_NTZ  NOT NULL DEFAULT SYSDATE()
)
CLUSTER BY (territory_id, flow_date)
COMMENT = 'Fund flow transactions — batch loaded daily';

-- Salesforce Opportunity (mirrors Zero-Copy share schema)
CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.SFDC_OPPORTUNITY (
  opportunity_id VARCHAR(36)   NOT NULL,
  advisor_id     VARCHAR(36)   NOT NULL,
  territory_id   VARCHAR(36)   NOT NULL,
  stage          VARCHAR(50)   NOT NULL,
  amount         NUMBER(18,2),
  close_date     DATE,
  fund_id        VARCHAR(36),
  created_date   TIMESTAMP_NTZ,
  last_modified  TIMESTAMP_NTZ,
  row_timestamp  TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
CLUSTER BY (territory_id)
COMMENT = 'Salesforce Opportunity — dev mock; replace with Zero-Copy share in production';

-- Salesforce Account
CREATE OR REPLACE TABLE ANALYTICS_DEV_DB.STAGING.SFDC_ACCOUNT (
  account_id       VARCHAR(36)   NOT NULL,
  advisor_id       VARCHAR(36)   NOT NULL,
  territory_id     VARCHAR(36)   NOT NULL,
  account_name     VARCHAR(200)  NOT NULL,
  aum_tier         VARCHAR(20),
  relationship_mgr VARCHAR(100),
  last_activity    TIMESTAMP_NTZ,
  row_timestamp    TIMESTAMP_NTZ NOT NULL DEFAULT SYSDATE()
)
COMMENT = 'Salesforce Account — dev mock; replace with Zero-Copy share in production';

-- ============================================================================
-- SEED REFERENCE DATA
-- ============================================================================

INSERT INTO ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM
  (territory_id, territory_name, region, territory_mgr, active, row_timestamp)
VALUES
  ('T001', 'Northeast',  'East',    'John Smith',       TRUE, SYSDATE()),
  ('T002', 'Southeast',  'East',    'Mary Johnson',     TRUE, SYSDATE()),
  ('T003', 'Midwest',    'Central', 'Robert Davis',     TRUE, SYSDATE()),
  ('T004', 'Southwest',  'West',    'Jennifer Wilson',  TRUE, SYSDATE()),
  ('T005', 'Pacific',    'West',    'Michael Brown',    TRUE, SYSDATE());

INSERT INTO ANALYTICS_DEV_DB.STAGING.FUND_DIM
  (fund_id, fund_name, fund_category, asset_class, benchmark, inception_date, row_timestamp)
VALUES
  ('F001', 'Voya Growth Fund',       'Equity',       'Large Cap Growth', 'Russell 1000 Growth', '2010-01-01', SYSDATE()),
  ('F002', 'Voya Income Fund',       'Fixed Income', 'Core Bond',        'Bloomberg US Agg',    '2008-06-15', SYSDATE()),
  ('F003', 'Voya Balanced Fund',     'Multi-Asset',  'Balanced',         '60/40 Blend',         '2012-03-01', SYSDATE()),
  ('F004', 'Voya Small Cap Fund',    'Equity',       'Small Cap',        'Russell 2000',         '2015-09-01', SYSDATE()),
  ('F005', 'Voya International Fund','Equity',       'International',    'MSCI EAFE',            '2011-04-01', SYSDATE());

-- 200 synthetic advisors spread across 5 territories and 4 tiers
-- CTE pattern: generate a single row-number (n) per row so all derived columns
-- reference the same sequence value.  seq4() called once; MOD/UNIFORM used for rest.
INSERT INTO ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM
  (advisor_id, advisor_name, territory_id, tier, hire_date, email, active, row_timestamp)
WITH rn AS (
  SELECT ROW_NUMBER() OVER (ORDER BY seq4()) - 1 AS n
  FROM TABLE(GENERATOR(ROWCOUNT => 200))
)
SELECT
  UUID_STRING()                                                      AS advisor_id,
  'Advisor_' || LPAD(n::VARCHAR, 3, '0')                            AS advisor_name,
  'T00' || (1 + MOD(n, 5))                                          AS territory_id,
  CASE MOD(n, 10)
    WHEN 0 THEN 'PLATINUM'  WHEN 1 THEN 'PLATINUM'
    WHEN 2 THEN 'GOLD'      WHEN 3 THEN 'GOLD'     WHEN 4 THEN 'GOLD'
    WHEN 5 THEN 'SILVER'    WHEN 6 THEN 'SILVER'   WHEN 7 THEN 'SILVER'
    ELSE 'BRONZE'
  END                                                                AS tier,
  DATEADD('day', -1 * UNIFORM(30, 3650, RANDOM()), CURRENT_DATE()) AS hire_date,
  'advisor' || LPAD(n::VARCHAR, 3, '0') || '@voya-demo.com'         AS email,
  TRUE                                                               AS active,
  SYSDATE()                                                          AS row_timestamp
FROM rn;

-- ============================================================================
-- SYNTHETIC ADVISOR EVENTS (30-day history for Dynamic Table seeding)
-- ============================================================================
-- Use UNIFORM() for categorical picks — avoids seq4() multi-call ordering issues
INSERT INTO ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
  (event_id, advisor_id, territory_id, event_type, event_timestamp,
   fund_id, aum_amount, opportunity_id, row_timestamp)
SELECT
  UUID_STRING()                                                 AS event_id,
  a.advisor_id,
  a.territory_id,
  CASE MOD(UNIFORM(0, 100000, RANDOM()), 4)
    WHEN 0 THEN 'CALL'
    WHEN 1 THEN 'MEETING'
    WHEN 2 THEN 'EMAIL'
    ELSE 'EVENT_ATTENDANCE'
  END                                                           AS event_type,
  DATEADD('minute',
    -1 * UNIFORM(0, 43200, RANDOM()),   -- up to 30 days back
    CURRENT_TIMESTAMP())                                        AS event_timestamp,
  'F00' || (1 + MOD(UNIFORM(0, 100000, RANDOM()), 5))          AS fund_id,
  UNIFORM(100000, 50000000, RANDOM())                          AS aum_amount,
  CASE WHEN MOD(UNIFORM(0, 100000, RANDOM()), 3) = 0
    THEN UUID_STRING()
    ELSE NULL
  END                                                           AS opportunity_id,
  SYSDATE()                                                     AS row_timestamp
FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM a
CROSS JOIN TABLE(GENERATOR(ROWCOUNT => 15))   -- ~15 events per advisor
ORDER BY RANDOM();

-- ============================================================================
-- SYNTHETIC FUND FLOWS (90-day history)
-- ============================================================================
INSERT INTO ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
  (flow_id, fund_id, advisor_id, territory_id, flow_amount, flow_date,
   flow_type, share_class, row_timestamp)
SELECT
  UUID_STRING()                                                AS flow_id,
  'F00' || (1 + MOD(UNIFORM(0, 100000, RANDOM()), 5))         AS fund_id,
  a.advisor_id,
  a.territory_id,
  CASE WHEN MOD(UNIFORM(0, 100000, RANDOM()), 4) = 0
    THEN -1 * UNIFORM(10000, 500000, RANDOM())     -- outflow
    ELSE UNIFORM(25000, 2000000, RANDOM())          -- inflow
  END                                                          AS flow_amount,
  DATEADD('day', -1 * UNIFORM(0, 90, RANDOM()), CURRENT_DATE()) AS flow_date,
  CASE WHEN MOD(UNIFORM(0, 100000, RANDOM()), 4) = 0
    THEN 'OUTFLOW' ELSE 'INFLOW'
  END                                                          AS flow_type,
  CASE MOD(UNIFORM(0, 100000, RANDOM()), 3)
    WHEN 0 THEN 'A' WHEN 1 THEN 'I' ELSE 'R'
  END                                                          AS share_class,
  SYSDATE()                                                    AS row_timestamp
FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM a
CROSS JOIN TABLE(GENERATOR(ROWCOUNT => 20))   -- ~20 flow records per advisor
ORDER BY RANDOM();

-- ============================================================================
-- SYNTHETIC SALESFORCE OPPORTUNITIES
-- ============================================================================
INSERT INTO ANALYTICS_DEV_DB.STAGING.SFDC_OPPORTUNITY
  (opportunity_id, advisor_id, territory_id, stage, amount, close_date,
   fund_id, created_date, last_modified, row_timestamp)
SELECT
  UUID_STRING()                                                     AS opportunity_id,
  a.advisor_id,
  a.territory_id,
  CASE MOD(UNIFORM(0, 100000, RANDOM()), 5)
    WHEN 0 THEN 'Prospecting'
    WHEN 1 THEN 'Qualification'
    WHEN 2 THEN 'Proposal/Quote'
    WHEN 3 THEN 'Negotiation'
    ELSE 'Closed Won'
  END                                                               AS stage,
  UNIFORM(100000, 10000000, RANDOM())                               AS amount,
  DATEADD('day', UNIFORM(1, 120, RANDOM()), CURRENT_DATE())        AS close_date,
  'F00' || (1 + MOD(UNIFORM(0, 100000, RANDOM()), 5))              AS fund_id,
  DATEADD('day', -1 * UNIFORM(1, 180, RANDOM()), CURRENT_DATE())   AS created_date,
  DATEADD('day', -1 * UNIFORM(0, 30, RANDOM()), CURRENT_DATE())    AS last_modified,
  SYSDATE()                                                         AS row_timestamp
FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM a
CROSS JOIN TABLE(GENERATOR(ROWCOUNT => 5))
WHERE a.tier IN ('PLATINUM', 'GOLD');  -- only active sellers get opps

-- ============================================================================
-- VERIFICATION
-- ============================================================================
SELECT 'TERRITORY_DIM'   AS tbl, COUNT(*) AS row_count FROM ANALYTICS_DEV_DB.STAGING.TERRITORY_DIM
UNION ALL
SELECT 'FUND_DIM',                COUNT(*)           FROM ANALYTICS_DEV_DB.STAGING.FUND_DIM
UNION ALL
SELECT 'ADVISOR_DIM',             COUNT(*)           FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_DIM
UNION ALL
SELECT 'ADVISOR_EVENTS_RAW',      COUNT(*)           FROM ANALYTICS_DEV_DB.STAGING.ADVISOR_EVENTS_RAW
UNION ALL
SELECT 'FUND_FLOWS_RAW',          COUNT(*)           FROM ANALYTICS_DEV_DB.STAGING.FUND_FLOWS_RAW
UNION ALL
SELECT 'SFDC_OPPORTUNITY',        COUNT(*)           FROM ANALYTICS_DEV_DB.STAGING.SFDC_OPPORTUNITY
ORDER BY 1;
