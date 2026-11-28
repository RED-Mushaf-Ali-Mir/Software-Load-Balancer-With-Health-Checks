# Software Load Balancer Network Lab

This directory provides an isolated Linux network for the Software Load Balancer project. It connects a test client and load balancer to three backend namespaces through two routers. The lab supports routing and connectivity checks, traffic impairment, and packet capture. The network scripts do not start the load-balancer application or backend services.

The editable architecture diagram is in [topology.md](topology.md).

## Architecture

The lab has seven network namespaces, two Linux bridges, and three IPv4 subnets:

- `client`, `lb`, and `r1` connect to the client LAN through `br-client`.
- `r1` and `r2` connect over the point-to-point transit subnet.
- `r2` and `backend1`–`backend3` connect to the backend LAN through `br-backend`.
- IPv4 forwarding is enabled in `r1` and `r2`; the scripts configure no forwarding in other namespaces.

### IP addressing plan

| Namespace or bridge | Interface | IPv4 address | Gateway or role |
|---|---|---|---|
| `client` | `eth0` | `10.10.1.10/24` | Default gateway `10.10.1.1` |
| `lb` | `eth0` | `10.10.1.20/24` | Default gateway `10.10.1.1` |
| `r1` | `eth0` | `10.10.1.1/24` | Client LAN gateway |
| `r1` | `eth1` | `10.10.12.1/30` | Transit link to `r2` |
| `r2` | `eth0` | `10.10.12.2/30` | Transit link to `r1` |
| `r2` | `eth1` | `10.10.3.1/24` | Backend LAN gateway |
| `backend1` | `eth0` | `10.10.3.11/24` | Default gateway `10.10.3.1` |
| `backend2` | `eth0` | `10.10.3.12/24` | Default gateway `10.10.3.1` |
| `backend3` | `eth0` | `10.10.3.13/24` | Default gateway `10.10.3.1` |
| `br-client` | — | No IP assigned | Layer 2 bridge for the client LAN |
| `br-backend` | — | No IP assigned | Layer 2 bridge for the backend LAN |

| Subnet | Connected devices |
|---|---|
| `10.10.1.0/24` | `client`, `lb`, and `r1 eth0` via `br-client` |
| `10.10.12.0/30` | `r1 eth1` and `r2 eth0` |
| `10.10.3.0/24` | `r2 eth1` and the three backends via `br-backend` |

The client reaches the load balancer directly on the client LAN. For load-balancer-to-backend traffic, `lb` uses `r1` (`10.10.1.1`) as its gateway; `r1` routes `10.10.3.0/24` through `r2` (`10.10.12.2`). `r2` delivers packets on the backend LAN. Replies use the backend gateway `10.10.3.1`, and `r2` routes `10.10.1.0/24` through `r1` (`10.10.12.1`).

## Ubuntu requirements

Use Ubuntu Linux with a kernel that supports network namespaces, veth devices, Linux bridges, and `tc` netem. Run the network scripts from the repository root with `sudo`. Install the tools used by the scripts:

```bash
sudo apt update
sudo apt install iproute2 iputils-ping procps gawk tcpdump
```

`iproute2` provides `ip` and `tc`; `iputils-ping` provides `ping`; `procps` provides `sysctl`; `gawk` supports the setup and teardown ownership checks; and `tcpdump` is used for captures. For the optional bandwidth measurement below, install `iperf3`. Wireshark is optional for graphical PCAP inspection:

```bash
sudo apt install iperf3 wireshark
```

## Set up, route, and verify

From the repository root, create the namespaces and links, configure routes, then run the verifier:

```bash
sudo ./network/setup.sh
sudo ./network/routing.sh
sudo ./network/verify.sh
```

`setup.sh` creates the seven namespaces, both bridges, veth links, and interface addresses. It deliberately does not configure routes or forwarding. It refuses to overwrite pre-existing lab names, so do not rerun it on an already-created topology. `routing.sh` sets the endpoint default gateways, the two static router routes, and forwarding in `r1` and `r2`; its route updates can be repeated safely. `verify.sh` reports PASS/FAIL for namespaces, addresses, bridges, routes, forwarding, and ping connectivity, followed by a count summary. It checks client-to-load-balancer and client/load-balancer-to-backend reachability.

To run a few explicit connectivity checks:

```bash
sudo ip netns exec client ping -n -c 3 10.10.1.20
sudo ip netns exec client ping -n -c 3 10.10.3.11
sudo ip netns exec client ping -n -c 3 10.10.3.12
sudo ip netns exec client ping -n -c 3 10.10.3.13
```

## Simulate network impairment

`netem.sh` changes the egress root qdisc on `eth0` in the selected backend namespace only. Each command replaces the previous managed profile on that backend. Delay and loss therefore affect packets leaving the backend, including replies to client pings.

| Command | Profile |
|---|---|
| `sudo ./network/netem.sh delay backend1` | 100 ms delay |
| `sudo ./network/netem.sh loss backend1` | 5% packet loss |
| `sudo ./network/netem.sh bandwidth backend1` | 10 Mbit/s TBF rate limit |
| `sudo ./network/netem.sh combined backend1` | 100 ms delay plus 5% packet loss |
| `sudo ./network/netem.sh status backend1` | Show qdisc status for `backend1/eth0` |
| `sudo ./network/netem.sh normal backend1` | Remove this script's managed qdisc, if present |

Replace `backend1` with `backend2` or `backend3` to target another backend. `normal` leaves unrelated qdiscs untouched. If a profile command refuses an unrelated root qdisc, inspect it with `status`; do not remove an unrecognized qdisc as part of this lab workflow.

## Packet capture

`capture.sh` runs `tcpdump` inside one of the seven namespaces and writes a `.pcap` file for Wireshark. It requires an existing writable output directory and refuses to overwrite an existing file. The default packet count is 100; pass a positive count as the fourth argument to choose another limit. Use a fresh filename for each capture.

Create an output directory once:

```bash
mkdir -p captures
```

Example capture on the load balancer's interface (the namespace must already exist):

```bash
sudo ./network/capture.sh lb eth0 captures/lb.pcap 100
```

The command ends after it captures the requested packet count. To inspect a saved capture in text form or Wireshark:

```bash
tcpdump -nn -r captures/lb.pcap
wireshark captures/lb.pcap
```

## Reproducible experiments

Run these experiments after setup and routing. Use `normal` to reset a backend profile before comparing results. Captures and measurements depend on the host and are not guaranteed to be identical between runs.

### Connectivity

Run `sudo ./network/verify.sh` or the four explicit ping commands above. **Expected:** the verifier's checks pass and the pings receive replies when routes are configured and no impairment causes loss. This is an expected outcome, not a result reported from a run.

### Delay

Compare a baseline with the delay profile from the client to `backend1`:

```bash
sudo ip netns exec client ping -n -c 5 10.10.3.11
sudo ./network/netem.sh delay backend1
sudo ip netns exec client ping -n -c 5 10.10.3.11
sudo ./network/netem.sh normal backend1
```

**Expected:** the second ping's round-trip time increases by roughly 100 ms because the backend's egress echo replies are delayed. Actual timings vary with the host.

### Packet loss

Apply the loss profile and send 100 probes:

```bash
sudo ./network/netem.sh loss backend1
sudo ip netns exec client ping -n -i 0.1 -c 100 10.10.3.11
sudo ./network/netem.sh normal backend1
```

**Expected:** some echo replies may be lost, with a rate around 5% over a sufficiently large sample. Netem loss is probabilistic, so the observed count can differ.

### Bandwidth limit

Install `iperf3` first. Apply the limit, then run the server and client in separate terminals. Reverse mode makes `backend1` transmit, so its `eth0` egress rate limit is exercised.

```bash
sudo ./network/netem.sh bandwidth backend1
```

Terminal 1:

```bash
sudo ip netns exec backend1 iperf3 -s -1
```

Terminal 2:

```bash
sudo ip netns exec client iperf3 -c 10.10.3.11 -R -t 10
```

After the one-off server exits, reset the profile:

```bash
sudo ./network/netem.sh normal backend1
```

**Expected:** reverse-direction throughput is limited to approximately 10 Mbit/s or lower due to protocol overhead and host conditions.

### Packet capture

Warm up neighbor discovery, then capture 20 packets in Terminal 1 and generate traffic in Terminal 2:

```bash
sudo ip netns exec client ping -n -c 1 10.10.1.20
```

Terminal 1:

```bash
sudo ./network/capture.sh client eth0 captures/client.pcap 20
```

Terminal 2, after the capture starts:

```bash
sudo ip netns exec client ping -n -c 10 10.10.1.20
```

Inspect the resulting file with `tcpdump -nn -r captures/client.pcap` or open it in Wireshark. **Expected:** the capture contains the generated ICMP traffic. The capture process waits until the requested count is reached, so generate enough traffic while it is running.

## Expected and observed results

**Expected results** are the outcomes described in the experiment sections: successful connectivity with a correctly configured lab, increased RTT under delay, probabilistic loss under the loss profile, reduced throughput under the bandwidth profile, and decodable PCAP output.

**Actual observed results:** no runtime measurements or packet captures are reported in this documentation. Record ping output, packet loss, iperf3 throughput, and capture inspection results after running the experiments on the target Ubuntu host; do not treat the expected outcomes above as measured results.

## Troubleshooting

- **A namespace already exists:** `setup.sh` intentionally refuses to reuse it. If it is the project lab, continue with routing and verification; to rebuild, clean up first with `teardown.sh`.
- **Missing command or permission error:** install the listed packages and run setup, routing, verification, shaping, and capture commands with `sudo`.
- **Connectivity checks fail:** run `sudo ./network/routing.sh`, then `sudo ./network/verify.sh`. Confirm no impairment is active with `sudo ./network/netem.sh status backend1` (and the relevant backend); run `normal` before interpreting connectivity checks under loss.
- **A shaping command refuses the root qdisc:** use `status` to inspect the selected backend interface. The script intentionally does not overwrite unrelated qdiscs.
- **Capture fails validation:** use a supported namespace, an interface present in it (for example `eth0`), a `.pcap` filename, an existing writable directory, and a filename that does not already exist.
- **Capture appears to wait:** it ends after the requested packet count, not after a fixed time. Generate traffic in another terminal or use a smaller packet count.
- **Teardown refuses to proceed:** stop processes in the namespaces first. Teardown also refuses to remove namespaces, bridges, or veths that are busy, unexpected, or lack the project ownership tags.

## Cleanup

Stop any test services or other processes running in the namespaces. Optionally remove managed impairment profiles before deleting the topology:

```bash
sudo ./network/netem.sh normal backend1
sudo ./network/netem.sh normal backend2
sudo ./network/netem.sh normal backend3
sudo ./network/teardown.sh
```

`teardown.sh` removes only tagged project namespaces, veths, and bridges, and refuses cleanup if it finds live namespace processes or unexpected resources. PCAP files are ordinary output files and are not removed by teardown.
