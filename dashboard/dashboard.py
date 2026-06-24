"""
distribution_insights.py
Streamlit in Snowflake Dashboard — Distribution Analytics
ACME IM | Powered by Snowflake Cortex AI

Features:
- Role-aware (WHOLESALER, TERRITORY_MANAGER, DISTRIBUTION_ANALYST, ADMIN)
- Real-time data from Dynamic Tables
- Cortex Analyst chat panel (natural language queries)
- DMF data quality health panel
- Alert status panel
- Territory heat map
- Advisor engagement table

Deployment:
  snow streamlit deploy --name DISTRIBUTION_INSIGHTS --database ANALYTICS_DEV_DB --schema DISTRIBUTION
"""

import streamlit as st
import pandas as pd
import json
from snowflake.cortex import Complete

# ============================================================================
# SESSION — works both in Streamlit in Snowflake and local `streamlit run`
#
# Local dev: run via manage.sh which sets SNOWFLAKE_DEFAULT_CONNECTION_NAME.
#   ./manage.sh run-dashboard
# The env var is picked up by Session.builder automatically.
# ============================================================================
_SESSION_ERROR: str | None = None

def _get_session():
    global _SESSION_ERROR
    # 1. Inside Streamlit in Snowflake
    try:
        from snowflake.snowpark.context import get_active_session
        return get_active_session()
    except Exception:
        pass
    # 2. Local dev — read connections.toml and resolve private_key_path manually.
    #    Session.builder.config("connection_name", ...) doesn't resolve key files.
    try:
        import os, tomllib
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        from snowflake.snowpark import Session

        toml_path = os.path.expanduser("~/.snowflake/connections.toml")
        with open(toml_path, "rb") as f:
            all_conns = tomllib.load(f)

        conn_name = os.environ.get("SNOWFLAKE_DEFAULT_CONNECTION_NAME", "your_connection")
        conn_cfg = dict(all_conns.get(conn_name, {}))

        # Resolve private_key_path → private_key bytes (keypair auth)
        if "private_key_path" in conn_cfg:
            key_path = os.path.expanduser(conn_cfg.pop("private_key_path"))
            with open(key_path, "rb") as f:
                conn_cfg["private_key"] = load_pem_private_key(f.read(), password=None)

        return Session.builder.configs(conn_cfg).create()
    except Exception as exc:
        _SESSION_ERROR = str(exc)
        return None

session = _get_session()

st.set_page_config(
    page_title="Distribution Insights | ACME IM",
    page_icon="📊",
    layout="wide"
)

# Show connection error banner immediately if no session could be established
if session is None:
    st.error(
        f"**No Snowflake session.** Run via `./manage.sh run-dashboard` which sets "
        f"`SNOWFLAKE_DEFAULT_CONNECTION_NAME=your_connection` before launching Streamlit.\n\n"
        f"Error: `{_SESSION_ERROR}`"
    )
    st.stop()

# ============================================================================
# HELPERS
# ============================================================================

@st.cache_data(ttl=300)  # 5-minute cache
def run_query(sql: str) -> pd.DataFrame:
    """Execute SQL and return DataFrame."""
    if session is None:
        return pd.DataFrame()
    return session.sql(sql).to_pandas()


def get_user_role() -> str:
    """Detect current user's highest distribution role."""
    result = session.sql("SELECT CURRENT_ROLE()").collect()
    role = result[0][0].upper()
    if "ADMIN" in role or "SYSADMIN" in role:
        return "ADMIN"
    elif "TERRITORY_MANAGER" in role:
        return "TERRITORY_MANAGER"
    elif "WHOLESALER" in role:
        return "WHOLESALER"
    else:
        return "DISTRIBUTION_ANALYST"


def send_cortex_analyst_query(question: str) -> dict:
    """Call Cortex Analyst REST API. Uses _snowflake in SiS; falls back to urllib locally."""
    payload = {
        'messages': [{'role': 'user', 'content': [{'type': 'text', 'text': question}]}],
        'semantic_view': 'ANALYTICS_DEV_DB.DISTRIBUTION.DISTRIBUTION_INSIGHTS_SV',
    }

    def _parse(body: dict) -> dict:
        for item in body.get('message', {}).get('content', []):
            if item.get('type') == 'sql':
                return {'sql': item.get('statement', '')}
        return {'sql': '', 'message': json.dumps(body)}

    # Path 1: Streamlit in Snowflake / Snowflake Notebooks (_snowflake module)
    try:
        import _snowflake
        response = _snowflake.send_snow_api_request(
            'POST', '/api/v2/cortex/analyst/message', {}, {}, payload, None, 30000
        )
        if response.get('status') == 200:
            return _parse(json.loads(response['content']))
        return {'sql': '', 'message': f"API error {response.get('status')}: {response.get('content')}"}
    except ImportError:
        pass  # not in SiS — fall through to local REST path
    except Exception as e:
        return {'sql': '', 'message': f'Cortex Analyst SiS error: {e}'}

    # Path 2: Local dev — call REST API directly using session token
    try:
        import os, tomllib, urllib.request, urllib.error
        from cryptography.hazmat.primitives.serialization import load_pem_private_key
        import snowflake.connector
        _cn = os.environ.get('SNOWFLAKE_DEFAULT_CONNECTION_NAME', 'your_connection')
        with open(os.path.expanduser('~/.snowflake/connections.toml'), 'rb') as _f:
            _cfg = tomllib.load(_f)[_cn]
        _kp = os.path.expanduser(_cfg['private_key_path'])
        with open(_kp, 'rb') as _f:
            _pk = load_pem_private_key(_f.read(), password=None)
        _p = {k: v for k, v in _cfg.items() if k != 'private_key_path'}
        _p['private_key'] = _pk
        _rc = snowflake.connector.connect(**_p)
        _tok = _rc.rest.token
        _rc.close()
        _host = f"{_cfg['account']}.snowflakecomputing.com"
        _url = f'https://{_host}/api/v2/cortex/analyst/message'
        _req = urllib.request.Request(
            _url, data=json.dumps(payload).encode(),
            headers={'Authorization': f'Snowflake Token="{_tok}"',
                     'Content-Type': 'application/json'},
            method='POST'
        )
        with urllib.request.urlopen(_req) as _r:
            return _parse(json.loads(_r.read()))
    except Exception as e:
        return {'sql': '', 'message': f'Cortex Analyst unavailable locally: {e}'}


def get_ai_summary(data_context: str, prompt_prefix: str) -> str:
    """Generate AI summary using Cortex Complete (mistral-7b for cost efficiency)."""
    try:
        prompt = f"{prompt_prefix}\n\nData: {data_context}\n\nSummary:"
        return Complete("mistral-7b", prompt)
    except Exception as e:
        return f"AI summary unavailable: {str(e)}"


# ============================================================================
# HEADER
# ============================================================================
col_logo, col_title = st.columns([1, 6])
with col_title:
    st.title("Distribution Insights")
    st.caption("Powered by Snowflake Cortex AI | Real-time from Dynamic Tables")

user_role = get_user_role()
st.sidebar.metric("Current Role", user_role)
st.sidebar.info("Data refreshes every 5 minutes. Dynamic Tables update hourly.")

# ============================================================================
# NAVIGATION
# ============================================================================
tabs = st.tabs([
    "Overview",
    "Territory Map",
    "Advisors",
    "Fund Flows",
    "Ask Cortex Analyst",
    "Data Health"
])

# ============================================================================
# TAB 1: OVERVIEW
# ============================================================================
with tabs[0]:
    st.header("Distribution Overview")

    # KPI metrics row
    kpi_sql = """
        SELECT
            COUNT(DISTINCT advisor_id) AS total_advisors,
            SUM(aum_amount) AS total_aum,
            AVG(engagement_score) AS avg_engagement,
            COUNT(CASE WHEN engagement_score < 30 THEN 1 END) AS at_risk_advisors,
            SUM(open_opportunity_value) AS total_pipeline
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
        WHERE score_date = (SELECT MAX(score_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE)
    """
    try:
        kpi_df = run_query(kpi_sql)
        kpi = kpi_df.iloc[0]

        col1, col2, col3, col4, col5 = st.columns(5)
        col1.metric("Active Advisors", f"{int(kpi['TOTAL_ADVISORS']):,}")
        col2.metric("Total AUM", f"${kpi['TOTAL_AUM'] / 1e9:.1f}B")
        col3.metric("Avg Engagement", f"{kpi['AVG_ENGAGEMENT']:.0f}/100")
        col4.metric(
            "At-Risk Advisors",
            f"{int(kpi['AT_RISK_ADVISORS']):,}",
            delta=f"-{int(kpi['AT_RISK_ADVISORS'])} vs target: 0",
            delta_color="inverse"
        )
        col5.metric("Open Pipeline", f"${kpi['TOTAL_PIPELINE'] / 1e6:.0f}M")
    except Exception as e:
        st.error(f"Unable to load KPI data: {e}")

    st.divider()

    # AI-generated morning brief
    st.subheader("AI Morning Brief")
    if st.button("Generate Today's Brief", type="primary"):
        with st.spinner("Cortex AI generating brief..."):
            context_sql = """
                SELECT OBJECT_CONSTRUCT(
                    'total_advisors', COUNT(DISTINCT advisor_id),
                    'avg_engagement', ROUND(AVG(engagement_score), 1),
                    'at_risk_count', COUNT(CASE WHEN engagement_score < 30 THEN 1 END),
                    'top_territory', (SELECT territory_name FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
                                     WHERE as_of_date = (SELECT MAX(as_of_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP) ORDER BY net_flows_30d DESC LIMIT 1),
                    'total_pipeline_m', ROUND(SUM(open_opportunity_value) / 1e6, 1)
                )::VARCHAR AS context
                FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
                WHERE score_date = (SELECT MAX(score_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE)
            """
            try:
                context = run_query(context_sql).iloc[0]["CONTEXT"]
                brief = get_ai_summary(
                    context,
                    "You are a distribution analytics assistant. Create a 3-bullet morning brief for a distribution manager. "
                    "Focus on engagement trends, pipeline health, and at-risk advisors. Be concise and actionable."
                )
                st.info(brief)
            except Exception as e:
                st.warning(f"Brief generation failed: {e}")

    # Territory comparison chart
    st.subheader("Territory Performance")
    territory_sql = """
        SELECT
            territory_name,
            ROUND(total_aum / 1e6, 1) AS aum_millions,
            ROUND(avg_engagement_score, 1) AS engagement_score,
            ROUND(net_flows_30d / 1e6, 2) AS net_flows_m,
            at_risk_advisor_count,
            advisor_count
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
        WHERE as_of_date = (SELECT MAX(as_of_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP)
        ORDER BY total_aum DESC
    """
    try:
        territory_df = run_query(territory_sql)
        st.dataframe(
            territory_df,
            use_container_width=True,
            column_config={
                "TERRITORY_NAME": "Territory",
                "AUM_MILLIONS": st.column_config.NumberColumn("AUM ($M)", format="$%.1f"),
                "ENGAGEMENT_SCORE": st.column_config.ProgressColumn("Engagement", max_value=100),
                "NET_FLOWS_M": st.column_config.NumberColumn("Net Flows 30d ($M)", format="$%.2f"),
                "AT_RISK_ADVISOR_COUNT": st.column_config.NumberColumn("At-Risk Advisors"),
                "ADVISOR_COUNT": "Advisors"
            }
        )
    except Exception as e:
        st.error(f"Territory data unavailable: {e}")

# ============================================================================
# TAB 2: TERRITORY MAP
# ============================================================================
with tabs[1]:
    st.header("Territory Heat Map")
    st.info("Territory scores are computed by Cortex AI from engagement, flows, and AUM data.")

    territory_heat_sql = """
        SELECT
            territory_name,
            region,
            territory_mgr,
            ROUND(total_aum / 1e6, 1) AS aum_m,
            ROUND(avg_engagement_score, 1) AS avg_engagement,
            ROUND(net_flows_30d / 1e6, 2) AS net_flows_m,
            advisor_count,
            at_risk_advisor_count,
            ROUND(territory_heat_score, 1) AS heat_score
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
        WHERE as_of_date = (SELECT MAX(as_of_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP)
        ORDER BY heat_score DESC
    """
    try:
        heat_df = run_query(territory_heat_sql)
        for _, row in heat_df.iterrows():
            score = row["HEAT_SCORE"]
            color = "🟢" if score >= 70 else "🟡" if score >= 40 else "🔴"
            with st.expander(f"{color} {row['TERRITORY_NAME']} — Heat Score: {score:.0f}/100"):
                c1, c2, c3, c4 = st.columns(4)
                c1.metric("AUM", f"${row['AUM_M']:.1f}M")
                c2.metric("Engagement", f"{row['AVG_ENGAGEMENT']:.1f}/100")
                c3.metric("Net Flows 30d", f"${row['NET_FLOWS_M']:.2f}M")
                c4.metric("At-Risk Advisors", int(row["AT_RISK_ADVISOR_COUNT"]))
                st.caption(f"Manager: {row['TERRITORY_MGR']} | Region: {row['REGION']} | Advisors: {row['ADVISOR_COUNT']}")
    except Exception as e:
        st.error(f"Heat map unavailable: {e}")

# ============================================================================
# TAB 3: ADVISORS
# ============================================================================
with tabs[2]:
    st.header("Advisor Engagement")

    col_filter1, col_filter2 = st.columns(2)

    with col_filter1:
        territory_options = ["All Territories"] + list(
            run_query("SELECT DISTINCT territory_name FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP ORDER BY 1")["TERRITORY_NAME"].tolist()
        )
        selected_territory = st.selectbox("Territory", territory_options)

    with col_filter2:
        tier_options = ["All Tiers", "PLATINUM", "GOLD", "SILVER", "BRONZE"]
        selected_tier = st.selectbox("Advisor Tier", tier_options)

    where_clauses = ["score_date = (SELECT MAX(score_date) FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE)"]
    if selected_territory != "All Territories":
        where_clauses.append(f"territory_name = '{selected_territory}'")
    if selected_tier != "All Tiers":
        where_clauses.append(f"advisor_tier = '{selected_tier}'")

    advisor_sql = f"""
        SELECT
            advisor_name,
            territory_name,
            advisor_tier AS tier,
            ROUND(engagement_score, 1) AS engagement_score,
            ROUND(aum_amount / 1e6, 2) AS aum_millions,
            call_count_30d,
            meeting_count_30d,
            open_opportunity_count,
            ROUND(open_opportunity_value / 1e6, 2) AS pipeline_millions,
            days_since_last_activity
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
        WHERE {' AND '.join(where_clauses)}
        ORDER BY aum_amount DESC
        LIMIT 100
    """
    try:
        advisor_df = run_query(advisor_sql)
        st.dataframe(
            advisor_df,
            use_container_width=True,
            column_config={
                "ENGAGEMENT_SCORE": st.column_config.ProgressColumn("Engagement", max_value=100),
                "AUM_MILLIONS": st.column_config.NumberColumn("AUM ($M)", format="$%.2f"),
                "PIPELINE_MILLIONS": st.column_config.NumberColumn("Pipeline ($M)", format="$%.2f"),
            }
        )
        st.caption(f"Showing {len(advisor_df)} advisors")
    except Exception as e:
        st.error(f"Advisor data unavailable: {e}")

# ============================================================================
# TAB 4: FUND FLOWS
# ============================================================================
with tabs[3]:
    st.header("Fund Flow Analysis")

    flow_sql = """
        SELECT
            fund_name,
            fund_category,
            SUM(CASE WHEN flow_type = 'INFLOW' THEN flow_amount ELSE 0 END) / 1e6 AS inflows_m,
            SUM(CASE WHEN flow_type = 'OUTFLOW' THEN ABS(flow_amount) ELSE 0 END) / 1e6 AS outflows_m,
            SUM(flow_amount) / 1e6 AS net_flows_m,
            COUNT(DISTINCT advisor_id) AS contributing_advisors
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION
        WHERE flow_date >= DATEADD('day', -30, CURRENT_DATE())
        GROUP BY fund_name, fund_category
        ORDER BY net_flows_m DESC
    """
    try:
        flow_df = run_query(flow_sql)
        st.bar_chart(flow_df.set_index("FUND_NAME")[["INFLOWS_M", "OUTFLOWS_M"]])
        st.dataframe(
            flow_df,
            use_container_width=True,
            column_config={
                "INFLOWS_M": st.column_config.NumberColumn("Inflows ($M)", format="$%.2f"),
                "OUTFLOWS_M": st.column_config.NumberColumn("Outflows ($M)", format="$%.2f"),
                "NET_FLOWS_M": st.column_config.NumberColumn("Net Flows ($M)", format="$%.2f"),
            }
        )
    except Exception as e:
        st.error(f"Fund flow data unavailable: {e}")

# ============================================================================
# TAB 5: CORTEX ANALYST CHAT
# ============================================================================
with tabs[4]:
    st.header("Ask Cortex Analyst")
    st.caption("Ask any question about advisor engagement, territories, fund flows, or pipeline in plain English.")

    # Example questions
    example_questions = [
        "Who are the top 5 advisors by AUM in the Northeast?",
        "Which territories have the highest attrition risk?",
        "Show me net fund flows by category this quarter",
        "Which high-AUM advisors have had no activity in 14 days?",
        "Compare the Northeast and Pacific territory performance"
    ]

    st.write("**Example questions:**")
    example_cols = st.columns(len(example_questions))
    for i, q in enumerate(example_questions):
        if example_cols[i].button(f"Q{i+1}", help=q, key=f"example_{i}"):
            st.session_state["analyst_question"] = q

    question = st.text_input(
        "Your question",
        value=st.session_state.get("analyst_question", ""),
        placeholder="Type a question about your distribution data...",
        key="analyst_input"
    )

    if st.button("Ask", type="primary") and question:
        with st.spinner("Cortex Analyst is generating SQL..."):
            response = send_cortex_analyst_query(question)

        if "sql" in response and response["sql"]:
            st.code(response["sql"], language="sql")
            with st.spinner("Executing query..."):
                try:
                    result_df = session.sql(response["sql"]).to_pandas()
                    st.dataframe(result_df, use_container_width=True)

                    if len(result_df) > 0:
                        st.caption(f"Returned {len(result_df)} rows")

                        # AI narrative summary of results
                        if st.checkbox("Generate AI narrative from results"):
                            with st.spinner("Generating narrative..."):
                                summary = get_ai_summary(
                                    result_df.head(10).to_string(),
                                    f"Summarize these distribution analytics results for a wholesaler in 2-3 bullet points. Question asked: {question}"
                                )
                                st.info(summary)
                except Exception as e:
                    st.error(f"Query execution failed: {e}")
        else:
            st.warning(response.get("message", "No SQL generated. Try rephrasing your question."))

# ============================================================================
# TAB 6: DATA HEALTH
# ============================================================================
with tabs[5]:
    st.header("Data Quality & Observability")

    # DMF Results
    st.subheader("Data Metric Function Results")
    dmf_sql = """
        SELECT
            TABLE_NAME,
            TABLE_SCHEMA,
            METRIC_NAME,
            MEASUREMENT_TIME,
            VALUE,
            CASE
                WHEN METRIC_NAME = 'NULL_COUNT' AND VALUE > 0 THEN 'WARNING'
                WHEN METRIC_NAME = 'DUPLICATE_COUNT' AND VALUE > 0 THEN 'WARNING'
                ELSE 'OK'
            END AS status
        FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
        WHERE TABLE_DATABASE = 'ANALYTICS_DEV_DB'
          AND TABLE_SCHEMA IN ('STAGING', 'DISTRIBUTION')
          AND MEASUREMENT_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
        ORDER BY MEASUREMENT_TIME DESC
        LIMIT 50
    """
    try:
        dmf_df = run_query(dmf_sql)
        st.dataframe(
            dmf_df,
            use_container_width=True,
            column_config={
                "STATUS": st.column_config.TextColumn(
                    "Status",
                    help="OK = healthy, WARNING = needs attention"
                )
            }
        )
    except Exception as e:
        st.warning(f"DMF results unavailable: {e}")

    st.divider()

    # Alert History — ACCOUNT_USAGE has 1-2h lag; may show 'No data' initially.
    # Correct columns: NAME, SCHEMA_NAME, SCHEDULED_TIME, STATE
    st.subheader("Recent Alerts (Last 24h)")
    st.caption("ACCOUNT_USAGE has a 1-2 hour lag. Alerts fired within the last hour may not appear yet.")
    alert_sql = """
        SELECT
            NAME                                               AS alert_name,
            SCHEMA_NAME,
            SCHEDULED_TIME,
            STATE
        FROM SNOWFLAKE.ACCOUNT_USAGE.ALERT_HISTORY
        WHERE SCHEMA_NAME = 'DISTRIBUTION'
          AND SCHEDULED_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
        ORDER BY SCHEDULED_TIME DESC
        LIMIT 20
    """
    try:
        alert_df = run_query(alert_sql)
        st.dataframe(alert_df, use_container_width=True)
    except Exception as e:
        st.warning(f"Alert history unavailable: {e}")

    st.divider()

    # Dynamic Table Health — use direct row counts + SHOW (INFORMATION_SCHEMA.DYNAMIC_TABLES
    # is not queryable; use ACCOUNT_USAGE.DYNAMIC_TABLES with ~1h lag or direct counts).
    st.subheader("Dynamic Table Health")
    dt_sql = """
        SELECT 'ADVISOR_ENGAGEMENT_SCORE' AS table_name,
               COUNT(*) AS row_count, 'Target: 1h' AS target_lag
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
        UNION ALL
        SELECT 'FUND_FLOW_ATTRIBUTION', COUNT(*), 'Target: 1d'
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.FUND_FLOW_ATTRIBUTION
        UNION ALL
        SELECT 'TERRITORY_HEAT_MAP', COUNT(*), 'Target: 4h'
        FROM ANALYTICS_DEV_DB.DISTRIBUTION.TERRITORY_HEAT_MAP
        ORDER BY 1
    """
    try:
        dt_df = run_query(dt_sql)
        st.dataframe(dt_df, use_container_width=True)
    except Exception as e:
        st.warning(f"Dynamic table health unavailable: {e}")

    st.divider()

    # Cortex AI Usage
    st.subheader("Cortex AI Usage Today")
    # Try CORTEX_USAGE_HISTORY (requires ACCOUNTADMIN or SNOWFLAKE.ACCOUNT_USAGE grant).
    # Falls back to a credit-check via METERING_HISTORY if unavailable.
    cortex_sql = """
        SELECT
            SERVICE_TYPE,
            SUM(CREDITS_USED) AS credits_used,
            COUNT(*) AS api_calls
        FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_USAGE_HISTORY
        WHERE DATE(USAGE_DATE) = CURRENT_DATE()
        GROUP BY SERVICE_TYPE
    """
    try:
        cortex_df = run_query(cortex_sql)
        st.dataframe(cortex_df, use_container_width=True)
        total_credits = cortex_df["CREDITS_USED"].sum() if not cortex_df.empty else 0
        st.progress(min(1.0, total_credits / 10.0), text=f"Daily budget: {total_credits:.2f} / 10 credits")
    except Exception:
        # CORTEX_USAGE_HISTORY not available in all accounts — show budget note
        st.info(
            "Cortex AI usage details require `SNOWFLAKE.ACCOUNT_USAGE` grant. "
            "Resource budget is enforced at the agent level (max 10 credits/day). "
            "Run: `SHOW AGENTS IN SCHEMA ANALYTICS_DEV_DB.DISTRIBUTION;` to check budget configuration."
        )
