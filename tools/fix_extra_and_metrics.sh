#!/usr/bin/env bash
set -euo pipefail

mkdir -p tools

# 0) backups
cp -f dubash "dubash.bak.$(date +%s)" || true
[ -f tools/extra_cmds.sh ] && cp -f tools/extra_cmds.sh "tools/extra_cmds.sh.bak.$(date +%s)" || true

# 1) (ré)écrire extra_cmds.sh complet
cat > tools/extra_cmds.sh <<'EXTRA'
# Sera "sourcé" par dubash après que ses fonctions soient définies.

# Fallbacks si lancé hors-ordre
ensure_dirs(){ mkdir -p var/logs var/memory var/tmp; : > "${LOG_FILE:-var/logs/dubash.log}"; }
require(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Requis: $1" >&2; exit 1; }; }

extra_dispatch() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    tree:circles)    cmd_tree_circles "$@" ;;
    circle:move)     cmd_circle_move "$@" ;;
    metrics:circles) cmd_metrics_circles "$@" ;;
    *) return 1 ;;
  esac
}

cmd_tree_circles(){
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  echo "[tree] rendering…" >&2
  python3 - "$API_PORT" <<'PYT'
import sys, json, urllib.request, os
port = int(sys.argv[1])

def fetch(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode('utf-8'))

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

children = {}
for c in items:
    children.setdefault(c.get("parent_id"), []).append(c)

def walk(pid=None, prefix=""):
    nodes = children.get(pid, [])
    for i, n in enumerate(sorted(nodes, key=lambda x: (x.get("title","") or "").lower())):
        is_last = (i == len(nodes)-1)
        branch = "└─ " if is_last else "├─ "
        print(prefix + branch + f"[{n['id']}] {n.get('title','')}")
        walk(n["id"], prefix + ("   " if is_last else "│  "))

walk(None)
PYT
}

cmd_circle_move(){
  # Usage: ./dubash circle:move <id> <new_parent_id|none>
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  local id="${1:-}"; local np="${2:-}"
  if [[ -z "$id" || -z "$np" ]]; then
    echo "Usage: ./dubash circle:move <id> <new_parent_id|none>" >&2
    exit 1
  fi
  local payload
  if [[ "$np" == "none" ]]; then
    payload='{"parent_id": null}'
  else
    payload="{\"parent_id\": ${np}}"
  fi
  curl -s -X PATCH "http://127.0.0.1:${API_PORT}/circles/${id}" \
       -H "Content-Type: application/json" \
       -d "$payload"
  echo
}

cmd_metrics_circles(){
  # Usage: ./dubash metrics:circles [--json]
  ensure_dirs
  require python3
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  local want_json="false"
  if [[ "${1:-}" == "--json" ]]; then want_json="true"; fi

  python3 - "$API_PORT" "$want_json" <<'PYT'
import sys, json, urllib.request, os
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
items = [{"id": c.get("id"), "parent_id": c.get("parent_id"), "title": c.get("title","")} for c in items]

children = {}
ids = set()
for c in items:
    ids.add(c["id"])
    children.setdefault(c["parent_id"], []).append(c)

roots = [c for c in items if c["parent_id"] is None or c["parent_id"] not in ids]
total = len(items)

max_depth = 0
leaf_count = 0
def walk(node, d):
    global max_depth, leaf_count
    max_depth = max(max_depth, d)
    kids = children.get(node["id"], [])
    if not kids:
        leaf_count += 1
    for k in kids:
        walk(k, d+1)

for r in roots:
    walk(r, 1)

branchers = [len(children.get(c["id"], [])) for c in items if len(children.get(c["id"], []))>0]
avg_branching = (sum(branchers)/len(branchers)) if branchers else 0.0

def height(node):
    kids = children.get(node["id"], [])
    if not kids: return 1
    return 1 + max(height(k) for k in kids)

heights = { str(r["id"]): height(r) for r in roots }

result = {
    "total_nodes": total,
    "roots_count": len(roots),
    "max_depth": max_depth,
    "leaf_count": leaf_count,
    "average_branching": round(avg_branching, 3),
    "height_per_root": heights
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
        for rid in sorted(result["height_per_root"].keys(), key=lambda x:int(x)):
            print(f"  - root {rid}: {result['height_per_root'][rid]}")
PYT
}
EXTRA

# 2) nettoyer les vieux hooks mal placés (entre nos marqueurs si présents)
tmp="$(mktemp)"
awk '
  BEGIN{skip=0}
  /# === extra cmds hook/ { skip=1 }
  skip==1 && /# === end hook ===/ { skip=0; next }
  skip==1 { next }
  { print }
' dubash > "$tmp" && mv "$tmp" dubash

# 3) insérer le hook unique juste avant le case "${1:-help}" in
tmp="$(mktemp)"
awk '
  BEGIN{done=0}
  /case *"\$\{1:-help\}" *in/ && !done {
    print "# === extra cmds hook (after functions) ==="
    print "if [ -f \"tools/extra_cmds.sh\" ]; then"
    print "  case \"${1:-}\" in"
    print "    tree:circles|circle:move|metrics:circles)"
    print "      . tools/extra_cmds.sh"
    print "      extra_dispatch \"$@\""
    print "      exit 0"
    print "    ;;"
    print "  esac"
    print "fi"
    print "# === end hook ==="
    done=1
  }
  { print }
' dubash > "$tmp" && mv "$tmp" dubash

chmod +x tools/extra_cmds.sh dubash
echo "✅ Extra cmds + hook remis à plat."
