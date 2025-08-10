#!/usr/bin/env bash
set -euo pipefail

mkdir -p services/api var/logs

# 1) API stdlib minimaliste
grep -q '^API_PORT=' .env 2>/dev/null || echo 'API_PORT=5050' >> .env

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
    def _json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code); self._cors()
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def log_message(self, fmt, *args):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {self.client_address[0]} {self.command} {self.path} | " + fmt%args)
    def do_OPTIONS(self): self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        if self.path=="/health": return self._json(200, {"status":"ok"})
        if self.path=="/time":   return self._json(200, {"epoch": time.time()})
        return self._json(404, {"error":"not_found"})
    def do_POST(self):
        if self.path!="/echo": return self._json(404, {"error":"not_found"})
        n = int(self.headers.get("Content-Length","0")); raw = self.rfile.read(n) if n>0 else b"{}"
        try: payload = json.loads(raw.decode("utf-8") or "{}")
        except Exception: payload={"_raw": raw.decode("utf-8","ignore")}
        return self._json(200, {"ok": True, "received": payload})
def main():
    HTTPServer(("0.0.0.0", API_PORT), Handler).serve_forever()
if __name__=="__main__": main()
PY
chmod +x services/api/app.py

cat > services/api/run.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && { set -a; . ".env"; set +a; }
: "${API_PORT:=5050}"
echo "[api] listening on http://127.0.0.1:${API_PORT}"
exec python3 services/api/app.py
SH
chmod +x services/api/run.sh

# 2) Réécrire dubash propre avec api:*
cat > dubash <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && { set -a; . ".env"; set +a; }
LOG_FILE="${LOG_FILE:-var/logs/dubash.log}"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
require(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Requis: $1"; exit 1; }; }
ensure_dirs(){ mkdir -p var/logs var/memory var/tmp; : > "$LOG_FILE"; }

help(){
cat <<HLP
Usage: ./dubash <cmd>
  up           Lance l’environnement minimal (web)
  down         Placeholder
  build        Vérifie outils
  test         Placeholder
  status       Infos utiles (ports, logs)
  logs         Tail logs
  web:up       Lance serveur statique (public/)
  web:open     Ouvre navigateur
  api:up       Lance l'API (Python stdlib)
  api:open     Ouvre /health
  api:status   Liste endpoints
HLP
}

cmd_build(){ ensure_dirs; log "🔧 Vérifs"; require python3; log "✅ OK"; }
cmd_up(){ ensure_dirs; log "🚀 Start web"; ./dubash web:up; }
cmd_down(){ log "🛑 Rien à arrêter (fg)"; }
cmd_test(){ ensure_dirs; log "🧪 Rien pour l'instant"; }
cmd_status(){ ensure_dirs; echo "== ${AGORA_NAME:-Agora} (${AGORA_ENV:-dev}) =="; echo "Web: http://127.0.0.1:${WEB_PORT:-8080}"; echo "API: http://127.0.0.1:${API_PORT:-5050}"; echo "Log: $LOG_FILE"; }
cmd_logs(){ ensure_dirs; tail -n 200 -f "$LOG_FILE"; }

cmd_web_up(){ ensure_dirs; log "🌐 web"; ./services/web/run.sh; }
cmd_web_open(){ port="${WEB_PORT:-8080}"; if command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:${port}" >/dev/null 2>&1||true; elif command -v open >/dev/null; then open "http://127.0.0.1:${port}" >/dev/null 2>&1||true; else echo "→ http://127.0.0.1:${port}"; fi; }

cmd_api_up(){ ensure_dirs; log "🧩 API → start"; ./services/api/run.sh; }
cmd_api_open(){
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"; url="http://127.0.0.1:${API_PORT}/health"
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1||true
  elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1||true
  else echo "→ $url"; fi
}
cmd_api_status(){
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  echo "API: http://127.0.0.1:${API_PORT}"
  echo "Endpoints: GET /health, GET /time, POST /echo"
}

case "${1:-help}" in
  help|-h|--help) help ;;
  build) cmd_build ;;
  up) cmd_up ;;
  down) cmd_down ;;
  test) cmd_test ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  web:up) cmd_web_up ;;
  web:open) cmd_web_open ;;
  api:up) cmd_api_up ;;
  api:open) cmd_api_open ;;
  api:status) cmd_api_status ;;
  *) echo "Commande inconnue: $1"; echo; help; exit 1 ;;
esac
BASH
chmod +x dubash

# 3) (Optionnel) commit & push vers dev si repo git
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "feat(api): stub stdlib + commandes dubash (api:up|open|status)"
    # si tu veux pousser automatiquement, décommente la ligne suivante :
    # git push -u origin dev || true
  fi
fi

echo "✅ Patch appliqué. Lance: ./dubash api:up"
