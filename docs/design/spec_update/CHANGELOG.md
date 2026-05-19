# Changelog — Spec ticket

## 2026-05-18 — Refonte « édition centrale »

### Layout
- **Éditeur centré** (colonne max 820 px) au lieu d'un chat plein-écran.
- **Chat repositionné à droite** (380 px PC / 320 px tablette) — plus un panneau auxiliaire qu'un mode dominant.
- Inversion explicite par rapport à la v1 : la rédaction manuelle redevient le geste principal, le chat est en accompagnement.

### Nouvelles capacités
- **Édition manuelle markdown** : textarea mono + barre de formatage (B, I, code, H, liste, citation, joindre, image).
- **Toggle Édition / Aperçu** : prévisualisation du rendu markdown sans quitter l'écran.
- **Drag-and-drop de captures** : zone dropzone sur toute la colonne éditeur, overlay accent dashed pendant le drag, grille d'attachments persistante avec slot dashed toujours visible.
- **Titre éditable inline** (input transparent 28 px).
- **Meta chips au-dessus du titre** : projet, type, assigné, priorité, tags — éditables au clic.

### Chat
- Composer avec textarea + paperclip + toggle « insérer la prochaine réponse dans le brouillon » + bouton Envoyer.
- **Suggestions d'insertion** : Autodev peut proposer un patch ciblé sur une section du markdown ; l'utilisateur l'applique via un bouton dashed sous la bulle.
- **Quick chips** sous le composer : reformule, cas limites, titre alternatif.

### Mobile
- Onglets renommés et réordonnés : **Édition** (par défaut) puis **Discussion**.
- Footer sticky avec `Annuler` + `Créer` dans l'onglet Édition.

### Hors périmètre (à venir)
- Coloration syntaxique markdown dans la textarea.
- Support `@mention` dans les messages.
- Tableaux markdown dans la preview.
- Édition collaborative multi-utilisateurs.
