# Sera "sourcé" par dubash après que ses fonctions soient définies.# Fallbacks si on est lancé hors-ordre (sécurité)
ensure_dirs(){ mkdir -p var/logs var/memory var/tmp; : > "${LOG_FILE:-var/logs/dubash.log}"; }
require(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Requis: $1" >&2; exit 1; }; }extra_dispatch() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    tree:circles)  cmd_tree_circles "$@" ;;
    circle:move)   cmd_circle_move "$@" ;;
    *) return 1 ;;
  esac
}cmd_tree_circles(){
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  echo "[tree] rendering…" >&2
  python3 - "$API_PORT" <<'PYT'
import sys, json, urllib.request, os
port = int(sys.argv[1])def fetch(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode('utf-8'))try:
    data = fetch(f"http://127.0.0.1:{port}/circles")
    items = data.get("items", [])
except Exception:
    p = os.path.join("var","memory","circles.json")
    try:
        with open(p,"r",encoding="utf-8") as f:
            items = json.load(f)
    except Exception:
        items = []children = {}
for c in items:
    children.setdefault(c.get("parent_id"), []).append(c)def walk(pid=None, prefix=""):
    nodes = children.get(pid, [])
    for i, n in enumerate(sorted(nodes, key=lambda x: x.get("title","").lower())):
        is_last = (i == len(nodes)-1)
        branch = "└─ " if is_last else "├─ "
        print(prefix + branch + f"[{n['id']}] {n.get('title','')}")
        walk(n["id"], prefix + ("   " if is_last else "│  "))walk(None)
PYT
}cmd_circle_move(){
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
