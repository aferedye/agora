#!/usr/bin/env bash
set -euo pipefail

# === Bootstrap Agora (full Bash) ===
# - Arborescence minimale
# - .env de base
# - dubash (orchestrateur)
# - Service web minimal pour valider le flow

# 0) Racine projet
proj_dir="$(pwd)"
echo "[*] Bootstrap Agora dans: $proj_dir"

# 1) Arborescence
mkdir -p core services/web public tools var/logs var/memory var/tmp

# 2) .env de base
cat > .env <<'EOF'
# === Agora .env ===
AGORA_NAME="Agora"
AGORA_ENV="dev"

# Ports
WEB_PORT=8080

# Logs
LOG_FILE="var/logs/dubash.log"
EOF

# 3) Page web minimale
cat > public/index.html <<'EOF'
<!doctype html>
<html lang="fr">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Agora — it works</title>
  <style>
    html,body{font-family:system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,"Helvetica Neue",Arial,sans-serif;margin:0;padding:0;background:#0b0f14;color:#e7edf3}
    .wrap{max-width:780px;margin:8vh auto;padding:24px}
    .card{background:#121821;border:1px solid #1d2430;border-radius:14px;padding:20px;box-shadow:0 10px 30px rgba(0,0,0,.25)}
    h1{margin:0 0 8px 0;font-size:28px}
    code,pre{background:#0f141c;border:1px solid #1a2330;padding:.35em .6em;border-radius:8px}
    .muted{opacity:.75}
  </style>
</head>
<body>
  <div class="wrap">
    <div class="card">
      <h1>🚀 Agora est en place</h1>
      <p>Servi via <code>dubash web:up</code>. Tu peux éditer <code>public/index.html</code>.</p>
      <p class="muted">Fil rouge prêt. On ajoutera des services ensuite (API, IA, etc.).</p>
    </div>
  </div>
</body>
</html>
EOF

# 4) Service web minimal (Python http.server)
cat > services/web/run.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Charge .env
if [ -f ".env" ]; then
  set -a; . ".env"; set +a
fi

port="${WEB_PORT:-8080}"

# Démarrage du serveur statique sur ./public
echo "[web] Serving ./public on http://127.0.0.1:${port}"
cd public
# Python 3 requis
python3 -m http.server "${port}"
EOF
chmod +x services/web/run.sh

# 5) dubash — orchestrateur du projet
cat > dubash <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Charge .env si dispo
if [ -f ".env" ]; then
  set -a; . ".env"; set +a
else
  LOG_FILE="${LOG_FILE:-var/logs/dubash.log}"
fi

LOG_FILE="${LOG_FILE:-var/logs/dubash.log}"

log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*" | tee -a "$LOG_FILE"
}

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ Commande requise manquante: $1"; exit 1; }
}

ensure_dirs() {
  mkdir -p var/logs var/memory var/tmp
  : > "$LOG_FILE" # crée le fichier s'il n'existe pas (n’efface pas l’historique tee -a)
}

help() {
  cat <<HLP
Usage: ./dubash <commande>

Commandes de base:
  up                 Lance l’environnement minimal (web)
  down               Arrête les services lancés par dubash (si gérés en bg)
  build              Prépare/valide l’environnement (vérifs outils)
  test               Point d’entrée pour des tests (placeholder)
  status             Affiche les infos utiles (ports, services)
  logs               Montre les derniers logs
  help               Aide

Services:
  web:up             Lance le service web statique (public/)
  web:open           Ouvre le navigateur sur le port WEB_PORT

Astuce:
  - Configure .env pour tes ports & variables
  - Ajoute tes propres commandes ici (API, IA…)
HLP
}

cmd_build() {
  ensure_dirs
  log "🔧 Vérification outils requis"
  require python3
  log "✅ Environnement OK"
}

cmd_up() {
  ensure_dirs
  log "🚀 Démarrage minimal: web"
  ./dubash web:up
}

cmd_down() {
  # Ici, on pourrait gérer des PID si on lance en arrière-plan. Pour l’instant, rien.
  log "🛑 Rien à arrêter (mode fg)."
}

cmd_test() {
  ensure_dirs
  log "🧪 Rien pour l'instant (placeholder)."
}

cmd_status() {
  ensure_dirs
  local port="${WEB_PORT:-8080}"
  echo "== ${AGORA_NAME:-Agora} (${AGORA_ENV:-dev}) =="
  echo "Web: http://127.0.0.1:${port}"
  echo "Log file: $LOG_FILE"
}

cmd_logs() {
  ensure_dirs
  tail -n 200 -f "$LOG_FILE"
}

cmd_web_up() {
  ensure_dirs
  log "🌐 Lancement du service web"
  ./services/web/run.sh
}

cmd_web_open() {
  local port="${WEB_PORT:-8080}"
  # Essaie d’ouvrir selon OS
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "http://127.0.0.1:${port}" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open "http://127.0.0.1:${port}" >/dev/null 2>&1 || true
  else
    echo "Ouvre ton navigateur sur: http://127.0.0.1:${port}"
  fi
}

main() {
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
    *)
      echo "Commande inconnue: $1"
      echo
      help
      exit 1
      ;;
  esac
}
main "$@"
EOF
chmod +x dubash

echo "[✓] Bootstrap terminé."
echo "→ Étapes suivantes:"
echo "   1) chmod +x bootstrap_agora.sh"
echo "   2) ./bootstrap_agora.sh"
echo "   3) ./dubash build && ./dubash up"
