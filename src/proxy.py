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


BACKENDS = [
    Backend("127.0.0.1", 9001),
    Backend("127.0.0.1", 9002),
    Backend("127.0.0.1", 9003),
]

LISTEN_PORT = 8080
BACKEND_PORT = 9001
BACKEND_HOST = "127.0.0.1"

async def handle_client(client_reader , client_writer):
	client_addr = client_writer.get_extra_info("peername")
	backend_writer = None
	
	try:
		request = await client_reader.readuntil(b"\r\n\r\n")
		
		try:
			backend_reader , backend_writer = await asyncio.open_connection(BACKEND_HOST , BACKEND_PORT)
		except OSError:
			body = b"Bad Gateway: backend unreachable\n"
			client_writer.write(
				b"HTTP/1.1 502 Bad Gateway\r\n"
				b"Content-Length: " + str(len(body)).encode() + b"\r\n"
				b"Connection: close\r\n\r\n" + body
			)
			await client_writer.drain()
			return
		backend_writer.write(request)
		await backend_writer.drain()
	        
		while True:
			chunk = await backend_reader.read(4096)
			if not chunk:
				break
			client_writer.write(chunk)
			await client_writer.drain()
		print(f"Served {client_addr} via backend {BACKEND_PORT}")
	        	
	except asyncio.IncompleteReadError:
		pass
	
	finally:
		if backend_writer:
			backend_writer.close()
		client_writer.close()


async def main():

	server = await asyncio.start_server(handle_client , "127.0.0.1" , LISTEN_PORT)
	print(f"Porxy Listening on {LISTEN_PORT} , to {BACKEND_PORT}")
	async with server:
		await server.serve_forever()

asyncio.run(main())
