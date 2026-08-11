# Utiliser Autodev sur Powerpanne

Guide pratique du parcours d'un ticket sur Powerpanne, de sa redaction par le CSM jusqu'a la QA, avec Autodev au milieu.

> Projet : `modulosource/powerpanne/powerpanne/core`

## Les acteurs

| Acteur | Role |
|--------|------|
| **CSM** | Ecrit le ticket, valide la fonctionnalite apres Autodev, fait la QA apres le CR. |
| **Julien** | Relit chaque ticket, clarifie la spec avec le CSM, declenche Autodev. |
| **Autodev** | Implemente, ouvre la MR, corrige les reviews. |
| **Devs** | Relisent la MR apres validation fonctionnelle du CSM. |

## Le parcours du ticket en une phrase

Le CSM redige, Julien clarifie et declenche Autodev, Autodev implemente et ouvre la MR, le CSM valide fonctionnellement, les devs font le CR, le CSM fait la QA.

## Etape 1 -- Redaction et clarification

1. Le **CSM** cree le ticket et decrit la fonctionnalite attendue.
2. **Julien** relit le ticket. Tant que la spec n'est pas assez precise pour etre implementee, il echange avec le CSM en commentaires pour l'affiner.
3. Une fois la spec claire, Julien **assigne `autodev`** et pose le label **`To Do`**.

Autodev prend le ticket au prochain poll (toutes les 5 min), avec un delai de grace de 10 min apres la creation pour laisser le temps aux derniers ajustements.

## Etape 2 -- Implementation par Autodev

Autodev pose `Development::Doing` des qu'il commence, retire `To Do`, puis :

- **Clone** le repo.
- **Evalue** la spec.
- Soit **implemente** (commit, push, MR vers `staging`, pipeline, mr-review, corrections), soit **pose des questions** si la spec reste floue, soit **repond en commentaire** si le ticket est une question/investigation sans code.
- Quand c'est termine, il retire `Development::Doing` et pose **`Development::Awaiting Feature Review`** : la main est rendue au CSM.

Les sections plus bas detaillent chaque type d'interaction avec Autodev pendant cette phase.

## Etape 3 -- Validation fonctionnelle par le CSM

Le ticket arrive en **`Development::Awaiting Feature Review`** avec une MR ouverte et (quand le projet l'expose) des captures d'ecran postees sur le ticket.

Le **CSM auteur du ticket** teste la fonctionnalite.

- **Ca marche** : il pose **`Development::Awaiting CR`** sur le ticket.
- **Ca ne marche pas** : il poste un commentaire expliquant le(s) probleme(s), **reassigne `autodev`** et **repose le label `To Do`**. Autodev repart depuis le debut en tenant compte du commentaire.

## Etape 4 -- Code Review par les devs

Avec le label **`Development::Awaiting CR`**, les **devs** relisent la MR.

- **CR validee** : le ticket passe en **`Ready for QA`**. Autodev est hors boucle, le CSM auteur du ticket fait la QA.
- **Il y a des retours** : les devs laissent leurs commentaires sur la MR (discussions non resolues), **reassignent `autodev`** et **reposent le label `To Do`**. Autodev reprend le ticket depuis le debut et prend en charge les discussions ouvertes sur la MR existante.

## Les labels du parcours

| Label | Qui le pose | Signification |
|-------|-------------|---------------|
| `To Do` | Julien (puis CSM ou devs en cas de retour) | A prendre par Autodev. |
| `Development::Doing` | Autodev | Autodev travaille. |
| `Development::Awaiting Feature Review` | Autodev | Pret a etre teste par le CSM. |
| `Development::Awaiting CR` | CSM | Fonctionnellement valide, en attente de Code Review. |
| `Ready for QA` | Devs | CR validee, QA a faire par le CSM auteur du ticket. |

`Development::Doing` et `Development::Awaiting Feature Review` sont toujours poses par Autodev -- ne les pose jamais a la main. Les trois autres sont poses par les humains.

## Ce qu'Autodev ecrit sur le ticket

Autodev commente le ticket a plusieurs moments :

- **Demande de clarification** -- quand la spec est floue, il pose des questions numerotees et attend des reponses.
- **Reponse a une question** -- si le ticket est une question (pas une implementation), il poste sa reponse et ferme le cycle.
- **Desassignation** -- confirmation qu'il a bien arrete.
- **Alerte de stagnation** -- quand il n'arrive plus a progresser, il previent et s'arrete.
- **Captures d'ecran** -- apres l'implementation, un commentaire groupe avec les screenshots des pages impactees.

Ses commentaires commencent toujours par un emoji + `**autodev**:` pour etre reperables.

## Repondre a une demande de clarification d'Autodev

Quand Autodev pose des questions, le ticket repasse en attente et `Development::Doing` est retire.

Pour relancer :

- **Poste un commentaire standard** sur le ticket avec les reponses. N'importe quel format, tant que ce n'est pas un commentaire systeme.
- Au prochain poll, Autodev detecte la reponse et reprend le travail.

> Autodev ne detecte pas ses propres commentaires (ceux qui contiennent `**autodev**`). Un commentaire humain est identifie des qu'il est poste apres la demande de clarification.

## Ticket de question vs ticket d'implementation

Autodev classe automatiquement le ticket a la premiere etape :

- **Implementation** -- il code, commit, push, ouvre une MR.
- **Question / investigation** -- il explore le code, poste une reponse en commentaire, et marque le ticket comme termine (label `Development::Awaiting Feature Review`). Aucune MR n'est creee.

Pas besoin de marquer explicitement le type : c'est la formulation du ticket qui le determine.

## Review de la MR : comment demander des changements

Autodev ouvre la MR vers `staging`. Apres le premier pipeline vert, il lance une review automatique (`mr-review`) qui depose ses propres commentaires.

Pour demander une modification, que ce soit depuis la review auto, un dev en CR, ou le CSM en test fonctionnel :

- **Laisse un commentaire sur la MR** (sur une ligne du diff pour un commentaire cible, ou en discussion generale).
- Laisse la discussion **non resolue**.
- **Reassigne `autodev`** et **repose `To Do`** sur le ticket pour que Autodev reprenne.

Autodev :

- **Corrige chaque discussion non resolue** une par une, commit par commit.
- **Marque la discussion comme resolue** apres correction.
- **Ignore** les discussions deja resolues.

Si tu resous une discussion toi-meme, Autodev la laisse tranquille.

## Arreter Autodev sur un ticket

Deux facons, equivalentes. Dans les deux cas Autodev s'arrete au prochain poll, proprement, quel que soit l'etat en cours (implementation, attente de pipeline, correction de discussions...), poste un commentaire de confirmation sur le ticket, et **ne touche pas aux labels** -- la main est a toi.

- **Desassigne `autodev`** du ticket.
- **Ou deplace le label de workflow** : retire `Development::Doing`, ou pose `Development::Awaiting CR`, `Development::Awaiting Feature Review`, ou n'importe quel autre label du scope `Development::`. C'est le geste naturel quand tu reprends la main apres avoir teste -- inutile de penser a desassigner en plus.

Les labels hors du scope `Development::` (`PM::Evolution`, `Backlog`, noms de clients, `To Do`...) n'arretent rien : tu peux les poser et les retirer librement pendant qu'Autodev travaille.

Autodev pose et retire lui-meme `Development::Doing` et `Development::Awaiting Feature Review` en fonctionnement normal ; il fait la difference et ne s'arrete que sur une edition faite par quelqu'un d'autre.

Le ticket passe alors en **cloture** cote Autodev (il ne le suit plus). Pour qu'il reprenne : **repose `To Do`** et **reassigne `autodev`** -- c'est le meme geste que pour un retour de recette ou de CR, et il refonctionne meme apres un arret.

## Quand Autodev abandonne

Trois situations ou Autodev s'arrete sans avoir fini et rend la main via une alerte en commentaire :

| Cas | Signal |
|-----|--------|
| **Memes discussions** non resolues pendant 5 rounds consecutifs | `:warning: stagnation detectee -- les memes discussions restent non resolues` |
| **Memes jobs CI** en echec pendant 5 corrections consecutives | `:warning: stagnation detectee -- les memes jobs echouent` |
| **3 rounds de review** deja effectues | `:warning: la limite de review (3 tours) est atteinte` |

Dans tous ces cas, le ticket est marque comme termine (label `Development::Awaiting Feature Review`) et reprend manuellement.

Cas particulier : si le pipeline echoue pour des **raisons d'infrastructure** (pas le code), Autodev relance une fois. Si ca re-echoue, il reste en attente du pipeline sans alerter -- a quelqu'un de relancer le pipeline ou corriger l'infra.

## Captures d'ecran

Quand le projet a des serveurs exposes, Autodev lance l'appli en sandbox, navigue sur les pages impactees et **poste un commentaire sur le ticket** avec les screenshots. Les captures prises lors des corrections de review sont annotees `(correction suite a review)`.

C'est informatif : utile au CSM pour le test fonctionnel.

## Resume : qui fait quoi

| Action | Qui | Ou | Effet |
|--------|-----|----|----|
| Redige le ticket | CSM | Ticket | Point de depart |
| Clarifie la spec avec le CSM | Julien | Commentaires ticket | Rend le ticket implementable |
| Assigne `autodev` + `To Do` | Julien | Ticket | Declenche Autodev |
| Repond a une clarification d'Autodev | Julien / CSM | Commentaire ticket | Autodev reprend |
| Teste la fonctionnalite | CSM | Staging | Decide si c'est OK |
| Pose `Development::Awaiting CR` | CSM | Ticket | Passe la main aux devs (et arrete Autodev s'il travaillait encore) |
| Reassigne `autodev` + `To Do` apres test KO | CSM | Ticket | Autodev reprend avec le commentaire |
| Fait la Code Review | Devs | MR | Decide si c'est OK |
| Pose `Ready for QA` | Devs | Ticket | Passe la main au CSM pour la QA |
| Fait la QA | CSM | Staging | Verification finale apres CR |
| Reassigne `autodev` + `To Do` apres CR KO | Devs | Ticket | Autodev corrige les discussions |
| Desassigne `autodev` | N'importe qui | Ticket | Arret immediat |

## Cycle de vie d'un ticket (vue fonctionnelle)

```{.mermaid format=svg}
sequenceDiagram
    actor CSM
    actor Julien
    participant GL as GitLab<br/>(ticket + MR)
    participant AD as Autodev
    actor Devs

    CSM->>GL: Cree le ticket
    loop Clarification
        Julien->>GL: Commente pour clarifier
        CSM->>GL: Repond / ajuste la spec
    end
    Julien->>GL: Assigne @autodev, pose "To Do"

    Note over GL,AD: Delai de grace 10 min
    AD->>GL: Prend le ticket, pose "Development::Doing"
    AD->>AD: Clone et evalue la spec

    alt Spec claire : implementation
        AD->>GL: Implemente, ouvre la MR, poste les captures
        loop Pipeline + review + corrections
            AD->>GL: Attend le pipeline vert
            opt Premier tour
                AD->>GL: Lance mr-review
            end
            alt Discussions non resolues
                AD->>GL: Corrige, pousse, resout
            else Aucune discussion non resolue
                AD->>GL: Pose "Development::Awaiting Feature Review"
            end
        end
    else Spec floue
        AD->>GL: Poste les questions
        Julien->>GL: Repond en commentaire (ou CSM)
        AD->>AD: Reprend l'evaluation
    else Question / investigation
        AD->>GL: Poste la reponse (pas de MR)
        AD->>GL: Pose "Development::Awaiting Feature Review"
    end

    CSM->>GL: Teste la fonctionnalite
    alt CSM valide
        CSM->>GL: Pose "Development::Awaiting CR"
        Devs->>GL: Relisent la MR
        alt CR validee
            Devs->>GL: Pose "Ready for QA"
            CSM->>GL: Fait la QA
        else Retours sur la MR
            Devs->>GL: Commentaires non resolus sur la MR,<br/>reassignent @autodev, reposent "To Do"
            Note over AD: Autodev reprend, corrige les discussions
        end
    else CSM invalide
        CSM->>GL: Commentaire explicatif,<br/>reassigne @autodev, repose "To Do"
        Note over AD: Autodev reprend depuis le debut
    end

    opt Autodev doit etre arrete en cours de route
        Julien->>GL: Desassigne @autodev<br/>ou deplace le label "Development::*"
        AD->>GL: Confirme l'arret en commentaire,<br/>laisse les labels en l'etat
    end

    opt Autodev n'arrive plus a progresser
        Note over AD: Memes discussions x5, memes jobs CI x5,<br/>ou 3 rounds de review atteints
        AD->>GL: Alerte de stagnation,<br/>pose "Awaiting Feature Review"
    end
```
