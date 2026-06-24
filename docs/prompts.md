# Distribution Insights — Demo Prompts & CoCo Prompts
## ACME IM | Snowflake Cortex AI

---

## 1. CORTEX AGENT SYSTEM PROMPT

```
You are a distribution analytics assistant for ACME Investment Management.
You have access to:
1. A semantic model with advisor engagement, territory performance, fund flows, and pipeline data
2. A Cortex Search service for fund documentation
3. SQL execution for ad-hoc analysis

RULES:
- Always ground answers in data; never speculate
- Format numbers: AUM in $B or $M, flows in $M, percentages with 1 decimal
- When an advisor or territory question is asked, always check engagement scores
- Flag at-risk advisors (engagement score < 30) proactively
- Do NOT discuss competitor pricing, legal advice, or individual employee salaries
- For compliance questions, recommend consulting the compliance team

PERSONA:
Concise, data-driven, financial services professional. Speak to wholesalers and
distribution managers, not data engineers. Use business language, not SQL.
```

---

## 2. CORTEX ANALYST VERIFIED QUERY PROMPTS

These prompts are used in the `verified_queries` section of the semantic view:

### Pipeline & Pipeline Analysis
- "Who are the top 10 advisors by open opportunity value?"
- "Which territories have the most pipeline this quarter?"
- "Show me stale opportunities — deals that haven't moved in 30 days"
- "What is the win rate by territory and fund category?"
- "Which advisors have the highest opportunity-to-AUM conversion?"

### Advisor Engagement
- "Who are the most engaged advisors in the Northeast this month?"
- "List all advisors with engagement score below 30 — sort by AUM"
- "Which Platinum tier advisors have had no calls in the last 14 days?"
- "Compare engagement scores for Gold vs Silver tier advisors"
- "Show me the top 20 advisors by engagement score"

### Territory Performance
- "Which territory had the highest net fund flows last quarter?"
- "Compare the Pacific and Southeast territories on all metrics"
- "Which territory has the most at-risk advisors?"
- "Rank all territories by their heat score"
- "Show the territory with the largest drop in engagement over 90 days"

### Fund Flows
- "What are total net flows by fund category year-to-date?"
- "Which fund had the highest inflows last month?"
- "Show me advisors responsible for the most fund outflows"
- "What is the capture rate by territory?"
- "Which advisor has the highest net fund flows this quarter?"

---

## 3. CORTEX COMPLETE TASK PROMPTS

### Advisor Morning Brief
```
You are a distribution analytics assistant for an asset management firm.
Generate a concise 3-bullet morning brief for a territory wholesaler based on the following data:
{data_json}

Format:
• [Engagement insight]
• [Pipeline/opportunity insight]
• [At-risk advisor insight or positive trend]

Keep each bullet under 25 words. Be specific with numbers.
```

### Attrition Risk Classification
```
Classify this advisor as HIGH, MEDIUM, or LOW attrition risk.

Engagement Score: {engagement_score}/100
Calls last 30 days: {call_count_30d}
Meetings last 30 days: {meeting_count_30d}
Days since last activity: {days_since_last_activity}
AUM: ${aum_m}M
Tier: {tier}

Rules:
- HIGH: engagement < 20 OR no activity > 21 days AND AUM > $10M
- MEDIUM: engagement 20-40 OR no activity 14-21 days
- LOW: engagement > 40 AND activity within 14 days

Respond with EXACTLY one word: HIGH, MEDIUM, or LOW
```

### Territory Summary for Leadership
```
You are a distribution analytics assistant. Write a 5-sentence executive summary
of this territory for a presentation to senior leadership.

Territory: {territory_name}
AUM: ${aum_m}M
Advisor Count: {advisor_count}
Average Engagement: {avg_engagement}/100
Net Flows 30d: ${net_flows_m}M
At-Risk Advisors: {at_risk_count}
Pipeline Value: ${pipeline_m}M

Tone: Professional, results-oriented, highlight strengths and one area of concern.
```

### Fund Flow Narrative
```
Generate a plain-English narrative explaining these fund flow results to a non-technical
distribution manager. Highlight the top performing fund, any concerning outflows, and
one actionable recommendation.

Data: {flow_data_json}

Keep to 3 sentences. Start with the most important finding.
```

### RFP Response Classifier
```
Classify this inbound RFP question by category and urgency.

Question: {rfp_question}

Categories: PERFORMANCE, RISK, ESG, FEES, OPERATIONS, COMPLIANCE, OTHER
Urgency: HIGH (24h response), MEDIUM (48h response), LOW (5-day response)

Respond in JSON: {"category": "...", "urgency": "...", "suggested_assignee": "..."}
```

---

## 4. COCO PROMPTS (Cortex Code)

### CoCo Prompt: Explore Distribution Data
```
Explore the distribution analytics tables in ANALYTICS_DEV_DB.DISTRIBUTION.
Show me what's in ADVISOR_ENGAGEMENT_SCORE — columns, sample data, and any anomalies.
Then show me the top 10 advisors by engagement score with their AUM and territory.
Use the INGEST warehouse.
```

### CoCo Prompt: Debug a Dynamic Table
```
The Dynamic Table ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
hasn't refreshed in 2 hours. 
1. Check the refresh history and tell me what happened
2. Look at the recommendations column for any optimization suggestions
3. If there are AUTO_RESOLVED_TO_FULL_REFRESH recommendations, explain what that means
4. Tell me if the underlying source table (ADVISOR_EVENTS_RAW) has recent data
```

### CoCo Prompt: Build a Semantic View
```
I need to create a Snowflake Semantic View for Cortex Analyst.
Tables: ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE and FUND_FLOW_ATTRIBUTION
Goal: Enable natural language queries about advisor performance and fund flows
Include:
- Entities (advisor, territory, fund)
- 5 key metrics (total_aum, avg_engagement, net_flows, at_risk_count, pipeline_value)
- 3 verified queries with SQL
- Synonyms for business-friendly terms
Use the Semantic View documentation format.
```

### CoCo Prompt: Check Alert Health
```
Show me the status of all Cortex Alerts in ANALYTICS_DEV_DB.DISTRIBUTION.
For each alert:
1. Is it STARTED or SUSPENDED?
2. When did it last fire?
3. What was the condition that triggered it?
Also show me any DMF quality checks that failed in the last 24 hours.
Give me a health summary at the end.
```

### CoCo Prompt: Optimize a Dynamic Table
```
The Dynamic Table ANALYTICS_DEV_DB.DISTRIBUTION.ADVISOR_ENGAGEMENT_SCORE
is doing full refreshes instead of incremental.
1. Read the current DDL
2. Check the recommendations from INFORMATION_SCHEMA.DYNAMIC_TABLE_RECOMMENDATIONS
3. Tell me why it might be doing full refreshes
4. Suggest how to fix it to enable incremental refresh
Don't execute any changes — just analyze and recommend.
```

### CoCo Prompt: Deploy Streamlit Dashboard
```
Deploy the Streamlit dashboard at dashboard/dashboard.py to Snowflake.
1. Check it compiles without errors
2. Deploy using: snow streamlit deploy --name DISTRIBUTION_INSIGHTS
   --database ANALYTICS_DEV_DB --schema DISTRIBUTION --warehouse INGEST
3. Verify it deployed by running: snow streamlit describe DISTRIBUTION_INSIGHTS
4. Show me the URL to access it
Use the your_connection connection profile.
```

### CoCo Prompt: Monitor Cortex AI Costs
```
Show me how much we've spent on Cortex AI today and this week.
Break it down by:
- Service type (Cortex Complete, Cortex Analyst, Cortex Search)
- Which warehouse was used
- Estimated cost vs yesterday
Also check if any resource budgets are close to their daily limits.
Use SNOWFLAKE.ACCOUNT_USAGE for the data.
```

---

## 5. DEMO SCRIPT FOR LIVE PRESENTATION

### Section 1: Zero-Copy Demo (5 minutes)
```
1. Open Snowsight
2. Run: SELECT * FROM salesforce_share.opportunity LIMIT 5
3. Show: No copy, live data, same latency as any Snowflake table
4. Ask Cortex Analyst: "Show top advisors by open opportunity value"
5. Highlight: The SQL joins Salesforce data to Snowflake fund performance — zero ETL
```

### Section 2: Pipeline Demo (5 minutes)
```
1. Show Snowpipe V2 throughput in ACCOUNT_USAGE
2. Query ADVISOR_EVENTS_RAW: SELECT COUNT(*), MAX(row_timestamp) FROM ...
3. Show Dynamic Table refresh status
4. Run: SELECT * FROM ADVISOR_ENGAGEMENT_SCORE ORDER BY engagement_score DESC LIMIT 5
5. Point out: Data is seconds old, no pipeline to manage
```

### Section 3: Observability Demo (5 minutes)
```
1. Open the Streamlit dashboard, go to Data Health tab
2. Show DMF results — all green
3. Show alert history
4. Live demo: manually insert a bad row to trigger a DMF
5. Show the Slack notification arriving in under 30 seconds
```

### Section 4: Cortex Analyst Demo (5 minutes)
```
1. Open the "Ask Cortex Analyst" tab
2. Type: "Which territories have the highest advisor attrition risk this quarter?"
3. Show SQL generated — explain it without showing the underlying complexity
4. Type a follow-up: "Break that down by fund category"
5. Show: Same context maintained, refined SQL generated
6. Click "Generate AI narrative" — show the plain-English summary
```

---

## 6. FREQUENTLY ASKED QUESTIONS (for demo Q&A)

**Q: Does Zero-Copy mean the data is always current?**
A: Yes — with Salesforce Data Cloud integration, changes in Salesforce appear in Snowflake
within minutes via the shared metadata layer. No batching, no ETL delay.

**Q: Can we control which Salesforce fields are visible in Snowflake?**
A: Absolutely. The Salesforce administrator controls the share configuration, and Snowflake
RBAC + column masking policies control access on the Snowflake side.

**Q: How do we prevent the Cortex Agent from answering off-topic questions?**
A: Cortex Guardrails topic restrictions block specific categories. The agent is also
constrained to the semantic view — it can only query tables you've defined in the model.

**Q: What if Cortex Analyst generates incorrect SQL?**
A: Verified Query Representations (VQRs) lock known-good SQL patterns for common questions.
The semantic view also defines metric calculations precisely so the same formula is always used.

**Q: How do we control costs on Cortex AI?**
A: Resource Budgets cap daily credits per agent. Alerts fire at 80% consumption.
We default to mistral-7b (smallest model that meets requirements) per project standards.

**Q: How long does it take to get from zero to production?**
A: Zero-Copy: 1 week. First Cortex Analyst query: 2 weeks. Full dashboard: 4-6 weeks.
The POC framework in the deck targets 30 days to first production-ready deliverable.
```
