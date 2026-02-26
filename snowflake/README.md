# Snowflake Intelligence and Cortex Analyst

This folder holds Snowflake-specific assets for the semantic view and Cortex Analyst: the semantic view YAML spec and the setup SQL for roles, warehouses, and stages. For full context on the semantic model (visits, charge attempts, metrics) and how they are used elsewhere, see [models/semantic/README.md](../models/semantic/README.md).

---

## Module 1: Cortex Analyst

### Setting up Cortex Analyst

1. Run the setup script first (if you have not already):
   - Execute `snowflake/intelligence_setup.sql` to create the role `intelligence_admin`, warehouse `intelligence_wh`, database `snowflake_intelligence`, and stage `analytics.DBT_PROD.semantic_models`.

2. Open the semantic view YAML in this repo:
   - Go through `snowflake/semantic_view.yml` to understand the logical tables (visits, charge_attempts), dimensions, metrics, and relationships.

3. Download or copy `snowflake/semantic_view.yml` so you can upload it in Snowflake.

4. In Snowflake, go to **AI & ML > Cortex Analyst**.

5. In the top right, set **Role** to `intelligence_admin` and **Warehouse** to `intelligence_wh`.

6. Click **Create new** (top right) and choose **Upload your YAML file**.

7. Choose database, schema, and stage: **ANALYTICS > DBT_PROD > SEMANTIC_MODELS**. Then click **Upload** and select your `semantic_view.yml` file.

8. Scroll through the UI and explore the components generated from the YAML (tables, dimensions, time dimensions, facts, metrics, relationships).

### Using Cortex Analyst

When you see **“Valid semantic model. Ready to answer your question”**, click **Open Playground** and start asking questions.

Sample questions:

- Explain the dataset.
- Show me total visits and total charge attempts over time.
- What is the first attempt success rate by day?
- Show me the trend of failed visits between [start date] and [end date].
- How many troubled success visits (succeeded after multiple attempts) per week?

---

## Module 2: Snowflake Intelligence

### Setting up a custom Snowflake Intelligence agent

**Creating an agent**

1. Go to **AI & ML > Cortex Agent**.

2. Click **Create agent** (top right).

3. Check the box **Create this agent for Snowflake Intelligence**. The default database and schema should be **SNOWFLAKE_INTELLIGENCE.AGENTS**.
   - If you don’t see that checkbox, set database and schema to **SNOWFLAKE_INTELLIGENCE.AGENTS** manually.

4. **Agent object name**: e.g. `Charging_AI` (internal identifier Snowflake uses for the agent’s metadata).

5. **Display name**: any user-facing name, e.g. `ChargingAI` (name shown to users).

6. Select the new agent from the list to open and configure it.

7. Configure the agent: optionally add a description; add a few **sample questions** to guide users, for example:
   - Show me the trend of total visits and charge attempts by day between June and August.
   - What is the first attempt success rate and troubled success rate this month?
   - Why did failed visits increase last week?

8. Click **Save** (top right) so the configuration and preview test chat reflect your changes.

**Setting up the tools**

1. Click **Tools** (top left) to configure what the agent can use (e.g. Cortex Analyst).

2. Add the Cortex Analyst semantic model from Module 3: click **+ Add**.

3. Configure the tool:
   - Select **Semantic model file**.
   - Choose **ANALYTICS.DBT_PROD.SEMANTIC_MODELS** and the **semantic_view.yml** file.
   - **Tool name**: e.g. `Charging_And_Visits_Data`.
   - **Description**: use **Generate with Cortex** to auto-generate a description for orchestration.
   - **Query timeout**: e.g. 60 seconds.
   - Click **Add** (bottom right).

4. Click **Save** to persist the tool configuration.

### Using the custom Snowflake Intelligence agent

1. Go to **AI & ML > Snowflake Intelligence** and sign in with your Snowflake credentials.

2. Use the chat interface to try the sample questions you configured and any of the following:

- Show me total visits and total charge attempts over time by day.
- What is the first attempt success rate by charge point?
- How many troubled success visits per week?
- What is the trend of failed visits between [start date] and [end date]?
- How do first attempt success rate and troubled success rate compare by week?
