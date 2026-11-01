from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
import sys


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/error":
            self.send_error(503)
            return
        if self.path == "/sse":
            body = 'data: {"choices":[{"delta":{"content":"héllo"}}]}\n\ndata: [DONE]\n\n'.encode()
            mime = "text/event-stream"
        elif self.path == "/a":
            body = b"<html><script>fixture-injected-script</script><p>Revenue 100</p></html>"
            mime = "text/html"
        elif self.path == "/large":
            body = b"padding " * 80000
            mime = "text/plain"
        else:
            body = b'{"costs":40}'
            mime = "application/json"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


class FixtureServer(ThreadingHTTPServer):
    def server_bind(self):
        # HTTPServer normally reverse-resolves its address here. This loopback-only
        # fixture needs no DNS, which can be slow or unavailable on hosted runners.
        TCPServer.server_bind(self)
        self.server_name = "localhost"
        self.server_port = self.server_address[1]


server = FixtureServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
