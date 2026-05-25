# Stage 1 Baseline vs Expanded

- Baseline run: `results_20260421_130451.json`
- Expanded run: `results_20260507_095345.json`

| metric | baseline | expanded | delta |
|---|---:|---:|---:|
| accuracy | 100.00% | 50.00% | -50.00% |
| passed/total | 1/1 | 2/4 | 1/3 |
| tokens | 16178 | 99727 | +83549 |
| cost (USD) | 0.037581 | 0.116858 | +0.079277 |
| execution_time (s) | 12.3 | 53.1 | +40.8 |

- Top failure pattern: both failed tests (`lately_snapshot`, `network_reliability_uptime`) hit the same SQL binder error (`Catalog "RAW" does not exist`).
- Interpretation: factual harness is working (2/4 pass), and failures are consistent with context/namespace drift rather than test file formatting issues.
