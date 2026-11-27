# Network Architecture

This diagram shows the seven network namespaces, the two Linux bridges, and the three subnets created by `setup.sh`. Interface addresses and routes reflect `README.md` and `routing.sh`. Bridges are Layer 2 switches and have no IP addresses assigned.

```mermaid
flowchart LR
  subgraph client_subnet["Client subnet · 10.10.1.0/24"]
    direction TB
    client(["client namespace<br/>eth0 · 10.10.1.10/24<br/>default gateway · 10.10.1.1"])
    lb(["lb namespace<br/>eth0 · 10.10.1.20/24<br/>default gateway · 10.10.1.1"])
    br_client[["br-client<br/>Linux bridge · Layer 2"]]
    client --- br_client
    lb --- br_client
  end

  subgraph transit_subnet["Transit subnet · 10.10.12.0/30"]
    direction LR
    r1{{"r1 · Router 1<br/>eth0 · 10.10.1.1/24<br/>eth1 · 10.10.12.1/30<br/>route 10.10.3.0/24 via 10.10.12.2<br/>IPv4 forwarding enabled"}}
    r2{{"r2 · Router 2<br/>eth0 · 10.10.12.2/30<br/>eth1 · 10.10.3.1/24<br/>route 10.10.1.0/24 via 10.10.12.1<br/>IPv4 forwarding enabled"}}
    r1 ---|"r1 eth1 · 10.10.12.1/30 ↔ r2 eth0 · 10.10.12.2/30"| r2
  end

  subgraph backend_subnet["Backend subnet · 10.10.3.0/24"]
    direction TB
    br_backend[["br-backend<br/>Linux bridge · Layer 2"]]
    backend1(["backend1 namespace<br/>eth0 · 10.10.3.11/24<br/>default gateway · 10.10.3.1"])
    backend2(["backend2 namespace<br/>eth0 · 10.10.3.12/24<br/>default gateway · 10.10.3.1"])
    backend3(["backend3 namespace<br/>eth0 · 10.10.3.13/24<br/>default gateway · 10.10.3.1"])
    br_backend --- backend1
    br_backend --- backend2
    br_backend --- backend3
  end

  br_client ---|"r1 eth0 · 10.10.1.1/24"| r1
  r2 ---|"r2 eth1 · 10.10.3.1/24"| br_backend

  classDef endpoint fill:#EAF2F8,stroke:#2874A6,stroke-width:1.5px,color:#17202A;
  classDef bridge fill:#FCF3CF,stroke:#B7950B,stroke-width:2px,color:#17202A;
  classDef router fill:#E8F8F5,stroke:#148F77,stroke-width:2px,color:#17202A;
  class client,lb,backend1,backend2,backend3 endpoint;
  class br_client,br_backend bridge;
  class r1,r2 router;
```

## Architecture and routing path

The client and load balancer share the `10.10.1.0/24` LAN through `br-client`; traffic between them stays on that subnet. For load-balancer traffic to a backend, the load balancer sends packets to its default gateway, Router 1 (`10.10.1.1`). Router 1 forwards them over the transit link to Router 2 (`10.10.12.2`), which delivers them to the backend subnet through `br-backend`. Replies use Router 2 as the backend gateway and follow Router 2's route to `10.10.1.0/24` via Router 1 (`10.10.12.1`). Both routers have IPv4 forwarding enabled.
