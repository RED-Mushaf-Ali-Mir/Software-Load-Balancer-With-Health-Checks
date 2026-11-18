import asyncio
import os

PORT = int(os.environ.get("PORT", 9001))
NAME = os.environ.get("NAME", f"backend{PORT}")
DELAY_MS = int(os.environ.get("DELAY_MS", 0))

async def handle(reader, writer):
    try:
        request = await reader.readuntil(b"\r\n\r\n")
        first_line = request.split(b"\r\n")[0].decode()
        method, path, _ = first_line.split(" ")

        if path == "/health":
            body = b"OK"
        else:
            await asyncio.sleep(DELAY_MS / 1000)   # simulated slow work
            body = f"Hello from {NAME}\n".encode()

        response = (
            b"HTTP/1.1 200 OK\r\n"
            b"Content-Type: text/plain\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n"
            b"Connection: close\r\n\r\n" + body
        )
        writer.write(response)
        await writer.drain()
    except asyncio.IncompleteReadError:
        pass  # client disconnected early
    finally:
        writer.close()
        await writer.wait_closed()

async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", PORT)
    print(f"{NAME} listening on {PORT}, delay {DELAY_MS} ms")
    async with server:
        await server.serve_forever()

asyncio.run(main())
