"""A local stand-in for a provider having a bad moment: the first N requests get HTTP 529 (overloaded) with a
Retry-After, later ones are forwarded to the real provider over TLS and streamed back. Logs request numbers, paths and
statuses only, never headers or bodies (they carry the API key)."""
import http.client, socketserver, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = sys.argv[1]            # e.g. api.anthropic.com
PORT = int(sys.argv[2])
FAILURES = int(sys.argv[3])       # how many requests fail first
RETRY_AFTER = sys.argv[4]         # seconds, as a string
count = 0
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        global count
        with lock:
            count += 1
            n = count
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        if n <= FAILURES:
            payload = b'{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
            self.send_response(529)
            self.send_header("Content-Type", "application/json")
            self.send_header("retry-after", RETRY_AFTER)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            print(f"request {n} {self.path}: answered 529 with retry-after {RETRY_AFTER}", flush=True)
            return
        headers = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "content-length", "connection", "accept-encoding")}
        conn = http.client.HTTPSConnection(UPSTREAM, timeout=60)
        conn.request("POST", self.path, body=body, headers=headers)
        resp = conn.getresponse()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("content-type", "retry-after", "request-id"):
                self.send_header(k, v)
        self.end_headers()
        sent = 0
        while True:
            chunk = resp.read1(4096)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()
            sent += len(chunk)
        print(f"request {n} {self.path}: forwarded to {UPSTREAM}, HTTP {resp.status}, {sent} bytes streamed", flush=True)

class Server(ThreadingHTTPServer):
    def server_bind(self):
        # Skip HTTPServer's reverse DNS lookup of the host name, which can hang for a long time.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", PORT

Server(("127.0.0.1", PORT), Handler).serve_forever()
