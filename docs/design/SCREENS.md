# Autodev — Écrans

Voir les screenshots dans `screenshots/` (light + dark, 1280×860).

## 01 · Tableau de bord (`/`)
Vue d'accueil. KPIs en haut (En cours, À surveiller, En attente d'une réponse, Livrés cette semaine). Liste des demandes en cours à gauche, sparkline + projets à droite. Banderole d'erreur en bas si des échecs nécessitent attention.

**Responsive :** 4 KPIs en grille 1 col mobile / 2 cols tablette / 4 cols PC.

## 02 · Liste des demandes (`/issues`)
Toutes les demandes sur tous les projets, avec onglets de filtrage (En cours / Échecs / Question en attente / Livrés / Tous), recherche, filtres avancés.

**Mobile :** la table devient des cartes empilées. Onglets scrollables horizontalement.

## 03 · À surveiller (`/errors`)
Demandes qui ont échoué ou attendent une réponse. Chaque carte explique la cause **en langage métier** d'abord, puis propose un bouton d'action et un toggle pour révéler les détails techniques (logs, stacktrace).

## 04 · Détail d'une demande (`/issues/:iid`)
Description du ticket + timeline d'activité chronologique avec les actions d'Autodev (transitions d'état + actions Claude).

**Nouveauté :** un panneau latéral droit permet de discuter avec Autodev pendant qu'il code. Bulles de chat, indicateur "en train de coder", possibilité d'envoyer un message qui sera vu en direct par l'agent.

**Mobile :** activité et discussion deviennent deux onglets.

## 05 · Spécification d'un nouveau ticket (`/new`)
Chat plein écran à gauche, brouillon de ticket auto-généré à droite. L'utilisateur décrit le besoin métier en langage naturel ; Autodev pose des questions de cadrage et rédige le ticket en direct. Bouton "Créer le ticket" valide et l'envoie sur GitLab.

**Mobile :** deux onglets (Discussion / Brouillon).

## 06 · Page projet (`/projects/:slug`)
Vue d'ensemble par projet : description, KPIs, demandes récentes, onglets pour Configuration (`.autodev.yml` + toggles de comportement) et Équipe.

## Règles de navigation

- **Sidebar** (PC) ou **bottom nav** (mobile) : Accueil, Demandes, À surveiller, Discuter (nouveau ticket), Projets.
- Le compteur d'erreurs est toujours visible (badge rouge) sur l'item "À surveiller".
- Le bouton "Discuter" en mobile est central et surélevé — c'est l'action principale.
