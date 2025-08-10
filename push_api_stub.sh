#!/usr/bin/env bash
set -euo pipefail

REMOTE_HOST_ALIAS="github.com-agora-deploy"
REMOTE_SLUG="aferedye/agora"
BRANCH="dev"

# Sanity
git rev-parse --show-toplevel >/dev/null || { echo "❌ Lance depuis la racine du repo."; exit 1; }

# Dossiers
mkdir -p services/api var/logs

# 1) .env → ajoute API_PORT si absent
grep -q '^API_PORT=' .env 2>/dev/null || echo 'API_PORT=5050' >> .env

# 2) services/api/app.py — API minimale (stdlib)
cat > services/api/app.py <<'PY'
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
        # Log propre (stdout)
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {self.client_address[0]} {self.command} {self.path} | " + fmt%args)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if self.path == "/health":
            return self._json(200, {"status": "ok"})
        elif self.path == "/time":
            return self._json(200, {"epoch": time.time()})
        else:
            return self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path == "/echo":
            length = int(self.headers.get("Content-Length", "0"))
            data = self.rfile.read(length) if length > 0 else b"{}"
            try:
                payload = json.loads(data.decode("utf-8") or "{}")
            except Exception:
                payload = {"_raw": data.decode("utf-8", errors="ignore")}
            return self._json(200, {"ok": True, "received": payload})
        else:
            return self._json(404, {"error": "not_found"})

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

# 3) services/api/run.sh — lance l’API
cat > services/api/run.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && { set -a; . ".env"; set +a; }
: "${API_PORT:=5050}"
echo "[api] starting on :${API_PORT}"
exec python3 services/api/app.py
SH
chmod +x services/api/run.sh

# 4) Patch dubash → commandes api:*
awk 'BEGIN{p=1}
     /case "\${1:-help}" in/ {p=0}
     {if(p) print}' dubash > dubash.head

cat > dubash.api <<'BASH'
api:up)       cmd_api_up ;;
api:open)     cmd_api_open ;;
api:status)   cmd_api_status ;;
BASH

awk 'BEGIN{p=0}
/case "\${1:-help}" in/ {print; p=1; next}
{print}' dubash > dubash.body

# Insère les nouvelles routes api:* dans le case si pas déjà présent
if ! grep -q "api:up)" dubash.body; then
  sed -i 's/^case "\${1:-help}" in$/case "${1:-help}" in\n  api:up)       cmd_api_up ;;\n  api:open)     cmd_api_open ;;\n  api:status)   cmd_api_status ;;/' dubash.body
fi

# Ajoute les fonctions si absentes
if ! grep -q "cmd_api_up()" dubash.body; then
cat >> dubash.body <<'FUN'

cmd_api_up(){
  ensure_dirs
  log "🧩 API → start"
  ./services/api/run.sh
}

cmd_api_open(){
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  url="http://127.0.0.1:${API_PORT}/health"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 || true
  else echo "→ $url"; fi
}

cmd_api_status(){
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  echo "API: http://127.0.0.1:${API_PORT}"
  echo "Endpoints: /health (GET), /echo (POST), /time (GET)"
}
FUN
fi

mv dubash.body dubash
rm -f dubash.head dubash.api
chmod +x dubash

# 5) DOC.md → section API
if ! grep -q "## API" DOC.md 2>/dev/null; then
  cat >> DOC.md <<'MD'

## API (stub)
- Lancer: `./dubash api:up`
- Ouvrir: `./dubash api:open`
- Endpoints:
  - `GET /health` → `{ "status": "ok" }`
  - `GET /time` → `{ "epoch": <timestamp> }`
  - `POST /echo` (JSON) → renvoie le payload
MD
fi

# 6) Commit & push vers dev (remote alias)
git remote set-url origin "git@${REMOTE_HOST_ALIAS}:${REMOTE_SLUG}.git" || true

if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git checkout "$BRANCH"
else
  if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
    git checkout -t "origin/$BRANCH"
  else
    git checkout -b "$BRANCH"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "feat(api): stub stdlib + commandes dubash (api:up|open|status)"
  git push -u origin "$BRANCH"
  echo "✅ API poussée sur origin/${BRANCH}"
else
  echo "ℹ️ Aucun changement à pousser."
fi

echo
echo "🎯 Lancer l'API:  ./dubash api:up"
echo "🔍 Tester:        curl -s http://127.0.0.1:${API_PORT:-5050}/health | jq ."
