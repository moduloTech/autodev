# Autodev — Composants

Composants React réutilisables. Tous les tokens sont des variables CSS définies dans `tokens.css`.

## Fondations

- **Couleurs sémantiques** : `--bg`, `--paper`, `--paper-2`, `--text`, `--text-strong`, `--text-muted`, `--text-subtle`, `--border`, `--divider`.
- **Accent (violet Autodev)** : `--accent-bg`, `--accent-bg-strong`, `--accent-solid`, `--accent-fg`.
- **Statuts** : working (teal), ok (vert), warn (ambre), err (rouge). Chacun a `-bg`, `-500`, `-fg`.
- **Code blocks** : `--code-bg`, `--code-fg`.
- **Rayons** : `--r-sm` (6px), `--r-md` (10px), `--r-lg` (14px), `--r-pill` (999px).
- **Ombres** : `--shadow-xs`, `--shadow-sm`, `--shadow-md`.
- **Polices** : `--font-sans` (Inter), `--font-mono` (JetBrains Mono).

## Logo

- `<AutodevLogoMark size={28} />` — Mark seul (cartes empilées + glyphe `</>`).
- `<AutodevAvatar size={28} />` — Alias du mark, utilisé comme avatar dans les chats.
- `<AutodevLogo size={24} withWord />` — Mark + mot "autodev".

## Composants UI

### `<StatusPill status size />`
Pastille d'état. `status` est l'une des clés de la table `STATES.md`. `size` : `sm` ou `md`.

### `<Button kind size icon iconRight full disabled>`
- `kind` : `default` (gris), `primary` (violet), `ghost` (transparent), `danger` (rouge).
- `size` : `sm`, `md`, `lg`.
- `full` : prend toute la largeur disponible.

### `<IconButton icon size active label />`
Bouton carré avec icône uniquement. `label` est utilisé pour `aria-label`.

### `<Card padding>`
Conteneur de base avec bordure, fond `--paper`, rayon `--r-lg`.

### `<Avatar name size />`
Initiales sur fond coloré dérivé du nom.

### `<Icon name size color strokeWidth />`
Icônes Lucide-like dessinées en SVG inline. Catalogue : `home`, `list`, `messages`, `alert-tri`, `folder`, `plus`, `refresh`, `external`, `more`, `search`, `filter`, `check`, `chevron-r`, `chevron-d`, `clock`, `play`, `paperclip`, `send`, `info`, `sparkles`, `settings`, `copy`, `menu`.

### `<StepBar status compact />`
Barre de progression du workflow (5 étapes : Reçue → Lecture → Code → Vérifs → Livrée).

### `<Sidebar active counts onClose />`
Navigation latérale (desktop). `counts` : `{ issues, errors, chat }`.

### `<Topbar title subtitle breadcrumb actions onMenuClick compact />`
Barre supérieure de chaque écran.

### `<MobileBottomNav active counts onNavigate />`
Barre de navigation mobile (5 items, le central est surélevé en violet).

## Hooks

### `useShellWidth()`
Renvoie la largeur du shell le plus proche (via `<ShellSizer>`). Utile pour rendre les écrans responsive.

### `shellMode(width)`
Renvoie `"mobile"` (< 640), `"tablet"` (< 1024) ou `"desktop"`.

## Wrapper

### `<ShellSizer width>`
Définit la largeur logique vue par les écrans descendants. Un même écran peut être rendu plusieurs fois côte-à-côte avec des tailles différentes.

## Thème

### `<ThemeContext.Provider value={{ theme, setTheme }}>`
Le thème (`light` | `dark`) est appliqué via `data-theme="…"` sur un ancêtre. Tous les tokens CSS basculent.

### `<ThemeToggle />`
Bouton ☀︎/☾ qui consomme le contexte.
