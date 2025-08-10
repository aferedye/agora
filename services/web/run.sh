#!/usr/bin/env bash
set -euo pipefail
if [ -f ".env" ]; then set -a; . ".env"; set +a; fi
port="${WEB_PORT:-8080}"
echo "[web] Serving ./public on http://127.0.0.1:${port}"
cd public
python3 -m http.server "${port}"
