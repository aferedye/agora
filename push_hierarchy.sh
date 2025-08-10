#!/usr/bin/env bash
set -euo pipefail

mkdir -p services/api var/memory

# --- API avec parent_id + anti-cycles + endpoints enfants / filtre / tree ---
cat > services/api/app.py <<'PY'
#!/usr/bin/env python3
import os, json, time, re, tempfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

API_PORT = int(os.getenv("API_PORT", "5050"))
DB_PATH  = os.path.join("var", "memory", "circles.json")
TITLE_MAX = 80
DESC_MAX  = 2000

def _load_db():
    try:
        with open(DB_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
            # normalise parent_id: None or int
            for c in data:
                if c.get("parent_id") in ("", "null", None):
                    c["parent_id"] = None
                else:
                    try:
                        c["parent_id"] = int(c["parent_id"])
                    except Exception:
                        c["parent_id"] = None
            return data
    except FileNotFoundError:
        return []
    except Exception:
        return []

def _save_db(data):
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="circles_", suffix=".json", dir=os.path.dirname(DB_PATH))
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, DB_PATH)

def _next_id(items):
    return (max((c.get("id", 0) for c in items), default=0) + 1)

def _now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def _norm_title(t):
    return (t or "").strip().lower()

def _has_title(items, title, exclude_id=None):
    nt = _norm_title(title)
    for c in items:
        if exclude_id is not None and c.get("id") == exclude_id:
            continue
        if _norm_title(c.get("title")) == nt:
            return True
    return False

def _by_id(items):
    return {c.get("id"): c for c in items}

def _is_ancestor(items_by_id, ancestor_id, node_id):
    """Retourne True si ancestor_id est un ancêtre de node_id (pour éviter cycles)."""
    seen = set()
    cur = items_by_id.get(node_id)
    while cur and cur.get("parent_id") is not None:
        pid = cur.get("parent_id")
        if pid in seen:  # safety
            return True
        seen.add(pid)
        if pid == ancestor_id:
            return True
        cur = items_by_id.get(pid)
    return False

def _build_tree(items):
    """Retourne une forêt (liste) de noeuds {id,title,children:[...]}, racines d’abord."""
    by_id = _by_id(items)
    children = {c["id"]: [] for c in items}
    roots = []
    for c in items:
        pid = c.get("parent_id")
        node = {"id": c["id"], "title": c.get("title",""), "description": c.get("description",""),
                "parent_id": pid, "created_at": c.get("created_at"), "updated_at": c.get("updated_at"),
                "children": children[c["id"]]}
        if pid is None or pid not in by_id:
            roots.append(node)
        else:
            # le parent aura sa children list déjà construite via dict
            pass
    # remplir les children en seconde passe
    id_to_node = {}
    def link_nodes():
        # map id -> node (with children list already referenced)
        stack = roots[:]
        while stack:
            n = stack.pop()
            id_to_node[n["id"]] = n
            stack.extend(n["children"])
    link_nodes()
    for c in items:
        pid = c.get("parent_id")
        if pid is not None and pid in id_to_node:
            id_to_node[pid]["children"].append(id_to_node.get(c["id"], {
                "id": c["id"], "title": c.get("title",""), "description": c.get("description",""),
                "parent_id": pid, "created_at": c.get("created_at"), "updated_at": c.get("updated_at"),
                "children": []
            }))
    return roots

class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,PATCH,DELETE,OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _json(self, code:int, payload:dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _parse_body(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n) if n > 0 else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except Exception:
            return {}

    def log_message(self, fmt, *args):
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{ts}] {self.client_address[0]} {self.command} {self.path} | " + fmt%args)

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    # ---- GET ----
    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        q = parse_qs(parsed.query)

        if path in ("/", ""):
            return self._json(200, {
                "name": "Agora API",
                "endpoints": [
                    "/health", "/time", "/echo (POST)",
                    "/circles", "/circles?parent_id=<id>",
                    "/circles/<id>", "/circles/<id>/children",
                    "/circles/tree"
                ],
                "limits": {"title_max": TITLE_MAX, "description_max": DESC_MAX}
            })
        if path == "/health":
            return self._json(200, {"status": "ok"})
        if path == "/time":
            return self._json(200, {"epoch": time.time()})
        if path == "/circles":
            data = _load_db()
            if "parent_id" in q:
                try:
                    pid = int(q.get("parent_id", [None])[0]) if q.get("parent_id") else None
                except Exception:
                    return self._json(400, {"error": "invalid_parent_id"})
                items = [c for c in data if c.get("parent_id") == pid]
                return self._json(200, {"items": items, "count": len(items)})
            return self._json(200, {"items": data, "count": len(data)})

        m = re.match(r"^/circles/(\d+)$", path)
        if m:
            cid = int(m.group(1))
            data = _load_db()
            for c in data:
                if c.get("id") == cid:
                    return self._json(200, c)
            return self._json(404, {"error": "not_found"})

        m = re.match(r"^/circles/(\d+)/children$", path)
        if m:
            cid = int(m.group(1))
            data = _load_db()
            ids = {c["id"] for c in data}
            if cid not in ids:
                return self._json(404, {"error": "not_found"})
            children = [c for c in data if c.get("parent_id") == cid]
            return self._json(200, {"items": children, "count": len(children)})

        if path == "/circles/tree":
            data = _load_db()
            forest = _build_tree(data)
            return self._json(200, {"forest": forest})

        return self._json(404, {"error":"not_found"})

    # ---- POST ----
    def do_POST(self):
        if self.path == "/echo":
            return self._json(200, {"ok": True, "received": self._parse_body()})

        if self.path == "/circles":
            body  = self._parse_body()
            title = (body.get("title") or "").strip()
            desc  = (body.get("description") or "").strip()
            pid   = body.get("parent_id", None)
            if pid in ("", "null"): pid = None
            if pid is not None:
                try: pid = int(pid)
                except Exception: return self._json(400, {"error":"invalid_parent_id"})

            if not title:
                return self._json(400, {"error": "title_required"})
            if len(title) > TITLE_MAX:
                return self._json(400, {"error": "title_too_long", "max": TITLE_MAX})
            if len(desc) > DESC_MAX:
                return self._json(400, {"error": "description_too_long", "max": DESC_MAX})

            data = _load_db()
            if _has_title(data, title):
                return self._json(409, {"error": "title_exists"})

            # parent doit exister si fourni
            if pid is not None and pid not in {c["id"] for c in data}:
                return self._json(400, {"error":"parent_not_found"})

            cid = _next_id(data)
            now = _now_iso()
            item = {
                "id": cid, "title": title, "description": desc,
                "parent_id": pid, "created_at": now, "updated_at": now
            }
            data.append(item)
            _save_db(data)
            return self._json(201, item)

        return self._json(404, {"error":"not_found"})

    # ---- PATCH ----
    def do_PATCH(self):
        m = re.match(r"^/circles/(\d+)$", self.path)
        if not m:
            return self._json(404, {"error":"not_found"})
        cid = int(m.group(1))
        body = self._parse_body()
        data = _load_db()
        byid = _by_id(data)
        if cid not in byid:
            return self._json(404, {"error":"not_found"})
        c = byid[cid]

        # title / description validations
        if "title" in body:
            t = (body.get("title") or "").strip()
            if not t:
                return self._json(400, {"error": "title_required"})
            if len(t) > TITLE_MAX:
                return self._json(400, {"error": "title_too_long", "max": TITLE_MAX})
            if _has_title(data, t, exclude_id=cid):
                return self._json(409, {"error": "title_exists"})
            c["title"] = t

        if "description" in body:
            d = (body.get("description") or "").strip()
            if len(d) > DESC_MAX:
                return self._json(400, {"error": "description_too_long", "max": DESC_MAX})
            c["description"] = d

        # move parent
        if "parent_id" in body:
            pid = body.get("parent_id", None)
            if pid in ("", "null"): pid = None
            if pid is not None:
                try: pid = int(pid)
                except Exception: return self._json(400, {"error":"invalid_parent_id"})
                if pid not in byid:
                    return self._json(400, {"error":"parent_not_found"})
                # interdit: se mettre sous soi-même ou sous un descendant
                if pid == cid or _is_ancestor(byid, cid, pid):
                    return self._json(400, {"error":"cycle_forbidden"})
            c["parent_id"] = pid

        c["updated_at"] = _now_iso()
        # sauvegarde liste
        _save_db(list(byid.values()))
        return self._json(200, c)

    # ---- DELETE ----
    def do_DELETE(self):
        m = re.match(r"^/circles/(\d+)$", self.path)
        if not m:
            return self._json(404, {"error":"not_found"})
        cid = int(m.group(1))
        data = _load_db()
        ids = {c["id"] for c in data}
        if cid not in ids:
            return self._json(404, {"error":"not_found"})
        # on autorise la suppression d’un parent: ses enfants deviennent racines
        for c in data:
            if c.get("parent_id") == cid:
                c["parent_id"] = None
        new_data = [c for c in data if c.get("id") != cid]
        _save_db(new_data)
        return self._json(204, {})

def main():
    server = HTTPServer(("0.0.0.0", API_PORT), Handler)
    print(f"[api] listening on http://127.0.0.1:{API_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == "__main__":
    main()
PY
chmod +x services/api/app.py

# --- dubash: ajoute tree:circles (ASCII) ---
# logs sont déjà sur stderr, on n’y touche pas
if ! grep -q "tree:circles" dubash; then
  sed -i 's|^esac$|  tree:circles) cmd_tree_circles ;;\n  esac|' dubash
  cat >> dubash <<'FUN'

cmd_tree_circles(){
  ensure_dirs
  require curl
  [ -f ".env" ] && { set -a; . ".env"; set +a; }
  : "${API_PORT:=5050}"
  log "🌳 Tree cercles (ASCII)"
  python3 - "$API_PORT" <<'PYT'
import sys, json, urllib.request
port = int(sys.argv[1])

def fetch(url):
    with urllib.request.urlopen(url) as r:
        return json.loads(r.read().decode('utf-8'))

try:
    data = fetch(f"http://127.0.0.1:{port}/circles")
    items = data.get("items", [])
except Exception as e:
    # si API down, on lit le fichier local
    import os
    p = os.path.join("var","memory","circles.json")
    try:
        with open(p,"r",encoding="utf-8") as f:
            items = json.load(f)
    except Exception:
        items = []

by_id = {c["id"]: c for c in items}
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

# racines
walk(None)
PYT
}
FUN
fi

echo "✅ Hiérarchie prête. Redémarre l'API si nécessaire: ./dubash api:up"
echo "→ Afficher l'arbre: ./dubash tree:circles"
