#!/usr/bin/env bash
set -euo pipefail

echo "== Agora · test basique =="

fail=0

# 1) Vérifier que dubash répond
echo "-- Test dubash help"
if ./dubash help >/dev/null 2>&1; then
  echo "✅ dubash OK"
else
  echo "❌ dubash KO"
  fail=1
fi

# 2) Vérifier commandes dubash principales
for cmd in tree:circles metrics:circles; do
  echo "-- Test dubash $cmd"
  if ./dubash "$cmd" >/dev/null 2>&1; then
    echo "✅ $cmd OK"
  else
    echo "⚠️  $cmd KO (peut être normal si API down)"
  fi
done

# 3) Lister les scripts tools/ et tester exécution basique
echo "-- Test scripts tools/"
for f in tools/*.sh; do
  [ -x "$f" ] || continue
  name="$(basename "$f")"
  echo "   → $name"
  # On tente l'option --help ou -h si dispo
  if grep -qE '(-h|--help)' "$f"; then
    if "$f" --help >/dev/null 2>&1; then
      echo "     ✅ help OK"
    else
      echo "     ⚠️ help KO"
    fi
  else
    # Sinon simple exécution à blanc si safe
    if "$f" >/dev/null 2>&1; then
      echo "     ✅ exec OK"
    else
      echo "     ⚠️ exec KO"
    fi
  fi
done

# 4) Test API /metrics (si API up)
echo "-- Test API /metrics"
if curl -s "http://127.0.0.1:5050/metrics" | grep -q '{'; then
  echo "✅ API /metrics OK"
else
  echo "⚠️  API /metrics non accessible"
fi

echo
if [ $fail -eq 0 ]; then
  echo "== ✅ Tests basiques terminés sans erreur bloquante =="
else
  echo "== ❌ Des tests bloquants ont échoué =="
  exit 1
fi
