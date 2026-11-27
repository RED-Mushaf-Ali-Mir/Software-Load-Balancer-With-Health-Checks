# Planned Network Topology

This document describes the network planned for the load-balancer project. It is a design only: this phase does not create Linux network namespaces, change system networking, or start any services.

## Topology

The lab has two routers and three separate IP networks (subnets):

1. A client subnet containing the test client and load balancer.
2. A transit subnet connecting Router 1 to Router 2.
3. A backend subnet containing Router 2 and the three backend servers.

```text
 Client                 Load balancer              Router 1
10.10.1.10              10.10.1.20              10.10.1.1
    |                         |                       |
    +----------- Client subnet: 10.10.1.0/24 --------+
                                                     |
                                  Router 1: 10.10.12.1/30
                                                     |
                                  Transit: 10.10.12.0/30
                                                     |
                                  Router 2: 10.10.12.2/30
                                                     |
                                  Router 2: 10.10.3.1/24
                                                     |
    +---------- Backend subnet: 10.10.3.0/24 --------+
    |                         |                       |
 Backend 1              Backend 2               Backend 3
10.10.3.11              10.10.3.12              10.10.3.13
```

The client sends requests to the load balancer on the client subnet. The load balancer then sends each request through Router 1 and Router 2 to a backend. Replies return through the routers in the opposite direction.

## IP addressing plan

| Subnet | Device | Address | Purpose |
|---|---|---|---|
| `10.10.1.0/24` | Router 1, client-facing interface | `10.10.1.1` | Gateway for the client subnet |
| `10.10.1.0/24` | Client | `10.10.1.10` | Sends test requests |
| `10.10.1.0/24` | Load balancer | `10.10.1.20` | Receives requests from the client |
| `10.10.12.0/30` | Router 1, transit interface | `10.10.12.1` | Router 1 end of the router-to-router link |
| `10.10.12.0/30` | Router 2, transit interface | `10.10.12.2` | Router 2 end of the router-to-router link |
| `10.10.3.0/24` | Router 2, backend-facing interface | `10.10.3.1` | Gateway for the backend subnet |
| `10.10.3.0/24` | Backend 1 | `10.10.3.11` | First backend server |
| `10.10.3.0/24` | Backend 2 | `10.10.3.12` | Second backend server |
| `10.10.3.0/24` | Backend 3 | `10.10.3.13` | Third backend server |

All addresses are from private IPv4 ranges and are intended for this isolated lab.

## What the subnet sizes mean

The `/24` suffix means that the first 24 bits identify the subnet. Devices whose addresses start with the same first three numbers, such as `10.10.1`, are on the same subnet and can communicate directly through that subnet's local network segment.

The router-to-router link uses `/30`, which is a small subnet with two usable device addresses. That is enough for Router 1 and Router 2, and keeps the transit link separate from both endpoint networks.

## Routing plan

Each device uses a gateway when it needs to send traffic outside its own subnet:

- The client and load balancer use Router 1 at `10.10.1.1` as their default gateway.
- Each backend uses Router 2 at `10.10.3.1` as its default gateway.
- Router 1 needs a route for `10.10.3.0/24` through Router 2 at `10.10.12.2`.
- Router 2 needs a route for `10.10.1.0/24` through Router 1 at `10.10.12.1`.

The two router namespaces will also need IP forwarding enabled so they can pass packets between their connected subnets. These settings and routes are part of the future implementation; they are not applied by this document-only phase.

## Example request path

For a request sent to Backend 2, the load balancer sees `10.10.3.12` is outside its own `10.10.1.0/24` subnet. It sends the packet to its gateway, Router 1. Router 1 forwards it across the transit subnet to Router 2, which delivers it to Backend 2. The backend sends its reply to its gateway, Router 2, and the routers forward it back toward the load balancer.
