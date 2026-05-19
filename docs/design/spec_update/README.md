# Handoff — Refonte écran « Spécification d'un nouveau ticket »

**Date :** 18 mai 2026
**Artboard concerné :** `05 · Spec ticket — PC` + `05 · Spec ticket — Mobile`
**Fichier source HTML :** `Autodev Design.html` → `screen-chat-spec.jsx`

---

## À propos de ce dossier

Les fichiers de `reference/` sont des **maquettes HTML/JSX** : prototypes
illustrant l'intention visuelle et comportementale, **pas du code de
production à copier tel quel**. La tâche pour Claude Code est de
**reproduire ces écrans dans le codebase Autotech existant** (Rails + ERB +
quel que soit le framework JS en place) en réutilisant ses composants,
ses helpers d'attachement et son client markdown.

**Fidélité :** High-fidelity. Les couleurs, espacements et typographies
sont définitifs (voir `reference/tokens.css`). Les seuls degrés de liberté
sont la stack technique et l'éventuelle adaptation aux primitives déjà
présentes dans Autotech.

---

## Ce qui change par rapport à la version précédente

| Avant | Après |
|---|---|
| Chat plein écran **à gauche**, brouillon read-only à droite (panneau 460 px). | **Éditeur central et large** (colonne max 820 px), **chat à droite** (380 px desktop / 320 px tablette). |
| Brouillon généré uniquement par la conversation. | **Édition manuelle markdown** en parallèle de la conversation. Les deux modes coexistent. |
| Aucun support d'images. | **Drag-and-drop** de captures sur toute la zone éditeur, vignettes en bas du ticket. |
| Pas de prévisualisation. | Toggle **Édition / Aperçu** dans la barre d'outils. |
| Métadonnées dans une zone de droite figée. | **Meta chips** (projet, type, assigné, priorité, tags) au-dessus du titre, éditables au clic. |
| Mobile : onglets « Discussion / Brouillon ». | Mobile : onglets **« Édition / Discussion »** (édition en premier, c'est le nouveau cœur). |

---

## Layout

```
┌─────────────┬──────────────────────────────────────────┬────────────────┐
│  Sidebar    │  Topbar : Conversations › Nouveau ticket │                │
│  240 px     │  Titre + sous-titre + actions à droite   │                │
│  (desktop)  ├──────────────────────────────────────────┤  Chat Autodev  │
│             │  Toolbar éditeur                         │  380 px (PC)   │
│             │  [Édition|Aperçu]  B I </> H — > 📎 🖼️   │  320 px (tab.) │
│             ├──────────────────────────────────────────┤                │
│             │                                          │  Header avatar │
│             │   Meta chips (projet / type / …)         │                │
│             │   Titre éditable (28 px / 600)           │  Messages      │
│             │                                          │  (scrollable)  │
│             │   ┌──────────────────────────────────┐   │                │
│             │   │ Textarea markdown (mono 13.5)    │   │                │
│             │   │ OU rendu prévisualisé            │   │                │
│             │   └──────────────────────────────────┘   │                │
│             │                                          │  ─── Composer  │
│             │   CAPTURES JOINTES · n                   │  textarea +    │
│             │   ┌────┐ ┌────┐ ┌────────┐               │  pièce jointe  │
│             │   │img │ │img │ │+ drop  │               │  + envoyer     │
│             │   └────┘ └────┘ └────────┘               │                │
│             │                                          │  Quick chips : │
│             │   ℹ Markdown · drag&drop · ⌘+↵           │  reformule…    │
└─────────────┴──────────────────────────────────────────┴────────────────┘
```

**Largeurs :**
- Sidebar : 240 px (desktop uniquement, < 1024 px → masquée + bouton hamburger)
- Colonne éditeur : `flex: 1`, contenu contraint à `max-width: 820 px` centré
- Colonne chat : `0 0 380 px` (desktop ≥ 1280) / `0 0 320 px` (960–1279) / `flex: 1` (mobile, onglet)

**Breakpoints :**
- `desktop` : ≥ 1280 px → sidebar + éditeur + chat côte à côte
- `tablet` : 960–1279 → sidebar masquée (hamburger), éditeur + chat
- `mobile` : < 960 → tabs **Édition / Discussion**, bottom nav

---

## Spécifications composant par composant

### 1. Topbar
- Hauteur : auto, padding `20px 32px` (desktop) / `14px 16px` (mobile)
- Breadcrumb : `Conversations › Nouveau ticket` (11 px / `--text-muted`)
- Titre H1 : `Nouveau ticket` (24 px / 600 / `--text-strong`)
- Sous-titre : *« Rédigez à la main ou laissez Autodev poser les bonnes questions — les deux modes sont en parallèle. »*
- Actions droite : `Brouillon` (secondary) + `Créer le ticket` (primary, icône check)

### 2. Toolbar éditeur (sticky en haut de la colonne)
- Background : `--paper`, border-bottom : `1px solid --border`
- Padding : `12px 32px`
- Gauche : **SegmentedTabs** Édition / Aperçu (pill, 12 px, accent quand actif)
- Séparateur 1×22 px
- **FormatToolbar** (en mode Édition uniquement) :
  - B (gras) — insère `**texte**`
  - I (italique) — insère `_texte_`
  - `</>` (code inline) — insère `` `code` ``
  - séparateur
  - H (titre) — insère `## Titre`
  - liste — insère `- élément`
  - citation — insère `> citation`
  - séparateur
  - 📎 paperclip (joindre fichier)
  - 🖼️ image (insérer image)
  - Chaque bouton : 28×28, radius 6, `--text-muted`, hover `--paper-2`
- Droite : indicateur **« Enregistré »** (dot vert + label 11 px / `--ok-fg`)

### 3. Meta chips
- Row flex-wrap, gap 8 px, **au-dessus du titre**
- Chaque chip :
  - padding `5px 10px`, radius `--r-pill`, bg `--paper`, border `--border`, shadow `--shadow-xs`
  - icône 12 px + label 12 px + chevron-down 11 px
  - cliquable → ouvre un menu pour modifier
- Chips obligatoires : **Projet** (carré couleur projet), **Type** (icône alert pour bug), **Assigné**, **Priorité**
- Puis séparateur vertical + tags `#frontend #panier #ux` (pill `--paper-2`, 11 px) + bouton `+ étiquette` (pill dashed)

### 4. Titre du ticket
- Input transparent, sans border, sans outline
- Police 28 px / 600 / -0.4 letter-spacing / `--text-strong`
- Placeholder : `Titre du ticket`
- En mode Aperçu : rendu en `<h1>` avec mêmes styles

### 5. Markdown editor
- Container `--paper`, border `--border`, radius `--r-lg`, padding `18px 22px`, shadow `--shadow-xs`
- Textarea : `font-family: --font-mono`, 13.5 px, line-height 1.65, min-height 320 px, resize vertical
- Pas de coloration syntaxique (intentionnellement sobre)
- Raccourcis :
  - `Cmd+B` → entoure la sélection de `**`
  - `Cmd+I` → entoure de `_`
  - `Cmd+K` → insère un lien
  - `Cmd+Enter` → soumet (= clic sur « Créer le ticket »)
- Persistance brouillon : autosave toutes les 2 s en localStorage (clé `autodev:draft:new`)

### 6. Markdown preview
- Container identique à l'éditeur
- Rendu : H2 (20 px / 600), H3 (15 px / 600), ul/ol (padding-left 22), blockquote (border-left 3 px `--border-strong`, padding 6×12), code inline (`--paper-2` + border, 12.5 px mono)
- Pas de support tableaux pour l'instant (à reporter)
- Inline : `**bold**`, `_italic_`, `` `code` ``

### 7. Drag-and-drop captures

**Comportement :**
- La **zone éditeur entière** (colonne centrale) est dropzone
- Sur `dragenter` / `dragover` : overlay plein-cadre (`position: absolute, inset: 0`) avec :
  - Background : `color-mix(in oklab, --accent-bg 92%, transparent)`
  - Border : `2px dashed --accent-solid`
  - Card centrée : icône image 26 px + « Déposez vos captures ici » (14 px / 600) + « PNG, JPG, GIF — jusqu'à 10 Mo » (12 px muted)
- Sur `drop` : upload, ajoute des AttachmentCard
- Sur `dragleave` : retire l'overlay

**AttachmentCard :**
- Container `--paper`, border, radius `--r-md`, shadow `--shadow-xs`
- Aperçu : 112 px de haut, background teinté + diagonal stripes
- Bouton ✕ en haut à droite (22×22, rond, `--paper`, border)
- Pied : nom (12 px / 500, ellipsis) + dimensions × taille (10.5 px muted) + bouton copier markdown

**DropTarget (slot vide) :**
- Min-height 156 px (88 px mobile), border 1.5 dashed `--border-strong`, radius `--r-md`, bg `--paper-2`
- Contenu : icône image + « Glisser une capture » + lien « parcourir »
- Toujours visible à la fin de la grille des attachments

**Grille :** `grid-template-columns: repeat(auto-fill, minmax(220px, 1fr))`, gap 10 px (1 col en mobile)

### 8. Footer hint
Sous les captures, bandeau d'aide :
- bg `--paper-2`, border `--border`, radius `--r-md`, padding `10px 14px`
- icône info + texte 12 px muted
- *« Markdown supporté · glissez une capture n'importe où dans cette zone pour la joindre · ⌘+↵ pour créer »*
- Les `⌘` et `↵` sont stylés en `<kbd>` (mono 10 px, border, radius 4)

### 9. Chat pane (droite)

**Header (sticky) :**
- AutodevAvatar 28 px + nom « Autodev » (13 px / 600 / accent dot vert) + sous-titre « Vous aide à cadrer le ticket » (11 px muted)
- Bouton more à droite (28×28)
- border-bottom `--border`

**Messages (scrollable) :**
- Padding `16px 18px`, gap 14 px entre messages
- Séparateur de jour centré, 10.5 px `--text-subtle`
- Bulle Autodev :
  - avatar 24 px à gauche, max 86 % de largeur
  - bg `--accent-bg`, border `--accent-bg-strong`, radius 12 (3 en bas-gauche)
  - padding `9px 12px`, 13 px / 1.55
- Bulle utilisateur : symétrique, bg `--paper-2`, border `--border`
- Sous chaque bulle : timestamp + auteur (10 px `--text-subtle`)
- **Suggestion d'insertion** (quand Autodev propose un ajout précis) :
  - sous la bulle Autodev, bouton dashed avec icône sparkles + « Insérer dans " *section* " » + flèche →
  - clic = patch le markdown du brouillon central

**Composer :**
- Container `--paper`, border, radius `--r-md`, shadow `--shadow-xs`, padding 10
- Textarea 2 rows, transparent
- Sous-row : paperclip, « insérer la prochaine réponse dans le brouillon » (toggle), spacer, bouton primary `Envoyer` (size sm, icône send)
- Sous le composer : chips rapides
  - *« Reformule plus court », « Ajoute des cas limites », « Propose un titre alternatif »*
  - pill `--paper-2`, border, 11 px

### 10. Mobile

- Sidebar → overlay (bouton hamburger dans la topbar)
- Pas de meta-tags étendus (`#frontend` etc. masqués)
- Deux tabs sous la topbar : **Édition** | **Discussion** (active = underline 2 px accent)
- Bottom nav fixe
- Sticky footer dans l'onglet Édition : `Annuler` + `Créer` (full width chacun)

---

## Interactions

| Action utilisateur | Résultat |
|---|---|
| Drag fichier au-dessus de l'éditeur | Overlay drop affiché |
| Drop fichier(s) | Upload + AttachmentCard ajoutée |
| Clic « Aperçu » | Textarea remplacée par rendu Markdown, FormatToolbar masquée |
| Clic « Édition » | Retour textarea, focus restauré |
| Clic bouton formatage | Insertion du snippet à la position du curseur (ou en fin si pas de focus) |
| Saisie dans textarea | Autosave 2 s |
| Clic suggestion Autodev | Patch markdown (insertion sous le heading ciblé) |
| `⌘+Enter` | Soumet le ticket |
| Clic « Créer le ticket » | POST → création GitLab → redirection `/issues/:iid` |
| Clic « Brouillon » | Sauvegarde explicite, toast « Brouillon enregistré » |

---

## Tokens utilisés

Voir `reference/tokens.css` (light + dark). Aucun nouveau token introduit dans cette refonte.

**Couleurs clés :**
- `--accent-bg` : fond des bulles Autodev + overlay drop
- `--accent-solid` (#5E47E8 light / #7259ED dark) : bouton primary, dashed border drop
- `--accent-fg` (#3A2AA0 / #C5B9FB) : texte sur bg accent
- `--paper`, `--paper-2`, `--border`, `--border-strong`, `--text`, `--text-muted`, `--text-subtle` : neutres

**Typographie :**
- Sans : Inter (400 / 500 / 600 / 700)
- Mono : JetBrains Mono (400 / 500) — utilisée dans la textarea et les `<kbd>`

---

## API attendue côté backend

L'écran a besoin de :

```
POST   /api/issues/draft            # autosave brouillon
GET    /api/issues/draft            # rehydrate au chargement
POST   /api/issues                  # création réelle (body: { title, markdown, attachments[], project_id, type, priority, labels[] })
POST   /api/uploads                 # multipart, retourne { id, url, name, size, w, h }
POST   /api/autodev/chat            # streaming SSE, body: { thread_id, message, draft_state }
                                    # réponses : { text, suggestion?: { kind: 'insert'|'replace', target: string, text: string } }
PATCH  /api/issues/draft/apply      # appliquer une suggestion (server-side patch)
```

---

## Fichiers de référence dans ce dossier

- `reference/screen-chat-spec.jsx` — composant React complet de l'écran (source de vérité visuelle)
- `reference/primitives.jsx` — `Sidebar`, `Topbar`, `Button`, `Icon`, `Avatar`, `AutodevAvatar`, `StatusPill`, etc.
- `reference/tokens.css` — tokens light + dark
- `screenshots/spec-desktop-light.png` — capture de l'artboard PC

Le reste du système de design (autres écrans, états, palette complète) est documenté à la racine de `design/` (le dossier parent).
