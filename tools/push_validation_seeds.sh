#!/usr/bin/env bash
set -euo pipefail

# -- Constantes
TITLE_MAX=80
DESC_MAX=2000

mkdir -p services/api var/memory var/logs tools

# 1) API avec validations + erreurs propres
cat > services/api/app.py <<'PY'
#!/usr/bin/env python3
import os, json, time, re, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer

API_PORT = int(os.getenv("API_PORT", "5050"))
DB_PATH  = os.path.join("var", "memory", "circles.json")

TITLE_MAX = 80
DESC_MAX  = 2000

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
    fd, tmp = tempfile.mkstemp(prefix="circles_", suffix=".json", dir=os.path.dirname(DB_PATH))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, DB_PATH)

def _next_id(items):
    return (max((c.get("id", 0) for c in items), default=0) + 1)

def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _norm_title(t):
    return (t or "").strip().lower()

def _has_title(items, title, exclude_id=None):
    nt = _norm_title(title)
    for c in items:
        if exclude_id is not None and c.get("id") == exclude_id:
            continue
        if _norm_title(c.get("title")) == nt:
            return True
    return False

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
                "endpoints": ["/health", "/time", "/echo (POST)", "/circles"],
                "limits": {"title_max": TITLE_MAX, "description_max": DESC_MAX}
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
            if len(title) > TITLE_MAX:
                return self._json(400, {"error": "title_too_long", "max": TITLE_MAX})
            if len(desc) > DESC_MAX:
                return self._json(400, {"error": "description_too_long", "max": DESC_MAX})

            data = _load_db()
            if _has_title(data, title):
                return self._json(409, {"error": "title_exists"})

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
                if "title" in body:
                    t = (body.get("title") or "").strip()
                    if not t:
                        return self._json(400, {"error": "title_required"})
                    if len(t) > TITLE_MAX:
                        return self._json(400, {"error": "title_too_long", "max": TITLE_MAX})
                    if _has_title(data, t, exclude_id=cid):
                        return self._json(409, {"error": "title_exists"})
                    c["title"] = t
                if "description" in body:
                    d = (body.get("description") or "").strip()
                    if len(d) > DESC_MAX:
                        return self._json(400, {"error": "description_too_long", "max": DESC_MAX})
                    c["description"] = d
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

# 2) Ajout commandes Dubash utilitaires (seed/dump/clear via l’API)
#    (pas de jq requis; on utilise curl)
awk 'BEGIN{p=1}
     /case "\${1:-help}" in/ {p=0}
     {if(p) print}' dubash > dubash.head

awk 'BEGIN{p=0}
/case "\${1:-help}" in/ {print; p=1; next}
{print}' dubash > dubash.body

# Injecte nouveaux cases si absents
grep -q "seed:circles)" dubash.body || \
  sed -i 's/^case "\${1:-help}" in$/case "${1:-help}" in\n  seed:circles) cmd_seed_circles ;;\n  dump:circles) cmd_dump_circles ;;\n  clear:circles) cmd_clear_circles ;;/' dubash.body

# Ajoute les fonctions si absentes
if ! grep -q "cmd_seed_circles()" dubash.body; then
cat >> dubash.body <<'FUN'

cmd_seed_circles(){
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  log "🌱 Seeding cercles (via API)"
  seeds='[
    {"title":"Agora — Cœur","description":"Coordination, écoute, cadence"},
    {"title":"Tech — Forge","description":"Backend, IA, orchestration Bash"},
    {"title":"Culture — Racines","description":"Art, récit, mémoire vivante"}
  ]'
  # Poste chaque seed (ignore 409 title_exists)
  python3 - "$API_PORT" <<'PYSEED'
import sys, json, urllib.request
port = int(sys.argv[1])
seeds = json.loads(sys.stdin.read())
for s in seeds:
    req = urllib.request.Request(f"http://127.0.0.1:{port}/circles",
                                 data=json.dumps(s).encode("utf-8"),
                                 headers={"Content-Type":"application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            print("[seed] OK", s["title"], resp.status)
    except urllib.error.HTTPError as e:
        if e.code == 409:
            print("[seed] SKIP exists", s["title"])
        else:
            print("[seed] ERR", s["title"], e.code)
PYSEED
}

cmd_dump_circles(){
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  log "📝 Dump cercles"
  curl -s "http://127.0.0.1:${API_PORT}/circles"
}

cmd_clear_circles(){
  ensure_dirs
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  # si API up → DELETE chaque id, sinon wipe fichier
  if curl -sf "http://127.0.0.1:${API_PORT}/health" >/dev/null 2>&1; then
    log "🧽 Clear (via API)"
    ids=$(curl -s "http://127.0.0.1:${API_PORT}/circles" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(" ".join(str(i["id"]) for i in data.get("items",[])))')
    for id in $ids; do
      curl -s -X DELETE "http://127.0.0.1:${API_PORT}/circles/$id" >/dev/null
      echo "[clear] id=$id"
    done
  else
    log "🧼 Clear (wipe fichier)"
    echo "[]" > var/memory/circles.json
  fi
  log "✅ Cercles vidés"
}
FUN
fi

mv dubash.body dubash
rm -f dubash.head
chmod +x dubash

# 3) DOC
if ! grep -q "### Validation" DOC.md 2>/dev/null; then
  cat >> DOC.md <<'MD'

### Validation
- `title` requis, max 80 caractères, **unique** (insensible à la casse)
- `description` max 2000 caractères
- Erreurs possibles : `title_required` (400), `title_too_long` (400), `description_too_long` (400), `title_exists` (409)

### Commandes utilitaires
- `./dubash seed:circles` → crée 2–3 cercles de démo (via API)
- `./dubash dump:circles` → affiche la liste JSON
- `./dubash clear:circles` → supprime tous les cercles (API si up, sinon wipe fichier)
MD
fi

# 4) (Optionnel) commit
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "feat(circles): validations + seed/dump/clear (dubash)"
    # décommente pour pousser auto:
    # git push -u origin dev || true
  fi
fi

echo "✅ Validations + commandes ajoutées."
echo "→ Redémarre l'API si nécessaire: ./dubash api:up"
echo "→ Puis: ./dubash seed:circles && ./dubash dump:circles"
