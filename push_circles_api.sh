#!/usr/bin/env bash
set -euo pipefail

# Dossiers & données
mkdir -p services/api var/memory var/logs
[ -f var/memory/circles.json ] || echo "[]" > var/memory/circles.json
grep -q '^API_PORT=' .env 2>/dev/null || echo 'API_PORT=5050' >> .env

# API complète (garde /, /health, /time, /echo + endpoints circles)
cat > services/api/app.py <<'PY'
#!/usr/bin/env python3
import os, json, time, re, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

API_PORT = int(os.getenv("API_PORT", "5050"))
DB_PATH  = os.path.join("var", "memory", "circles.json")

def _load_db():
    try:
        with open(DB_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return []
    except Exception:
        return []

def _save_db(data):
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    # Écriture atomique
    fd, tmp = tempfile.mkstemp(prefix="circles_", suffix=".json", dir=os.path.dirname(DB_PATH))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, DB_PATH)

def _next_id(items):
    return (max((c.get("id", 0) for c in items), default=0) + 1)

def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code:int, payload:dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _parse_body(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n) if n > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return {}

    def log_message(self, fmt, *args):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {self.client_address[0]} {self.command} {self.path} | " + fmt%args)

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    # ---- GET ----
    def do_GET(self):
        if self.path in ("/", ""):
            return self._json(200, {
                "name": "Agora API",
                "endpoints": ["/health", "/time", "/echo (POST)", "/circles"]
            })
        if self.path == "/health":
            return self._json(200, {"status": "ok"})
        if self.path == "/time":
            return self._json(200, {"epoch": time.time()})
        if self.path == "/circles":
            data = _load_db()
            return self._json(200, {"items": data, "count": len(data)})

        m = re.match(r"^/circles/(\d+)$", self.path)
        if m:
            cid = int(m.group(1))
            data = _load_db()
            for c in data:
                if c.get("id") == cid:
                    return self._json(200, c)
            return self._json(404, {"error": "not_found"})
        return self._json(404, {"error":"not_found"})

    # ---- POST ----
    def do_POST(self):
        if self.path == "/echo":
            return self._json(200, {"ok": True, "received": self._parse_body()})

        if self.path == "/circles":
            body = self._parse_body()
            title = (body.get("title") or "").strip()
            desc  = (body.get("description") or "").strip()
            if not title:
                return self._json(400, {"error": "title_required"})
            data = _load_db()
            cid = _next_id(data)
            now = _now_iso()
            item = {
                "id": cid,
                "title": title,
                "description": desc,
                "created_at": now,
                "updated_at": now
            }
            data.append(item)
            _save_db(data)
            return self._json(201, item)

        return self._json(404, {"error":"not_found"})

    # ---- PATCH ----
    def do_PATCH(self):
        m = re.match(r"^/circles/(\d+)$", self.path)
        if not m:
            return self._json(404, {"error":"not_found"})
        cid = int(m.group(1))
        body = self._parse_body()
        data = _load_db()
        for c in data:
            if c.get("id") == cid:
                if "title" in body and isinstance(body["title"], str):
                    c["title"] = body["title"].strip()
                if "description" in body and isinstance(body["description"], str):
                    c["description"] = body["description"].strip()
                c["updated_at"] = _now_iso()
                _save_db(data)
                return self._json(200, c)
        return self._json(404, {"error":"not_found"})

    # ---- DELETE ----
    def do_DELETE(self):
        m = re.match(r"^/circles/(\d+)$", self.path)
        if not m:
            return self._json(404, {"error":"not_found"})
        cid = int(m.group(1))
        data = _load_db()
        new_data = [c for c in data if c.get("id") != cid]
        if len(new_data) == len(data):
            return self._json(404, {"error":"not_found"})
        _save_db(new_data)
        return self._json(204, {})

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
PY
chmod +x services/api/app.py

# Doc
if ! grep -q "### Cercles" DOC.md 2>/dev/null; then
  cat >> DOC.md <<'MD'

### Cercles
- `GET /circles` → `{"items":[...],"count":n}`
- `POST /circles` → crée `{ "title": "...", "description": "..." }`
- `GET /circles/<id>`
- `PATCH /circles/<id>` → MAJ partielle `title|description`
- `DELETE /circles/<id>`
MD
fi

# (Optionnel) Commit & push si git
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Basculer/Créer dev si besoin
  if git rev-parse --verify dev >/dev/null 2>&1; then
    git checkout dev
  else
    if git ls-remote --heads origin dev | grep -q dev; then git checkout -t origin/dev; else git checkout -b dev; fi
  fi
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "feat(circles): endpoints CRUD + stockage JSON local"
    # Décommente si tu veux pousser auto :
    # git push -u origin dev || true
  fi
fi

echo "✅ Cercles prêts. Redémarre l'API: ./dubash api:up"
