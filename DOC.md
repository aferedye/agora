# Agora – Fil rouge (Bash)
- `./dubash build` : vérifs outils
- `./dubash up`    : lance web (public/)
- `./dubash status`: infos
Prochaines briques : `api:up`, auth, modèle fractal.

### Cercles
- `GET /circles` → `{"items":[...],"count":n}`
- `POST /circles` → crée `{ "title": "...", "description": "..." }`
- `GET /circles/<id>`
- `PATCH /circles/<id>` → MAJ partielle `title|description`
- `DELETE /circles/<id>`
