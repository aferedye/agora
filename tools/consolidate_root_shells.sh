#!/usr/bin/env bash
set -euo pipefail

echo "== Agora · consolidation des scripts .sh =="

ROOT="$(pwd)"
TOOLS_DIR="tools"
mkdir -p "$TOOLS_DIR"

# 0) Entrypoints à laisser à la racine
KEEP_AT_ROOT=("dubash")

# 1) Lister les .sh à la racine
shopt -s nullglob
ROOT_SHELLS=(*.sh)
shopt -u nullglob

if [ ${#ROOT_SHELLS[@]} -eq 0 ]; then
  echo "Aucun .sh à la racine — rien à faire."
  exit 0
fi

# 2) Déplacer les .sh (sauf entrypoints) vers tools/
MOVED=()
for f in "${ROOT_SHELLS[@]}"; do
  skip=0
  for k in "${KEEP_AT_ROOT[@]}"; do
    [[ "$f" == "$k" ]] && skip=1 && break
  done
  [[ $skip -eq 1 ]] && continue

  src="$ROOT/$f"
  dst="$ROOT/$TOOLS_DIR/$f"

  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    git mv -f "$src" "$dst"
  else
    mv -f "$src" "$dst"
  fi
  chmod +x "$dst" || true
  MOVED+=("$f")
  echo "→ Déplacé: $f  ==>  $TOOLS_DIR/$f"
done

if [ ${#MOVED[@]} -eq 0 ]; then
  echo "Rien à déplacer (seuls les entrypoints sont en racine)."
  exit 0
fi

# 3) Mettre à jour les références ./script.sh -> ./tools/script.sh
#    On touche code & docs, mais on évite .git, node_modules, var, vendor, dist, build, .next
EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=node_modules
  --exclude-dir=var
  --exclude-dir=vendor
  --exclude-dir=dist
  --exclude-dir=build
  --exclude-dir=.next
  --exclude-dir="$TOOLS_DIR"
)
FILES_TO_SCAN=$(grep -RIl . "${EXCLUDES[@]}" || true)

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp -n "$file" "$file.bak_move_sh" 2>/dev/null || true
}

for s in "${MOVED[@]}"; do
  # motifs les plus courants: ./script.sh , bash script.sh , sh script.sh
  # on patchera en priorité les appels relatifs depuis la racine
  for file in $FILES_TO_SCAN; do
    # Patch uniquement si le fichier contient le nom
    if grep -q "$s" "$file"; then
      backup_file "$file"
      # ./script.sh -> ./tools/script.sh
      sed -i "s#\./$s#./$TOOLS_DIR/$s#g" "$file"
      # bash script.sh -> bash tools/script.sh
      sed -i "s#\(bash \)\?$s#\1$TOOLS_DIR/$s#g" "$file"
      # sh script.sh -> sh tools/script.sh
      sed -i "s#\(sh \)\?$s#\1$TOOLS_DIR/$s#g" "$file"
    fi
  done
done

# 4) S'assurer que tools/ est exécutable et propre
chmod +x "$TOOLS_DIR"/*.sh || true

# 5) .gitignore: ignorer backups temporaires *.bak_move_sh
if [ -f .gitignore ]; then
  if ! grep -q '\.bak_move_sh$' .gitignore; then
    echo "*.bak_move_sh" >> .gitignore
  fi
else
  echo "*.bak_move_sh" > .gitignore
fi

# 6) Commit
git add -A
git commit -m "chore(tools): move root .sh scripts to tools/ and update references" || true

echo "✅ Consolidation terminée."
echo "ℹ️  Entrypoints conservés à la racine: ${KEEP_AT_ROOT[*]}"
echo "👉 Vérifie vite fait README/CI si tu déclenches des scripts par chemin absolu."
