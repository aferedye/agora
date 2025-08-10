#!/usr/bin/env bash
set -euo pipefail
[ -f ".env" ] && { set -a; . ".env"; set +a; }
: "${API_PORT:=5050}"
echo "[api] starting on :${API_PORT}"
exec python3 services/api/app.py
