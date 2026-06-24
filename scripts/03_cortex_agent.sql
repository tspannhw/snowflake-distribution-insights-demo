-- ============================================================================
-- 03_cortex_agent.sql
-- Distribution Insights — Cortex Agent, Cortex Search, Stage
--
-- Validated DDL (June 2026, docs.snowflake.com/sql-reference/sql/create-agent):
--
--   CREATE [OR REPLACE] AGENT <name>
--     [COMMENT = '...']
--     [PROFILE = '{"display_name": "...", "color": "..."}']
--     FROM SPECIFICATION
--     $$ <yaml_spec> $$;
--
--   ALTER AGENT <name> MODIFY LIVE VERSION SET SPECIFICATION = $$ <yaml> $$;
--
-- Tool resource key for Cortex Analyst:
--   semantic_view: "<db>.<schema>.<view_name>"   ← SQL semantic view object
--   semantic_model_file: "@stage/file.yaml"      ← YAML file on stage (alt)
--
-- Tool resource key for Cortex Search:
--   name: "<db>.<schema>.<service_name>"
--
-- INVALID (confirmed):
--   CREATE CORTEX AGENT          → use CREATE AGENT
--   WAREHOUSE = ...              → not a valid agent property
--   CREATE CORTEX ANALYST SEMANTIC MODEL  → no SQL DDL for YAML models;
--                                           use semantic_model_file in spec
-- ============================================================================
USE WAREHOUSE INGEST;
USE DATABASE ANALYTICS_DEV_DB;
USE SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- ============================================================================
-- STEP 1: Stage for semantic view YAML
-- ============================================================================
CREATE STAGE IF NOT EXISTS ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Stage for Cortex Agent YAML artifacts';

-- Upload YAML from project root before creating the agent:
--   snow stage copy scripts/02_semantic_view.yaml \
--     @ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/ --connection your_connection --overwrite
--
-- To verify the file is staged:
--   LIST @ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE;

-- ============================================================================
-- STEP 2: Cortex Search Service — fund documentation
-- ============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE ANALYTICS_DEV_DB.DISTRIBUTION.FUND_DOCS_SEARCH
  ON search_text
  ATTRIBUTES fund_id, fund_name, fund_category
  WAREHOUSE = INGEST
  TARGET_LAG = '1 hour'
  AS (
    SELECT
      fund_id,
      fund_name,
      fund_category,
      benchmark,
      CONCAT(
        fund_name, ' is a ', fund_category,
        ' fund benchmarked against ', COALESCE(benchmark, 'N/A'),
        '. Asset class: ', COALESCE(asset_class, 'Unknown'), '.'
      ) AS search_text
    FROM ANALYTICS_DEV_DB.STAGING.FUND_DIM
    WHERE fund_id IS NOT NULL
  );

-- ============================================================================
-- STEP 3: Cortex Agent with tools and system prompt
--
-- Uses semantic_model_file (YAML on stage) for Cortex Analyst tool.
-- If you create a native SEMANTIC VIEW SQL object instead, replace with:
--   semantic_view: "ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV"
-- ============================================================================
CREATE OR REPLACE AGENT ANALYTICS_DEV_DB.DISTRIBUTION.distribution_insights_agent
  COMMENT = 'Distribution analytics agent for ACME IM — advisor, territory, fund, and pipeline insights'
  PROFILE = '{"display_name": "Distribution Insights Assistant", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: mistral-7b

  orchestration:
    budget:
      seconds: 60
      tokens: 32000

  instructions:
    response: "Be concise and data-driven. Format AUM in $B or $M, flows in $M, percentages with 1 decimal."
    orchestration: "For advisor, territory, pipeline, and fund questions use DistributionAnalyst. For fund documentation and product details use FundSearch."
    sample_questions:
      - question: "Who are the top 5 advisors by AUM in the Northeast?"
      - question: "Which territories have the highest attrition risk?"
      - question: "Show net fund flows by category this quarter."
      - question: "Which high-AUM advisors have had no activity in 14 days?"

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: DistributionAnalyst
        description: "Answer questions about advisor engagement scores, territory performance, fund flows, and sales pipeline. Use for any numeric or aggregated distribution analytics question."
    - tool_spec:
        type: cortex_search
        name: FundSearch
        description: "Search fund documentation including fund names, categories, benchmarks, and asset class descriptions. Use when the user asks about specific fund products or characteristics."
    - tool_spec:
        type: data_to_chart
        name: data_to_chart
        description: "Generate visualizations from query results. Use when the user asks for a chart, graph, or visual comparison."

  tool_resources:
    DistributionAnalyst:
      semantic_model_file: "@ANALYTICS_DEV_DB.DISTRIBUTION.AGENT_STAGE/02_semantic_view.yaml"
    FundSearch:
      name: ANALYTICS_DEV_DB.DISTRIBUTION.FUND_DOCS_SEARCH
      max_results: "5"
  $$;

-- ============================================================================
-- STEP 4: Verification
-- ============================================================================
SHOW AGENTS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;
SHOW CORTEX SEARCH SERVICES IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;
SHOW STAGES IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;

-- ============================================================================
-- STEP 5: Functional tests (require Dynamic Tables to be populated)
-- ============================================================================

-- Test A: Cortex Complete — verifies LLM access and mistral-7b availability
SELECT SNOWFLAKE.CORTEX.COMPLETE(
  'mistral-7b',
  'In one sentence, describe what a distribution analytics assistant does for an asset manager.'
) AS model_test;

-- Test B: AI territory summary from live Dynamic Table
SELECT SNOWFLAKE.CORTEX.COMPLETE(
  'mistral-7b',
  CONCAT(
    'Summarize this territory data in 3 bullet points for a wholesaler. Be specific with numbers. ',
    (SELECT OBJECT_CONSTRUCT(
        'territory',    territory_name,
        'aum_m',        ROUND(total_aum / 1e6, 1),
        'advisors',     advisor_count,
        'engagement',   ROUND(avg_engagement_score, 1),
        'flows_30d_m',  ROUND(net_flows_30d / 1e6, 2),
        'at_risk',      at_risk_advisor_count
    )::VARCHAR
    FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
    ORDER BY territory_heat_score DESC
    LIMIT 1)
  )
) AS territory_brief;

-- Test C: Attrition risk classification on Platinum advisors
-- Column is advisor_tier (renamed from tier in DIM table)
SELECT
  advisor_name,
  advisor_tier,
  ROUND(engagement_score, 1)  AS engagement,
  ROUND(aum_amount / 1e6, 2)  AS aum_m,
  SNOWFLAKE.CORTEX.COMPLETE(
    'mistral-7b',
    CONCAT(
      'Classify attrition risk as HIGH, MEDIUM, or LOW. ',
      'Score: ', engagement_score::VARCHAR, '/100  ',
      'Calls: ', call_count_30d::VARCHAR, '  ',
      'Meetings: ', meeting_count_30d::VARCHAR, '  ',
      'Days inactive: ', days_since_last_activity::VARCHAR, '. ',
      'Reply with one word only.'
    )
  ) AS attrition_risk
FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
WHERE advisor_tier = 'PLATINUM'
ORDER BY aum_amount DESC
LIMIT 5;
