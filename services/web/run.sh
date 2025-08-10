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
