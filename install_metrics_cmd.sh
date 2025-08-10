#!/usr/bin/env bash
set -euo pipefail

file="tools/extra_cmds.sh"
[ -f "$file" ] || { echo "❌ $file introuvable. Lance d'abord install_tree_cmds.sh."; exit 1; }

# 1) Assurer que le dispatcher connaît metrics:circles
if ! grep -q 'metrics:circles' "$file"; then
  tmp="$(mktemp)"
  awk '
    /extra_dispatch\(\)/,/\}/ {
      if ($0 ~ /extra_dispatch\(\)/) in_dispatch=1
      if (in_dispatch && $0 ~ /case.*cmd.*in/) seen_case=1
      if (in_dispatch && seen_case && $0 ~ /\*\)\s*return 1\s*;;/) {
        print "    metrics:circles) cmd_metrics_circles \"$@\" ;;"
      }
    }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
fi

# 2) Ajouter l’implémentation si absente
if ! grep -q 'cmd_metrics_circles' "$file"; then
cat >> "$file" <<'EXTRA'

cmd_metrics_circles(){
  # Usage: ./dubash metrics:circles [--json]
  ensure_dirs
  require python3
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "\${API_PORT:=5050}"
  local want_json="false"
  if [[ "\${1:-}" == "--json" ]]; then want_json="true"; fi

  python3 - "\$API_PORT" "\$want_json" <<'PYT'
import sys, json, urllib.request, os, math
port     = int(sys.argv[1])
want_json = (sys.argv[2].lower() == "true")

def fetch(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode("utf-8"))

# Chargement des cercles
items = []
try:
    data = fetch(f"http://127.0.0.1:{port}/circles")
    items = data.get("items", data if isinstance(data, list) else [])
except Exception:
    p = os.path.join("var","memory","circles.json")
    try:
        with open(p,"r",encoding="utf-8") as f:
            items = json.load(f)
    except Exception:
        items = []

# Normalisation minimale
norm = []
for c in items:
    norm.append({
        "id": c.get("id"),
        "parent_id": c.get("parent_id"),
        "title": c.get("title","")
    })
items = norm

# Index enfants et set d'IDs
children = {}
ids = set()
for c in items:
    ids.add(c["id"])
    children.setdefault(c["parent_id"], []).append(c)

roots = [c for c in items if c["parent_id"] is None or c["parent_id"] not in ids]
total = len(items)

# Profondeur & feuilles
max_depth = 0
leaf_count = 0
depths = {}

def walk(node, d):
    global max_depth, leaf_count
    depths[node["id"]] = d
    max_depth = max(max_depth, d)
    kids = children.get(node["id"], [])
    if not kids:
        leaf_count += 1
    for k in kids:
        walk(k, d+1)

for r in roots:
    walk(r, 1)

# Branching factor moyen (sur nœuds qui ont des enfants)
branchers = [len(children.get(c["id"], [])) for c in items if len(children.get(c["id"], []))>0]
avg_branching = (sum(branchers)/len(branchers)) if branchers else 0.0

# Profondeur par racine
def height(node):
    kids = children.get(node["id"], [])
    if not kids: return 1
    return 1 + max(height(k) for k in kids)

heights = {}
for r in roots:
    heights[r["id"]] = height(r)

result = {
    "total_nodes": total,
    "roots_count": len(roots),
    "max_depth": max_depth,
    "leaf_count": leaf_count,
    "average_branching": round(avg_branching, 3),
    "height_per_root": { str(k): v for k,v in heights.items() }
}

if want_json:
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    print("=== Metrics: circles ===")
    print(f"Total nodes      : {result['total_nodes']}")
    print(f"Roots            : {result['roots_count']}")
    print(f"Max depth        : {result['max_depth']}")
    print(f"Leaf count       : {result['leaf_count']}")
    print(f"Avg. branching   : {result['average_branching']}")
    if result["height_per_root"]:
        print("Height per root  :")
        for rid, h in sorted(result["height_per_root"].items(), key=lambda x:int(x[0])):
            print(f"  - root {rid}: {h}")
PYT
}
EXTRA
fi

echo "✅ metrics:circles installé."
