#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && { set -a; . ".env"; set +a; }
: "${API_PORT:=5050}"
echo "[api] listening on http://127.0.0.1:${API_PORT}"
exec python3 services/api/app.py
