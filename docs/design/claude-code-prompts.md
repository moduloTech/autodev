# Prompts catalog pour Claude Code

Prompts prêts à copier pour intégrer cette direction design dans l'app Sinatra existante d'Autodev.

## 0 · Setup

```
Lis le dossier `design/` du projet. Il contient :
- `tokens.css` : variables CSS pour light + dark
- `STATES.md`  : table de correspondance état technique → libellé FR
- `COMPONENTS.md` : composants réutilisables
- `SCREENS.md` : description de chaque écran
- `screenshots/` : captures de référence

Le code actuel est dans `lib/autodev/web/` (Sinatra + ERB). Je vais te demander d'intégrer les écrans un par un. Avant chaque tâche : confirme que tu as lu les références.
```

## 1 · Migration des tokens

```
Crée `lib/autodev/web/public/css/tokens.css` à partir de `design/tokens.css`. 
Mets-le à jour dans `lib/autodev/web/views/layout.erb` à la place du <style> inline actuel. 
Ajoute aussi un toggle de thème dans le header (bouton ☀︎/☾) qui basculle l'attribut `data-theme` sur <html> et persiste le choix dans localStorage.
```

## 2 · Pastilles d'état

```
Dans `lib/autodev/web/`, crée un helper `status_pill(status)` qui génère le HTML d'une pastille.
Utilise la table de correspondance définie dans `design/STATES.md`. 
Référence exacte : screenshots/01-dashboard-light.png et 02-issues-light.png.
Remplace tous les affichages bruts de status dans les vues ERB par ce helper.
```

## 3 · Tableau de bord

```
Refactor `lib/autodev/web/views/dashboard.erb` pour matcher `screenshots/01-dashboard-light.png`. 
Composants requis : 4 KPIs en haut, liste des demandes en cours à gauche, sparkline + liste de projets à droite, banderole d'erreur en bas si applicable. 
Toutes les couleurs viennent des tokens. 
Responsive : breakpoints à 640px et 1024px (cf SCREENS.md).
```

## 4 · Liste des demandes

```
Refactor `lib/autodev/web/views/issues_list.erb` pour matcher `screenshots/02-issues-light.png`. 
Onglets de filtrage en haut (En cours / Échecs / Question en attente / Livrés / Tous) + champ de recherche. 
En desktop : table dense. En mobile (<640px) : cartes empilées (cf 02-issues-mobile dans le canvas).
```

## 5 · À surveiller

```
Crée `lib/autodev/web/views/errors_list.erb` qui matche `screenshots/03-errors-light.png`. 
Chaque carte affiche : titre, cause en langage métier, explication, bouton d'action suggéré, et un toggle "Afficher les détails techniques" qui révèle le stacktrace dans un <pre>.
```

## 6 · Détail d'une demande + chat latéral

```
Refactor `lib/autodev/web/views/issue_show.erb` selon `screenshots/04-detail-light.png`. 
Layout 2 colonnes en desktop, onglets en mobile. 
Le panneau de droite est NOUVEAU : il faut implémenter le chat avec Autodev pendant qu'il code. 
Backend : 
- Endpoint POST `/issues/:iid/messages` qui pousse un message dans la queue de l'agent.
- Endpoint SSE GET `/issues/:iid/stream` qui streame les nouveaux messages + transitions d'état.
- Côté frontend : Turbo Streams ou WebSocket, à toi de proposer.
```

## 7 · Spécification d'un nouveau ticket

```
Crée la route /new et la vue correspondante, selon `screenshots/05-spec-light.png`. 
Chat plein écran à gauche, brouillon de ticket auto-généré à droite. 
Backend : un nouvel agent "spec" qui prend les messages de l'utilisateur et renvoie 
(a) une réponse conversationnelle, (b) un objet ticket structuré (title, description, acceptance_criteria[], labels[]). 
À la validation, créer l'issue sur GitLab via l'API.
```

## 8 · Page projet

```
Crée `/projects/:slug` qui matche `screenshots/06-project-light.png`. 
Onglets : Vue d'ensemble / Demandes / Configuration / Équipe. 
L'onglet Configuration affiche le `.autodev.yml` du projet (lecture seule, syntaxe colorée) + des toggles pour les options runtime stockées en DB. 
Pour la vue d'équipe, lire les membres depuis l'API GitLab.
```

## 9 · Polish

```
Vérifie l'accessibilité : 
- contraste des textes (WCAG AA)
- aria-label sur tous les IconButton
- focus visible sur tous les boutons et liens
- navigation clavier complète

Teste light + dark sur chaque écran. Vérifie sur 390px, 768px et 1280px.
```

## Notes pour Claude Code

- Le design préserve la simplicité Sinatra/ERB existante. Pas besoin de framework JS lourd : Turbo + un peu de vanilla JS suffit.
- Le chat (écrans 04 et 05) est le seul endroit qui demande du temps réel (SSE ou WebSocket).
- Les screenshots sont en 1280×860 (desktop). Les versions mobile/tablette sont dans le HTML de référence (`Autodev Design.html`) si besoin de visualiser.
