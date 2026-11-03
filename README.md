<img
  alt="kwwhat banner and logo" 
  src="https://github.com/user-attachments/assets/7460eae2-b0d7-4366-ad87-947103054d9a"
style="width: 100%; height: auto;"
/>

# kWwhat: open-source EV charging context layer
the data foundation you plug into an agentic stack to give it EV charging awareness out of the box [here](https://github.com/appspace/kwwhat)

---

**kwwhat** is an open-source data pipeline that transforms raw OCPP logs into a structured, queryable context layer for EV charging. It models charge attempts, visits, uptime, and session outcomes — so whatever agentic use case you are building has reliable, grounded domain knowledge from day one.

This project is designed for AI engineers, data practitioners, and CSMS providers building support agents, analytics agents, or agentic ops workflows who want to give their agents a deep understanding of charger behavior.

---

## What’s included

- Source modeling for raw OCPP logs (StatusNotification, Heartbeat, Start/StopTransaction)
- Charge attempt and visit models for operational drill-down and driver outcomes
- Port-day uptime, outage-reason detail, and current hardware/error-code dimensions
- Sparse identified-driver activity history, without storing inactive driver-days
- Supporting 15-minute energy intervals and location-capacity marts; these are not yet published as dbt Semantic Layer models

### Core metrics

| Metric | Description |
| --- | --- |
| `uptime_ratio` | Commissioned Port minutes not lost to outages, weighted by duration |
| `total_commissioned_minutes`, `total_uptime_minutes` | Additive minute totals behind uptime |
| `total_downtime_minutes` | OFFLINE + FAULTED Port-day minutes |
| `total_downtime_minutes_detailed` | The same downtime total at outage detail, for diagnosis by type, reason, and error code |
| `total_visits` | All charging visits, including unidentified visits |
| `total_successful_visits` | Visits whose last charge attempt succeeded |
| `total_charge_attempts` | Sum of attempts belonging to visits, attributed to visit end time |
| `first_attempt_success` | Successful visits with exactly one attempt |
| `troubled_success` | Successful visits with multiple attempts |
| `failed_visits` | Visits whose last attempt was unsuccessful |
| `first_attempt_success_rate`, `troubled_success_rate`, `failed_rate` | Each outcome category divided by total visits |
| `average_attempts_per_visit` | Total attempts belonging to visits divided by total visits |
| `active_drivers_7d`, `active_drivers_30d` | Distinct identified drivers across trailing 7-day and fixed 30-day windows |
| `new_drivers` | Identified driver credentials first observed on the reporting date |
| `retained_drivers_7d`, `retained_drivers_30d` | Drivers in both today's and yesterday's overlapping rolling active sets |
| `resurrected_drivers_7d`, `resurrected_drivers_30d` | Returning drivers entering today's rolling set after absence from yesterday's set |
| `churned_drivers_7d`, `churned_drivers_30d` | Drivers aging out of today's rolling set, not permanent customer loss |

Metrics are defined in the dbt Semantic Layer. Visit metrics use visit end time; driver
activity uses charge-attempt start dates. A driver means an observed `id_tag` credential,
not a resolved person. Activity includes unsuccessful attempts and excludes anonymous IDs.
Driver growth accounting is daily and compares overlapping windows shifted by one day.
Use completed, fully ingested dates with sufficient prehistory; do not sum daily distinct
active or retained counts.

See the [semantic model and metric guide](models/semantic/README.md) for all model grains,
default time dimensions, join guidance, rolling-window helpers, and integration details.

---


## Try it yourself

The fastest way to see what kwwhat can do is the self-contained [Chat BI demo](demo/README.md) — ask plain-English questions about EV charger reliability and get answers grounded in real OCPP data. No cloud account needed, runs locally. Or explore a live [Tableau dashboard](https://public.tableau.com/app/profile/daria.sukhareva1853/viz/WIPkwwhatdemo/Overview) if you want to see the metrics without running anything.

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

#### Analytical concepts

A **charge attempt** captures intent to charge on a Port. It begins when bay occupancy changes or a driver plugs in, and ends when the connector is no longer performing any charging related tasks. If all prerequisites align, a charge attempt wraps around a transaction. A charge attempt may or may not result in energy transfer — if the transaction was successful, there was meaningful energy transfer (more than 0.1 kWh).

A **visit** is a single driver trip to a charging location. It may span multiple charge attempts — for example, when a driver unplugs and retries on the same or a nearby port.

Operational models reconstruct individual charge attempts from OCPP logs. But a driver's experience at a charging site is rarely a single attempt. They park, plug in, face an error, unplug, try another port, eventually get a charge. Visit modeling turns that sequence of technical events into a single, coherent unit of analysis: one driver, one stop, one outcome.

Two grouping strategies are used depending on whether the driver successfully authorised.

For authenticated drivers, all charge attempts by the same driver at the same location within a 30-minute window belong to the same visit. A gap of 30 or more minutes, or a different location, starts a new visit.

For unauthenticated drivers, attempts on the same port within a 2-minute window belong to the same visit. Different ports always start a new visit. When an anonymous attempt immediately precedes an authorized attempt on the same port within 2 minutes, the driver identity is inferred retroactively.
    
<img alt="visit same driver" src="https://github.com/user-attachments/assets/f0f4c775-4aeb-43a1-9e91-00dc73df5f0e" width="48%" />
<img alt="visit unknown driver" src="https://github.com/user-attachments/assets/905e79e9-b5c3-4c42-8801-5c5c9b24cb79" width="48%" />

This model unlocks four driver-centric metrics: first attempt success rate (charging worked on the first try), troubled success rate (succeeded after retrying), failure rate (no successful charge in the visit), and average attempts per visit (a guardrail for how much effort drivers expend).

Together, these shift the question from "did this transaction complete?" to "did this driver get a charge?" — a behavioral measure of real impact of reliability improvements on driver outcomes. It is behavioral in the sense that in the absence of a clear failure signal, a driver who keeps retrying is telling you they have not reached success yet. Repeated attempts within a visit are evidence of friction, not ambiguity.

---

## Success criteria

**Visit** is successful when the last charge attempt is successful.

**Charge attempt** is successful when:
  - there is an associated transaction
  - the next status is not `Faulted`, or no next status is reported
  - transaction stop reason is `Local`, `Remote`, or `EVDisconnected`
  - energy transferred exceeds `success_energy_threshold_kwh` (default `0.1` kWh)

The mart's `is_successful` flag is authoritative. The semantic layer uses that flag so
configured thresholds and visit outcomes remain aligned.


 Success criteria are partially borrowed from https://github.com/chargex-consortium/OCPP-2.0.1-Interim-KPI-Calculator and/or are a modification of visit success when at least one charge attempt is successful here [Customer-Focused Key Performance Indicators (KPIs) for Electric Vehicle Charging](https://inl.gov/content/uploads/2024/05/chargex-Customer-Focused-KPIs-for-EV-Charging-6-24-24.pdf)

---

## Installation

```bash
git clone https://github.com/appspace/kwwhat.git
cd kwwhat
```

Configure `profiles.yml` for your warehouse, such as Snowflake or BigQuery. For the
self-contained local experience, follow the [Chat BI demo setup](demo/README.md).


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

Design decisions and the reasoning behind them are recorded as [Architecture Decision Records](docs/adr/README.md). If your change alters grain, a metric definition, a key strategy, or a project-wide convention, add an ADR in the same PR.

---

## Contact

Questions? Ideas? Drop an issue or find us on LinkedIn [kwwhat](https://www.linkedin.com/company/108154470)



