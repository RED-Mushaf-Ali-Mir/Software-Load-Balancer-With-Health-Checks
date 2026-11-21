# Software Load Balancer with Health Checks (CS3001 Project 5)

Team: Mushaf Ali Mir, Aazan Noor, Abbas Ahmed
Status: in progress

A Python asyncio reverse proxy that spreads HTTP requests across several backend servers.
It supports three balancing algorithms (round robin, least connections, IP hash).
Active health checks and dynamic weights are planned (see Roadmap).

## Project structure

```
src/        load balancer code (proxy.py)
backends/   backend servers used for experiments (Docker/Nginx/Flask, added later)
tools/      dev_backend.py: small stand-in backend for local testing
docs/       interfaces and design notes
captures/   packet captures (.pcapng)
experiments/ benchmark scripts and results
config.yaml backends and settings, read by the proxy at startup
```

## Requirements

- Python 3.10+
- PyYAML: `pip install pyyaml` (or `sudo apt install python3-yaml`)

## How to run (local test)

Run each command in its own terminal, from the project root.

1. Start three dev backends with different speeds:

```bash
PORT=9001 DELAY_MS=0   python3 tools/dev_backend.py
PORT=9002 DELAY_MS=100 python3 tools/dev_backend.py
PORT=9003 DELAY_MS=500 python3 tools/dev_backend.py
```

2. Start the load balancer, choosing an algorithm:

```bash
python3 src/proxy.py --algo roundrobin   # or leastconn, or iphash
```

3. Send requests:

```bash
curl http://127.0.0.1:8080/
```

## Algorithms

| Flag | Behaviour | Good for |
|---|---|---|
| `--algo roundrobin` | Backends take turns in order | Equal backends, equal requests |
| `--algo leastconn` | Picks the backend with the fewest in-flight requests | Uneven backend speed or request cost |
| `--algo iphash` | Same client IP always goes to the same backend | Sticky sessions, cache locality |

Unhealthy backends are skipped by all three. If none are healthy the proxy returns 503. If a chosen backend cannot be reached it returns 502.

## Configuration (`config.yaml`)

```yaml
listen: {host: 127.0.0.1, port: 8080}
backends:
  - {host: 127.0.0.1, port: 9001}
  - {host: 127.0.0.1, port: 9002}
  - {host: 127.0.0.1, port: 9003}
health: {interval_s: 1, fail_threshold: 3}   # used once health checks land
```

Change addresses here, not in the code.

## Backend interface (agreed with the team)

- Ports 9001/9002/9003
- `GET /` returns `Hello from <name>`
- `GET /health` returns `200 OK`
- Artificial delay via env var `DELAY_MS`

## Roadmap

- [x] TCP echo server and asyncio basics
- [x] Reverse proxy, 502/503 handling
- [x] Round robin, least connections, IP hash, config file
- [ ] Active health checks (GET /health every 1 s, down after 3 failures)
- [ ] Keep-alive and request bodies
- [ ] Optional dynamic weights
- [ ] Routed topology, tc netem, HAProxy comparison, benchmarks, report

## Known limitations

GET only, one request per connection (no keep-alive), no health checks yet.

## AI-use disclosure

AI assistance (Claude) was used for explanations and code guidance during development. To be completed in the final report.
