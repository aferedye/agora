#!/usr/bin/env bash
set -euo pipefail

echo "=== Agora :: setup metrics (API + dubash) ==="

# --- helpers ---
ensure_file_contains() {
  local file="$1" needle="$2"
  grep -qF "$needle" "$file" 2>/dev/null
}

insert_after_line_match() {
  # insert $3 after first line matching regex $2 in file $1
  local file="$1" regex="$2" insert="$3"
  awk -v re="$regex" -v ins="$insert" '
    BEGIN{done=0}
    {print}
    done==0 && $0 ~ re { print ins; done=1 }
  ' "$file" > "$file.__tmp__" && mv "$file.__tmp__" "$file"
}

# --- detect stack ---
STACK=""
if [ -f "services/api/package.json" ] || grep -q express package.json 2>/dev/null; then
  STACK="express"
elif ls services/api/*.py >/dev/null 2>&1; then
  STACK="fastapi"
else
  echo "❌ Impossible de détecter la stack API (Express ou FastAPI)."
  echo "   Place-toi à la racine du projet (où se trouve services/api/)."
  exit 1
fi
echo "→ Stack détectée : $STACK"

mkdir -p services/api

# --- API: create /metrics route ---
if [ "$STACK" = "express" ]; then
  mkdir -p services/api/routes

  # route file
  cat > services/api/routes/metrics.js <<'JS'
// services/api/routes/metrics.js
const express = require("express");
const router = express.Router();

function computeMetrics(items) {
  const byParent = new Map();
  const ids = new Set(items.map(i => i.id));
  for (const c of items) {
    const k = c.parent_id ?? "__root__";
    if (!byParent.has(k)) byParent.set(k, []);
    byParent.get(k).push(c);
  }
  const roots = items.filter(c => c.parent_id == null || !ids.has(c.parent_id));

  let maxDepth = 0, leafCount = 0;
  const children = (id) => byParent.get(id) || [];
  const height = (n) => {
    const kids = children(n.id);
    if (kids.length === 0) return 1;
    return 1 + Math.max(...kids.map(height));
  };
  for (const r of roots) {
    const stack = [[r,1]];
    while (stack.length) {
      const [node, d] = stack.pop();
      maxDepth = Math.max(maxDepth, d);
      const kids = children(node.id);
      if (kids.length === 0) leafCount++;
      for (const k of kids) stack.push([k, d+1]);
    }
  }

  const branching = items.map(i => children(i.id).length).filter(n => n > 0);
  const avgBranch = branching.length
    ? Number((branching.reduce((a,b)=>a+b,0) / branching.length).toFixed(3))
    : 0;

  const heightPerRoot = {};
  for (const r of roots) heightPerRoot[String(r.id)] = height(r);

  return {
    total_nodes: items.length,
    roots_count: roots.length,
    max_depth: maxDepth,
    leaf_count: leafCount,
    average_branching: avgBranch,
    height_per_root: heightPerRoot
  };
}

router.get("/", async (req, res) => {
  try {
    const getCircles = req.app.locals?.getCircles;
    if (typeof getCircles !== "function") {
      return res.status(500).json({ error: "No circles source bound (app.locals.getCircles missing)" });
    }
    let items = await getCircles();
    items = items.map(c => ({ id: c.id, parent_id: c.parent_id ?? null, title: c.title ?? "" }));
    return res.json(computeMetrics(items));
  } catch (e) {
    console.error(e);
    return res.status(500).json({ error: "metrics_failed" });
  }
});

module.exports = router;
JS

  # try wire app.use in typical entry files
  for ENTRY in services/api/index.js services/api/app.js; do
    if [ -f "$ENTRY" ]; then
      if ! grep -q "require('./routes/metrics')" "$ENTRY"; then
        insert_after_line_match "$ENTRY" 'express\(' "app.use('/metrics', require('./routes/metrics'));"
        echo "→ Auto-wiring ajouté dans $ENTRY (app.use('/metrics', ...))."
      fi
    fi
  done

  echo "✅ /metrics (Express) prêt. Assure-toi que app.locals.getCircles est défini."

else
  # FASTAPI
  cat > services/api/metrics.py <<'PY'
# services/api/metrics.py
from fastapi import APIRouter, HTTPException
from typing import List, Dict, Any, Optional

router = APIRouter()

# À remplacer par ta vraie source de cercles
def get_circles() -> List[Dict[str, Any]]:
    # return db.select_all_circles()
    from main import app
    return getattr(app.state, "CIRCLES", [])

def compute_metrics(items: List[Dict[str, Any]]) -> Dict[str, Any]:
    ids = {c["id"] for c in items}
    by_parent: Dict[Optional[int], List[Dict[str, Any]]] = {}
    for c in items:
        by_parent.setdefault(c.get("parent_id"), []).append(c)
    roots = [c for c in items if c.get("parent_id") is None or c.get("parent_id") not in ids]

    def children(cid: Optional[int]) -> List[Dict[str, Any]]:
        return by_parent.get(cid, [])

    max_depth = 0
    leaf_count = 0

    def walk(n: Dict[str, Any], d: int):
        nonlocal max_depth, leaf_count
        max_depth = max(max_depth, d)
        kids = children(n["id"])
        if not kids:
            leaf_count += 1
        for k in kids:
            walk(k, d + 1)

    for r in roots:
        walk(r, 1)

    branching = [len(children(c["id"])) for c in items if len(children(c["id"])) > 0]
    avg_branch = round(sum(branching)/len(branching), 3) if branching else 0.0

    def height(n: Dict[str, Any]) -> int:
        kids = children(n["id"])
        if not kids:
            return 1
        return 1 + max(height(k) for k in kids)

    heights = {str(r["id"]): height(r) for r in roots}

    return {
        "total_nodes": len(items),
        "roots_count": len(roots),
        "max_depth": max_depth,
        "leaf_count": leaf_count,
        "average_branching": avg_branch,
        "height_per_root": heights
    }

@router.get("/metrics")
def metrics():
    try:
        items = get_circles()
        items = [{"id": c.get("id"), "parent_id": c.get("parent_id"), "title": c.get("title","")} for c in items]
        return compute_metrics(items)
    except Exception:
        raise HTTPException(status_code=500, detail="metrics_failed")
PY

  # try include_router in main.py
  if [ -f services/api/main.py ]; then
    if ! grep -q "from services.api import metrics" services/api/main.py; then
      insert_after_line_match services/api/main.py 'FastAPI\(' $'from services.api import metrics\napp.include_router(metrics.router)'
      echo "→ Auto-wiring ajouté dans services/api/main.py (include_router)."
    fi
  fi

  echo "✅ /metrics (FastAPI) prêt. Branche ta vraie source de cercles si besoin."
fi

# --- dubash: ensure hook + extra metrics command (with --remote) ---
mkdir -p tools
cp -f dubash "dubash.bak.$(date +%s)" || true
[ -f tools/extra_cmds.sh ] && cp -f tools/extra_cmds.sh "tools/extra_cmds.sh.bak.$(date +%s)" || true

# (re)write tools/extra_cmds.sh if missing
if [ ! -f tools/extra_cmds.sh ]; then
  cat > tools/extra_cmds.sh <<'EXTRA'
# Sera "sourcé" par dubash après que ses fonctions soient définies.
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

cmd_tree_circles(){ :; }
cmd_circle_move(){ :; }
cmd_metrics_circles(){ :; }
EXTRA
fi

# ensure dispatcher cases include metrics
if ! grep -q 'metrics:circles' tools/extra_cmds.sh; then
  sed -i 's/circle:move) \{0,1\}cmd_circle_move "\$@" ;;/circle:move)     cmd_circle_move "$@" ;;\n    metrics:circles) cmd_metrics_circles "$@" ;;/' tools/extra_cmds.sh || true
fi

# install/replace metrics impl (remote-enabled)
awk -v RS= -v ORS= '
  {
    gsub(/cmd_metrics_circles\(\)[\s\S]*?\n}\n/,"")
    print
  }
' tools/extra_cmds.sh > tools/extra_cmds.sh.__tmp__ && mv tools/extra_cmds.sh.__tmp__ tools/extra_cmds.sh

cat >> tools/extra_cmds.sh <<'EXTRA'

cmd_metrics_circles(){
  # Usage:
  #   ./dubash metrics:circles [--json]
  #   ./dubash metrics:circles --remote http://127.0.0.1:5050 [--json]
  ensure_dirs
  require python3
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"

  local remote=""
  local want_json="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote) remote="$2"; shift 2 ;;
      --json)   want_json="true"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "$remote" ]]; then
    python3 - "$remote" "$want_json" <<'PYT'
import sys, json, urllib.request
base = sys.argv[1].rstrip("/")
want_json = (sys.argv[2].lower() == "true")
with urllib.request.urlopen(f"{base}/metrics") as r:
    data = json.loads(r.read().decode("utf-8"))
if want_json:
    print(json.dumps(data, ensure_ascii=False, indent=2))
else:
    print("=== Metrics: circles (remote) ===")
    for k,label in [
        ("total_nodes","Total nodes"),
        ("roots_count","Roots"),
        ("max_depth","Max depth"),
        ("leaf_count","Leaf count"),
        ("average_branching","Avg. branching"),
    ]:
        print(f"{label:<16}: {data.get(k)}")
    hpr = data.get("height_per_root",{}) or {}
    if hpr:
        print("Height per root  :")
        for rid in sorted(hpr.keys(), key=lambda x:int(x)):
            print(f"  - root {rid}: {hpr[rid]}")
PYT
    return
  fi

  # LOCAL fallback: fetch /circles then compute
  python3 - "$API_PORT" "$want_json" <<'PYT'
import sys, json, urllib.request, os
port     = int(sys.argv[1])
want_json = (sys.argv[2].lower() == "true")

def fetch(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode("utf-8"))

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

# normalize
items = [{"id": c.get("id"), "parent_id": c.get("parent_id"), "title": c.get("title","")} for c in items]

by_parent = {}
ids = set([c["id"] for c in items])
for c in items:
    by_parent.setdefault(c.get("parent_id"), []).append(c)
roots = [c for c in items if c.get("parent_id") is None or c.get("parent_id") not in ids]

max_depth = 0
leaf_count = 0
def walk(n, d):
    global max_depth, leaf_count
    max_depth = max(max_depth, d)
    kids = by_parent.get(n["id"], [])
    if not kids: 
        leaf_count += 1
    for k in kids:
        walk(k, d+1)

for r in roots:
    walk(r, 1)

branching = [len(by_parent.get(c["id"], [])) for c in items if len(by_parent.get(c["id"], []))>0]
avg_branch = round(sum(branching)/len(branching),3) if branching else 0.0

def height(n):
    kids = by_parent.get(n["id"], [])
    if not kids: return 1
    return 1 + max(height(k) for k in kids)

heights = { str(r["id"]): height(r) for r in roots }

result = {
    "total_nodes": len(items),
    "roots_count": len(roots),
    "max_depth": max_depth,
    "leaf_count": leaf_count,
    "average_branching": avg_branch,
    "height_per_root": heights
}

if want_json:
    print(json.dumps(result, ensure_ascii=False, indent=2))
else:
    print("=== Metrics: circles ===")
    for k,label in [
        ("total_nodes","Total nodes"),
        ("roots_count","Roots"),
        ("max_depth","Max depth"),
        ("leaf_count","Leaf count"),
        ("average_branching","Avg. branching"),
    ]:
        print(f"{label:<16}: {result.get(k)}")
    if heights:
        print("Height per root  :")
        for rid in sorted(heights.keys(), key=lambda x:int(x)):
            print(f"  - root {rid}: {heights[rid]}")
PYT
}
EXTRA

# tree:circles & circle:move minimal presence (skip if already implemented)
if ! grep -q 'cmd_tree_circles' tools/extra_cmds.sh; then
  cat >> tools/extra_cmds.sh <<'EXTRA'
cmd_tree_circles(){
  ensure_dirs; require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  python3 - "$API_PORT" <<'PYT'
import sys, json, urllib.request
port = int(sys.argv[1])
with urllib.request.urlopen(f"http://127.0.0.1:{port}/circles") as r:
    data = json.loads(r.read().decode("utf-8"))
items = data.get("items", data if isinstance(data, list) else [])
children={}
for c in items: children.setdefault(c.get("parent_id"), []).append(c)
def walk(pid=None,prefix=""):
  nodes=children.get(pid,[])
  for i,n in enumerate(sorted(nodes,key=lambda x:(x.get("title","") or "").lower())):
    last=(i==len(nodes)-1); br="└─ " if last else "├─ "
    print(prefix+br+f"[{n['id']}] {n.get('title','')}")
    walk(n["id"], prefix+("   " if last else "│  "))
walk(None)
PYT
}
EXTRA
fi

if ! grep -q 'cmd_circle_move' tools/extra_cmds.sh; then
  cat >> tools/extra_cmds.sh <<'EXTRA'
cmd_circle_move(){
  ensure_dirs; require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  local id="${1:-}"; local np="${2:-}"
  if [[ -z "$id" || -z "$np" ]]; then
    echo "Usage: ./dubash circle:move <id> <new_parent_id|none>" >&2; exit 1
  fi
  local payload
  if [[ "$np" == "none" ]]; then payload='{"parent_id": null}'; else payload="{\"parent_id\": ${np}}"; fi
  curl -s -X PATCH "http://127.0.0.1:${API_PORT}/circles/${id}" -H "Content-Type: application/json" -d "$payload"
  echo
}
EXTRA
fi

# patch dubash hook (remove old, insert new before case "${1:-help}" in)
awk '
  BEGIN{skip=0}
  /# === extra cmds hook/ { skip=1 }
  skip==1 && /# === end hook ===/ { skip=0; next }
  skip==1 { next }
  { print }
' dubash > dubash.__tmp__ && mv dubash.__tmp__ dubash

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
' dubash > dubash.__tmp__ && mv dubash.__tmp__ dubash

chmod +x tools/extra_cmds.sh dubash
echo "✅ dubash mis à jour (hook + metrics:circles)."

echo "=== Done. Tests suggérés ==="
echo "1) Lancer l API (./dubash api:up) puis:"
echo "   curl -s http://127.0.0.1:5050/metrics | jq . || true"
echo "2) Client dubash local:"
echo "   ./dubash metrics:circles"
echo "3) Client dubash remote:"
echo "   ./dubash metrics:circles --remote http://127.0.0.1:5050 --json"
