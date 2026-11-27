import asyncio
from dataclasses import dataclass
import argparse
import zlib
from datetime import datetime
import yaml
#Weakness: it spreads request counts, not work. If backend3 is five times slower, it still gets a third of the requests and its queue grows while backend1 sits idle. You’ll measure this, and it’s why least-connections exists.
@dataclass
class Backend:
    host: str
    port: int
    healthy: bool = True   # health checks will flip this later
    active: int = 0        # connections in flight right now
    total: int = 0         # requests handled so far

    @property
    def name(self):
        return f"{self.host}:{self.port}"


LISTEN_PORT = 8080

class RoundRobin:
    def __init__ (self , backends):
        self.backends = backends
        self.index = 0
    def pick(self , client_ip = None):
        n = len(self.backends)
        for _ in range(n):
            b = self.backends[self.index % n]
            self.index += 1
            if b.healthy:
                return b
        return None

class LeastConnections:
    
    def __init__ (self , backends):
        self.backends = backends
    
    def pick(self , client_ip = None):
        healthy = [b for b in self.backends if b.healthy]
        if not healthy:
            return None
        return min(healthy , key=lambda b:(b.active , b.total))

class IPHash:
    def __init__ (self , backends):
        self.backends = backends
    def pick (self , client_ip = None):
        n = len(self.backends)
        start = zlib.crc32(client_ip.encode()) % n
        for i in range(n):
            b = self.backends[(start + i) % n]
            if b.healthy:
                return b
        return None
 
ALGOS = {
    "roundrobin": RoundRobin,
    "leastconn": LeastConnections,
    "iphash": IPHash,
}


async def send_error(writer, status, message):
    body = (message + "\n").encode()
    writer.write(
        f"HTTP/1.1 {status}\r\n".encode()
        + b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Connection: close\r\n\r\n" + body
    )
    await writer.drain()

async def check_once(backend, timeout):
    """Return True if backend answers GET /health with status 200."""
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(backend.host, backend.port), timeout)
        writer.write(
            b"GET /health HTTP/1.1\r\n"
            b"Host: lb\r\n"
            b"Connection: close\r\n\r\n")
        await writer.drain()
        status_line = await asyncio.wait_for(reader.readline(), timeout)
        return b" 200 " in status_line
    except (OSError, asyncio.TimeoutError):
        return False
    finally:
        if writer:
            writer.close()

def ts():
    return datetime.now().strftime("%H:%M:%S.%f")[:-3]

async def watch(backend, interval, fail_threshold, timeout):
    fails = 0                                   # consecutive failures
    while True:
        ok = await check_once(backend, timeout)
        if ok:
            fails = 0
            if not backend.healthy:             # B1: one success brings it back
                backend.healthy = True
                print(f"[{ts()}] [health] {backend.name} is UP")
        else:
            fails += 1
            if fails >= fail_threshold and backend.healthy:
                backend.healthy = False
                print(f"[{ts()}] [health] {backend.name} is DOWN ({fails} failures)")
        await asyncio.sleep(interval)       
    

def make_handler (balancer):
    async def handle_client(client_reader , client_writer):
        client_addr = client_writer.get_extra_info("peername")
        client_ip = client_addr[0]
        backend_writer = None
        backend = None

        try:
            request = await client_reader.readuntil(b"\r\n\r\n")

            picked = balancer.pick(client_ip)
            if picked is None:
                await send_error(client_writer , "503 Service Unavailable","No healthy backends")
                return
            picked.active += 1
            picked.total += 1
            backend = picked

            try:
                backend_reader , backend_writer = await asyncio.open_connection(backend.host, backend.port)

            except OSError:
                await send_error(client_writer, "502 Bad Gateway",
                                 f"Backend {backend.name} unreachable")
                return

            backend_writer.write(request)
            await backend_writer.drain()

            while True:
                chunk = await backend_reader.read(4096)
                if not chunk:
                    break
                client_writer.write(chunk)
                await client_writer.drain()
            print(f"Served {client_addr} via backend {backend.port}")

        except asyncio.IncompleteReadError:
            pass

        finally:
            if backend:
                backend.active -= 1
            if backend_writer:
                backend_writer.close()
            client_writer.close()

    return handle_client
    
def parse_args():
    p = argparse.ArgumentParser(description="Software load balancer")
    p.add_argument("--algo", choices=ALGOS.keys(), default="roundrobin")
    p.add_argument("--config", default="config.yaml")
    return p.parse_args()

async def main():
    args = parse_args()
    with open(args.config) as f:
        cfg = yaml.safe_load(f)

    backends = [Backend(b["host"], b["port"]) for b in cfg["backends"]]
    balancer = ALGOS[args.algo](backends)

    host, port = cfg["listen"]["host"], cfg["listen"]["port"]
    server = await asyncio.start_server(make_handler(balancer), host, port)
    print(f"LB on {host}:{port}, algo={args.algo}, backends={[b.name for b in backends]}")
    async with server:
        await server.serve_forever()


asyncio.run(main())
