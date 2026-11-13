[PRD]
# PRD: neo-compute, mode arrière-plan

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-11-12 | Arthur Jean | Version initiale : mode `background` sans interférence, cohabitation avec l'utilisateur, actions sémantiques complètes, perception ciblée, passe visuelle par fenêtre et mesure (EP-011 à EP-016), d'après la recherche `docs/research/2026-11-11-agent-desktop.md` |
| 1.1 | 2026-11-13 | Arthur Jean | Amendement après la revue de EP-012 (décision 0013, « Amendement du 2026-11-13 ») : libellé du mode en anglais (US-046) ; garde de premier plan sur l'événement de premier plan, règle du geste et issues d'audit `third_party`, `same_app`, `unknown` (US-050) ; gestionnaires d'événements UIA côté client admis pour les fenêtres UWP (contrainte levée, US-048) ; A19 séparée entre Chromium et Electron, notes pour US-058 et US-059 |
| 1.2 | 2026-11-13 | Arthur Jean | Garde de premier plan prolongée 2 s après l'action, champ d'audit `guard_late` (US-050) ; abonnement UIA appris pour les applications qui changent sans événement (US-048) ; mesures d'agent-desktop à reprendre dans US-058 |

## Problem Statement

1. **neo-compute prend la machine pendant qu'il agit.** Les 17 outils du toolset passent par `SendInput` (`src/backend/windows/input.zig:13`) : ils déplacent le vrai curseur et écrivent dans la file d'entrée de l'utilisateur. Arthur ne peut pas travailler pendant une passe de l'agent.
2. **Même une action qui ne touche ni la souris ni le clavier bloque la cohabitation.** `ui_act` agit par pattern UI Automation (UIA), mais le kill switch s'arme pour tout outil d'action (`src/core/mcp.zig:457-459`). Un mouvement de souris physique de plus de 8 px ou un Échap physique pendant l'action met le serveur en pause jusqu'au réarmement (`src/core/control.zig:43-50`, `src/backend/windows/hooks.zig:187-214`).
3. **La stabilisation mesure l'écran, pas la fenêtre cible.** Elle attend la fin des changements de pixels dans le rectangle de la cible (`src/core/a11y.zig:600-673`). Quand la cible est recouverte par la fenêtre de l'utilisateur, c'est l'activité de l'utilisateur qui est mesurée, et `ui_find` `wait_ms` se réveille sur les mêmes pixels (`src/core/a11y.zig:413-483`).
4. **Sans `window`, l'agent lit la fenêtre de l'utilisateur.** `ui_tree` et `ui_find` visent la fenêtre au premier plan (`src/backend/windows/uia.zig:366`), et le delta repart d'un arbre complet à chaque changement de premier plan (`src/core/a11y.zig:228`).
5. **Rien n'interdit une action intrusive.** `ui_act` `focus` appelle `SetFocus` (`src/backend/windows/uia.zig:1085`), `fallback: "click"` injecte un vrai clic (`src/core/a11y.zig:573-581`), `app_launch` ouvre en `SW_SHOWNORMAL` (`src/backend/windows/shell.zig:387-403`). Aucun outil ne porte de classe d'interférence (`src/core/registry.zig:20-24`).
6. **Le vocabulaire sémantique est incomplet.** `ui_act` a 8 actions (`src/core/uitree.zig:200`). Il manque l'état final d'une case (cocher sans inverser), le défilement, les valeurs de curseur et la sélection par nom, que agent-desktop couvre avec 11 actions sans interférence.
7. **Une fenêtre recouverte ne peut pas être capturée.** La capture est par écran entier (DXGI, repli GDI) : pas de contrôle visuel d'une fenêtre qui travaille derrière.

**Why now:** (a) Le PRD de parité est implémenté jusqu'à EP-009 : `ui_tree`, `ui_find`, `ui_act`, `window_set` et `app_launch` forment déjà le moteur. (b) agent-desktop 1.2.0 (2026-11-05) prouve le modèle sur Windows par une politique de refus posée sur UIA, et sa sonde A19-1 mesure que les patterns agissent sur une fenêtre non active. (c) OpenAI documente que Codex sur Windows ne sait pas travailler en arrière-plan dans la même session ([Computer Use](https://developers.openai.com/codex/app/computer-use)) : le créneau est ouvert. (d) Cua Driver occupe ce créneau depuis mai 2026 ([blog](https://cua.ai/blog/inside-windows-computer-use)) avec un serveur plus lourd et un repli `PostMessage` que neo-compute n'a pas besoin de reprendre.

## Overview

Ce PRD ajoute un troisième mode serveur, `--mode background`, à côté de `a11y` et `vision`. Dans ce mode, `tools/list` ne contient que des outils classés sans interférence : `ui_tree`, `ui_find`, `ui_act`, `window_list`, `window_set`, `app_launch`, `clipboard`, `registry_read`, `wait`, puis `screenshot` et `zoom` limités à la fenêtre cible (EP-015). Une variante intrusive d'un outil listé (`ui_act` `focus`, `fallback: "click"`, `clipboard` `set`) est refusée avant tout effet, avec un message qui nomme la cause et l'action suivante. Le modèle n'a aucune échappatoire vers l'entrée physique : seul Arthur choisit le mode, au lancement du serveur.

La cohabitation repose sur quatre changements propres à ce mode. Le mouvement de souris et Échap ne déclenchent plus la pause, et le raccourci de réarmement devient une bascule de pause. La stabilisation et les attentes écoutent les WinEvents (notifications d'accessibilité de Windows) du processus cible au lieu des pixels. Les outils sans `window` visent une fenêtre cible de session, jamais le premier plan. Une garde vérifie après chaque action que le premier plan n'a pas été pris, et le rend s'il l'a été.

`ui_act` gagne `check`, `uncheck` et `scroll`, des valeurs numériques sur les curseurs, la sélection par nom, l'attente des préconditions et un verdict de livraison. `ui_tree` lit un sous-arbre, `ui_find` relit un élément. La capture d'une fenêtre recouverte passe par `PrintWindow` si la sonde US-060 la valide.

Décisions de contrat proposées, à confirmer par Arthur dans la décision 0013 (US-039) :

1. Le mode arrière-plan est à activer ; le défaut reste `a11y` jusqu'à la campagne US-063.
2. En mode arrière-plan, la pause se déclenche par le raccourci de réarmement, qui devient une bascule. FR-12 ne change pas.
3. En mode arrière-plan, l'indicateur se réduit à son libellé.
4. `ui_act` reçoit trois actions et étend `value` ; `ui_tree`, `ui_find`, `screenshot` et `zoom` reçoivent des paramètres optionnels.
5. Les modes `a11y` et `vision` gardent leur kill switch, leur indicateur, leur stabilisation et leur liste d'outils.

Périmètre : 6 epics, 25 stories, 72 points, en trois livraisons. Livraison 1 : EP-011 et EP-012 (sans interférence, 36 points). Livraison 2 : EP-013 et EP-014 (parité d'actions et perception, 24 points). Livraison 3 : EP-015 et EP-016 (passe visuelle et mesure, 12 points).

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| Violations de non-interférence (curseur, premier plan, focus clavier, presse-papiers) sur 1 000 actions du selftest d'arrière-plan | 0 | 0 |
| Appels à `SendInput` et à `SetFocus` UIA en mode arrière-plan | 0 | 0 |
| Réussite sur les tâches d'arrière-plan (US-062), fenêtre leurre au premier plan | ≥ 85 % | ≥ 95 % |
| Réussite comparée à agent-desktop 1.2.0 sur les mêmes tâches | ≥ agent-desktop | ≥ agent-desktop + 10 points |
| Réussite sur les 20 tâches existantes, mode a11y | ≥ 95 % | ≥ 95 % |
| Stabilisation d'une action sans effet en mode arrière-plan, p95 | < 150 ms | < 100 ms |

## Target Users

### Arthur (développeur, utilisateur principal)
- **Role:** ingénieur et fondateur, pilote Claude Code au quotidien sous Windows 11 Pro (deux écrans).
- **Behaviors:** délègue des tâches GUI et des passes de vérification visuelle à Claude Code par neo-compute, et veut continuer à coder pendant ce temps.
- **Pain points:** l'agent déplace son curseur et tape dans sa fenêtre ; s'il bouge la souris ou tape Échap, le serveur se met en pause ; un cadre s'affiche sur ses écrans à chaque action.
- **Current workaround:** lâcher la machine pendant la passe, ou installer agent-desktop à côté, qui relance un processus par commande et refuse la saisie de texte en arrière-plan.
- **Success looks like:** une passe de l'agent sur une fenêtre recouverte pendant qu'il tape dans son éditeur, sans un seul mouvement de curseur ni changement de premier plan, et un raccourci pour mettre en pause.

### Claude Code (agent consommateur des outils)
- **Role:** le modèle (Fable 5.2, Opus 5.5 et suivants) qui appelle les outils MCP.
- **Behaviors:** lit l'arbre, agit par ID d'élément, lit le delta après chaque action.
- **Pain points:** ne sait pas quels outils dérangent l'utilisateur ; doit enchaîner `scroll_into_view` puis l'action ; ne sait pas si une action a pris effet ; un `toggle` rejoué inverse l'état.
- **Current workaround:** captures répétées, `left_click` par coordonnées, relecture complète de l'arbre pour vérifier.
- **Success looks like:** une liste d'outils où tout est permis sans gêner, un état final demandé en un appel (`check`), un verdict par action, et une erreur qui dit quoi faire quand l'arrière-plan ne suffit pas.

### Développeurs Claude Code sous Windows (secondaire)
- **Role:** utilisateurs de la CLI qui veulent du computer use sans céder leur session.
- **Behaviors:** utilisent Codex ou Windows-MCP, qui prennent le premier plan, ou Cua Driver.
- **Pain points:** pas de mode arrière-plan dans la même session, ou un serveur lourd à installer.
- **Current workaround:** machine virtuelle dédiée, ou session Bureau à distance.
- **Success looks like:** un binaire unique lancé avec `--mode background`, sans droits administrateur.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **agent-desktop 1.2.0 (exploré le 2026-11-11, commit 54855b62) :**
  - fonctionnement : politique `headless` par défaut (`crates/core/src/actions/interaction_policy.rs:4-47`), 11 actions par pattern UIA, refus `POLICY_DENIED` pour `type`, `press`, `right-click`, `double-click`, `focus`, `hover` et `drag` (`skills/agent-desktop-windows/SKILL.md:35-38`) ;
  - limites : un processus par commande, références ré-identifiées sur disque et contrôles jumeaux refusés, entrées maintenues refusées, fenêtre minimisée non pilotable, arbre Chromium figé quand la fenêtre est recouverte, aucun bac à sable sur Windows, suite Windows hors intégration continue ;
  - ce que fait neo-compute : serveur persistant, éléments COM gardés vivants, format ligne et deltas.
- **Cua Driver (trycua) :** arrière-plan par défaut, patterns UIA d'abord, puis `PostMessage`, puis `SendInput` ; renvoie `background_unavailable` au lieu de prendre le premier plan ; capture par `PrintWindow` puis Windows.Graphics.Capture ([blog](https://cua.ai/blog/inside-windows-computer-use)). neo-compute reprend le refus explicite, pas le repli `PostMessage`.
- **Power Automate, mode « picture-in-picture » :** session enfant Windows (Windows 11 Pro ou Entreprise, droits administrateur) ou bureau virtuel en préversion, limité à UIA ([Learn](https://learn.microsoft.com/power-automate/desktop-flows/run-desktop-flows-pip)). Preuve que l'isolation forte existe, hors périmètre ici.
- **Codex (OpenAI) :** « It can't operate in the background while you keep using the same Windows session » ([docs](https://developers.openai.com/codex/app/computer-use)).
- **Windows Agent Workspace :** session séparée avec son propre bureau, préversion privée, désactivée par défaut ([Security book](https://learn.microsoft.com/en-us/windows/security/book/operating-system-agentic-security)).
- **Market gap:** aucun serveur ne combine, dans la session de l'utilisateur et sans droits administrateur, un mode où la liste d'outils elle-même garantit la non-interférence, une stabilisation indépendante de l'écran, une garde qui rend le premier plan, et une preuve de non-interférence dans la définition de terminé.

### Best Practices Applied
- Échec fermé : une action impossible sans entrée physique est refusée, jamais remplacée en silence (agent-desktop `CONCEPTS.md:244`, Cua).
- L'agent ne choisit pas de sortir de l'arrière-plan pour se dépanner (agent-desktop `skills/agent-desktop/SKILL.md:73`).
- Préconditions sondées avant l'action, avec un délai : visible, activé, éditable ([Playwright, actionability](https://playwright.dev/docs/actionability)).
- Verdict de livraison par relecture, sans rejouer l'action (agent-desktop `crates/core/src/actions/post_action.rs:56-57`).
- Preuve de non-interférence jointe à la preuve de l'effet : « inchangé » seul est satisfait par une action qui échoue (agent-desktop `tests/e2e-windows/scenarios/NonInterference.ps1:5-16`).
- Appels UIA depuis un thread MTA sans fenêtre ; `SetWinEventHook` hors contexte depuis un thread à boucle de messages ([threads UIA](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading), [SetWinEventHook](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook)).
- Messages clavier postés écartés : ils ne mettent pas à jour l'état des touches et contournent les IME ([The Old New Thing](https://devblogs.microsoft.com/oldnewthing/20250319-00/?p=110979)).

*Full research sources available in project documentation.*

## Assumptions & Constraints

### Assumptions (to validate)
- **A14 :** avec le client COM de neo-compute, `SetFocus` UIA sur un élément d'une fenêtre non active déplace le premier plan, comme le mesurent les sondes A3-4 et A19-5 d'agent-desktop. La documentation Microsoft ne le dit pas. Validé par US-040.
- **A15 :** Invoke, Toggle, Value, ExpandCollapse, SelectionItem et ScrollItem agissent sur une fenêtre non active et entièrement recouverte, sans changer le premier plan, sur les six applications de référence (Bloc-notes, Calculatrice, Paramètres, Explorateur, Chrome, VS Code). Validé par US-040.
- **A16 :** un menu ouvert par ExpandCollapse sur une fenêtre non active reste ouvert au moins 2 s et se lit comme racine du snapshot. Validé par US-040.
- **A17 :** une fenêtre se restaure et une application se lance sans prendre le premier plan (`SW_SHOWNOACTIVATE`, `SW_SHOWMINNOACTIVE`), ou la garde le rend en moins de 200 ms. Validé par US-040.
- **A18 :** les WinEvents du processus cible signalent au moins 95 % des changements d'arbre d'une fenêtre non active. Validé par US-047. Amendement 1.2 : A18 étant infirmée pour les applications XAML, le compteur de changements additionne aux WinEvents les événements UI Automation de la fenêtre, pour un cadre UWP d'emblée et pour toute application dont l'arbre a changé deux fois de suite sans événement ; l'abonnement est retiré si deux changements de plus restent sans événement (décision 0013).
- **A19 :** l'arbre d'une fenêtre Chromium entièrement recouverte se met à jour après une action. Inconnu : Chromium documente l'arrêt du rendu, pas l'effet sur l'arbre. Mesuré par US-058. Amendement 1.1 : Chromium et Electron sont deux cas. Chrome calcule lui-même l'occlusion de ses fenêtres et suspend le rendu d'une page recouverte, ce qui fige son arbre ; il ignore les fenêtres `WS_POPUP` dans ce calcul (`ui/gfx/win/hwnd_util.cc`). VS Code désactive ce calcul (`CalculateNativeWinOcclusion`) : une fenêtre VS Code recouverte continue de rendre. US-058 mesure les deux séparément.
- **A20 :** `PrintWindow` avec `PW_RENDERFULLCONTENT` rend une image non noire d'une fenêtre entièrement recouverte pour au moins 5 des 6 applications de référence. Cua rapporte du noir sur les fenêtres DirectComposition. Validé par US-060.
- **A21 :** les trois actions nouvelles de `ui_act` et les paramètres `root` et `depth` de `ui_tree` gardent les définitions `alwaysLoad` sous 1 500 tokens estimés. Vérifié à la compilation par le budget existant.

### Hard Constraints
- Zig 0.17.0, bindings générés depuis `bindings/windows.zon`, aucune vtable écrite à la main, aucun type WinRT (absent de win32metadata).
- Objets COM implémentés côté client : uniquement les gestionnaires d'événements UI Automation de `src/backend/windows/uia_events.zig` (amendement 1.1, décision 0013). Ils sont statiques, jamais libérés, et ne font qu'incrémenter un compteur. La version 1.0 les excluait ; la sonde `events-probe` a montré qu'une application UWP ne signale ses changements qu'à un client UIA abonné.
- Les invariants FR-07 à FR-18 restent vrais : aucune connexion réseau (FR-10), aucun outil de commande (FR-11), aucune valeur de mot de passe exposée (FR-09), une seule instance par bureau (FR-14), stdout réservé au JSON-RPC (FR-18).
- FR-12 inchangé : seul un geste physique lève la pause.
- Les 17 outils du toolset restent conformes à `tests/fixtures/toolset_20260801.json` ; une extension est un paramètre optionnel.
- Budgets de définitions : `alwaysLoad` ≤ 1 500 tokens estimés, total ≤ 4 500 (FR-22) ; chaque texte d'`instructions` ≤ 1 500 caractères.
- Le cœur (`src/core/`) n'appelle aucune API Windows ; `zig build cross` le compile pour Linux.
- Les modes `a11y` et `vision` gardent leur comportement de kill switch, d'indicateur et de stabilisation.
- Toute décision de contrat est celle d'Arthur et s'écrit dans `docs/decisions/0013` avant le code qui en dépend.
- Les campagnes d'évals passent par `claude -p` sur l'abonnement d'Arthur, avec son accord ; aucune clé `ANTHROPIC_API_KEY`.
- Chaque défaut de la couche COM Zig compte pour la condition 3 du Rust Switch Gate.

## Quality Gates

These commands must pass for every user story:
- `zig fmt --check .` - formatage
- `zig build` - serveur, sondes et bindings générés
- `zig build test` - tests du cœur sur le backend factice, budgets vérifiés à la compilation, bindings et dispositions de structures
- `zig build cross` - le cœur compile pour x86_64-linux-gnu sans dépendance Windows
- `zig build bench -- --check bench/baseline.json` - p95 ReleaseFast ≤ 110 % de la baseline et sous les budgets absolus

For backend stories (`src/backend/`, `bindings/`, `tools/winmdgen/`), additional gates:
- `zig build run -- selftest` - capture, souris, clavier, UIA et DPI sur une fenêtre de test, sortie jointe au rapport
- `zig build run -- selftest --background` - à partir de US-044 : non-interférence et effet de chaque action d'arrière-plan, sortie jointe au rapport
- `pwsh -NoProfile -Command "& ./evals/run.ps1 -DryRun"` - pour les stories qui touchent `evals/`

## Epics & User Stories

### EP-011: Contrat du mode arrière-plan

Donner au serveur un mode où la liste d'outils garantit la non-interférence, où chaque variante intrusive est refusée, et où une preuve automatique le vérifie. Livraison 1.

**Definition of Done:** `neo-compute --mode background` liste 9 outils, tous classés sans interférence. `zig build run -- selftest --background` passe avec 0 violation sur 1 000 actions et échoue sur l'action intrusive témoin. La décision 0013 est écrite et confirmée par Arthur.

#### US-039: Décision 0013, contrat du mode arrière-plan
**Description:** En tant qu'Arthur, je veux les choix de contrat de ce PRD consignés dans une décision numérotée afin qu'aucun code qui change le contrat ne parte sans mon accord.

**Priority:** P0
**Size:** XS (1 pt)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] `docs/decisions/0013-mode-arriere-plan.md` existe, en français, avec l'en-tête de `0002-mcp-protocol-version.md` (`- Statut :`, `- Date :`, `- Story :`).
- [ ] Le fichier tranche les cinq décisions de l'Overview et les questions Q10 à Q13, chacune avec la réponse d'Arthur citée et datée.
- [ ] Le fichier rappelle que FR-12 et la décision 0008 point 5 restent en vigueur dans les modes `a11y` et `vision`, et amende la décision 0011 pour le mode arrière-plan.
- [ ] Étant donné une décision sans réponse d'Arthur, quand la story est exécutée, alors elle passe `BLOCKED`, le rapport liste les points en attente, et aucune story bloquée par US-039 ne démarre.

#### US-040: Validate assumption: les primitives d'arrière-plan ne prennent pas le premier plan
**Description:** En tant qu'Arthur, je veux mesurer sur ma machine quelles primitives changent le premier plan afin de classer chaque action sur une mesure et non sur la documentation d'un tiers.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Une sonde (`zig build probe` ou sous-commande interne) place une fenêtre leurre au premier plan, puis exécute sur une fenêtre cible non active, 5 fois chacun : `SetFocus`, Invoke, Toggle, `ValuePattern.SetValue`, Expand, Collapse, `SelectionItem.Select`, `ScrollItem.ScrollIntoView`, `ShowWindow` avec `SW_SHOWNOACTIVATE`, `SW_SHOWMINNOACTIVE` et `SW_SHOWMAXIMIZED`, et le lancement de la Calculatrice et d'un document texte.
- [ ] Pour chaque primitive, la sonde écrit sur stderr : effet constaté sur la cible, fenêtre au premier plan avant et après, position du curseur avant et après, fenêtre qui a le focus clavier avant et après.
- [ ] La sonde tourne sur la fenêtre de test et sur les six applications de référence présentes ; une application absente est notée `skipped` avec sa raison.
- [ ] La sonde ouvre un menu par Expand sur une fenêtre non active et note s'il reste ouvert 2 s et s'il apparaît dans le snapshot (A16).
- [ ] Les résultats sont consignés dans `docs/decisions/0013-mode-arriere-plan.md` ou son fichier de sonde joint, avec le verdict de A14, A15, A16 et A17.
- [ ] Étant donné un pattern qui change le premier plan sur au moins une application de référence, alors il est listé comme intrusif pour US-041, et le rapport le signale en tête.
- [ ] Étant donné A15 infirmée pour Invoke ou `SetValue` sur plus de 2 applications de référence, alors la story s'arrête et rend compte à Arthur avant US-041.

#### US-041: Classe d'interférence et mode `background`
**Description:** En tant qu'Arthur, je veux lancer le serveur dans un mode qui ne liste que des outils sans interférence et refuse leurs variantes intrusives afin de garder ma souris, mon clavier et mon premier plan.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-039, US-040

**Acceptance Criteria:**
- [ ] `Annotations` dans `src/core/registry.zig` porte `intrusion` (`none`, `foreground`, `input`) ; un outil qui ne la déclare pas vaut `input`, et un test du registre liste la classe de chacun des 26 outils.
- [ ] `--mode background` est accepté par `src/main.zig` ; son registre contient exactement `ui_tree`, `ui_find`, `ui_act`, `window_list`, `window_set`, `app_launch`, `clipboard`, `registry_read` et `wait`.
- [ ] Étant donné un outil de classe `foreground` ou `input` ajouté au registre d'arrière-plan, quand le projet compile, alors l'erreur nomme l'outil et sa classe.
- [ ] Étant donné le mode arrière-plan, quand un outil non listé est appelé (`left_click`, `type`, `key`, `window_focus`), alors la réponse est `isError: true` « Mode arrière-plan : <outil> prendrait la souris, le clavier ou le premier plan de l'utilisateur. Aucune action exécutée. Utilise ui_act, ou demande à Arthur de relancer en mode a11y. »
- [ ] Étant donné le mode arrière-plan, quand `ui_act` reçoit `fallback: "click"` ou une action que US-040 a classée intrusive (`focus`), alors aucun pattern n'est appelé et le message nomme la variante et l'alternative.
- [ ] Étant donné le mode arrière-plan, quand `clipboard` reçoit `mode: "set"`, alors le presse-papiers n'est pas modifié et le message est « Mode arrière-plan : écrire le presse-papiers remplacerait celui de l'utilisateur. Aucune action exécutée. Utilise ui_act set_value. »
- [ ] Un texte d'`instructions` propre au mode, ≤ 1 500 caractères, vérifié à la compilation, dit que l'agent travaille derrière l'utilisateur, qu'il nomme sa fenêtre cible, et qu'aucun outil d'entrée physique n'existe dans ce mode.
- [ ] Les budgets FR-22 passent pour le registre d'arrière-plan ; son estimation est affichée par `registry_test.zig`.
- [ ] En modes `a11y` et `vision`, `tools/list` et le comportement de chaque outil sont identiques à ceux d'avant cette story (test de non-régression sur la sortie de `tools/list`).
- [ ] L'usage imprimé par `neo-compute` mentionne `--mode a11y|vision|background`, et une valeur inconnue renvoie le code 2.

#### US-042: Fenêtre cible de session
**Description:** En tant que Claude Code, je veux que les outils sans `window` visent ma fenêtre de travail afin de ne jamais lire ni modifier la fenêtre où l'utilisateur travaille.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-041

**Acceptance Criteria:**
- [ ] La session garde une fenêtre cible : la dernière fenêtre nommée par un paramètre `window`, ou celle que `app_launch` a renvoyée.
- [ ] En mode arrière-plan, `ui_tree` et `ui_find` sans `window` lisent la fenêtre cible, avec ses racines possédées (menus, popups, dialogues du même processus).
- [ ] Étant donné le mode arrière-plan et aucune cible, quand `ui_tree` est appelé sans `window`, alors la réponse est `isError: true` « Aucune fenêtre cible : passe window (handle de window_list) ou lance l'application avec app_launch. »
- [ ] Étant donné une cible fermée, alors la réponse est « Fenêtre cible fermée : rappelle window_list », et la cible est effacée.
- [ ] En mode arrière-plan, `since: "last"` compare au dernier arbre de la fenêtre cible ; un changement de premier plan fait par l'utilisateur ne produit pas d'arbre complet.
- [ ] Aucun appel du mode arrière-plan ne lit `GetForegroundWindow` pour choisir sa cible (test du cœur sur le backend factice, qui compte les appels à `foreground`).
- [ ] L'en-tête de chaque sortie de `ui_tree` en mode arrière-plan porte le handle de la cible, pour que le modèle sache ce qu'il lit.
- [ ] En modes `a11y` et `vision`, le défaut reste la fenêtre au premier plan.

#### US-043: Lancer et placer sans activer
**Description:** En tant que Claude Code, je veux lancer une application et restaurer une fenêtre sans qu'elle passe devant l'utilisateur afin de préparer mon travail derrière lui.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-040, US-041

**Acceptance Criteria:**
- [ ] En mode arrière-plan, `app_launch` ouvre l'application par la voie que US-040 a mesurée sans activation ; la fenêtre au premier plan est la même avant et 2 s après le lancement.
- [ ] En mode arrière-plan, `window_set` `state: normal` restaure une fenêtre minimisée par `SW_SHOWNOACTIVATE`, et `state: minimized` utilise `SW_SHOWMINNOACTIVE`.
- [ ] En mode arrière-plan, `window_set` avec `rect` reste sans activation (`SWP_NOACTIVATE`, déjà en place).
- [ ] Étant donné une application qui prend le premier plan malgré la voie sans activation, quand `app_launch` termine, alors le résultat le dit en une ligne (« <exe> a pris le premier plan ») ; la restauration relève de US-050.
- [ ] Étant donné `state: maximized` sans voie non activante mesurée en US-040, alors l'état est appliqué, et la ligne de résultat signale le changement de premier plan s'il a lieu.
- [ ] `app_launch` renvoie la fenêtre ouverte et son arbre, et en fait la fenêtre cible (US-042).
- [ ] En modes `a11y` et `vision`, `app_launch` et `window_set` gardent leur comportement actuel.
- [ ] Le selftest couvre le lancement de la Calculatrice et la restauration d'une fenêtre minimisée avec la fenêtre leurre au premier plan.

#### US-044: Selftest de non-interférence
**Description:** En tant qu'Arthur, je veux une preuve automatique que chaque action d'arrière-plan agit sans toucher à ma session afin que la promesse tienne à chaque changement de code.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-041, US-042

**Acceptance Criteria:**
- [ ] `neo-compute selftest --background` place une fenêtre leurre au premier plan avec le focus clavier dans un champ, et une fenêtre de test cible non active, recouverte par le leurre.
- [ ] Pour chaque action d'arrière-plan disponible (`ui_act` invoke, toggle, select, expand, collapse, set_value, scroll_into_view, puis `window_set`, `ui_tree`, `ui_find`), un contrôle nommé `bg-<action>` vérifie dans la même étape : l'effet reçu par la fenêtre cible, le premier plan inchangé, le focus clavier inchangé, la position du curseur inchangée, le numéro de séquence du presse-papiers inchangé, et 0 événement injecté vu par les hooks.
- [ ] Un contrôle `bg-loop` répète 1 000 actions et exige 0 violation.
- [ ] Un contrôle témoin `bg-must-catch` exécute un `left_click` en mode `a11y` et exige que le détecteur signale une violation ; s'il ne la voit pas, le selftest échoue.
- [ ] Étant donné une action dont l'effet n'atteint pas la cible, quand le contrôle tourne, alors il échoue même si rien n'a bougé dans la session.
- [ ] Étant donné un outil intrusif appelé en mode arrière-plan, alors le contrôle `bg-refusal` vérifie le refus et l'absence d'effet.
- [ ] La sortie du selftest liste chaque contrôle `bg-*` avec `ok`, `fail` ou `skip` et sa raison.
- [ ] `AGENTS.md` ajoute la commande à son tableau des gates, avec ses effets sur le bureau (fenêtre leurre au premier plan).

---

### EP-012: Cohabitation avec l'utilisateur

Faire que le kill switch, l'indicateur, la stabilisation et les attentes fonctionnent pendant que l'utilisateur se sert de sa souris, de son clavier et de son écran. Livraison 1.

**Definition of Done:** en mode arrière-plan, une action `ui_act` se termine pendant que l'utilisateur bouge la souris et tape Échap, sans pause. La stabilisation d'une action sans effet tient < 150 ms p95 avec une fenêtre animée par-dessus la cible. Le raccourci de pause arrête le serveur en < 100 ms.

#### US-045: Pause par raccourci en mode arrière-plan
**Description:** En tant qu'Arthur, je veux que mes mouvements de souris et mes Échap ne mettent pas l'agent en pause quand il travaille en arrière-plan, et garder un raccourci pour l'arrêter, afin de travailler normalement tout en restant maître de la machine.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039, US-041

**Acceptance Criteria:**
- [ ] Étant donné le mode arrière-plan et un `ui_act` en cours, quand la souris physique parcourt 500 px, alors l'action se termine et le serveur n'est pas en pause.
- [ ] Étant donné le mode arrière-plan et un `ui_act` en cours, quand Échap est pressé physiquement, alors la touche atteint l'application au premier plan (non consommée) et le serveur n'est pas en pause.
- [ ] Étant donné le mode arrière-plan, quand le raccourci de réarmement (`--rearm-key`, défaut Ctrl+Alt+Maj+R) est pressé alors que le serveur n'est pas en pause, alors le serveur passe en pause en < 100 ms, l'action en cours est annulée à son prochain point de contrôle, et le raccourci est consommé.
- [ ] Étant donné le serveur en pause, quand le même raccourci est pressé, alors la pause est levée (FR-12 : aucun outil MCP ne la lève).
- [ ] En pause, les outils d'action renvoient le message de pause existant et les outils d'observation continuent.
- [ ] Le texte d'`instructions` du mode arrière-plan nomme le raccourci de pause.
- [ ] En modes `a11y` et `vision`, Échap et un mouvement de plus de 8 px déclenchent la pause comme avant ; le raccourci n'y sert qu'à réarmer (contrôles `kill-escape`, `kill-mouse`, `kill-pause` inchangés et verts).
- [ ] Le selftest ajoute `bg-kill-ignore` (souris et Échap simulés par les messages de test des hooks) et `bg-kill-chord`.

#### US-046: Indicateur réduit au libellé
**Description:** En tant qu'Arthur, je veux un signal discret quand l'agent agit en arrière-plan afin de savoir qu'il travaille sans cadre sur mes écrans.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-045

**Acceptance Criteria:**
- [ ] En mode arrière-plan, pendant une action et 1 s après, seul le libellé s'affiche sur l'écran principal : « neo-compute is acting in the background: <raccourci> pauses » (en anglais comme le libellé de pause, amendement 1.1). Les quatre bandes de cadre ne sont pas affichées.
- [ ] En pause, le libellé de pause existant s'affiche, avec le raccourci de réarmement.
- [ ] Le libellé reste exclu des captures, ne prend jamais le focus et laisse passer les clics (FR-30).
- [ ] Étant donné `--no-indicator`, alors rien ne s'affiche, comme aujourd'hui.
- [ ] Étant donné `WDA_EXCLUDEFROMCAPTURE` refusé, alors aucun libellé n'est créé (décision 0011, point 1).
- [ ] En modes `a11y` et `vision`, l'indicateur garde son cadre et son libellé (contrôles `indicator-*` inchangés et verts).
- [ ] Le selftest ajoute `bg-indicator` : libellé visible pendant l'action, bandes absentes.

#### US-047: Validate assumption: les WinEvents signalent les changements d'une fenêtre non active
**Description:** En tant qu'Arthur, je veux savoir si les WinEvents suffisent à détecter les changements d'une fenêtre recouverte afin de choisir la source de la stabilisation sur une mesure.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] `SetWinEventHook` et `UnhookWinEvent` sont ajoutés à `bindings/windows.zon` et générés sans vtable manuelle.
- [ ] Une sonde enregistre, hors contexte et filtrés par processus, les événements `EVENT_OBJECT_*` et `EVENT_SYSTEM_*` d'une fenêtre non active et recouverte pendant 20 actions par application de référence (invoke, toggle, `SetValue`, expand).
- [ ] Pour chaque action qui a changé l'arbre (comparaison de deux snapshots), la sonde note si au moins un événement est arrivé dans les 200 ms, et son délai.
- [ ] Le rapport donne, par application : taux de changements signalés, délai médian et p95, événements par seconde au repos.
- [ ] Étant donné un taux ≥ 95 % sur toutes les applications mesurées, alors A18 est validée et le plancher de relecture de US-048 vaut 1 s.
- [ ] Étant donné un taux < 95 % sur une application, alors A18 est infirmée pour elle, le plancher vaut 250 ms, et le rapport nomme l'application.
- [ ] Étant donné une application absente, alors elle est notée `skipped`, sans compter dans le verdict.

#### US-048: Stabilisation sans pixels
**Description:** En tant que Claude Code, je veux que l'attente après une action dépende de la fenêtre cible et non de l'écran afin d'obtenir mon observation même quand l'utilisateur travaille par-dessus.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-042, US-047

**Acceptance Criteria:**
- [ ] En mode arrière-plan, la stabilisation écoute les WinEvents du processus de la fenêtre cible, reçus sur un thread dédié à boucle de messages ; l'écran est stable quand aucun événement n'arrive pendant 50 ms.
- [ ] En mode arrière-plan, la stabilisation n'appelle ni DXGI ni GDI (l'étape `capture` des timings vaut 0 pendant `settle`).
- [ ] Un plancher relit l'arbre de la cible à la période fixée par US-047 (1 s ou 250 ms) et tient l'état pour stable après deux lectures identiques.
- [ ] Étant donné une fenêtre animée qui recouvre la cible, quand une action sans effet se stabilise, alors la durée est < 150 ms p95 (contrôle `bg-settle-covered`).
- [ ] Étant donné une cible qui change sans cesse, quand `settle_timeout_ms` expire, alors le résultat porte « settle timeout » et l'observation est renvoyée.
- [ ] Étant donné une annulation ou une pause pendant la stabilisation, alors elle s'arrête au prochain point de contrôle sans réponse pour la requête annulée.
- [ ] Étant donné le hook WinEvent refusé par Windows, alors la stabilisation passe au plancher de relecture et le résultat porte « stabilisation par relecture ».
- [ ] Le thread WinEvent consomme < 1 % d'un cœur au repos (mesure par `QueryThreadCycleTime`, contrôle `bg-events-cpu`).
- [ ] Les scénarios de bench `bg-act` (action sans stabilisation) et `bg-settle` (action sans effet, stabilisation comprise) sont ajoutés ; `--write-baseline` n'est utilisé que pour eux.
- [ ] En modes `a11y` et `vision`, la stabilisation par dirty rects DXGI et son repli GDI sont inchangés (contrôles `settle` et `settle-gdi` verts).
- [ ] Le backend factice fournit une source de changements simulée, et les tests du cœur couvrent : stable d'emblée, changements puis calme, délai expiré, annulation.

#### US-049: Attentes sans pixels et attente de disparition
**Description:** En tant que Claude Code, je veux attendre l'apparition ou la disparition d'un élément d'une fenêtre recouverte afin de suivre un dialogue lent sans sonder par appels répétés.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-048

**Acceptance Criteria:**
- [ ] En mode arrière-plan, `ui_find` `wait_ms` relance sa recherche sur un WinEvent du processus cible, au plus toutes les 100 ms et au moins toutes les secondes.
- [ ] `ui_find` accepte le paramètre optionnel `gone` (booléen, défaut `false`) : avec `wait_ms`, l'outil rend la main quand plus aucun élément ne correspond.
- [ ] Étant donné un élément qui apparaît 800 ms après l'appel dans une fenêtre recouverte, alors `ui_find` répond en < 100 ms après son apparition (contrôle `bg-find-wait`).
- [ ] Étant donné `gone: true` et un élément qui disparaît, alors la réponse est « Plus aucun élément « <requête> » après <n> ms ».
- [ ] Étant donné `gone: true` sans `wait_ms`, alors la réponse est `isError: true` « gone demande wait_ms : la durée d'attente maximale. »
- [ ] Étant donné l'échéance atteinte, alors le message existant d'attente expirée est renvoyé, ou « Élément « <requête> » toujours présent après <n> ms » avec `gone`.
- [ ] L'attente consomme < 5 % d'un cœur (contrôle sur une fenêtre immobile d'un autre processus).
- [ ] Sans `gone`, et en modes `a11y` et `vision`, la sortie de `ui_find` est identique à celle d'avant cette story.

#### US-050: Garde de premier plan et restauration
**Description:** En tant qu'Arthur, je veux que le serveur vérifie après chaque action que mon premier plan est intact, et me le rende si l'application cible l'a pris, afin de ne pas être interrompu par un dialogue qui s'ouvre.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-041, US-044

**Acceptance Criteria:**
- [ ] En mode arrière-plan, chaque outil d'action lit la fenêtre au premier plan avant et après son exécution, stabilisation comprise.
- [ ] Étant donné un premier plan passé à une fenêtre du processus cible, sans geste de l'utilisateur capable de changer la fenêtre de premier plan, alors le serveur rend le premier plan à la fenêtre précédente en < 200 ms, sans `SendInput`. Amendement 1.1 : la restauration part de l'événement de premier plan (`EVENT_SYSTEM_FOREGROUND`), pendant que l'action attend encore, et le regard en fin d'action reste le filet. Trois restaurations au plus par action : une cible qui reprend le premier plan à chaque fois est laissée devant, avec la ligne « Premier plan pris par <exe cible> : repris après 3 restaurations, laissé devant ».
- [ ] Le résultat porte alors une ligne « Premier plan pris par <exe cible>, rendu à <exe> », ou « Premier plan pris par <exe cible> : Windows a refusé la restauration » si elle échoue.
- [ ] Étant donné un geste de l'utilisateur capable de changer la fenêtre de premier plan, vu par les hooks pendant l'action ou dans les 500 ms qui la précèdent, alors aucune restauration n'est tentée, et le résultat porte « Premier plan changé pendant l'action (entrée de l'utilisateur) : non restauré ». Amendement 1.1 : comptent comme tels un clic hors de la fenêtre de l'utilisateur et une touche avec Alt ou Win (Alt+Tab, Alt+Échap, Ctrl+Échap compris). Une frappe ordinaire ne compte plus : elle ne change aucune fenêtre de premier plan, et c'est elle qui tomberait dans le dialogue de la cible.
- [ ] Étant donné un premier plan inchangé, alors le résultat ne porte aucune ligne de garde.
- [ ] L'audit enregistre pour chaque action le mode et l'issue de la garde (`intact`, `restored`, `refused`, `user`, et depuis l'amendement 1.1 : `third_party` quand une autre application passe devant d'elle-même, `same_app` quand l'utilisateur était déjà dans une fenêtre du processus cible, `unknown` quand les hooks d'entrée sont absents). Aucune de ces trois dernières n'est restaurée.
- [ ] Amendement 1.2 : la garde reste armée 2 s après la fin de l'action. Étant donné une fenêtre du processus cible qui passe devant dans ce délai, sans geste de l'utilisateur, alors le premier plan est rendu en < 200 ms, le résultat de l'appel suivant porte « Premier plan pris par <exe cible> après l'action précédente, rendu à <exe> » (ou « : Windows a refusé la restauration ») et sa ligne d'audit porte `guard_late`.
- [ ] La garde ajoute < 100 µs à une action dont le premier plan est intact.
- [ ] Le selftest ajoute `bg-guard-restore` : une action qui ouvre un dialogue activant de la fenêtre de test, premier plan rendu au leurre.

---

### EP-013: Actions sémantiques complètes

Donner à `ui_act` l'état final d'une case, le défilement, les valeurs de curseur, la sélection par nom, l'attente des préconditions et un verdict de livraison. Livraison 2.

**Definition of Done:** les 11 actions sans interférence d'agent-desktop ont un équivalent dans `ui_act`. Chaque action nouvelle a son contrôle `bg-*` vert dans le selftest. Les budgets FR-22 tiennent.

#### US-051: `check`, `uncheck` et chaînes de repli
**Description:** En tant que Claude Code, je veux demander l'état final d'une case et agir sur un contrôle qui n'expose qu'une action héritée afin de ne pas inverser un état en rejouant et de couvrir plus de contrôles sans clic.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039

**Acceptance Criteria:**
- [ ] `ui_act` accepte les actions `check` et `uncheck` : l'état `ToggleState` est lu d'abord, et aucun pattern n'est appelé si l'état demandé est déjà là (résultat « déjà coché » ou « déjà décoché »).
- [ ] Étant donné une case à trois états, alors `Toggle` est appelé au plus 2 fois jusqu'à l'état demandé ; au-delà, la réponse est une erreur qui donne l'état lu.
- [ ] Étant donné un élément sans `TogglePattern`, quand `check` est demandé, alors aucune action n'est faite et le message nomme le pattern absent et `invoke` comme alternative.
- [ ] `invoke` sur un élément sans `InvokePattern` dont `LegacyIAccessible.DefaultAction` n'est pas vide appelle `DoDefaultAction`, pour toute application (aujourd'hui réservé à Firefox par MSAA).
- [ ] `toggle` sur un élément sans `TogglePattern` mais avec `InvokePattern` appelle Invoke.
- [ ] `expand` et `collapse` n'ont pas de repli par Invoke : sans `ExpandCollapsePattern`, l'état est inconnu et l'erreur propose `invoke`.
- [ ] Le résultat dit quel pattern a servi quand ce n'est pas le premier de la chaîne.
- [ ] Les niveaux de politique existants s'appliquent : `click` pour ces actions.
- [ ] Le selftest ajoute `bg-check`, `bg-uncheck` et `bg-legacy` (contrôle de la fenêtre de test sans `InvokePattern`).

#### US-052: Défilement sémantique
**Description:** En tant que Claude Code, je veux faire défiler un conteneur sans la molette afin d'atteindre un contenu hors vue sans déplacer le curseur de l'utilisateur.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039

**Acceptance Criteria:**
- [ ] `ui_act` accepte l'action `scroll` avec `value` : `up`, `down`, `left`, `right` suivi d'un nombre de crans de 1 à 100 (défaut 1), `page_up`, `page_down`, `top`, `bottom`, ou `<n>%`.
- [ ] L'action vise l'élément s'il expose `ScrollPattern`, sinon son premier ancêtre qui l'expose, sur 8 niveaux au plus.
- [ ] Les crans utilisent `ScrollPattern.Scroll` (petit ou grand incrément), `top`, `bottom` et `<n>%` utilisent `SetScrollPercent`.
- [ ] Étant donné un conteneur déjà à la limite demandée, alors le résultat est « déjà en bas » (ou en haut, à gauche, à droite), sans erreur.
- [ ] Étant donné aucun ancêtre défilable, alors aucune action n'est faite et le message est « <élément> n'est dans aucun conteneur défilable ».
- [ ] Étant donné une `value` invalide, alors la validation des arguments la refuse avec la liste des formes acceptées.
- [ ] `scroll_into_view` sur un élément sans `ScrollItemPattern` fait défiler son ancêtre défilable par incréments vers l'élément, 50 incréments ou 2 s au plus, jusqu'à ce que `IsOffscreen` soit faux.
- [ ] Le delta de l'observation montre le nouveau `scroll=<v>%`.
- [ ] Le selftest ajoute `bg-scroll` et `bg-scroll-ancestor`.

#### US-053: Valeurs de curseur et sélection par nom
**Description:** En tant que Claude Code, je veux régler un curseur et choisir une entrée de liste déroulante par son nom afin de remplir un formulaire sans ouvrir la liste à la souris.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039

**Acceptance Criteria:**
- [ ] `set_value` sur un élément sans `ValuePattern` mais avec `RangeValuePattern` appelle `RangeValuePattern.SetValue` quand `value` est un nombre.
- [ ] Étant donné une valeur hors plage, alors aucune action n'est faite et le message est « Valeur <n> hors plage <min>..<max> ».
- [ ] Étant donné une `value` non numérique sur un curseur, alors le message est « <élément> attend un nombre entre <min> et <max> ».
- [ ] `select` avec `value` sur un conteneur (liste, liste déroulante, onglets, arbre) cherche un descendant dont le nom correspond, sans égard à la casse ni aux accents, et appelle `SelectionItemPattern.Select`.
- [ ] Étant donné un conteneur replié, alors il est déplié, l'entrée est amenée en vue, sélectionnée, puis le conteneur est replié s'il a été déplié par l'action.
- [ ] Étant donné aucune entrée correspondante, alors le conteneur revient à son état initial et le message liste jusqu'à 10 noms d'entrées.
- [ ] Étant donné deux entrées de même nom, alors aucune sélection n'est faite et le message donne leurs IDs.
- [ ] `select` sans `value` garde son comportement actuel sur un élément sélectionnable.
- [ ] Le selftest ajoute `bg-range` (curseur `TRACKBAR` de la fenêtre de test) et `bg-select-name`.

#### US-054: Préconditions attendues et défilement automatique
**Description:** En tant que Claude Code, je veux que `ui_act` attende un élément pas encore activé et amène en vue un élément hors écran afin d'économiser un aller-retour par élément.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039

**Acceptance Criteria:**
- [ ] Étant donné un élément désactivé, quand `ui_act` est appelé, alors l'état est relu toutes les 100 ms pendant 2 000 ms au plus, et l'action part dès qu'il est activé.
- [ ] Étant donné un élément hors écran, alors un `scroll_into_view` (avec le repli de US-052) est fait une fois, puis la précondition est relue.
- [ ] Étant donné un élément toujours désactivé après 2 000 ms, alors aucune action n'est faite et le message est « Précondition non remplie : <élément> est resté désactivé 2000 ms. Aucune action exécutée. »
- [ ] Étant donné un élément disparu, alors l'erreur est immédiate : « Élément <id> introuvable : rappelle ui_tree ».
- [ ] Étant donné une annulation ou une pause pendant l'attente, alors elle s'arrête au prochain point de contrôle.
- [ ] Le résultat dit la durée attendue et le défilement fait quand ils ont eu lieu (« activé après 300 ms », « amené en vue »).
- [ ] Le comportement vaut dans les trois modes ; les tests du cœur qui attendaient l'erreur immédiate « Fais d'abord scroll_into_view » sont mis à jour.
- [ ] Le selftest ajoute `bg-wait-enabled` (bouton activé après 500 ms) et `bg-auto-scroll`.

#### US-055: Verdict de livraison
**Description:** En tant que Claude Code, je veux savoir si une action a pris effet, n'a pas pu être vérifiée ou a été contredite afin de décider si je peux la rejouer sans double effet.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-051, US-052, US-053

**Acceptance Criteria:**
- [ ] Après `toggle`, `check`, `uncheck`, `expand`, `collapse`, `select`, `scroll` et `set_value`, l'état de l'élément est relu toutes les 50 ms pendant 400 ms au plus, et l'action n'est jamais rejouée.
- [ ] La première ligne du résultat porte le verdict : « <action> <id> : vérifié (<état lu>) », « <action> <id> : délivré, effet non vérifiable », ou « <action> <id> : contredit, état lu <état> ».
- [ ] Un verdict « contredit » renvoie `isError: true` et finit par « L'action est partie : ne la rejoue pas sans relire l'arbre. »
- [ ] `invoke` et `scroll_into_view` renvoient « délivré, effet non vérifiable » : le delta de l'observation reste la preuve.
- [ ] Pour `set_value`, la valeur relue est comparée sans jamais être écrite dans le résultat (FR-09) : « valeur relue identique », ou « délivré, valeur reformatée par l'application » sans `isError`.
- [ ] Étant donné un champ mot de passe, alors aucune relecture n'est faite et le verdict est « délivré, effet non vérifiable ».
- [ ] Étant donné une action refusée par une précondition ou la politique, alors le message garde « Aucune action exécutée. » : le réessai est sûr.
- [ ] La relecture ajoute < 10 ms p95 à une action dont l'effet est lisible à la première lecture.
- [ ] L'audit enregistre le verdict de chaque action.

---

### EP-014: Perception ciblée

Lire une région d'une grande application, relire un seul élément, et savoir quand un arbre est figé parce que la fenêtre est recouverte. Livraison 2.

**Definition of Done:** `ui_tree` `root` renvoie un sous-arbre de VS Code sans élagage par le plafond de 8 000 caractères. `ui_find` `id:` relit un élément en < 10 ms p95. La sonde US-058 a rendu son verdict sur Chromium recouvert.

#### US-056: `ui_tree` par sous-arbre et profondeur
**Description:** En tant que Claude Code, je veux lire le squelette d'une grande application puis descendre dans une région afin de ne pas perdre des éléments à l'élagage.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-039, US-042

**Acceptance Criteria:**
- [ ] `ui_tree` accepte `root` (ID d'élément) : la sortie ne contient que le sous-arbre de cet élément, avec le plafond de 8 000 caractères pour lui seul.
- [ ] `ui_tree` accepte `depth` (1 à 25) : un élément à la profondeur limite qui a des descendants porte « … <n> descendants » sur sa ligne et garde son ID.
- [ ] Les IDs d'un sous-arbre sont les mêmes que dans l'arbre complet (FR-05).
- [ ] Étant donné `root` inconnu ou disparu, alors la réponse est « Élément <id> introuvable : rappelle ui_tree ».
- [ ] Étant donné `root` avec `since: "last"`, alors la réponse est `isError: true` « root et since ne se combinent pas : lis le sous-arbre, puis le delta de la fenêtre. »
- [ ] Le masquage des mots de passe et la politique `deny` s'appliquent au sous-arbre.
- [ ] Sans `root` ni `depth`, la sortie est identique à celle d'avant cette story.
- [ ] `ui_tree` `root` sur une fenêtre native tient le p95 du `ui_tree` complet de la même fenêtre.
- [ ] Les budgets FR-22 passent avec les deux paramètres.

#### US-057: `ui_find`, relecture d'un élément, valeur et total
**Description:** En tant que Claude Code, je veux relire l'état d'un élément et chercher par valeur afin de vérifier un résultat sans relire l'arbre.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-039, US-049

**Acceptance Criteria:**
- [ ] La requête `id:<id>` renvoie la ligne courante de l'élément, relue en direct, au format de `ui_tree`.
- [ ] `id:<id>` tient < 10 ms p95 sur la fenêtre de test (un aller-retour UIA, sans relire la fenêtre).
- [ ] Le terme `value:<texte>` filtre sur la valeur de l'élément ; un terme entre guillemets exige une correspondance exacte du nom.
- [ ] Étant donné plus de 20 correspondances, alors la première ligne est « <n> correspondances, 20 affichées ».
- [ ] Étant donné `id:<id>` d'un élément disparu, alors la réponse est « Élément <id> introuvable : rappelle ui_tree ».
- [ ] La valeur d'un champ mot de passe reste masquée, et `value:` ne correspond jamais à un champ mot de passe.
- [ ] Une requête sans ces termes renvoie la même sortie qu'avant cette story.

#### US-058: Validate assumption: l'arbre d'une fenêtre Chromium recouverte reste à jour
**Description:** En tant qu'Arthur, je veux mesurer ce que deviennent l'arbre et les actions d'une fenêtre Chrome ou VS Code recouverte afin de savoir si l'arrière-plan tient sur les applications Electron.

**Note de l'amendement 1.1 :** le leurre des sondes est désormais une fenêtre à cadre (`WS_CAPTION | WS_THICKFRAME`) : Chromium ignore une fenêtre `WS_POPUP` dans son calcul d'occlusion, donc l'absence de document web sous l'ancien leurre ne venait pas de l'occlusion. La sonde mesure en plus : si une action UIA force la mise à jour de l'arbre d'une page recouverte (l'accessibilité web s'active quand une requête UIA vise un nœud web) ; la plus petite bande visible qui suffit (16 px n'est qu'un point de départ) ; Chrome et VS Code séparément, VS Code ne calculant pas l'occlusion. Amendement 1.2 : la sonde sépare « arbre pas encore construit » (premier contact, qui se corrige en relisant) de « arbre figé par recouvrement », et vérifie que minimiser ou déplacer ce qui recouvre suffit à débloquer (mesures A1-5 et A1-6 d'agent-desktop).

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Une sonde mesure, pour Chrome et VS Code, le nombre de nœuds et le délai de mise à jour de l'arbre après une action `ui_act`, dans cinq situations : visible, recouverte en entier, recouverte sauf une bande de 16 px, sur l'autre écran, minimisée.
- [ ] Chaque situation est mesurée 10 fois, à froid (premier contact) et à chaud.
- [ ] La sonde relit une fenêtre WPF dans la seconde qui suit son lancement et note si l'arbre est vide (fournisseur générique) ; sans application WPF installée, ce point est `skipped`.
- [ ] Le rapport donne par situation : nœuds lus, délai p95 de mise à jour, part des actions dont l'effet apparaît en < 1 s.
- [ ] Étant donné une part ≥ 95 % en situation « recouverte en entier », alors A19 est validée et US-059 se limite au drapeau `occluded`.
- [ ] Étant donné une part < 95 %, alors A19 est infirmée, la situation la moins coûteuse qui atteint 95 % est nommée, et US-059 la recommande dans son message.
- [ ] Les résultats sont ajoutés à `bench/apps.md`.

#### US-059: Signalement d'une fenêtre recouverte
**Description:** En tant que Claude Code, je veux savoir que ma fenêtre cible est entièrement recouverte, et quoi faire quand son arbre peut être figé, afin de ne pas conclure à tort qu'une action a échoué.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-042, US-058

**Acceptance Criteria:**
- [ ] L'en-tête d'une racine entièrement recouverte par des fenêtres plus hautes dans l'ordre z porte le drapeau `{occluded}` ; une fenêtre visible, même d'un pixel, ne le porte pas.
- [ ] `window_list` porte le même drapeau.
- [ ] Étant donné A19 infirmée et une cible de classe `Chrome_WidgetWin_1` recouverte, alors `ui_tree` ajoute une ligne : « Fenêtre recouverte : Chromium suspend son rendu, l'arbre peut être figé. Déplace-la avec window_set pour <situation recommandée par US-058>. »
- [ ] Amendement 1.1 : pour une cible Chromium, « recouverte » se calcule avec les règles de Chromium (les fenêtres `WS_POPUP`, masquées, minimisées ou transparentes ne recouvrent pas), afin que le drapeau dise ce que Chrome décide. Une cible Electron qui désactive le calcul d'occlusion (VS Code) ne reçoit pas la ligne d'avertissement. `app_launch` n'ajoute aucun drapeau de ligne de commande par défaut.
- [ ] Étant donné A19 validée, alors aucune ligne d'avertissement n'est ajoutée.
- [ ] Le calcul de recouvrement ajoute < 1 ms p95 à `ui_tree` pour 50 fenêtres de premier niveau.
- [ ] Le calcul ignore les fenêtres de l'indicateur, les fenêtres minimisées et les fenêtres masquées (« cloaked »).
- [ ] Les tests du cœur couvrent : recouverte par une fenêtre, par l'union de deux fenêtres, visible d'une bande, sur un autre écran.

---

### EP-015: Passe visuelle en arrière-plan

Capturer une fenêtre recouverte pour un contrôle visuel, sans capturer l'écran de l'utilisateur. Livraison 3.

**Definition of Done:** en mode arrière-plan, `screenshot` renvoie l'image de la fenêtre cible recouverte, mots de passe masqués, pour au moins 5 des 6 applications de référence, en < 60 ms p95, sans changement de premier plan.

#### US-060: Validate assumption: `PrintWindow` capture une fenêtre recouverte
**Description:** En tant qu'Arthur, je veux savoir si `PrintWindow` suffit pour capturer mes applications recouvertes afin de décider si Windows.Graphics.Capture, qui demande WinRT, est nécessaire.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Une sonde capture par `PrintWindow` avec `PW_RENDERFULLCONTENT` chacune des six applications de référence, recouverte en entier, 20 fois.
- [ ] Pour chaque application, le rapport donne : part d'images non noires, durée médiane et p95, premier plan et curseur inchangés ou non, clignotement constaté ou non.
- [ ] La sonde compare l'image à une capture DXGI de la même fenêtre visible, par empreinte réduite, et donne l'écart.
- [ ] Étant donné au moins 5 applications sur 6 avec 100 % d'images non noires et un p95 < 60 ms, alors A20 est validée et US-061 utilise `PrintWindow`.
- [ ] Étant donné moins de 5 applications, alors A20 est infirmée, US-061 passe `BLOCKED`, et le rapport pose à Arthur la question Q13 (extension du générateur à WinRT pour Windows.Graphics.Capture).
- [ ] Étant donné une fenêtre qui ne répond pas, alors la sonde ne se bloque pas : elle vérifie d'abord que la fenêtre répond en 200 ms.

#### US-061: Capture de la fenêtre cible
**Description:** En tant que Claude Code, je veux une image de ma fenêtre cible même recouverte afin de vérifier visuellement mon travail sans voir l'écran de l'utilisateur.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-039, US-042, US-060

**Acceptance Criteria:**
- [ ] `screenshot` et `zoom` acceptent le paramètre optionnel `window` (handle) : l'image est celle de cette fenêtre seule ; la fixture du toolset reste respectée.
- [ ] En mode arrière-plan, `screenshot` et `zoom` sont listés, visent la fenêtre cible sans `window`, et ne renvoient jamais un écran entier.
- [ ] Le texte joint à l'image donne le handle, la taille, l'échelle et l'origine de la fenêtre, pour relier un pixel à un rectangle de `ui_tree`.
- [ ] Les champs mot de passe de la fenêtre capturée sont noircis avant l'encodage, par le balayage `IsPassword` existant appliqué à cette fenêtre (FR-09).
- [ ] Étant donné une fenêtre d'une application `deny`, alors la capture est refusée par le message de politique existant.
- [ ] Étant donné une fenêtre minimisée, alors la réponse est « Fenêtre minimisée : restaure-la avec window_set (state normal) avant la capture. »
- [ ] Étant donné une image entièrement noire, alors la réponse est `isError: true` « Capture noire : <exe> ne se laisse pas capturer hors de l'écran. Utilise ui_tree. »
- [ ] Étant donné une fenêtre qui ne répond pas en 200 ms, alors aucune capture n'est tentée et le message de fenêtre figée existant est renvoyé.
- [ ] `ui_tree` `marks: true` en mode arrière-plan dessine les IDs sur la capture de la fenêtre cible.
- [ ] La capture d'une fenêtre de 2560x1440 tient < 60 ms p95 (scénario de bench `bg-capture`, `--write-baseline` pour lui seul).
- [ ] Le selftest ajoute `bg-capture` (motif connu de la fenêtre de test recouverte, premier plan inchangé) et `bg-capture-password`.
- [ ] Sans `window`, en modes `a11y` et `vision`, `screenshot` et `zoom` renvoient la même sortie qu'avant cette story.

---

### EP-016: Mesure

Prouver sur des tâches écrites avant tout résultat que le mode arrière-plan réussit sans interférence, contre agent-desktop comme référence indépendante. Livraison 3.

**Definition of Done:** `evals/run.ps1 -DryRun -Suite background` passe. Une campagne approuvée par Arthur a produit son rapport dans `evals/reports/` avec la conclusion sur chaque ligne des Success Metrics et sur la question Q10.

#### US-062: Tâches d'évals d'arrière-plan
**Description:** En tant qu'Arthur, je veux des tâches exécutées pendant qu'une fenêtre leurre garde le premier plan afin de mesurer la réussite et la non-interférence sur des cas réels.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-044, US-048, US-050, US-055

**Acceptance Criteria:**
- [ ] Une suite `background` d'au moins 8 tâches, chacune avec préparation, vérification de l'état final et nettoyage : enregistrer un document du Bloc-notes par le menu et le dialogue, un calcul dans la Calculatrice, un réglage à bascule dans Paramètres, une case et une liste déroulante d'une page Chrome, une entrée d'une longue liste à faire défiler, un curseur à régler, une application à lancer sans activation, et un contrôle visuel d'une fenêtre recouverte.
- [ ] Chaque tâche tourne avec une fenêtre leurre au premier plan ; un témoin échantillonne toutes les 50 ms le premier plan, le focus clavier et la position du curseur.
- [ ] La vérification d'une tâche échoue si le témoin a vu un changement de premier plan ou de curseur, même quand l'état final est bon.
- [ ] `-Solve` joue la solution scriptée de chaque tâche en mode arrière-plan, et sa vérification doit l'accepter.
- [ ] Les consignes ne nomment aucun outil.
- [ ] Un mode de référence `agent-desktop` lance agent-desktop 1.2.0 par son serveur MCP, épinglé dans `evals/` comme dépendance de développement, absent du binaire livré.
- [ ] Étant donné une application absente, alors la tâche est `skipped` avec sa raison.
- [ ] Les tâches sont commitées avant la première exécution réelle.

#### US-063: Campagne d'arrière-plan
**Description:** En tant qu'Arthur, je veux une campagne mesurée afin de décider sur des chiffres si l'arrière-plan devient le mode par défaut.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-062

**Acceptance Criteria:**
- [ ] La campagne ne démarre qu'après l'accord écrit d'Arthur sur son budget (tâches × répétitions × modes).
- [ ] Elle couvre la suite `background` en modes `background` et `agent-desktop`, et les 20 tâches existantes en mode `a11y`, avec 3 répétitions.
- [ ] `evals/report.ps1` produit `evals/reports/<date>.md` avec réussite, violations de non-interférence, appels d'outils, tokens et durée par mode et par tâche.
- [ ] Le rapport conclut sur chaque ligne des Success Metrics et recommande une réponse à Q10.
- [ ] Étant donné une violation de non-interférence en mode `background`, alors le rapport la signale en tête et ouvre une story de correction.
- [ ] Étant donné une régression de plus de 5 points sur les 20 tâches existantes en mode `a11y`, alors le rapport la signale en tête et ouvre une story de correction.

## Functional Requirements

- FR-31: Le système doit offrir un mode `background` (`--mode background`) dont `tools/list` ne contient que des outils de classe d'interférence `none`.
- FR-32: Chaque outil déclare sa classe d'interférence (`none`, `foreground`, `input`) ; un outil qui ne la déclare pas est traité comme `input`.
- FR-33: En mode arrière-plan, le système ne doit jamais appeler `SendInput`, ni `SetFocus` UIA, ni écrire le presse-papiers, ni appeler `SetForegroundWindow` hors de la restauration de FR-38.
- FR-34: En mode arrière-plan, un outil ou une variante intrusive est refusé avant tout effet, avec un message qui nomme la cause et l'action suivante (FR-06).
- FR-35: En mode arrière-plan, un outil sans `window` vise la fenêtre cible de session ; le système ne lit jamais la fenêtre au premier plan pour choisir sa cible.
- FR-36: En mode arrière-plan, un mouvement de souris ou un Échap physiques ne déclenchent pas la pause et ne sont pas consommés ; le raccourci de réarmement met en pause en < 100 ms. FR-12 reste vrai.
- FR-37: En mode arrière-plan, la stabilisation et les attentes ne dépendent d'aucune capture d'écran.
- FR-38: En mode arrière-plan, chaque action vérifie le premier plan avant et après ; s'il a été pris par le processus cible sans entrée physique de l'utilisateur, le système le rend à la fenêtre précédente.
- FR-39: `ui_act` doit accepter les actions `check`, `uncheck` et `scroll`, une `value` numérique sur un élément à plage, et une `value` de nom avec `select` sur un conteneur.
- FR-40: Une action à état relisible renvoie un verdict (vérifié, non vérifiable, contredit) et n'est jamais rejouée par le système.
- FR-41: `ui_tree` doit accepter `root` et `depth`, `ui_find` doit accepter `gone` et les termes `id:` et `value:`, tous optionnels ; sans eux, la sortie est identique à celle d'avant ce PRD.
- FR-42: `screenshot` et `zoom` doivent accepter `window` ; en mode arrière-plan, ils ne renvoient que la fenêtre cible, mots de passe masqués (FR-09).
- FR-43: Les modes `a11y` et `vision` gardent leur liste d'outils, leur kill switch, leur indicateur et leur stabilisation.
- FR-44: L'audit de chaque action enregistre le mode, l'issue de la garde de premier plan et le verdict de livraison (étend FR-13).
- FR-45: Le système ne doit offrir au modèle aucun moyen de quitter le mode arrière-plan ou d'autoriser une action intrusive.

## Non-Functional Requirements

- **Performance:**
  - `ui_act` en mode arrière-plan, hors stabilisation, sur la fenêtre de test : p95 < 20 ms (scénario `bg-act`).
  - Stabilisation d'une action sans effet, fenêtre animée par-dessus la cible : p95 < 150 ms (scénario `bg-settle`).
  - Réaction de `ui_find` `wait_ms` : < 100 ms après l'apparition ou la disparition de l'élément.
  - `ui_find` `id:` : p95 < 10 ms. Relecture du verdict : < 10 ms p95 quand l'effet est lisible à la première lecture.
  - Garde de premier plan : < 100 µs par action intacte. Calcul de recouvrement : < 1 ms p95 pour 50 fenêtres.
  - Capture d'une fenêtre de 2560x1440 : p95 < 60 ms (scénario `bg-capture`).
  - Pause par raccourci : < 100 ms. Restauration du premier plan : < 200 ms.
- **Footprint:** binaire ReleaseFast strippé ≤ 3 MB ; RSS au repos < 15 MB ; thread WinEvents < 1 % d'un cœur au repos ; attente `ui_find` < 5 % d'un cœur ; 0 allocation du GPA par requête en régime établi sur `ui_act` en mode arrière-plan.
- **Security:** 0 appel à `SendInput` et à `SetFocus` en mode arrière-plan sur le selftest (compteur) ; 100 % des outils et variantes intrusifs couverts par un test de refus ; 0 fuite sur les tâches canari, capture par fenêtre comprise ; 0 connexion réseau (test des imports PE inchangé).
- **Accessibility:** le libellé ne prend jamais le focus et laisse passer les clics (`WS_EX_TRANSPARENT`) ; Narrateur et NVDA fonctionnent pendant une passe d'arrière-plan, vérifié une fois par version publiée.
- **Reliability:** 0 violation de non-interférence sur 1 000 actions (`bg-loop`) ; restauration du premier plan réussie dans ≥ 95 % des 100 répétitions de `bg-guard-restore` ; dérive < 5 MB de private bytes et 0 handle sur 10 000 actions d'arrière-plan ; 0 crash quand la cible se ferme pendant une action, sur 1 000 itérations.

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | Aucune cible | `ui_tree` sans `window` avant tout `app_launch`, mode arrière-plan | Aucune lecture | « Aucune fenêtre cible : passe window (handle de window_list) ou lance l'application avec app_launch. » |
| 2 | Outil intrusif | `left_click`, `type`, `key` ou `window_focus` en mode arrière-plan | Refus avant tout effet | « Mode arrière-plan : <outil> prendrait la souris, le clavier ou le premier plan de l'utilisateur. Aucune action exécutée. Utilise ui_act, ou demande à Arthur de relancer en mode a11y. » |
| 3 | Variante intrusive | `ui_act` `fallback: "click"` ou `focus` | Aucun pattern appelé | « Mode arrière-plan : <variante> prendrait <ressource>. Aucune action exécutée. Essaie <alternative>. » |
| 4 | Écriture du presse-papiers | `clipboard` `mode: "set"` en mode arrière-plan | Presse-papiers intact | « Mode arrière-plan : écrire le presse-papiers remplacerait celui de l'utilisateur. Aucune action exécutée. Utilise ui_act set_value. » |
| 5 | Pattern absent, pas de voie sémantique | Éditeur de VS Code sans `ValuePattern` | Aucune action | « <élément> ne supporte pas set_value (pattern Value absent). En arrière-plan, aucune saisie clavier n'est possible : demande à Arthur de relancer en mode a11y. » |
| 6 | Cible minimisée | `ui_act` sur une fenêtre minimisée | Aucune action | « Fenêtre minimisée : restaure-la avec window_set (state normal), elle restera derrière. » |
| 7 | Cible fermée pendant l'action | L'utilisateur ferme la fenêtre cible | Erreur, cible effacée | « Fenêtre cible fermée : rappelle window_list » |
| 8 | Cible volée au premier plan | Un dialogue de la cible s'active | Premier plan rendu | « Premier plan pris par <exe cible>, rendu à <exe> » |
| 9 | Restauration refusée | Windows refuse `SetForegroundWindow` | Ligne d'avertissement, action comptée | « Premier plan pris par <exe cible> : Windows a refusé la restauration » |
| 10 | Changement par l'utilisateur | Alt+Tab pendant l'action | Aucune restauration | « Premier plan changé pendant l'action (entrée de l'utilisateur) : non restauré » |
| 11 | Pause par raccourci | Raccourci de réarmement pendant une action | Annulation, pause en < 100 ms | « En pause par l'utilisateur : attends qu'Arthur réarme » |
| 12 | Arbre Chromium figé | Cible `Chrome_WidgetWin_1` recouverte, A19 infirmée | Drapeau `{occluded}` et conseil | « Fenêtre recouverte : Chromium suspend son rendu, l'arbre peut être figé. Déplace-la avec window_set pour <situation>. » |
| 13 | WinEvents indisponibles | `SetWinEventHook` refusé | Stabilisation par relecture | « stabilisation par relecture » |
| 14 | Cible qui change sans cesse | Animation continue dans la cible | Observation à l'échéance | « settle timeout » |
| 15 | Case à trois états | `check` sur une case indéterminée | 2 bascules au plus | « État <lu> après 2 bascules : la case n'atteint pas « coché » » |
| 16 | Valeur hors plage | `set_value` 150 sur un curseur 0..100 | Aucune action | « Valeur 150 hors plage 0..100 » |
| 17 | Entrée introuvable | `select` avec un nom absent | Conteneur remis en état | « Aucune entrée « <nom> » dans <conteneur>. Entrées : <10 noms au plus> » |
| 18 | Action contredite | L'application refuse un `toggle` | `isError: true`, pas de rejeu | « toggle <id> : contredit, état lu décoché. L'action est partie : ne la rejoue pas sans relire l'arbre. » |
| 19 | Précondition jamais remplie | Bouton resté désactivé | Aucune action après 2 000 ms | « Précondition non remplie : <élément> est resté désactivé 2000 ms. Aucune action exécutée. » |
| 20 | Capture noire | `PrintWindow` rend une image noire | `isError: true` | « Capture noire : <exe> ne se laisse pas capturer hors de l'écran. Utilise ui_tree. » |
| 21 | Cible élevée | Fenêtre lancée en administrateur | Refus existant (UIPI) | Message de cible élevée existant |
| 22 | Fenêtre figée | La cible ne répond pas en 200 ms | Aucun aller-retour UIA | Message de fenêtre figée existant |
| 23 | Session verrouillée | Verrouillage pendant une passe | Actions et captures refusées, reprise au retour | Message de session inactive existant |
| 24 | Seconde instance | Un autre serveur contrôle déjà le bureau | Actions refusées (FR-14) | Message d'instance existant |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Un pattern UIA prend le premier plan sur certaines applications (A15 infirmée) | Med | High | Sonde US-040 avant le mode ; classement par application mesurée ; garde et restauration (US-050) |
| 2 | Chromium fige son arbre quand la fenêtre est recouverte (A19) ; Electron selon l'application (VS Code désactive le calcul d'occlusion) | High | High | Sonde US-058, Chrome et VS Code séparément ; drapeau `{occluded}` calculé avec les règles de Chromium et conseil de placement (US-059) ; écran secondaire comme situation de repli |
| 3 | Les WinEvents manquent des changements (A18) | Med | Med | Sonde US-047 ; plancher de relecture à 250 ms ; stabilisation bornée par `settle_timeout_ms` |
| 4 | `PrintWindow` rend du noir sur les fenêtres DirectComposition (A20) | High | Med | Sonde US-060 ; US-061 bloquée et question Q13 posée plutôt qu'une voie WinRT ajoutée sans décision |
| 5 | La pause par raccourci est moins réflexe que la souris ou Échap : une action non voulue va à son terme | Med | Med | Aucune action du mode ne touche l'entrée de l'utilisateur ; politique par application et audit inchangés ; raccourci rappelé par le libellé |
| 6 | L'agent agit sur la fenêtre où l'utilisateur travaille | Low | High | Fenêtre cible explicite (US-042) ; politique `deny` et `observe` par application ; aucune lecture du premier plan |
| 7 | Les définitions `alwaysLoad` dépassent 1 500 tokens (A21) | Med | Med | Actions ajoutées à l'énumération existante, pas de paramètre nouveau sur `ui_act` ; budget vérifié à la compilation ; arrêt et rapport si dépassé |
| 8 | Le thread WinEvents ou la couche COM fait apparaître des défauts Zig | Med | High | Bindings générés ; rappel C simple pour les WinEvents ; côté client, seuls les gestionnaires d'événements UIA statiques de `uia_events.zig` (amendement 1.1), construits sur les vtables générées ; chaque défaut compté pour la condition 3 du Rust Switch Gate |
| 9 | Un texte lu dans une fenêtre recouverte injecte des consignes | Med | High | Texte d'`instructions` inchangé sur ce point ; aucun outil de commande ni réseau ; politique par application |
| 10 | La capture par fenêtre expose un mot de passe | Low | High | Balayage `IsPassword` de la fenêtre capturée avant l'encodage ; tâche canari ; refus des applications `deny` |
| 11 | Le changement de `ui_act` (attente, verdict) fait régresser le mode `a11y` | Med | Med | Tests du cœur mis à jour ; campagne sur les 20 tâches existantes (US-063) ; seuil de 5 points |
| 12 | La restauration du premier plan contrarie l'utilisateur qui voulait la fenêtre cible | Low | Low | Aucune restauration si un geste capable de changer la fenêtre de premier plan a été vu (clic hors de sa fenêtre, touche avec Alt ou Win) ; trois restaurations au plus par action |
| 13 | 25 stories dépassent une livraison | High | Low | Trois livraisons ordonnées ; la livraison 1 est utilisable seule |

## Non-Goals

What this version explicitly does NOT include:

- **Surface CLI et daemon :** le client est Claude Code par MCP stdio. Une CLI demande un canal local vers un serveur résident, à confronter à FR-10 et FR-14. À revisiter après la campagne US-063 (Q14).
- **Isolation forte (session enfant, bureau dédié, Agent Workspace) :** elle seule permet l'entrée réelle sans interférence, mais demande des droits administrateur (Power Automate) ou une préversion privée. PRD séparé (Q15).
- **Saisie de texte et raccourcis clavier en arrière-plan :** pas de `PostMessage` de touches (état des touches et IME faussés), pas de résolution de raccourcis par l'arbre dans cette version. `set_value` couvre le remplacement d'une valeur.
- **Échappatoire vers le premier plan par appel d'outil :** le modèle ne peut pas autoriser une action intrusive (FR-45).
- **Pilotage parallèle de plusieurs fenêtres ou de plusieurs agents :** un seul répartiteur, FR-14 inchangé.
- **Gestionnaires d'événements UIA :** ils demandent des objets COM côté client en Zig. Les WinEvents les remplacent.
- **Windows.Graphics.Capture :** WinRT est absent de win32metadata ; décision d'Arthur si US-060 infirme A20 (Q13).
- **Pilotage d'une fenêtre minimisée sans la restaurer :** UIA rapporte ses éléments hors écran.
- **Notifications et surfaces système (menu Démarrer, zone de notification) :** elles prennent le premier plan chez agent-desktop aussi.
- **Changement du mode par défaut :** décidé après la campagne (Q10).
- **Partition des fenêtres entre l'utilisateur et l'agent :** l'agent peut viser toute fenêtre que la politique permet.
- **Lot d'actions en un appel, diff visuel entre deux captures.**

## Files NOT to Modify

- `tests/fixtures/toolset_20260801.json` : contrat externe d'Anthropic. Les 17 structs du toolset dans `src/core/tools.zig` ne reçoivent que le paramètre optionnel `window` sur `screenshot` et `zoom`.
- `bench/baseline.json`, sauf l'ajout des scénarios `bg-act`, `bg-settle` et `bg-capture`.
- L'écriture sur stdout et l'ordre du dispatcher dans `src/core/mcp.zig`.
- La logique de déclenchement du kill switch pour les modes `a11y` et `vision` dans `src/backend/windows/hooks.zig` et `src/core/control.zig` : seul le mode arrière-plan reçoit un comportement nouveau.
- La voie de stabilisation par dirty rects DXGI et son repli GDI dans `src/core/a11y.zig` : conservée pour `a11y` et `vision`.
- La liste `properties` du cache principal dans `src/backend/windows/uia.zig` (12 propriétés).
- Le fichier `win32.zig` généré : ajouter les API dans `bindings/windows.zon`.
- `docs/decisions/0001` à `0012`, sauf le compteur de la condition 3 dans `0001-zig-vs-rust.md`. Les amendements vont dans `0013`.
- `C:/dev/agent-desktop`, `C:/dev/ghostty` et `C:/dev/Windows-MCP` : références en lecture seule.

## Technical Considerations

Frame as questions for engineering input, not mandates:

- **Registre du mode :** un troisième registre filtré à la compilation, comme `VisionReg` (`src/core/mcp.zig:228`), ou un filtre à l'exécution sur le registre complet ? Recommandé : registre filtré, pour que le budget et la liste soient vérifiés à la compilation. Engineering to confirm feasibility.
- **Variantes intrusives :** la classe d'un argument (`ui_act` `focus`, `clipboard` `set`) se déclare-t-elle dans le struct `Args`, ou se teste-t-elle dans `run` ? Recommandé : déclaration à côté de l'argument, pour que le test de refus énumère les variantes sans liste tenue à la main.
- **Kill switch :** le mode arrière-plan évite-t-il `beginAction`, ou `Control` reçoit-il un champ de mode lu par le thread des hooks ? Recommandé : un champ atomique dans `Control`, lu par `onKey` et `onMouse`, pour garder un seul chemin d'annulation.
- **Source de changements :** les WinEvents entrent-ils par `backend.changes()` comme une troisième source à côté de DXGI et GDI, ou par une méthode distincte ? Recommandé : même forme de résultat (« changé ou non depuis le dernier regard »), pour réutiliser la boucle `settle`.
- **Thread WinEvents :** thread dédié, ou thread des hooks existant qui a déjà sa boucle de messages ? Recommandé : thread dédié, le thread des hooks devant répondre en moins de 1 ms.
- **Portée du hook :** un hook par processus cible, posé à la première action et retiré à la fermeture de la cible, ou un hook global filtré ? Recommandé : par processus, pour le coût au repos.
- **Restauration :** `SetForegroundWindow` seul, puis `AttachThreadInput`, sans l'étape `SendInput` de `focusWindow` (`src/backend/windows/window.zig:171-203`) ? À mesurer en US-050.
- **Relecture d'un élément (`id:`) :** `BuildUpdatedCache` sur le pointeur gardé, avec le cache à 12 propriétés ? Recommandé : oui, même requête que le snapshot pour un format identique.
- **Capture :** `PrintWindow` dans un DC mémoire puis le réducteur et l'encodeur existants ? Le balayage des mots de passe (`src/backend/windows/uia.zig:882-980`) prend-il un handle quelconque ? À vérifier en US-061.
- **Espace de coordonnées d'une capture de fenêtre :** origine de la fenêtre et échelle propre, ou espace screenshot de son écran rogné ? Recommandé : espace de l'écran rogné, pour que les rectangles de `ui_tree` restent valables sans conversion.
- **Bindings :** `SetWinEventHook`, `UnhookWinEvent`, `PrintWindow`, `GetClipboardSequenceNumber` et `GetGUIThreadInfo` sont-ils tous générés sans `dll_aliases` nouveaux ? À vérifier au premier `zig build` de chaque story.
- **Migration :** aucune donnée à migrer. Le mode est à activer ; retour arrière : relancer sans `--mode background`. Les changements de `ui_act` valables dans les trois modes (US-054, US-055) n'ont pas d'interrupteur : la campagne US-063 mesure leur effet.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Violations de non-interférence sur 1 000 actions | N/A (nouveau) | 0 | Month-1 | `selftest --background`, contrôle `bg-loop` |
| Appels à `SendInput` et `SetFocus` en mode arrière-plan | N/A (nouveau) | 0 | Month-1 | Compteur du selftest |
| Outils et variantes intrusifs couverts par un test de refus | 0 % | 100 % | Month-1 | Test du registre (US-041) |
| Actions sans interférence d'agent-desktop ayant un équivalent `ui_act` | 7 sur 11 | 11 sur 11 | Month-1 | Inventaire de la recherche, revu à la clôture de EP-013 |
| Stabilisation d'une action sans effet, cible recouverte, p95 | Non mesurable (dépend de l'écran) | < 150 ms, puis < 100 ms | Month-1, Month-6 | Scénario de bench `bg-settle` |
| Réussite sur la suite `background` | N/A (nouveau) | ≥ 85 %, puis ≥ 95 % | Month-1, Month-6 | Campagne US-063 |
| Réussite comparée au mode `agent-desktop` | Mesurée en US-063 | ≥ agent-desktop, puis + 10 points | Month-1, Month-6 | Campagne US-063 |
| Violations de non-interférence sur la suite `background` | N/A (nouveau) | 0 | Month-1 | Témoin des tâches (US-062) |
| Réussite sur les 20 tâches existantes, mode a11y | 100 % (2026-11-03) | ≥ 95 % | Month-1 | Campagne US-063 |
| Médiane de tokens par delta après action | 96 (2026-11-03) | ≤ 150 | Month-1 | Rapport de US-063 |
| Applications de référence capturées recouvertes | 0 sur 6 | ≥ 5 sur 6 | Month-6 | Sonde US-060, contrôle `bg-capture` |
| Tokens des définitions `alwaysLoad` | Valeur affichée par `registry_test.zig` | ≤ 1 500 | Month-1 | Test du registre |

## Open Questions

- **Q10 :** l'arrière-plan devient-il le mode par défaut ? Décision d'Arthur après le rapport de US-063 ; sans réponse, le défaut reste `a11y`.
- **Q11 :** le geste de pause du mode arrière-plan est-il le raccourci de réarmement en bascule (recommandé), ou un second raccourci distinct ? Décision d'Arthur dans US-039, avant US-045.
- **Q12 :** l'indicateur du mode arrière-plan est-il le libellé seul (recommandé), ou rien ? Décision d'Arthur dans US-039, avant US-046. Prolonge Q9 du PRD de parité.
- **Q13 :** si `PrintWindow` ne suffit pas (A20 infirmée), étend-on `tools/winmdgen` aux métadonnées WinRT pour Windows.Graphics.Capture, au prix d'une surface COM plus large face au Rust Switch Gate ? Décision d'Arthur à la clôture de US-060.
- **Q14 :** veut-on une surface CLI au-dessus du serveur résident ? Elle demande un canal local (tube nommé refusant les clients distants) à confronter à FR-10 et FR-14. Décision d'Arthur après US-063.
- **Q15 :** l'isolation forte (session enfant, prise en charge sur Windows 11 Pro d'après Power Automate) fait-elle l'objet d'un PRD séparé ? Décision d'Arthur après la livraison 2.
- **Q16 :** quel budget pour la campagne de US-063 (environ 8 tâches × 3 répétitions × 2 modes, plus 20 tâches × 3 répétitions, soit 108 exécutions) ? Décision d'Arthur avant US-063.
- **Q17 :** `clipboard` `get` reste-t-il permis en mode arrière-plan ? Il ne gêne pas l'utilisateur mais lit ce qu'il vient de copier. Recommandé : permis, sous `system.clipboard`. Décision d'Arthur dans US-039.
[/PRD]
