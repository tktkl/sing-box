"""Isolated HTTP/UDP target and TLS 1.3 REALITY handshake fixture."""
import http.server
import socket
import subprocess
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/idle-75":
            # No response bytes for longer than nginx's default 60-second timeout.
            time.sleep(75)
        body = b"sb-manager-e2e-ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def udp(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    while True:
        message, address = sock.recvfrom(65535)
        sock.sendto(message, address)


for port in (8000, 8001):
    threading.Thread(target=udp, args=(port,), daemon=True).start()
subprocess.run([
    "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt",
    "ec_paramgen_curve:prime256v1", "-nodes", "-days", "2",
    "-subj", "/CN=target.test", "-addext", "subjectAltName=DNS:target.test",
    "-keyout", "/state/target.key", "-out", "/state/target.pem",
], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.Popen([
    "openssl", "s_server", "-accept", "443", "-tls1_3", "-alpn", "h2",
    "-cert", "/state/target.pem", "-key", "/state/target.key", "-www",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
http.server.ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
