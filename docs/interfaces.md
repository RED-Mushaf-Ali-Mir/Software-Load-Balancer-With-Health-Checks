# Interfaces (team contract)

Project: CS3001 Project 5, Software Load Balancer with Health Checks.
Everyone builds against this page. If you need to change something here, tell the team first.

## 1. Backends (Friend 2: Docker backends)

| Item | Value |
|---|---|
| Ports | 9001, 9002, 9003 (a 4th backend: 9004) |
| `GET /` | `200`, body `Hello from <name>` |
| `GET /health` | `200`, body `OK` |
| Delay | env var `DELAY_MS` adds artificial latency to `GET /` only (not to `/health`) |
| Unequal capacity | e.g. 0 ms / 100 ms / 500 ms |
| Connection handling | **Must close the connection after every response** (`Connection: close`). For Nginx set `keepalive_timeout 0;`. This is needed until the LB supports keep-alive (roadmap step 9). |

A local stand-in is `tools/dev_backend.py` (env vars `PORT`, `NAME`, `DELAY_MS`).

## 2. Load balancer (Mushaf: LB core)

Start: `python3 src/proxy.py --algo roundrobin|leastconn|iphash [--config config.yaml]`

`config.yaml`:

```yaml
listen: {host: 127.0.0.1, port: 8080}   # in the routed topology use 0.0.0.0 or the LB's own IP
backends:
  - {host: 127.0.0.1, port: 9001}
  - {host: 127.0.0.1, port: 9002}
  - {host: 127.0.0.1, port: 9003}
health:
  interval_s: 1        # seconds between checks, per backend
  fail_threshold: 3    # consecutive failures before DOWN
  timeout_s: 1         # per-check timeout (optional, default 1)
```

Behaviour:
- Health check: `GET /health` on each backend every `interval_s`. DOWN after `fail_threshold` consecutive failures (connect error, timeout, or non-200). UP again after 1 successful check.
- No healthy backend: `503 Service Unavailable`. Chosen backend unreachable: `502 Bad Gateway`.
- Health transitions are logged as `[HH:MM:SS.mmm] [health] <host:port> is DOWN|UP`. Use these timestamps to compute failure detection time.
- Supported requests (for now): HTTP GET, one request per connection.

## 3. HAProxy reference (Friend 2)

Same listen port 8080, same backends, equivalent settings so the comparison is fair:

- `balance roundrobin` / `leastconn` / `source` (client-IP hash)
- `option httpchk GET /health`
- `server <name> <ip>:<port> check inter 1s fall 3 rise 1`
- `timeout check 1s`

(Friend 2 to verify exact syntax against the HAProxy version used.)

## 4. Topology and addressing (Friend 1)

To be filled in by Friend 1. Example only:

| Subnet | Role |
|---|---|
| 10.0.1.0/24 | clients |
| 10.0.2.0/24 | load balancer |
| 10.0.3.0/24 | backends |

Needed from Friend 1: router count and links, IP of each node, how to start/stop the topology, netem profiles (3 network conditions), pcap capture points.

## 5. Experiment plan (shared)

- Concurrency: 50 / 200 / 500 connections, 60 s each, one backend killed at t = 30 s.
- Metrics: req/s, p50/p95/p99 latency, requests per backend, failure detection time, failed requests during failure, LB CPU.
- Each metric under 3 network conditions x 3 runs (mean and standard deviation).

## 6. Who does what

| Person | Owns |
|---|---|
| Mushaf | LB core (proxy, 3 algorithms, health checks, optional dynamic weights), design/analysis report sections |
| Friend 1 | Routed topology (2+ routers, 3+ subnets), tc netem, pcaps, architecture diagram, addressing plan |
| Friend 2 | Docker backends, HAProxy config, load tests, plots |
| Everyone | Report sections, README, AI-use disclosure |
