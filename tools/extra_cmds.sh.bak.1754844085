# Sera "sourcé" par dubash après que ses fonctions soient définies.

# Fallbacks si on est lancé hors-ordre (sécurité)
ensure_dirs(){ mkdir -p var/logs var/memory var/tmp; : > "${LOG_FILE:-var/logs/dubash.log}"; }
require(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ Requis: $1" >&2; exit 1; }; }

extra_dispatch() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    tree:circles)  cmd_tree_circles "$@" ;;
    circle:move)   cmd_circle_move "$@" ;;
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
    items = data.get("items", [])
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
    for i, n in enumerate(sorted(nodes, key=lambda x: x.get("title","").lower())):
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
