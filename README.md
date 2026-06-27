<img
  alt="kwwhat banner and logo" 
  src="https://github.com/user-attachments/assets/7460eae2-b0d7-4366-ad87-947103054d9a"
style="width: 100%; height: auto;"
/>

# kWwhat: open-source data analytics pipeline for EV charging
from raw OCPP logs to automated reliability/utilization reporting [here](https://github.com/appspace/kwwhat)

---
**kwwhat** is an open-source dbt project that models reliability and utilization metrics from EV charger logs based on the OCPP 1.6 and 2.0.1 protocols. Starting from raw OCPP logs, the project builds a transparent path toward meaningful metrics like uptime, session success, and visit-level outcomes.

This project is powered by public OCPP log data and is designed for CSMS providers, utilities, researchers, and data practitioners aiming to build their own charger analytics stack.

---

## What’s included

**kwwhat** includes:

- Source modeling for raw OCPP logs (StatusNotification, Heartbeat, Start/StopTransaction)
- Session and visit grouping logic
- Core metrics like:
  - [x] Outages: from, to, type
  - [x] Port uptime (% of commissioned time a Port was online and not faulted — a solid base for calculating uptime by adding maintenance and exclusion rules)
  - [x] Attempt success
  - [x] Visit success
  - [x] First attempt success rate
  - [x] Troubled success rate
- Public OCPP logs for realistic examples
- Modular dbt structure to plug into your existing stack
- Interval data for other reporting use cases that require energy delivery by 15-min time slices

Check Tableau dashboard [here](https://public.tableau.com/app/profile/daria.sukhareva1853/viz/WIPkwwhatdemo/Overview)

---

## Definitions

#### Hardware hierarchy

| Term | Definition | Sanity check |
|---|---|---|
| **Charger** (Charging Station) | Physical system where EVs can be charged. Has one or more Ports (EVSEs). | What a driver perceives as a single charger |
| **Port** (EVSE) | Independently operated and managed part of a Charger that can deliver energy to one EV at a time. | "How many vehicles can charge simultaneously?" = number of Ports |
| **Connector** | Independently operated electrical outlet on a Port. A Port may have multiple Connectors (socket types or tethered cables) to support different vehicle types (e.g. four-wheeled EVs and electric scooters). | "What vehicle types can charge here?" = Connector types |

Reliability and utilisation metrics are tracked at **Port grain**.

Source: OCPP 2.1 Edition 1 — © Open Charge Alliance 2025, Definitions

#### Success criteria
Charge attempt is successful when:
  - there is a transaction (energy transfer)
  - next connector status is not ‘Faulted'
  - transaction stop reason is 'Local’ or ‘Remote’ or ‘EVDisconnected'
  - energy transferred is above 0.1 kWh
  
  partially borrowed from https://github.com/chargex-consortium/OCPP-2.0.1-Interim-KPI-Calculator

Visits is successful when the last attempt of the visit is successful.

  a modification of visit success when at least one charge attempt is successful here [Customer-Focused Key Performance Indicators (KPIs) for Electric Vehicle Charging](https://inl.gov/content/uploads/2024/05/chargex-Customer-Focused-KPIs-for-EV-Charging-6-24-24.pdf)

---

## Try it locally (demo)

The fastest way to explore kwwhat is the self-contained Docker demo — no cloud account needed.

```bash
cd demo
cp .env.example .env   # add your Anthropic API key
./run-demo.sh
```

This spins up three services: a local DuckDB database loaded with sample OCPP logs, the full dbt pipeline, and an AI chat interface where you can ask plain-English questions about your EV charger data.

See [`demo/README.md`](demo/README.md) for details.

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/kwwhat.git
cd kwwhat
````

Then update your `profiles.yml` to point to your raw data location (e.g., DuckDB, BigQuery, Snowflake, Redshift, etc.).

---

## Example metrics

| Metric | Description |
|---|---|
| `uptime` | Average fraction of commissioned time a Port was online and not in a Faulted state |
| `total_visits` | Total number of charging visits |
| `total_charge_attempts` | Total charge attempts across all visits |
| `first_attempt_success` | Count of visits where the first attempt succeeded |
| `troubled_success` | Count of visits that succeeded but required more than one attempt |
| `failed_visits` | Count of visits that did not end in a successful charge |
| `first_attempt_success_rate` | Proportion of visits where the first attempt succeeded |
| `troubled_success_rate` | Proportion of visits that were troubled success |
| `failed_rate` | Proportion of visits that failed |
| `average_attempts_per_visit` | Total charge attempts divided by total visits |

---

## Data sources & attribution

- OCPP 1.6 logs were kindly donated by [Epic Charging](https://www.linkedin.com/company/epiccharging)

- OCPP 2.0.1 logs were borrowed from [OCPP-2.0.1-Interim-KPI-Calculator](https://github.com/chargex-consortium/OCPP-2.0.1-Interim-KPI-Calculator)

Seed data was generated with [OCPP synthetic log generator](https://chatgpt.com/g/g-68923b4c67548191a90737f5c3dc4d57-ocpp-synthetic-log-generator)

Use `dbt seed` command to add seed data to your warehouse.

---

## Insights & References

Designed based on industry frameworks and academic research to align metrics with real-world expectations:

- The **Public EV Charging Infrastructure Playbook** by U.S. Joint Office offers guidance for performance evaluation in EV infrastructure [EV Charging KPI Playbook](https://driveelectric.gov/news/kpi-ev-playbook)

- The Sage‑published journal article **Novel Methodology to Measure the Reliability of Public DC Fast Charging Stations** proposes a data-driven framework for charger reliability, which informed the visits logic in kwwhat. [Novel Methodology to Measure the Reliability of Public DC Fast Charging Stations](https://journals.sagepub.com/doi/full/10.1177/03611981241244798)

- Uptime calculations modeled in part after [NEVI guidelines](https://driveelectric.gov/ev-infrastructure-funding/program-guidance/) 

---

## Disclaimer

This project was created independently and outside of any prior employment. It does **not** include any proprietary information, logic, or data.

---

## License

The kwwhat project is licensed under the [MIT License](LICENSE).
External datasets and tools used in this repo follow their respective licenses as noted above.

---

## Contributing

Open to contributions from the EV data community. If you’re building in this space and want to improve reliability tracking, user experience analytics, or charger diagnostics — join in!

---

## Contact

Questions? Ideas? Drop an issue or find us on LinkedIn [kwwhat](https://www.linkedin.com/company/108154470)



