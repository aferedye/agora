# Agora – Fil rouge (Bash)
- `./dubash build` : vérifs outils
- `./dubash up`    : lance web (public/)
- `./dubash status`: infos
Prochaines briques : `api:up`, auth, modèle fractal.

### Validation
- `title` requis, max 80 caractères, **unique** (insensible à la casse)
- `description` max 2000 caractères
- Erreurs possibles : `title_required` (400), `title_too_long` (400), `description_too_long` (400), `title_exists` (409)

### Commandes utilitaires
- `./dubash seed:circles` → crée 2–3 cercles de démo (via API)
- `./dubash dump:circles` → affiche la liste JSON
- `./dubash clear:circles` → supprime tous les cercles (API si up, sinon wipe fichier)
