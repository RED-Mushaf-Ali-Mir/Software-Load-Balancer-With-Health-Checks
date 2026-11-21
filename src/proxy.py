import asyncio
from dataclasses import dataclass
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

class Round_Robin:
    def __init__ (self , backends):
        self.backends = backends
        self.index = 0
    def pick(self):
        n = len(self.backends)
        for _ in range(n):
            b = self.backends[self.index % n]
            self.index += 1
            if b.healthy:
                return b
        return None

async def send_error(writer, status, message):
    body = (message + "\n").encode()
    writer.write(
        f"HTTP/1.1 {status}\r\n".encode()
        + b"Content-Length: " + str(len(body)).encode() + b"\r\n"
        b"Connection: close\r\n\r\n" + body
    )
    await writer.drain()

def make_handler (balancer):
    async def handle_client(client_reader , client_writer):
        client_addr = client_writer.get_extra_info("peername")
        backend_writer = None
        backend = None

        try:
            request = await client_reader.readuntil(b"\r\n\r\n")

            picked = balancer.pick()
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

async def main():

    backends = [
        Backend("127.0.0.1", 9001),
        Backend("127.0.0.1", 9002),
        Backend("127.0.0.1", 9003),
    ]
    balancer = Round_Robin(backends)
    server = await asyncio.start_server(make_handler(balancer), "127.0.0.1", LISTEN_PORT)

    print(f"LB listening on {LISTEN_PORT}, round robin over {[b.name for b in backends]}")

    async with server:
        await server.serve_forever()

asyncio.run(main())
