import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NAME = os.getenv("BACKEND_NAME", "Backend")
DELAY_MS = int(os.getenv("DELAY_MS", "0"))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/health":
            body = b"OK\n"
        elif self.path == "/":
            time.sleep(DELAY_MS / 1000)
            body = f"Hello from {NAME}\n".encode()
        else:
            self.send_error(404)
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True


ThreadingHTTPServer(("127.0.0.1", 8000), Handler).serve_forever()