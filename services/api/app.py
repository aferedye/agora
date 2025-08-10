#!/usr/bin/env python3
import os, json, time
from http.server import BaseHTTPRequestHandler, HTTPServer

API_PORT = int(os.getenv("API_PORT", "5050"))

class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code:int, payload:dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {self.client_address[0]} {self.command} {self.path} | " + fmt%args)

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_GET(self):
        if self.path == "/" or self.path == "":
            return self._json(200, {
                "name": "Agora API",
                "endpoints": ["/health", "/time", "/echo (POST)"]
            })
        if self.path == "/health":
            return self._json(200, {"status": "ok"})
        if self.path == "/time":
            return self._json(200, {"epoch": time.time()})
        return self._json(404, {"error":"not_found"})

    def do_POST(self):
        if self.path != "/echo":
            return self._json(404, {"error":"not_found"})
        n = int(self.headers.get("Content-Length","0"))
        raw = self.rfile.read(n) if n>0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            payload={"_raw": raw.decode("utf-8","ignore")}
        return self._json(200, {"ok": True, "received": payload})

def main():
    server = HTTPServer(("0.0.0.0", API_PORT), Handler)
    print(f"[api] listening on http://127.0.0.1:{API_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
