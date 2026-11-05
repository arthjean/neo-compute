[PRD]
# PRD: neo-compute, parité native avec Windows-MCP

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-11-05 | Arthur Jean | Version initiale : perception enrichie, fenêtres et applications, attente conditionnelle, ancrage visuel et capture de repli, indicateur de contrôle, presse-papiers et registre, évals de parité (EP-005 à EP-010), périmètre fixé par la décision 0008 |
| 1.1 | 2026-11-05 | Arthur Jean | US-025 : le repli MSAA passe par le proxy MSAA d'UI Automation et `LegacyIAccessible` (voie 1 de la revue de EP-005, décision 0009) ; un parcours `IAccessible` direct coûte environ six fois le budget |
| 1.2 | 2026-11-05 | Arthur Jean | US-022 : la seconde requête `FindAllBuildCache` avec condition OR, essayée, coûte 25 ms p95 dans le Bloc-notes (critère 7 impossible) ; patterns en cache et un aller-retour par élément, précédé d'une vérification de réponse de la fenêtre (décision 0009) |

## Problem Statement

1. **Des tâches courantes restent hors de portée des outils de neo-compute.** Windows-MCP v0.8.8 (exploré le 2026-11-05, commit 9ab92bc) expose 21 outils ; neo-compute en couvre 9, 6 en partie, et il en manque 2 (inventaire de la décision 0008). Lancer une application, ranger une fenêtre, lire le presse-papiers ou vérifier un réglage obligent l'agent à enchaîner des raccourcis (Win, saisie du nom, Entrée) et des captures, au prix de 1 à 5 s par aller-retour modèle.
2. **Les menus contextuels et les popups échappent à `ui_tree`.** Le snapshot ne lit que la fenêtre au premier plan, dont l'élément 0 est la racine (`src/core/uitree.zig:104`). Un menu contextuel ou un popup Win32 est une fenêtre de premier niveau distincte : après un `right_click`, l'agent doit repasser par la vision.
3. **Il n'existe aucune attente conditionnelle.** La stabilisation après action (US-015) attend la fin des changements à l'écran, pas l'apparition d'un élément précis. Pour attendre un dialogue lent, l'agent enchaîne `wait` et `ui_find`, un aller-retour par sondage.
4. **Firefox et le texte des pages web sont mal servis.** Firefox 143 n'active l'UIA natif que progressivement ([notes de version](https://www.firefox.com/en-US/firefox/143.0/releasenotes/)), et `ui_tree` ne renvoie pas le texte d'une page : lire un article demande des captures.
5. **Obtenir ces fonctions aujourd'hui supposerait de lancer Windows-MCP en parallèle.** Ce serveur exige un runtime Python et active la télémétrie par défaut. Il expose aussi un shell complet, alors que son contrôle n'est qu'au mieux (« best-effort, not a security boundary », d'après son README). Son code imprime la valeur LegacyIAccessible des champs mot de passe (`tree/service.py:673`), et son `WaitFor element_enabled` ne teste pas l'état activé (`tools/input.py:150`).

**Why now:** (a) Le PRD neo-compute est terminé (EP-001 à EP-004 DONE), et la campagne du 2026-11-03 donne 100 % de réussite en mode a11y sur 20 tâches : la base est stable. (b) L'exploration de Windows-MCP v0.8.8 et la décision 0008 fixent un périmètre exact. (c) Le budget des définitions d'outils est à 2 934 tokens estimés sur 3 000 (`src/core/registry.zig:13`) : aucun outil ne peut être ajouté sans une décision de budget. (d) L'UIA natif de Firefox 143 ne rend plus le repli MSAA nécessaire que pour une partie des installations.

## Overview

Ce PRD étend neo-compute par du code Zig natif, sans dépendance nouvelle ni runtime. Il ne reprend ni le code ni les noms d'outils de Windows-MCP, seulement les comportements que la décision 0008 retient. Il ajoute quatre outils à chargement différé : `window_set`, `app_launch`, `clipboard` et `registry_read`. `ui_tree` reçoit les paramètres optionnels `text` et `marks`, `ui_find` le paramètre `wait_ms`, et `window_list` un en-tête des écrans. Les 17 outils du toolset et `window_focus` ne changent pas.

La perception gagne :
- les plages de valeurs, le pourcentage de défilement et la sélection de texte, lus par une seconde requête UIA ciblée qui laisse le cache principal à 12 propriétés ;
- plusieurs racines par snapshot : fenêtre au premier plan, fenêtres possédées, menus et popups du même processus, avec un drapeau `modal` ;
- le texte des pages web ;
- un repli MSAA pour Firefox, qui ne lit jamais la valeur d'un champ protégé.

Les applications du menu Démarrer sont énumérées sur un thread STA dédié et appariées par un algorithme approximatif écrit dans le cœur. Elles sont lancées par `ActivateApplication` si elles sont empaquetées, par `ShellExecuteExW` sinon. L'attente conditionnelle ne relance la recherche que lorsque DXGI signale un changement. `marks` dessine les IDs stables de `ui_tree` sur l'image : un hybride accessibilité et vision où chaque marque reste actionnable par `ui_act`.

La sécurité suit les invariants existants :
- aucun réseau, aucun outil de commande (FR-10, FR-11) ;
- une section `system` de la politique encadre les outils sans fenêtre cible ;
- le presse-papiers refuse les contenus marqués secrets, et le registre masque les valeurs dont le nom évoque un secret ;
- `app_launch` refuse exécutables, scripts et URI ;
- un indicateur visuel, exclu des captures, signale les actions de l'agent, sans bloquer les entrées physiques : l'humain garde la priorité par le kill switch (FR-12).

Périmètre : 6 epics, 19 stories, 58 points.

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| Fonctions retenues par la décision 0008 livrées | 100 % des stories P0 | 100 % des stories P0 et P1 |
| Réussite sur les tâches de parité (US-037), mode a11y | ≥ 90 % | ≥ 95 % |
| Réussite sur les tâches de parité, comparée au mode windows-mcp | ≥ windows-mcp | ≥ windows-mcp + 10 points |
| Snapshot UIA p95 avec les propriétés et racines nouvelles (≤ 400 nœuds, apps natives) | < 50 ms et ≤ 110 % de la baseline | < 50 ms |
| Fuite de secret (presse-papiers, registre, mots de passe) sur les tâches canari | 0 | 0 |

## Target Users

### Arthur (développeur, utilisateur principal)
- **Role:** ingénieur et fondateur, pilote Claude Code au quotidien sous Windows 11 (deux écrans, double GPU).
- **Behaviors:** délègue des tâches GUI à Claude Code par neo-compute ; garde Windows-MCP comme référence d'éval.
- **Pain points:** l'agent ne sait ni lancer une app, ni ranger une fenêtre, ni lire un menu contextuel sans capture ; attendre un dialogue coûte plusieurs allers-retours ; il ne voit pas quand l'agent agit.
- **Current workaround:** séquences clavier (Win, nom, Entrée), `wait` fixes, ou lancement de Windows-MCP à côté, avec son shell complet et sa télémétrie.
- **Success looks like:** une seule commande `claude mcp add`, aucune dépendance externe à l'exécution, et les tâches de parité réussies avec moins d'allers-retours que Windows-MCP.

### Claude Code (agent consommateur des outils)
- **Role:** le modèle (Opus 5.5 et suivants) qui appelle les outils MCP.
- **Behaviors:** charge les outils différés à la demande ; agit par ID d'élément ; lit les deltas après chaque action.
- **Pain points:** menus et popups absents de l'arbre ; pas d'attente sur condition ; pas de texte de page web ; aucun lien entre l'image et les IDs.
- **Current workaround:** captures répétées, `wait` arbitraires, raccourcis clavier pour lancer les apps.
- **Success looks like:** un menu contextuel visible dans le delta, une attente qui rend la main dès que l'élément apparaît, une image dont chaque marque est un ID utilisable par `ui_act`.

### Développeurs Claude Code sous Windows (secondaire)
- **Role:** utilisateurs de la CLI qui utilisent Windows-MCP faute de mieux.
- **Behaviors:** installent un serveur Python, excluent ses outils dangereux par `--exclude-tools`.
- **Pain points:** runtime Python, télémétrie, shell complet, latence.
- **Current workaround:** Windows-MCP, AutoHotkey, scripts PowerShell.
- **Success looks like:** les mêmes capacités GUI dans un binaire unique, sans shell ni réseau.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **Windows-MCP (CursorTouch) :**
  - fonctionnement : `App` lance par PowerShell (`Get-StartApps`, `Start-Process`) ; `WaitFor` reconstruit l'arbre complet toutes les 250 ms ; Clipboard, Registry en écriture, PowerShell et Process donnent un accès système complet ;
  - défauts observés dans son code : la valeur des champs mot de passe est imprimée, la télémétrie par outil ne s'envoie jamais, `element_enabled` n'est pas testé ;
  - ce que fait neo-compute : du natif, sans shell, avec des IDs stables et des deltas.
- **Terminator (mediar-ai, Rust) :**
  - fonctionnement : plus de 40 outils, sélecteurs à la Playwright, `wait_for_element`, `open_application` ;
  - limite : noms d'outils instables entre les versions 0.6 et 0.20 ([docs.rs](https://docs.rs/crate/terminator-rs/0.6.9)) ;
  - ce que fait neo-compute : un contrat stable, et des définitions sous budget de tokens.
- **Microsoft UFO2 :** UIA d'abord, vision en repli, vérification des préconditions avant chaque action ([arXiv 2504.14603](https://arxiv.org/html/2504.14603v2)). neo-compute reprend l'idée hybride avec `marks`, sans modèle de vision local.
- **Market gap:** aucun serveur ne combine des IDs d'accessibilité stables dessinés sur l'image, une attente pilotée par les changements d'écran, un presse-papiers qui respecte les marqueurs des gestionnaires de mots de passe et un indicateur de contrôle exclu des captures, sans shell ni réseau.

### Best Practices Applied
- Identifiants d'accessibilité d'abord, vision en repli (UFO2).
- Attente conditionnelle bornée par un délai, jamais une pause fixe (Windows-MCP, Terminator).
- Lancement par AUMID et sans shell ; un `hProcess` NULL est une issue normale de `ShellExecuteExW` ([SHELLEXECUTEINFOW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shellexecuteinfow)).
- Respect des formats presse-papiers `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory` et `CanUploadToCloudClipboard` ([Clipboard Formats](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats)), et de `Clipboard Viewer Ignore` ([CopyQ](https://raw.githubusercontent.com/hluk/CopyQ/v17.0.0/docs/security.rst)).
- `WDA_EXCLUDEFROMCAPTURE` pour une fenêtre propre au processus, depuis Windows 10 2004 ; ce n'est pas une frontière de sécurité ([SetWindowDisplayAffinity](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity)).
- Firefox : UIA natif par `accessibility.uia.enable`, désactivé si un client incompatible est détecté ; NVDA lit encore le web par IA2 ([intent to ship](https://groups.google.com/a/mozilla.org/g/dev-platform/c/qljNUMTNtyA), [bug 1957314](https://bugzilla.mozilla.org/show_bug.cgi?id=1957314)).

*Full research sources available in project documentation.*

## Assumptions & Constraints

### Assumptions (to validate)
- **A7 :** une seconde requête `FindAllBuildCache`, limitée aux éléments qui portent RangeValue ou Scroll, ajoute ≤ 5 ms p95 à un snapshot de 400 nœuds. Mesuré en US-022.
- **A8 :** sur le build 26300, `WDA_EXCLUDEFROMCAPTURE` retire une fenêtre de la duplication DXGI et du BitBlt GDI, et l'animation d'une fenêtre exclue ne produit aucun dirty rect DXGI. Non documenté par Microsoft. Validé par US-033.
- **A9 :** sur la machine de référence, Firefox expose son contenu par l'UIA natif ou, à défaut, par MSAA. Vérifié par la sonde de US-025.
- **A10 :** une application non empaquetée lancée par `shell:AppsFolder\<AUMID>` ouvre une fenêtre détectable en moins de 10 s, même quand `hProcess` reste NULL. Mesuré en US-029.
- **A11 :** les gestionnaires de mots de passe usuels posent au moins un des formats presse-papiers de secret ; Bitwarden ne le faisait pas selon un fil de son forum. Vérifié en US-035 sur les gestionnaires installés.
- **A12 :** Claude Code ne charge la définition d'un outil MCP différé qu'à la recherche d'outils ; seuls les outils `anthropic/alwaysLoad` coûtent à chaque requête (PRD neo-compute, Why now b). Le budget de US-020 repose sur ce comportement.
- **A13 :** l'énumération du dossier `FOLDERID_AppsFolder` réussit 100 fois sur 100 depuis un thread STA dédié, en < 300 ms au premier appel. Mesuré en US-028.

### Hard Constraints
- Zig 0.17.0, pas de `@cImport`, bindings générés depuis `bindings/windows.zon` ; aucune vtable écrite à la main (AGENTS.md).
- Les invariants FR-07 à FR-18 du PRD neo-compute restent vrais, en particulier : aucune connexion réseau (FR-10), aucun outil de commande ou de script (FR-11), aucune valeur de mot de passe exposée (FR-09), stdout réservé au JSON-RPC (FR-18).
- Les 17 outils du toolset, leur fixture `tests/fixtures/toolset_20260801.json` et `window_focus` ne changent pas (décision 0008).
- Le cache UIA principal reste à 12 propriétés au plus (US-011).
- Le cœur (`src/core/`) n'appelle aucune API Windows ; `zig build cross` le compile pour Linux avec le backend factice.
- Les campagnes d'évals passent par `claude -p` sur l'abonnement d'Arthur, uniquement avec son accord ; aucune clé `ANTHROPIC_API_KEY`.
- Chaque défaut de la couche COM Zig compte pour la condition 3 du Rust Switch Gate (`docs/decisions/0001-zig-vs-rust.md`).

## Quality Gates

These commands must pass for every user story:
- `zig fmt --check .` - formatage
- `zig build` - serveur, sondes et bindings générés
- `zig build test` - tests du cœur sur le backend factice, budgets vérifiés à la compilation, bindings et dispositions de structures
- `zig build cross` - le cœur compile pour x86_64-linux-gnu sans dépendance Windows
- `zig build bench -- --check bench/baseline.json` - p95 ReleaseFast ≤ 110 % de la baseline et sous les budgets absolus

For backend stories (`src/backend/`, `bindings/`, `tools/winmdgen/`), additional gates:
- `zig build run -- selftest` - capture, souris, clavier, UIA et DPI sur une fenêtre de test, sortie jointe au rapport
- `pwsh -NoProfile -Command "& ./evals/run.ps1 -DryRun"` - pour les stories qui touchent `evals/`

## Epics & User Stories

### EP-005: Socle et perception enrichie

Rendre le budget et la politique prêts pour de nouveaux outils, puis donner à `ui_tree` ce que l'agent doit aujourd'hui chercher par capture : plages, défilement, sélection, menus et popups, texte des pages web, Firefox.

**Definition of Done:** les définitions respectent les deux plafonds de US-020. Un menu contextuel ouvert par `right_click` dans le Bloc-notes apparaît avec ses IDs dans le delta suivant. Le texte d'une page Chrome est lisible par `ui_tree`. `zig build bench -- notepad` et le nouveau scénario `notepad-menu` tiennent < 50 ms p95.

#### US-020: Budget des définitions par mode de chargement
**Description:** En tant qu'Arthur, je veux un budget de tokens séparé pour les outils chargés d'office et pour l'ensemble des outils afin d'ajouter des outils différés sans alourdir chaque requête.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] `src/core/registry.zig` remplace `max_definition_tokens` par deux plafonds vérifiés à la compilation : définitions des outils `anthropic/alwaysLoad` ≤ 1 500 tokens estimés, total des définitions ≤ 4 500 tokens estimés, avec le ratio calibré de `bench/token_calibration.json`.
- [ ] Étant donné un outil `alwaysLoad` qui ferait dépasser 1 500 tokens, quand le projet compile, alors l'erreur nomme l'outil, l'estimation et le plafond concerné.
- [ ] `registry_test.zig` vérifie les deux plafonds et affiche les deux estimations courantes (1 100 et 2 934 tokens environ à la date du PRD).
- [ ] Aucun des outils ajoutés par ce PRD (`window_set`, `app_launch`, `clipboard`, `registry_read`) n'est marqué `alwaysLoad`.
- [ ] La ligne « Tokens des définitions d'outils » des Success Metrics de `tasks/prd-neo-compute.md` renvoie à ce PRD, sans réécrire son historique.

#### US-021: Section `system` de la politique
**Description:** En tant qu'Arthur, je veux régler dans `policy.json` les outils qui ne visent aucune fenêtre afin de pouvoir couper le lancement d'apps, le presse-papiers ou le registre sans toucher aux niveaux par application.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Le parseur de `src/core/policy.zig` accepte une clé `system` avec `app_launch` (`allow` ou `deny`), `clipboard` (`off`, `read`, `write` ou `read_write`) et `registry_read` (`allow` ou `deny`).
- [ ] Les défauts, sans section `system`, sont `app_launch: allow`, `clipboard: read_write`, `registry_read: allow`.
- [ ] Étant donné une valeur inconnue dans `system`, quand la politique est chargée, alors le serveur démarre en `observe` global et `instructions` cite la ligne fautive, comme pour toute politique invalide (US-017).
- [ ] Un outil refusé par `system` renvoie `isError: true` « Politique : <outil> est désactivé (system.<clé> dans policy.json) ».
- [ ] La politique par défaut versionnée dans le dépôt documente la section avec ses défauts.
- [ ] Les tests du cœur couvrent chaque valeur, une clé inconnue et l'absence de section.

#### US-022: Plages, défilement et sélection dans `ui_tree`
**Description:** En tant que Claude Code, je veux lire la valeur et les bornes d'un curseur, la position de défilement d'un conteneur et le texte sélectionné afin de régler un contrôle ou de savoir s'il reste du contenu sans capture.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Le cache principal reste à 12 propriétés ; il porte les patterns RangeValue et Scroll, et chaque élément qui les expose lit `RangeValue` (valeur, minimum, maximum, lecture seule) et `Scroll` (pourcentages vertical et horizontal) en un aller-retour en cache (`BuildUpdatedCache`). Une seconde requête `FindAllBuildCache` avec condition OR, mesurée à 25 ms p95 dans le Bloc-notes, ne tient pas le critère de performance (décision 0009).
- [ ] Une ligne d'élément à plage affiche `[=<valeur>/<min>..<max>]` ; un conteneur défilable affiche `scroll=<v>%` et, s'il défile horizontalement, `,h<h>%` ; la valeur `UIA_ScrollPatternNoScroll` (-1) n'affiche rien.
- [ ] Pour l'élément qui a le focus clavier, s'il expose TextPattern et n'est pas `IsPassword`, la ligne affiche `sel="<texte>"` (100 caractères au plus) quand la sélection n'est pas vide ; un champ `IsPassword` n'affiche jamais de sélection.
- [ ] Le delta (`since=last`) signale un changement de valeur, de bornes, de défilement ou de sélection comme une modification de l'élément.
- [ ] Étant donné un provider qui ne répond pas à la seconde requête dans le timeout UIA, alors les champs nouveaux sont omis, l'arbre principal est renvoyé et la sortie porte `{partial: timeout}`. UI Automation n'applique pas son timeout à une fenêtre qui s'arrête après la lecture principale : chaque aller-retour vérifie d'abord que la fenêtre répond dans ce timeout, et le selftest `ui-range-timeout` le prouve sur un processus dont le thread s'arrête entre deux curseurs.
- [ ] Un test sur le backend factice vérifie le format de chaque champ, et un test du selftest lit un curseur Win32 (`TRACKBAR`) de la fenêtre de test.
- [ ] `zig build bench -- notepad` et le scénario `snapshot` restent ≤ 110 % de la baseline et < 50 ms p95 ; le surcoût mesuré de la seconde requête est consigné (A7).

#### US-023: Menus, popups et dialogues modaux comme racines du snapshot
**Description:** En tant que Claude Code, je veux que `ui_tree` inclue les menus contextuels, les popups et les dialogues de l'application au premier plan afin d'agir dessus par ID juste après les avoir ouverts.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Un snapshot sans `window` porte une liste de racines : la fenêtre au premier plan, les fenêtres de premier niveau visibles qu'elle possède (chaîne `GW_OWNER`), les menus de classe `#32768` visibles et les popups visibles du même processus, dans l'ordre z.
- [ ] Chaque racine a sa ligne d'en-tête : rôle, nom, handle, `display=` et échelle de son écran ; une racine modale (`WindowPattern.IsModal`, ou une fenêtre propriétaire désactivée) porte `{modal}`.
- [ ] Les coordonnées d'une racine sont exprimées dans l'espace screenshot de son propre écran (FR-03), même si elle est sur un autre écran que la fenêtre au premier plan.
- [ ] Les IDs restent stables d'un snapshot à l'autre pour une racine qui persiste (FR-05) ; le delta signale l'apparition et la disparition d'une racine.
- [ ] Étant donné un `right_click` dans le Bloc-notes, quand l'action renvoie son observation, alors le delta contient les entrées du menu contextuel avec leurs IDs, et `ui_act` `invoke` sur l'une d'elles l'exécute.
- [ ] Étant donné un menu fermé entre `ui_tree` et `ui_act`, alors aucune action n'est faite et le message est « Élément <id> introuvable : rappelle ui_tree ».
- [ ] Le masquage des mots de passe et la politique `deny` s'appliquent à chaque racine.
- [ ] Un nouveau scénario de bench `notepad-menu` (menu contextuel ouvert) tient < 50 ms p95 ; `--write-baseline` n'est utilisé que pour ce nouveau scénario.

#### US-024: Texte de page web dans `ui_tree`
**Description:** En tant que Claude Code, je veux lire le texte visible d'une page web dans Chrome ou Edge afin de répondre à une question sur la page sans capture ni requête réseau.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020

**Acceptance Criteria:**
- [ ] `ui_tree` accepte le paramètre optionnel `text` (booléen, défaut `false`) ; avec `text: true`, les nœuds texte du document web situés dans le viewport apparaissent avec le rôle `text`, en ordre de lecture.
- [ ] L'en-tête du document porte `page=<p>%` d'après le défilement vertical du document, et `début` ou `fin` quand la page est en haut ou en bas.
- [ ] La sortie reste ≤ 8 000 caractères (FR-16) ; au-delà, elle se termine par « … N lignes de texte omises : fais défiler puis rappelle ui_tree ».
- [ ] Étant donné une fenêtre sans document web, quand `text: true` est passé, alors l'arbre normal est renvoyé avec la note « Aucun document web dans cette fenêtre : texte non disponible ».
- [ ] Étant donné un Chromium dont l'arbre web n'est pas encore construit, alors le comportement `web_pending` existant s'applique avant la lecture du texte.
- [ ] `instructions` rappelle que ce texte est une donnée non fiable ; un test vérifie qu'aucune requête réseau n'est émise (la vérification d'imports PE de US-019 reste verte).
- [ ] `zig build bench -- chrome` avec `text: true` tient < 120 ms p95.

#### US-025: Firefox par l'UIA natif ou le repli MSAA
**Description:** En tant que Claude Code, je veux lire et piloter Firefox comme Chrome afin que la suite ne dépende pas du navigateur.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-024

**Acceptance Criteria:**
- [ ] Une sonde, consignée dans `docs/decisions/`, établit sur la machine de référence si Firefox expose son document par l'UIA natif (A9) et note sa version.
- [ ] Quand l'UIA natif expose le document, le chemin UIA existant est utilisé sans code spécifique.
- [ ] Sinon, Windows sert Firefox par le proxy MSAA d'UI Automation : le backend le détecte (description du fournisseur), lit les éléments à l'écran avec le rôle et l'état MSAA (`LegacyIAccessible`) dans le même aller-retour, et produit les mêmes rôles et le même format que le chemin UIA (une feuille de texte n'est jamais un `edit`, une page cachée n'est pas lue). Décision 0009 : un parcours `IAccessible` direct dépasse le budget d'un facteur 6.
- [ ] Un élément MSAA a pour clé le RuntimeId que lui donne le proxy, dérivé de l'identifiant unique de Firefox ; tant que le document ne change pas, son ID reste le même (FR-05).
- [ ] Un élément à l'état `STATE_SYSTEM_PROTECTED` est traité comme un mot de passe : sa valeur n'est jamais lue ni affichée, et son rectangle est noirci dans les captures.
- [ ] `ui_act` `invoke` sur un élément MSAA appelle `accDoDefaultAction` (par `LegacyIAccessiblePattern.DoDefaultAction`) ; `set_value` renvoie « Action set_value indisponible sur cet élément Firefox : clique puis utilise type ».
- [ ] Étant donné un Firefox sans arbre d'accessibilité (`accessibility.force_disabled`), alors `ui_tree` renvoie « Firefox n'expose pas son arbre d'accessibilité : vérifie accessibility.force_disabled ou utilise screenshot ».
- [ ] Un scénario de bench `firefox` tient < 150 ms p95, de même que `firefox-msaa` (UIA natif coupé, proxy MSAA) ; il échoue avec « Firefox absent de la machine » s'il n'est pas installé, sans fausser les autres scénarios.

---

### EP-006: Fenêtres et applications

Donner à l'agent le lancement d'applications, l'ouverture de documents et le rangement de fenêtres, sans shell et sous la politique.

**Definition of Done:** `app_launch` ouvre la Calculatrice et un document texte, `window_set` place le Bloc-notes sur la moitié gauche d'un écran puis le ferme, et `window_list` liste les écrans. Chaque refus de sécurité a un test.

#### US-026: Écrans et bureaux virtuels dans `window_list`
**Description:** En tant que Claude Code, je veux connaître les écrans et savoir quelles fenêtres sont sur un autre bureau virtuel afin de choisir l'écran d'une capture ou d'un placement sans deviner.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] La sortie de `window_list` commence par une ligne par écran : `display=<n>`, `primary` s'il l'est, taille physique, taille du screenshot, échelle, DPI effectif et zone de travail dans l'espace screenshot.
- [ ] Une fenêtre d'un autre bureau virtuel, détectée par `IVirtualDesktopManager.IsWindowOnCurrentVirtualDesktop`, porte le drapeau `other-desktop` au lieu de `cloaked`, et n'apparaît qu'avec `include_hidden`.
- [ ] Étant donné `IVirtualDesktopManager` indisponible (Explorer redémarré), alors les fenêtres gardent le drapeau `cloaked`, sans erreur.
- [ ] La sortie reste ≤ 8 000 caractères ; les lignes d'écrans ne sont jamais tronquées.
- [ ] Le scénario de bench `window_list` reste ≤ 110 % de la baseline.

#### US-027: `window_set`, placement, état et fermeture d'une fenêtre
**Description:** En tant que Claude Code, je veux déplacer, redimensionner, réduire, agrandir ou fermer une fenêtre par son handle afin de préparer l'écran d'une tâche sans glisser à la souris.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020

**Acceptance Criteria:**
- [ ] L'outil `window_set` prend `window` (handle de `window_list`), et optionnellement `rect` (`[x, y, w, h]` dans l'espace screenshot de `display`, ou de l'écran actuel de la fenêtre), `display`, `state` (`normal`, `minimized`, `maximized`, `closed`), `force` (booléen), `observe` et `settle_timeout_ms`.
- [ ] `rect` place le cadre visible (`DWMWA_EXTENDED_FRAME_BOUNDS`) au rectangle demandé, à 2 pixels screenshot près ; une fenêtre agrandie est d'abord restaurée ; la réponse donne le rectangle obtenu.
- [ ] `state: closed` envoie `WM_SYSCOMMAND` / `SC_CLOSE` et attend jusqu'à 2 s ; si un dialogue apparaît (enregistrer ?), l'outil réussit et l'observation montre le dialogue.
- [ ] `force: true` avec `state: closed` termine le processus de la fenêtre s'il est encore vivant après 2 s ; il exige le niveau `full`, et refuse le processus de neo-compute, ses ancêtres (dont Claude Code), `explorer.exe`, `csrss.exe`, `winlogon.exe`, `lsass.exe` et `services.exe` avec « Fermeture forcée refusée : <exe> est protégé ».
- [ ] Déplacer, redimensionner, changer l'état ou fermer sans `force` exige le niveau `click` de l'application de la fenêtre.
- [ ] Étant donné un `rect` hors de l'écran, alors aucune action n'est faite et le message est « Rectangle hors écran : bornes valides 0..<w-1> x 0..<h-1> ».
- [ ] Étant donné une fenêtre élevée, alors le message est celui de l'Edge Case 5 du PRD neo-compute (UIPI).
- [ ] Étant donné un handle fermé entre `window_list` et `window_set`, alors le message est « Fenêtre fermée : rappelle window_list ».
- [ ] L'audit enregistre l'état demandé et, pour `force`, le pid et l'exe terminés.

#### US-028: Catalogue des applications et appariement approximatif
**Description:** En tant que Claude Code, je veux désigner une application par son nom, en français ou en anglais et avec une faute d'une lettre au plus, afin de la lancer sans connaître son chemin ni son AUMID.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Le backend énumère `FOLDERID_AppsFolder` (`SHGetKnownFolderItem`, `IEnumShellItems`, `PKEY_AppUserModel_ID`) sur un thread STA dédié, et produit pour chaque entrée un nom affiché, un AUMID et un indicateur d'empaquetage.
- [ ] Le catalogue est mis en cache pour la session ; une recherche sans résultat relance une énumération, une seule fois par minute au plus.
- [ ] L'appariement vit dans `src/core/` : insensible à la casse et aux accents, préfixes de mots, puis score de similarité ; un AUMID exact court-circuite l'appariement.
- [ ] Étant donné deux candidats dont les scores diffèrent de moins de 5 %, alors l'erreur liste au plus 5 noms : « Plusieurs applications correspondent à « <nom> » : <a>, <b>… ; précise le nom ».
- [ ] Étant donné aucun candidat au-dessus du seuil, alors l'erreur est « Aucune application « <nom> » dans le menu Démarrer : vérifie le nom ou passe un AUMID ».
- [ ] Les tests du cœur couvrent un catalogue de fixture (« Calculatrice », « Paramètres », « Visual Studio Code », « Bloc-notes »), des fautes d'une lettre, les accents et l'ambiguïté.
- [ ] La première énumération tient < 300 ms et un appariement en cache < 1 ms (A13), mesurés par un scénario de bench `apps`.

#### US-029: `app_launch`, lancement d'applications et ouverture de documents
**Description:** En tant que Claude Code, je veux lancer une application du menu Démarrer ou ouvrir un document par son application par défaut afin d'obtenir directement le handle de la fenêtre et son arbre.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-020, US-021, US-028

**Acceptance Criteria:**
- [ ] L'outil `app_launch` prend exactement un de `name` (nom ou AUMID) et `path` (document ou dossier), plus `observe` et `settle_timeout_ms` ; les deux ou aucun renvoient « Passe soit name, soit path ».
- [ ] Une application empaquetée est lancée par `IApplicationActivationManager::ActivateApplication`, qui donne le pid ; une application non empaquetée par `ShellExecuteExW` sur `shell:AppsFolder\<AUMID>` avec `SEE_MASK_NOCLOSEPROCESS` et `SEE_MASK_FLAG_NO_UI`.
- [ ] La fenêtre lancée est identifiée par son pid quand il est connu, sinon par la première fenêtre de premier niveau nouvelle dans les 10 s ; l'attente est annulable (`notifications/cancelled`, kill switch).
- [ ] Si l'application était déjà ouverte et que Windows active sa fenêtre existante, l'outil renvoie cette fenêtre.
- [ ] La réponse donne `0x<handle> "<titre>" <exe> pid=<n>`, puis l'observation de la nouvelle fenêtre (arbre complet par défaut).
- [ ] `path` doit désigner un fichier ou un dossier existant. Il refuse les extensions de `PATHEXT` et une liste versionnée (`.lnk`, `.url`, `.scf`, `.ps1`, `.psm1`, `.vbs`, `.vbe`, `.js`, `.jse`, `.wsf`, `.wsh`, `.hta`, `.msi`, `.msp`, `.appref-ms`, `.cpl`, `.scr`, `.reg`, `.application`), ainsi que tout URI (`scheme:`), avec « app_launch n'ouvre que des documents et des dossiers : <ext> refusé ».
- [ ] Une application dont l'exe est connu avant le lancement et classé `deny` n'est pas lancée ; si la fenêtre obtenue appartient à une application `deny`, elle reste masquée et la réponse est « Politique : <app> est en mode deny ».
- [ ] `system.app_launch: deny` refuse l'outil (US-021) ; en pause ou dans une seconde instance, l'outil est refusé comme toute action.
- [ ] Étant donné un lancement refusé par Windows, alors « Lancement de <app> refusé par Windows (0x<hresult>) : vérifie que l'application est installée » ; étant donné aucune fenêtre après 10 s, alors « <app> lancée (pid <n>) mais aucune fenêtre après 10 s : rappelle window_list ».
- [ ] L'audit enregistre l'AUMID ou l'extension du document, jamais le chemin complet d'un document.

---

### EP-007: Attente et ancrage visuel

Remplacer les attentes fixes par une attente sur condition, relier l'image aux IDs, et garder une capture quand DXGI fait défaut.

**Definition of Done:** `ui_find` avec `wait_ms` rend la main dans les 100 ms qui suivent l'apparition de l'élément. `ui_tree` avec `marks` renvoie une image dont chaque marque est un ID valide pour `ui_act`. La capture GDI fonctionne quand DXGI est forcé indisponible.

#### US-030: `ui_find` avec `wait_ms`
**Description:** En tant que Claude Code, je veux attendre qu'un élément apparaisse en un seul appel afin de ne plus enchaîner `wait` et `ui_find`.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020

**Acceptance Criteria:**
- [ ] `ui_find` accepte `wait_ms` optionnel (0 à 30 000, défaut 0) ; à 0, le comportement actuel est inchangé.
- [ ] Avec `wait_ms > 0`, la recherche est relancée seulement après un dirty rect DXGI, un déplacement de fenêtre ou une nouvelle fenêtre de premier niveau, au plus une fois toutes les 100 ms, et au moins une fois toutes les 1 000 ms.
- [ ] Dès qu'au moins un élément correspond, l'outil renvoie les lignes habituelles (20 au plus) précédées de `found after <n> ms`.
- [ ] Étant donné aucun résultat à l'échéance, alors `isError: true` « Aucun élément « <requête> » après <n> ms : vérifie la requête ou augmente wait_ms ».
- [ ] L'attente s'arrête au prochain point de contrôle sur `notifications/cancelled` et ne compte pas comme une action : elle reste permise en pause, comme `wait`.
- [ ] Pendant l'attente, le processus consomme < 5 % d'un cœur, mesuré par le selftest sur 5 s d'attente sans changement.
- [ ] Le selftest vérifie qu'un bouton créé 800 ms après l'appel est trouvé en moins de 900 ms.

#### US-031: IDs dessinés sur l'image (`ui_tree` `marks`)
**Description:** En tant que Claude Code, je veux une image de la fenêtre où chaque élément actionnable porte son ID afin de relier ce que je vois à un ID utilisable par `ui_act`.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020

**Acceptance Criteria:**
- [ ] `ui_tree` accepte `marks` optionnel (booléen, défaut `false`) ; avec `marks: true`, le résultat contient l'arbre texte et un JPEG de l'écran de la racine, au format et à l'échelle de `screenshot` (FR-17).
- [ ] Chaque élément qui a au moins une action reçoit une étiquette avec son ID (`e12`), dessinée par une police bitmap du cœur (chiffres et lettres minuscules) dans un cadre contrasté, au coin supérieur gauche de son rectangle.
- [ ] Une étiquette qui recouvrirait de plus de 50 % une étiquette déjà dessinée est décalée d'une ligne, ou omise si aucun emplacement n'est libre ; 150 étiquettes au plus.
- [ ] Le masquage des mots de passe et des applications `deny` est appliqué avant le dessin des étiquettes.
- [ ] Les coordonnées de l'image sont celles de `screenshot` : `zoom` sur la dernière image fonctionne.
- [ ] Le surcoût de `marks` par rapport à `screenshot` est < 8 ms p95, mesuré par un scénario de bench.
- [ ] Étant donné une racine sans élément actionnable, alors l'image est renvoyée sans étiquette avec la note « Aucun élément actionnable à marquer ».

#### US-032: Capture de repli par GDI
**Description:** En tant qu'Arthur, je veux que `screenshot` fonctionne quand la duplication DXGI est refusée afin que l'agent garde la vue sur une session où DXGI échoue.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Quand la duplication échoue avec `DXGI_ERROR_UNSUPPORTED`, ou que sa recréation échoue après `DXGI_ERROR_ACCESS_LOST`, la capture passe par `BitBlt` (`CAPTUREBLT`) de l'écran vers une DIB section, puis suit le même pipeline (masquage, réduction, JPEG).
- [ ] Sans dirty rects, la stabilisation compare l'empreinte de deux images réduites successives à 50 ms d'intervalle ; deux empreintes égales valent « stable ».
- [ ] Le drapeau `--capture gdi` force ce chemin pour le selftest et le bench ; le scénario `capture-gdi` tient < 40 ms p95 en 2560x1440.
- [ ] Étant donné un bureau sécurisé, alors le refus existant (Edge Case 7) s'applique aussi au chemin GDI.
- [ ] La réponse de `screenshot` en mode GDI porte la note « Capture GDI : les fenêtres protégées contre la capture apparaissent en noir ».

---

### EP-008: Contrôle humain visible

Montrer à Arthur quand l'agent agit, sans bloquer ses entrées physiques.

**Definition of Done:** la sonde de US-033 a tranché A8 dans `docs/decisions/`. L'indicateur s'affiche pendant les actions, n'apparaît dans aucune capture de neo-compute et n'ajoute aucune latence mesurable aux hooks.

#### US-033: Validate assumption: `WDA_EXCLUDEFROMCAPTURE` masque une fenêtre de DXGI et de GDI
**Description:** En tant qu'Arthur, je veux savoir si une fenêtre exclue de la capture reste invisible pour la duplication DXGI et pour GDI, et si elle perturbe la stabilisation, afin de choisir la conception de l'indicateur sur une mesure.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Le selftest crée une fenêtre layered, topmost et transparente aux clics, de couleur unie, avec `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`, au-dessus de la fenêtre de test.
- [ ] Il capture la zone par DXGI puis par GDI et vérifie, pour chacun, si la couleur de la fenêtre est absente des pixels.
- [ ] Il anime la fenêtre à 30 Hz pendant 1 s et compte les dirty rects DXGI produits dans sa zone.
- [ ] Étant donné un échec de `SetWindowDisplayAffinity`, alors le selftest le signale avec le code d'erreur, sans échouer les autres vérifications.
- [ ] Le résultat (masquée ou non pour chaque capture, nombre de dirty rects) et la conception retenue pour US-034 sont consignés dans `docs/decisions/` (prochain numéro).

#### US-034: Indicateur « agent aux commandes »
**Description:** En tant qu'Arthur, je veux voir un cadre de 4 px et une étiquette quand l'agent agit ou que le serveur est en pause afin de savoir à tout moment si je peux toucher la souris.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-033

**Acceptance Criteria:**
- [ ] Un thread dédié possède une fenêtre layered par écran (`WS_EX_LAYERED`, `WS_EX_TRANSPARENT`, `WS_EX_TOPMOST`, `WS_EX_TOOLWINDOW`, `WS_EX_NOACTIVATE`) : un cadre de 4 px et une étiquette « neo-compute is acting: Esc pauses » pendant une action et sa stabilisation, puis 1 s après.
- [ ] En pause (kill switch), l'étiquette devient « neo-compute paused: Ctrl+Alt+Shift+R resumes » et reste affichée jusqu'au réarmement.
- [ ] Les fenêtres de l'indicateur n'apparaissent dans aucune capture de neo-compute : par `WDA_EXCLUDEFROMCAPTURE` si US-033 l'a validé, sinon parce qu'elles sont masquées avant chaque capture et réaffichées après.
- [ ] Si US-033 a montré que l'animation produit des dirty rects, l'indicateur reste statique pendant la stabilisation.
- [ ] Les fenêtres de l'indicateur sont absentes de `window_list`, de la résolution de fenêtre sous un point, de la politique et de `ui_tree`.
- [ ] Les hooks gardent < 1 ms de latence par événement (US-018) ; un changement d'état de l'indicateur coûte < 2 ms au thread appelant.
- [ ] Le drapeau `--no-indicator` le désactive ; un échec de création de l'indicateur est journalisé sur stderr et ne bloque aucun outil.

---

### EP-009: Presse-papiers et registre

Lire et écrire le presse-papiers et lire le registre sans exposer de secret.

**Definition of Done:** `clipboard` refuse un contenu marqué secret par chacun des formats listés, et `registry_read` masque une valeur nommée `Password`. Les deux outils respectent la section `system` et l'audit ne contient aucun contenu.

#### US-035: `clipboard`, lecture et écriture de texte
**Description:** En tant que Claude Code, je veux lire et écrire le texte du presse-papiers afin de transférer un contenu entre applications sans le retaper, sans jamais lire un secret.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020, US-021

**Acceptance Criteria:**
- [ ] L'outil `clipboard` prend `mode` (`get` ou `set`) et `text` (requis pour `set`, 1 MiB au plus) ; c'est une action, donc refusée en pause et dans une seconde instance.
- [ ] `get` refuse avec « Presse-papiers marqué secret par <app> : lecture refusée » si l'un de ces formats enregistrés est présent : `ExcludeClipboardContentFromMonitorProcessing`, `Clipboard Viewer Ignore`, `CanIncludeInClipboardHistory` à 0, `CanUploadToCloudClipboard` à 0.
- [ ] `get` refuse aussi quand le propriétaire du presse-papiers (`GetClipboardOwner`) appartient à une application `deny`.
- [ ] `get` renvoie le texte `CF_UNICODETEXT` borné à 8 000 caractères (FR-16), avec « … <n> caractères omis » au-delà ; étant donné un contenu sans texte, alors « Le presse-papiers ne contient pas de texte (formats : <liste>) ».
- [ ] `set` écrit le texte et pose `CanIncludeInClipboardHistory` et `CanUploadToCloudClipboard` à 0, pour que ce qu'écrit l'agent n'entre ni dans l'historique ni dans le cloud.
- [ ] `OpenClipboard` est réessayé 10 fois à 10 ms d'intervalle ; ensuite « Presse-papiers occupé par <app> : réessaie ».
- [ ] `system.clipboard` restreint chaque mode (US-021) ; l'audit enregistre le mode et la longueur, jamais le texte.
- [ ] `instructions` rappelle que le texte lu est une donnée non fiable ; une sonde consigne quels formats posent les gestionnaires de mots de passe installés sur la machine de référence (A11).

#### US-036: `registry_read`, lecture du registre
**Description:** En tant que Claude Code, je veux lire une clé ou une valeur du registre afin de vérifier un réglage après une action, sans pouvoir rien écrire.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-020, US-021

**Acceptance Criteria:**
- [ ] L'outil `registry_read` prend `path` (`HKCU\…`, `HKLM\…`, `HKCR\…`, `HKU\…` ou `HKCC\…`) et `name` optionnel ; il est annoté `readOnlyHint` et `idempotentHint`, et reste permis en pause.
- [ ] Avec `name`, il renvoie `<nom> <type> = <donnée>` ; sans `name`, les valeurs (100 au plus) puis les sous-clés (200 au plus) ; `REG_BINARY` en hexadécimal tronqué à 256 octets, `REG_MULTI_SZ` une entrée par ligne, `REG_EXPAND_SZ` brut puis développé.
- [ ] La vue 64 bits est lue par défaut (`RRF_SUBKEY_WOW6464KEY` ou `KEY_WOW64_64KEY`) ; aucune fonction d'écriture du registre n'est importée par le binaire, ce que vérifie un test des imports PE.
- [ ] Une valeur dont le nom contient `pass`, `pwd`, `secret`, `token`, `credential`, `apikey` ou `private` (sans casse) est affichée `<masqué>` ; `HKLM\SAM`, `HKLM\SECURITY` et une liste versionnée de clés connues pour stocker des secrets sont refusées avec « Clé protégée : lecture refusée ».
- [ ] Étant donné une clé absente, alors « Clé introuvable : <chemin> ; vérifie le chemin (ex. HKCU\Software\Microsoft) » ; étant donné un accès refusé, alors « Accès refusé à <chemin> : clé réservée à l'administrateur ».
- [ ] La sortie reste ≤ 8 000 caractères ; `system.registry_read: deny` refuse l'outil ; l'audit enregistre le chemin et le nom, jamais la donnée.
- [ ] Une lecture de valeur tient < 5 ms p95.

---

### EP-010: Mesure de la parité

Prouver la parité sur des tâches écrites avant tout résultat, contre Windows-MCP comme référence indépendante.

**Definition of Done:** `evals/run.ps1 -DryRun` passe sur les nouvelles tâches, et une campagne approuvée par Arthur a produit son rapport dans `evals/reports/` avec les conclusions sur les Success Metrics.

#### US-037: Tâches d'évals de parité
**Description:** En tant qu'Arthur, je veux des tâches qui exercent les capacités de ce PRD, écrites avant toute mesure, afin de comparer neo-compute et Windows-MCP sans biais.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-023, US-027, US-029, US-030, US-035

**Acceptance Criteria:**
- [ ] Au moins 8 tâches nouvelles, chacune avec préparation scriptée, vérification de l'état final et nettoyage : menu contextuel du Bloc-notes, lancement de la Calculatrice par son nom, placement de deux fenêtres côte à côte, copie d'un texte d'une application à une autre, attente d'un dialogue apparu après un délai, lecture d'un réglage du registre, lecture d'un article web, et Firefox si installé.
- [ ] Une tâche canari place dans le presse-papiers une valeur aléatoire marquée `ExcludeClipboardContentFromMonitorProcessing`, et vérifie qu'elle n'apparaît ni dans les résultats d'outils ni dans l'audit.
- [ ] Les consignes ne nomment aucun outil, pour rester valables dans les trois modes (a11y, vision, windows-mcp).
- [ ] Étant donné une application absente (Firefox), alors la tâche est marquée `skipped` avec sa raison, sans compter comme un échec.
- [ ] Les tâches sont commitées avant la première exécution réelle ; leur commit précède tout fichier de `evals/results/` qui les mesure.

#### US-038: Campagne de parité
**Description:** En tant qu'Arthur, je veux une campagne mesurée sur les tâches de parité afin de décider sur des chiffres si neo-compute remplace Windows-MCP pour ces usages.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-037

**Acceptance Criteria:**
- [ ] La campagne ne démarre qu'après l'accord écrit d'Arthur sur son budget (tâches × répétitions × modes).
- [ ] Elle couvre les tâches de US-037 et les 20 tâches existantes, en modes a11y, vision et windows-mcp, avec `--model claude-opus-5-5` et 3 répétitions.
- [ ] `evals/report.ps1` produit `evals/reports/<date>.md` avec réussite, appels d'outils, tokens et durée par mode et par tâche, et conclut sur chaque ligne des Success Metrics.
- [ ] Étant donné une régression de plus de 5 points sur les 20 tâches existantes en mode a11y, alors le rapport la signale en tête et ouvre une story de correction.
- [ ] Le rapport confirme 0 fuite sur les tâches canari (mots de passe et presse-papiers).

## Functional Requirements

- FR-21: Le système doit exposer, en plus de FR-01 et FR-02, les outils `window_set`, `app_launch`, `clipboard` et `registry_read` (amende FR-02).
- FR-22: Les outils ajoutés par ce PRD ne portent pas `anthropic/alwaysLoad` ; les définitions des outils `alwaysLoad` restent ≤ 1 500 tokens estimés et l'ensemble ≤ 4 500.
- FR-23: `ui_tree` doit accepter `text` et `marks`, `ui_find` doit accepter `wait_ms`, tous optionnels ; sans eux, la sortie est identique à celle d'avant ce PRD.
- FR-24: Un snapshot sans `window` doit inclure comme racines les fenêtres possédées, les menus et les popups du processus au premier plan.
- FR-25: `app_launch` ne doit lancer que des applications du menu Démarrer et n'ouvrir que des documents ou des dossiers ; il refuse exécutables, scripts, raccourcis et URI.
- FR-26: `clipboard` ne doit jamais renvoyer un contenu marqué secret par un format presse-papiers listé en US-035 ou posé par une application `deny`.
- FR-27: `registry_read` ne doit jamais écrire dans le registre et masque toute valeur dont le nom évoque un secret.
- FR-28: Les outils sans fenêtre cible sont soumis à la section `system` de la politique ; ceux qui visent une fenêtre, au niveau de son application.
- FR-29: L'audit de `clipboard`, `registry_read` et `app_launch` ne contient ni texte du presse-papiers, ni donnée du registre, ni chemin complet de document.
- FR-30: L'indicateur de contrôle ne doit ni bloquer, ni retarder de plus de 1 ms, ni consommer une entrée physique.

## Non-Functional Requirements

- **Performance:**
  - `ui_tree` sur une app native (≤ 400 nœuds, propriétés et racines nouvelles comprises) : p95 < 50 ms et ≤ 110 % de la baseline ; seconde requête de cache ≤ 5 ms p95.
  - `ui_tree` `text: true` sur Chromium < 120 ms p95 ; Firefox par MSAA < 150 ms p95.
  - `window_set` hors stabilisation < 20 ms p95.
  - Catalogue : première énumération < 300 ms, appariement < 1 ms.
  - `app_launch` : surcoût serveur < 50 ms au-delà du démarrage de l'application.
  - `ui_find` `wait_ms` : réaction < 100 ms après l'apparition de l'élément, < 5 % d'un cœur pendant l'attente.
  - `marks` < 8 ms p95 au-delà de `screenshot` ; capture GDI < 40 ms p95 en 2560x1440 ; `clipboard` < 10 ms ; `registry_read` < 5 ms p95.
- **Footprint:** binaire ReleaseFast strippé ≤ 3 MB ; RSS au repos < 15 MB ; 0 allocation du GPA par requête en régime établi sur `ui_tree` delta, `window_set` et `registry_read`.
- **Security:** 0 connexion réseau (test des imports PE inchangé) ; 0 fonction d'écriture du registre importée ; 0 fuite sur les tâches canari ; 100 % des extensions de la liste de refus de `app_launch` couvertes par un test ; `force` refuse 100 % des processus protégés listés en US-027.
- **Accessibility:** l'indicateur ne prend jamais le focus et laisse passer les clics (`WS_EX_TRANSPARENT`) ; Narrateur et NVDA fonctionnent pendant son affichage, vérifié une fois par version publiée.
- **Reliability:** un menu ou popup qui se ferme pendant un snapshot ne provoque aucun crash sur 1 000 itérations du scénario `notepad-menu` ; dérive < 5 MB de private bytes et 0 handle sur 10 000 appels de `clipboard`, `registry_read` et d'appariement du catalogue.

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | Menu fermé avant l'action | Le menu contextuel se ferme entre `ui_tree` et `ui_act` | Aucune action | « Élément <id> introuvable : rappelle ui_tree » |
| 2 | Popup sur un autre écran | Un popup s'ouvre sur l'écran 2, la fenêtre est sur l'écran 1 | Racine mappée sur son écran, `display=` dans son en-tête | Aucun |
| 3 | Nom d'application ambigu | `app_launch` `name: "code"` | Aucun lancement, candidats listés | « Plusieurs applications correspondent à « code » : … ; précise le nom » |
| 4 | Application déjà ouverte | `app_launch` de la Calculatrice ouverte | Fenêtre existante renvoyée | Aucun |
| 5 | Aucune fenêtre après lancement | Application sans fenêtre dans les 10 s | Échec après 10 s, pid donné | « <app> lancée (pid <n>) mais aucune fenêtre après 10 s : rappelle window_list » |
| 6 | Document exécutable | `app_launch` `path` vers `.ps1`, `.lnk`, `.exe` ou un URI | Refus avant tout appel shell | « app_launch n'ouvre que des documents et des dossiers : <ext> refusé » |
| 7 | Fermeture avec document non enregistré | `window_set` `state: closed` | Le dialogue d'enregistrement apparaît dans l'observation | Aucun |
| 8 | Fermeture forcée protégée | `force` sur Claude Code, Explorer ou un processus système | Refus | « Fermeture forcée refusée : <exe> est protégé » |
| 9 | Rectangle hors écran | `rect` au-delà des bornes du screenshot | Aucune action | « Rectangle hors écran : bornes valides 0..1279 x 0..719 » |
| 10 | Attente expirée | `ui_find` `wait_ms` sans résultat | `isError: true` à l'échéance | « Aucun élément « <requête> » après <n> ms : vérifie la requête ou augmente wait_ms » |
| 11 | Attente annulée | `notifications/cancelled` ou kill switch pendant `wait_ms` | Arrêt au prochain point de contrôle, aucune réponse pour la requête annulée | Aucun |
| 12 | Presse-papiers secret | Contenu copié par un gestionnaire de mots de passe | Lecture refusée | « Presse-papiers marqué secret par <app> : lecture refusée » |
| 13 | Presse-papiers occupé | Une application garde `OpenClipboard` | 10 essais à 10 ms, puis échec | « Presse-papiers occupé par <app> : réessaie » |
| 14 | Presse-papiers sans texte | Image ou fichiers copiés | Pas de contenu renvoyé | « Le presse-papiers ne contient pas de texte (formats : <liste>) » |
| 15 | Valeur de registre sensible | Valeur nommée `Password` ou clé de la liste de refus | Donnée masquée ou clé refusée | `<masqué>` ou « Clé protégée : lecture refusée » |
| 16 | Firefox sans accessibilité | `accessibility.force_disabled` actif | Arbre indisponible | « Firefox n'expose pas son arbre d'accessibilité : vérifie accessibility.force_disabled ou utilise screenshot » |
| 17 | DXGI indisponible | `DXGI_ERROR_UNSUPPORTED` ou recréation impossible | Capture GDI, stabilisation par empreinte | « Capture GDI : les fenêtres protégées contre la capture apparaissent en noir » |
| 18 | Indicateur visible en capture | `WDA_EXCLUDEFROMCAPTURE` inopérant (US-033) | Indicateur masqué avant chaque capture | Aucun |
| 19 | Pause pendant une action nouvelle | Kill switch puis `app_launch`, `window_set` ou `clipboard` | Refus comme toute action ; `registry_read` et `ui_find` restent permis | « En pause par l'utilisateur : attends qu'Arthur réarme » |
| 20 | Outil coupé par la politique | `system.clipboard: off` | Refus | « Politique : clipboard est désactivé (system.clipboard dans policy.json) » |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Les nouveaux outils dépassent le budget de 3 000 tokens (2 934 utilisés) | High | Med | Deux plafonds en US-020, outils nouveaux différés, A12 rappelée en Assumptions |
| 2 | Plusieurs racines cassent l'hypothèse « élément 0 = fenêtre » du diff, des IDs et du mapping d'écran | Med | High | Story L dédiée (US-023), tests du cœur sur le backend factice avant le backend, scénario `notepad-menu` |
| 3 | La seconde requête de cache dépasse le budget de 50 ms sur les gros arbres | Med | Med | Condition OR ciblée, mesure A7, champs omis sur timeout plutôt qu'arbre bloqué |
| 4 | `WDA_EXCLUDEFROMCAPTURE` inopérant pour DXGI, ou animation qui empêche la stabilisation | Med | Med | Spike US-033 avant l'indicateur, repli par masquage pendant la capture |
| 5 | Chemin MSAA de Firefox lent, ou IDs instables sans runtime id | Med | Med | P1, clés dérivées du chemin, sonde A9 ; l'UIA natif est prioritaire dès qu'il est actif |
| 6 | Fenêtre lancée mal identifiée quand `hProcess` est NULL et qu'une autre fenêtre s'ouvre en même temps | Med | Low | pid d'abord, puis fenêtre nouvelle appariée au nom de l'application ; A10 mesurée |
| 7 | La surface COM grandit (shell, oleacc, TextPattern) et fait apparaître des défauts de la couche Zig | Med | High | Bindings générés uniquement ; chaque défaut compté pour la condition 3 du Rust Switch Gate ; arrêt et rapport à Arthur si elle devient vraie |
| 8 | Un gestionnaire de mots de passe ne pose aucun format de secret (Bitwarden selon un fil de forum) | Med | High | Refus aussi quand le propriétaire est `deny`, liste des gestionnaires en `deny` par défaut (US-017), sonde A11 ; risque résiduel accepté et documenté |
| 9 | `registry_read` expose un secret stocké par une application | Med | Med | Masquage par nom de valeur, liste de clés refusées, audit sans donnée |
| 10 | `app_launch` détourné pour exécuter un script | Low | High | Liste de refus testée, `PATHEXT`, aucun URI, aucun argument de ligne de commande |
| 11 | Coût de la campagne d'évals sur l'abonnement | Med | Low | Campagne soumise à l'accord d'Arthur (US-038), DryRun d'abord |
| 12 | Un ancien binaire rejette une politique qui contient `system` | Low | Low | Repli `observe` global déjà défini ; un seul utilisateur, binaire et politique livrés ensemble |

## Non-Goals

What this version explicitly does NOT include:

- **Outil PowerShell ou shell :** FR-11 inchangé ; Claude Code fournit déjà un shell avec ses permissions et son sandbox (décision 0008).
- **Fetch HTTP (Scrape réseau) :** FR-10 inchangé ; WebFetch existe côté Claude Code, et `ui_tree` `text` couvre les pages ouvertes.
- **Opérations de fichiers (lire, écrire, copier, supprimer) :** Read, Write et Edit de Claude Code gardent leurs permissions par chemin et leurs checkpoints.
- **Outil générique de processus et `launch_executable` :** la fermeture passe par `window_set`, le lancement par le menu Démarrer.
- **Écriture et suppression dans le registre.**
- **Notifications Windows :** WinRT est absent de `Windows.Win32.winmd` ; à revisiter avec une extension du générateur.
- **Blocage des entrées physiques pendant les actions :** l'humain garde la priorité (FR-12, décision 0008).
- **Création, suppression ou changement de bureau virtuel :** les interfaces internes ne sont pas documentées, absentes de win32metadata, et exigeraient des vtables écrites à la main.
- **Attente de disparition et attente pilotée par les événements UIA :** à revisiter si US-038 montre plus de 2 appels `ui_find` par attente.
- **URI de réglages (`ms-settings:`) dans `app_launch` :** refusés avec tout URI en v1 ; voir Open Questions.
- **Compatibilité avec les noms d'outils de Windows-MCP, transports HTTP, télémétrie, sampling MCP.**

## Files NOT to Modify

- `tests/fixtures/toolset_20260801.json` et les 17 structs du toolset dans `src/core/tools.zig` : contrat externe d'Anthropic.
- `bench/baseline.json`, sauf l'ajout de scénarios nouveaux (`--write-baseline` réservé à ces scénarios).
- L'écriture sur stdout et l'ordre du dispatcher dans `src/core/mcp.zig` ; seule la fonction `record` de l'audit peut être étendue pour la rédaction des outils nouveaux.
- La liste `properties` du cache principal dans `src/backend/windows/uia.zig` (12 propriétés, US-011).
- Le fichier `win32.zig` généré : ajouter les API dans `bindings/windows.zon`.
- `docs/decisions/0001` à `0008`, sauf le compteur de la condition 3 dans `0001-zig-vs-rust.md`.
- `C:/dev/ghostty` et `C:/dev/Windows-MCP` : références en lecture seule.

## Technical Considerations

Frame as questions for engineering input, not mandates:

- **Architecture des racines :** une liste de racines dans un seul `Snapshot`, avec des plages d'éléments par racine, ou un snapshot par racine fusionné dans le cœur ? Recommandé : une liste dans un seul `Snapshot`, pour garder un seul magasin d'IDs et un seul diff par fenêtre au premier plan. Engineering to confirm feasibility.
- **Drapeau modal :** élargir `States` à 16 bits ou porter `modal` sur la racine ? Recommandé : sur la racine, car une modale est une propriété de fenêtre et `States` est plein.
- **Threads :** le catalogue tourne-t-il sur un thread STA dédié créé au premier usage, ou sur le worker UIA en MTA ? Recommandé : STA dédié, les dossiers shell pouvant exiger un STA ; à confirmer par la mesure A13.
- **Appariement :** préfixes de mots et Jaro-Winkler sur des noms normalisés, ou trigrammes ? Recommandé : préfixes puis Jaro-Winkler, plus lisible et testable dans le cœur.
- **Police de `marks` :** bitmap 5x7 dans le cœur, ou texte GDI dans le backend ? Recommandé : bitmap dans le cœur, portable et testable sans Windows.
- **Stabilisation sans DXGI :** empreinte d'image réduite toutes les 50 ms, ou attente fixe ? Recommandé : empreinte, pour garder une stabilisation mesurée.
- **Bindings :** `IAccessible` et `AccessibleObjectFromWindow` (`Windows.Win32.UI.Accessibility`), `IApplicationActivationManager`, `IShellItem2` et `IVirtualDesktopManager` (`Windows.Win32.UI.Shell`) sont-ils tous générés sans `dll_aliases` nouveaux ? À vérifier au premier `zig build` de chaque story.
- **Format de politique :** une section `system` plate, ou des niveaux par outil dans `apps` ? Recommandé : section `system`, car ces outils n'ont pas d'application cible.
- **Migration :** aucune donnée à migrer ; les sorties nouvelles sont additives et derrière des paramètres optionnels. Retour arrière : désactiver chaque outil par `system` dans la politique.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Outils de Windows-MCP couverts, entièrement ou par composition | 9 sur 21 (décision 0008) | 17 sur 21 (les 4 restants exclus par décision) | Month-1 | Inventaire de la décision 0008 revu à la clôture |
| Réussite sur les tâches de parité, mode a11y | N/A (nouveau) | ≥ 90 %, puis ≥ 95 % | Month-1, Month-6 | Campagne de US-038 |
| Réussite sur les tâches de parité, comparée au mode windows-mcp | Mesurée en US-038 | ≥ windows-mcp, puis + 10 points | Month-1, Month-6 | Campagne de US-038 |
| Appels d'outils médians par tâche de parité, mode a11y | Mode windows-mcp (US-038) | ≤ windows-mcp | Month-1 | Campagne de US-038 |
| Réussite sur les 20 tâches existantes, mode a11y | 100 % (2026-11-03) | ≥ 95 % | Month-1 | Campagne de US-038 |
| Snapshot UIA p95, Bloc-notes | Baseline de `bench/baseline.json` | ≤ 110 % et < 50 ms | Month-1 | `zig build bench -- --check bench/baseline.json` |
| Tokens des définitions `alwaysLoad` | 1 100 estimés | ≤ 1 500 | Month-1 | Test du registre (US-020) |
| Tokens de toutes les définitions | 2 934 estimés | ≤ 4 500 | Month-1 | Test du registre (US-020) |
| Fuites de secret sur les tâches canari | 0 (mots de passe, 2026-11-04) | 0, presse-papiers compris | Month-1 | Vérification de fuite de `evals/run.ps1` |
| Médiane de tokens par delta | 96 (2026-11-03) | ≤ 150 | Month-1 | Rapport de US-038 |

## Open Questions

- **Q6 :** faut-il ouvrir les URI de réglages (`ms-settings:display`, etc.) dans `app_launch` ? Ils raccourcissent les tâches Paramètres, mais font sauter la règle « aucun URI ». Décision d'Arthur avant US-029 ; sans réponse, ils restent refusés.
- **Q7 :** le seuil de 2 s avant `force` dans `window_set` convient-il aux applications qui mettent plus de 2 s à se fermer (VS Code avec extensions) ? À ajuster par Arthur après US-027 sur la mesure.
- **Q8 :** quel budget en exécutions pour la campagne de US-038 (environ 28 tâches × 3 répétitions × 3 modes, soit 252 exécutions) ? Décision d'Arthur avant US-038.
- **Q9 :** l'indicateur doit-il rester visible pendant toute la session, en plus des actions, pour signaler que le serveur est actif ? Choix d'Arthur après usage de US-034.
[/PRD]
