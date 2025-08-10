#!/usr/bin/env bash
set -euo pipefail

echo "== Agora · cleanup =="

# 1) .gitignore robuste
cat > .gitignore <<'GI'
# OS / editors
.DS_Store
Thumbs.db
.vscode/
.idea/

# Logs / runtime
var/logs/*
!var/logs/.gitkeep
var/tmp/*
!var/tmp/.gitkeep

# Env / secrets
.env
*.local
.env.*.local

# Node / front
node_modules/
dist/
build/

# Python
__pycache__/
*.pyc

# Misc
*.log
tools/patch.txt
tools/patches/*
GI

# 2) Assurer gitkeep sur runtime
mkdir -p var/logs var/tmp
: > var/logs/.gitkeep
: > var/tmp/.gitkeep

# 3) .env -> .env.example (non destructif)
if [ -f .env ] && [ ! -f .env.example ]; then
  cp .env .env.example
  echo "# ATTENTION: remplace les valeurs sensibles avant de commiter .env.example" >&2
fi

# 4) Déplacer bootstrap vers tools/
mkdir -p tools
if [ -f bootstrap_agora.sh ]; then
  git mv -f bootstrap_agora.sh tools/bootstrap.sh 2>/dev/null || mv -f bootstrap_agora.sh tools/bootstrap.sh
  chmod +x tools/bootstrap.sh
fi

# 5) s'assurer que dubash est exécutable
[ -f dubash ] && chmod +x dubash

# 6) Nettoyer l'index git des fichiers désormais ignorés
git rm -r --cached --quiet var/logs 2>/dev/null || true
git rm --cached --quiet .env 2>/dev/null || true

# 7) Ajouter et commiter
git add .gitignore var/logs/.gitkeep var/tmp/.gitkeep .env.example 2>/dev/null || true
git add -A
git commit -m "chore(repo): cleanup .env, logs, move bootstrap to tools/, add .gitignore & gitkeeps" || true

echo "✅ Cleanup terminé."
echo "→ Si .env a fui, pense à RÉGÉNÉRER tes secrets."
