#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------
# GPT Push Express — Agora (branch: dev)
# - Idempotent : crée/maj fichiers clés
# - Commit + push sur dev via host SSH dédié
# - Nécessite: deploy key chargée + host "github.com-agora-deploy"
# ---------------------------------------

REPO_EXPECTED="agora"
REMOTE_HOST_ALIAS="github.com-agora-deploy" # doit correspondre à ton ~/.ssh/config
REMOTE_SLUG="aferedye/agora"
BRANCH="dev"
LOG="var/logs/dubash.log"

# Sanity checks
repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo .)")"
if [[ "$repo_name" != "$REPO_EXPECTED" ]]; then
  echo "❌ Lance ce script depuis la racine du repo '$REPO_EXPECTED' (ici: '$repo_name')."
  exit 1
fi

mkdir -p var/logs var/memory var/tmp core services/web public tools

# --- .env ---
cat > .env <<'EOF'
AGORA_NAME="Agora"
AGORA_ENV="dev"
WEB_PORT=8080
LOG_FILE="var/logs/dubash.log"
EOF

# --- public/index.html ---
cat > public/index.html <<'EOF'
<!doctype html>
<html lang="fr"><head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Agora — it works</title>
<style>
html,body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,"Helvetica Neue",Arial,sans-serif;margin:0;padding:0;background:#0b0f14;color:#e7edf3}
.wrap{max-width:780px;margin:8vh auto;padding:24px}
.card{background:#121821;border:1px solid #1d2430;border-radius:14px;padding:20px;box-shadow:0 10px 30px rgba(0,0,0,.25)}
h1{margin:0 0 8px 0;font-size:28px}
code,pre{background:#0f141c;border:1px solid #1a2330;padding:.35em .6em;border-radius:8px}
.muted{opacity:.75}
</style>
</head><body>
<div class="wrap"><div class="card">
  <h1>🚀 Agora est en place</h1>
  <p>Servi via <code>./dubash web:up</code>. Édite <code>public/index.html</code>.</p>
  <p class="muted">Fil rouge prêt. API & IA viendront ensuite.</p>
</div></div>
</body></html>
EOF

# --- services/web/run.sh ---
cat > services/web/run.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ -f ".env" ]; then set -a; . ".env"; set +a; fi
port="${WEB_PORT:-8080}"
echo "[web] Serving ./public on http://127.0.0.1:${port}"
cd public
python3 -m http.server "${port}"
EOF
chmod +x services/web/run.sh

# --- dubash ---
cat > dubash <<'EOF'
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
  up         Lance l’environnement minimal (web)
  down       Placeholder
  build      Vérifie outils
  test       Placeholder
  status     Infos utiles (ports, logs)
  logs       Tail logs
  web:up     Lance serveur statique (public/)
  web:open   Ouvre navigateur
HLP
}

cmd_build(){ ensure_dirs; log "🔧 Vérifs"; require python3; log "✅ OK"; }
cmd_up(){ ensure_dirs; log "🚀 Start web"; ./dubash web:up; }
cmd_down(){ log "🛑 Rien à arrêter (fg)"; }
cmd_test(){ ensure_dirs; log "🧪 Rien pour l'instant"; }
cmd_status(){ ensure_dirs; echo "== ${AGORA_NAME:-Agora} (${AGORA_ENV:-dev}) =="; echo "Web: http://127.0.0.1:${WEB_PORT:-8080}"; echo "Log: $LOG_FILE"; }
cmd_logs(){ ensure_dirs; tail -n 200 -f "$LOG_FILE"; }
cmd_web_up(){ ensure_dirs; log "�� web"; ./services/web/run.sh; }
cmd_web_open(){ port="${WEB_PORT:-8080}"; if command -v xdg-open >/dev/null; then xdg-open "http://127.0.0.1:${port}" >/dev/null 2>&1||true; elif command -v open >/dev/null; then open "http://127.0.0.1:${port}" >/dev/null 2>&1||true; else echo "→ http://127.0.0.1:${port}"; fi; }

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
  *) echo "Commande inconnue: $1"; echo; help; exit 1 ;;
esac
EOF
chmod +x dubash

# --- DOC.md minimal ---
cat > DOC.md <<'EOF'
# Agora – Fil rouge (Bash)
- `./dubash build` : vérifs outils
- `./dubash up`    : lance web (public/)
- `./dubash status`: infos
Prochaines briques : `api:up`, auth, modèle fractal.
EOF

# --- log touch ---
: > "$LOG"

# --- Git remote via host alias + branche dev ---
git remote set-url origin "git@${REMOTE_HOST_ALIAS}:${REMOTE_SLUG}.git" || true

# create/switch dev
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  git checkout "$BRANCH"
else
  # Si existe côté remote, track; sinon crée
  if git ls-remote --heads origin "$BRANCH" | grep -q "$BRANCH"; then
    git checkout -t "origin/$BRANCH"
  else
    git checkout -b "$BRANCH"
  fi
fi

git add -A
if ! git diff --cached --quiet; then
  git commit -m "feat: squelette Bash initial (dubash, web stub, DOC)"
  git push -u origin "$BRANCH"
  echo "✅ Poussé sur origin/${BRANCH}"
else
  echo "ℹ️ Aucun changement à pousser."
fi

echo
echo "🎯 Done. Lance:  ./dubash build && ./dubash up"
