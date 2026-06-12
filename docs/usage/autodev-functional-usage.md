---
title: "Autodev — Guide utilisateur"
subtitle: "Comment confier une demande à Autodev et suivre son travail"
author: "Modulotech"
date: 2026-06-12
lang: fr
documentclass: article
papersize: a4
geometry: margin=2cm
fontsize: 11pt
toc: true
toc-depth: 2
numbersections: true
colorlinks: true
linkcolor: blue
urlcolor: blue
---

\newpage

# À qui s'adresse Autodev

Autodev est un collègue automatique. Vous lui confiez un ticket GitLab et il s'en occupe : il comprend ce qu'il faut faire, écrit le code, ouvre une *Merge Request*, attend que la pipeline soit verte, prend en compte les retours de relecture, et marque le ticket comme livré.

Ce guide explique comment lui confier une demande et comment suivre l'avancement depuis le tableau de bord. **Aucune connaissance technique n'est nécessaire** pour le lire ou l'utiliser.

## Comment lui confier une demande

Tout part de GitLab. Trois gestes suffisent :

1. **Assignez le ticket à *autodev*** (comme à n'importe quel développeur).
2. **Mettez le label *à traiter*** sur le ticket.
3. **Attendez quelques minutes** : Autodev vérifie ses tickets régulièrement et démarre dès qu'il en voit un.

C'est tout. Autodev change le label en **en cours** dès qu'il commence, et le mettra à **livré** quand il aura terminé.

## Ce qui se passe ensuite

1. **Préparation.** Autodev récupère le projet et lit la demande.
2. **Question ?** Si quelque chose lui manque pour bien faire, il pose une question directement dans le ticket et attend votre réponse.
3. **Écriture du code.** Sinon, il code, sauvegarde, et envoie son travail.
4. **Ouverture de la *Merge Request*.** La MR est créée automatiquement avec le numéro de votre ticket.
5. **Tests.** La pipeline d'intégration tourne. Si elle échoue, Autodev corrige et recommence.
6. **Relecture.** Une relecture automatique est faite ; Autodev applique les retours.
7. **Livraison.** Quand tout est vert, le label passe à **livré** et la MR est prête à merger.

Pendant tout ce temps, vous pouvez suivre l'avancement sur le dashboard.

\newpage

# Se connecter

Le dashboard est protégé par le SSO Microsoft 365 de Modulotech. À la première visite, vous tombez sur cette page :

![Page de connexion. Un seul bouton.](screenshots/08-sign-in.png)

Cliquez sur **Se connecter avec Microsoft** et terminez la connexion avec votre compte Modulotech habituel. Vous arrivez ensuite directement sur le tableau de bord.

Votre identité et le lien **Se déconnecter** apparaissent en bas du menu de gauche, sous une pastille qui reprend la première lettre de votre adresse mail.

\newpage

# Tableau de bord

C'est la page d'accueil — votre vision d'ensemble de ce qui se passe sur tous les projets.

![Le tableau de bord : KPIs en haut, demandes en cours à gauche, projets et activité à droite.](screenshots/01-dashboard.png)

## Les 5 indicateurs en haut

| Indicateur | Ce qu'il signifie |
|---|---|
| **En traitement** | Autodev travaille dessus en ce moment. |
| **En attente** | Dans la file, Autodev les prendra au prochain tour. |
| **À surveiller** | Échec ou intervention nécessaire — quelqu'un doit regarder. |
| **En attente d'une réponse** | Autodev a posé une question, il attend une réponse de votre part. |
| **Livrés cette semaine** | Tickets terminés sur les 7 derniers jours. |

Chaque carte est un raccourci vers la liste filtrée correspondante.

## Les blocs

- **En traitement** — les 10 demandes sur lesquelles Autodev travaille actuellement. Chaque ligne montre le projet, le titre du ticket, et son état du moment.
- **Activité de la semaine** — un mini-graphe du nombre d'opérations menées chaque jour sur les 7 derniers jours. Utile pour repérer une journée creuse ou un pic.
- **Vos projets** — un récap par projet avec le nombre de demandes actives et le nombre d'erreurs en cours.
- **Banderole d'alerte** — si au moins une demande est en échec, un bandeau rouge en bas vous le rappelle avec un lien direct.

## Le menu de gauche

Présent sur toutes les pages :

- **Tableau de bord** — cette page.
- **Demandes** — la liste complète des tickets.
- **À surveiller** — tout ce qui demande votre attention.
- **Conversations** *(à venir)* — la future entrée pour rédiger un ticket par chat.
- **Projets** — la liste des projets suivis.

Tout en bas du menu : votre identité connectée et le lien **Se déconnecter**.

## Les options en haut à droite

- Le sélecteur **FR / EN** pour changer la langue de l'interface.
- Un bouton **soleil / lune** pour basculer entre thème clair et thème sombre. Le choix est mémorisé sur votre navigateur.
- Un bouton **Actualiser** pour relancer une mise à jour du contenu.
- Un bouton **Nouvelle demande** *(à venir)*.

Le tableau de bord se rafraîchit tout seul : pas besoin de recharger pour voir les changements arriver.

\newpage

# Liste des demandes

Toutes les demandes suivies par Autodev, sur tous les projets confondus.

![La liste des demandes avec les onglets de filtrage en haut.](screenshots/02-issues-list.png)

## Les onglets

| Onglet | Ce qu'il contient |
|---|---|
| **En traitement** | Tout ce qu'Autodev est en train de faire. |
| **En attente** | Les tickets pris en compte mais pas encore démarrés. |
| **Échecs** | Les tickets bloqués par une erreur. |
| **Question en attente** | Les tickets où Autodev attend une précision. |
| **Livrés** | Les tickets terminés. |
| **Tous** | Aucun filtre — l'historique complet. |

Le compteur à côté de chaque onglet est mis à jour en direct.

## Pour chaque ligne

- L'identifiant interne (par exemple `#15124`).
- Le titre du ticket GitLab.
- Le chemin du projet.
- L'état actuel sous forme de pastille colorée.
- La date de la dernière activité.

Cliquez sur une ligne pour voir le **détail** de la demande (timeline complète, actions disponibles).

## Recherche et filtres

- **Champ de recherche** (en haut à droite) : tape un mot-clé, le titre et la description sont fouillés.
- **Filtre par dates** : permet de restreindre à une période.

\newpage

# À surveiller

La page qui regroupe **tout ce qui demande votre attention** : échecs, questions en attente, finalisations qui se sont mal passées.

![Page À surveiller — chaque demande est une carte avec explication métier.](screenshots/03-errors.png)

## Chaque carte explique d'abord ce qu'il s'est passé en langage clair

- Pour un échec : *« Une erreur a empêché autodev de continuer son travail. Consultez les détails techniques pour comprendre la cause. »*
- Pour une question en attente : *« Autodev a posé une question pour préciser la demande et attend une réponse pour reprendre. »*

## Deux actions par carte

- **Voir le détail** — ouvre la page détaillée du ticket.
- **Réessayer maintenant** — relance Autodev sur ce ticket, à zéro.

Si vous voulez voir ce qui s'est passé techniquement (pour faire suivre à un développeur, par exemple), le toggle **Afficher les détails techniques** déplie la trace :

![Détails techniques dépliés. Utile à transmettre à l'équipe technique.](screenshots/03b-errors-expanded.png)

\newpage

# Détail d'une demande

La vue complète d'un ticket. Vous y arrivez en cliquant sur une ligne depuis n'importe quelle liste.

![Détail d'une demande en cours. Timeline à gauche, métadonnées et actions à droite.](screenshots/06-issue-detail.png)

## En haut : l'en-tête

Le titre du ticket, l'état actuel sous forme de pastille, et deux raccourcis :

- **Voir sur GitLab** — ouvre le ticket d'origine.
- **Voir la MR** — ouvre la *Merge Request* (apparaît dès qu'Autodev l'a créée).

## Au centre : la chronologie

C'est le journal de bord. Chaque ligne est une étape de ce qu'Autodev a fait sur ce ticket — du clone initial jusqu'à la livraison, avec toutes les corrections intermédiaires.

Deux types d'entrées :

- **Étapes** — changements d'état (par exemple « passage de *Test de la fonctionnalité* à *Correction des tests qui échouent* »).
- **Actions** — événements détaillés : ouverture de la MR, échec d'un test, retentative, lancement d'une relecture, etc.

L'historique remonte les 200 dernières entrées par défaut.

## À droite : métadonnées et actions

**Métadonnées** :

- *Branche* — le nom de la branche créée par Autodev.
- *Langue* — la langue dans laquelle Autodev communique sur ce ticket.
- *Tentatives* — combien de fois Autodev a recommencé suite à une erreur.
- *Revues* — combien de fois la relecture automatique est passée.
- *Relances pipeline* — combien de fois la pipeline a été relancée.
- *Démarrée le* / *Créée le* — les horodatages.
- *Erreur* — le détail de l'erreur si la demande est bloquée.

**Actions** (varient selon l'état) :

- **Réinitialiser** — repart à zéro sur cette demande.
- **Forcer la transition** — fait passer manuellement la demande à l'étape suivante. Utile si vous voulez court-circuiter une attente.

## Quand Autodev pose une question

Si Autodev a besoin d'une précision, l'écran change légèrement :

![Une demande en attente d'une précision. Autodev a posté une question sur le ticket GitLab.](screenshots/09-issue-clarification.png)

Répondez directement sur le ticket GitLab (commentaire). Autodev verra votre réponse au prochain tour. Si vous voulez accélérer le redémarrage, l'action **Précision reçue** est disponible dans le panneau **Actions**.

\newpage

# Projets

La liste des projets que suit Autodev.

![Liste des projets — chaque carte porte les KPIs du projet.](screenshots/04-projects.png)

Chaque carte affiche, pour le projet :

- L'URL GitLab.
- Le nombre de **demandes en cours**.
- Le nombre de demandes **à surveiller**.
- Les demandes **livrées ce mois-ci**.
- Le **total** historique des demandes suivies.

Cliquez sur une carte pour ouvrir la page du projet.

## Détail d'un projet

![La page d'un projet : vue d'ensemble, demandes récentes, et configuration.](screenshots/05-project-show.png)

Quatre onglets en haut :

1. **Vue d'ensemble** — KPIs et les 5 demandes les plus récentes.
2. **Demandes** — la liste complète, préfiltrée sur ce projet.
3. **Configuration Autodev** — les réglages techniques du projet (à voir avec l'équipe technique).
4. **Équipe** — qui peut intervenir sur ce projet.

Le panneau de droite récapitule les **détails techniques** et l'**équipe**.

En haut à droite, **Voir sur GitLab** ouvre le projet GitLab.

\newpage

# Comprendre les pastilles d'état

Au fil des écrans, chaque demande porte une pastille colorée qui indique où elle en est. Voici la signification :

| Pastille | Ce que ça veut dire |
|---|---|
| **En attente** | Dans la file, Autodev la prendra au prochain tour. |
| **Préparation** | Autodev récupère le code du projet. |
| **Compréhension de la demande** | Autodev lit le ticket et vérifie qu'il a tout pour démarrer. |
| **Écriture du code** | Autodev produit les modifications. |
| **Sauvegarde** | Autodev commit son travail. |
| **Envoi sur GitLab** | Autodev pousse la branche. |
| **Ouverture de la demande de fusion** | Création de la MR. |
| **Test de la fonctionnalité** | La pipeline GitLab tourne. |
| **Relecture du travail** | La relecture automatique est en cours. |
| **Application des retours de relecture** | Autodev intègre les remarques laissées sur la MR. |
| **Correction des tests qui échouent** | Autodev corrige les erreurs de la pipeline. |
| **Réponse à une question** | Autodev rédige sa réponse à une question. |
| **En attente d'une précision** | Autodev a posé une question, il attend votre réponse. |
| **Finalisation** | Dernières opérations après la livraison. |
| **Livrée** | Terminé, la MR est prête à merger. |
| **Bloquée, intervention nécessaire** | Quelque chose a échoué, il faut regarder. |

\newpage

# Questions fréquentes

**Combien de temps avant qu'Autodev prenne ma demande en compte ?**
Autodev vérifie ses tickets toutes les quelques minutes. Le démarrage se fait donc en quelques minutes, pas en quelques secondes.

**Combien de tickets Autodev peut-il traiter en parallèle ?**
Plusieurs, mais pas en illimité. Si vous lui en confiez beaucoup d'un coup, certains attendront leur tour (visible sous *En attente*).

**Autodev a posé une question, comment je lui réponds ?**
Répondez directement sur le ticket GitLab en commentaire, comme à n'importe quel collègue. Il verra votre réponse au prochain tour.

**Autodev s'est trompé ou a fait n'importe quoi, je peux annuler ?**
Oui. Désassignez-le du ticket : il s'arrête. Vous pouvez ensuite reprendre la main et l'assigner à un humain. La MR créée reste disponible — vous pouvez la fermer ou la modifier librement.

**La MR n'est pas mergée, est-ce qu'il faut que je le fasse moi ?**
Oui. Autodev livre une MR prête à merger, mais le merge final reste à un humain (validation finale, déploiement, etc.).

**Une demande est bloquée en *Test de la fonctionnalité* depuis longtemps. Pourquoi ?**
C'est généralement une pipeline d'infra (pas un bug du code) qui a échoué et n'a pas pu être relancée automatiquement. La demande attend une intervention manuelle. Ouvrez le détail, regardez les **détails techniques**, et faites suivre à l'équipe technique si besoin.

**Je vois *« Synchronisation avec les membres GitLab à venir »* sur un projet. Normal ?**
Oui, c'est un message d'attente : la synchronisation des équipes depuis GitLab sera mise en place dans une prochaine version. Cela n'empêche pas Autodev de travailler.

**Et le hook *post-completion* qui apparaît parfois en erreur ?**
C'est une action de finalisation après livraison (par exemple, mise à jour d'un changelog). Si elle échoue, la demande reste tout de même livrée — mais elle apparaîtra dans **À surveiller** pour signaler le problème de finalisation.
