# OCPP Log Simulator

Simple OCPP server/client simulator for generating synthetic charger logs.

## Installation

```bash
pip install -r requirements.txt
```

## Run server

```bash
python server.py
```

## Run client

```bash
python client.py client.py --loops 100 --interval 0.2 --charge-point-id CH-001 --response-delay-ms 40 --response-delay-jitter-ms 0 --output ocpp_client_generated_logs.csv 
```
