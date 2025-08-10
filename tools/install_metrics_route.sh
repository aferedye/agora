#!/usr/bin/env bash
set -euo pipefail

echo "=== Installation de la route /metrics ==="

# Détection stack
if [ -f "services/api/package.json" ] || grep -q express package.json 2>/dev/null; then
    STACK="express"
elif ls services/api/*.py >/dev/null 2>&1; then
    STACK="fastapi"
else
    echo "❌ Impossible de détecter la stack (Express ou FastAPI)."
    echo "Place-toi à la racine de ton projet API et relance."
    exit 1
fi

echo "Stack détectée : $STACK"

if [ "$STACK" = "express" ]; then
    mkdir -p services/api/routes

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

  const branching = items
    .map(i => children(i.id).length)
    .filter(n => n > 0);
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

    echo "✅ Fichier services/api/routes/metrics.js créé."
    echo "➡ Dans ton app.js / index.js, après avoir défini app.locals.getCircles, ajoute :"
    echo "   app.use('/metrics', require('./routes/metrics'));"

elif [ "$STACK" = "fastapi" ]; then
    mkdir -p services/api

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

    echo "✅ Fichier services/api/metrics.py créé."
    echo "➡ Dans ton main.py, ajoute :"
    echo "   from services.api import metrics"
    echo "   app.include_router(metrics.router)"
fi

echo "=== Fini ==="
