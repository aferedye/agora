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
