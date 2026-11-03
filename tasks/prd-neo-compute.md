[PRD]
# PRD: neo-compute, computer-use natif Windows pour Claude Code

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-11-03 | Arthur Jean | Version initiale : R1 Windows (EP-001 à EP-004), R2 macOS (EP-005), R3 Linux X11/Wayland (EP-006), gate de bascule Zig vers Rust |
| 1.1 | 2026-11-03 | Arthur Jean | Périmètre réduit à Windows : EP-005 (macOS) et EP-006 (Linux) retirés ; le portage Linux fera l'objet d'un PRD dédié |

## Problem Statement

1. **La CLI Claude Code n'a aucun computer-use sous Windows.** Le serveur intégré `computer-use` est limité à macOS, aux plans Pro/Max/Ultra et aux sessions interactives, pas `-p` ([Claude Code computer use](https://code.claude.com/docs/en/computer-use)). Sur la machine principale d'Arthur (Windows 11 Pro 10.0.26300, deux écrans, RTX 4070 Ti SUPER + iGPU AMD Radeon), l'agent ne peut piloter aucune application graphique hors navigateur.
2. **L'observation par screenshot coûte cher à chaque tour.** Une image coûte ceil(w/28) × ceil(h/28) tokens, soit 1 196 tokens en 1280x720 et 1 000 à 1 800 tokens aux résolutions recommandées ([Vision](https://platform.claude.com/docs/en/build-with-claude/vision)). Le toolset `computer` ajoute environ 4 500 tokens d'overhead par requête ([Computer use tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool)). Une boucle qui re-capture après chaque action paie ce coût à chaque étape.
3. **Les serveurs existants paient en latence et en stabilité.** Windows-MCP (Python, UIA) sérialise la capture d'arbre pour éviter les deadlocks de marshaling COM et a dû ajouter un snapshot borné et un watchdog de reconnexion COM en v0.8.5 ([Windows-MCP releases](https://github.com/CursorTouch/Windows-MCP/releases)).
4. **L'arbre d'accessibilité brut n'est pas gratuit.** OSWorld-Human mesure qu'ajouter l'arbre aux screenshots augmente nettement la latence par tâche et parfois le nombre d'étapes sur Chrome et VS Code ([arXiv 2506.16042](https://arxiv.org/pdf/2506.16042)). Le levier est un arbre élagué, demandé à la volée et différentiel.
5. **Chaque aller-retour modèle coûte de 1 à 5 s.** Le temps local (capture, encodage, IPC d'accessibilité) doit rester négligeable devant ce coût, et le serveur doit supprimer des allers-retours : stabilisation gérée côté serveur, observation post-action incluse dans la réponse.

**Why now:** (a) Claude 5.5+ n'accepte plus que `computer_toolset_20260801` (17 outils, sans champ `action`) : le schéma d'actions de référence est stable et documenté. (b) Claude Code diffère le chargement des outils MCP et propose `anthropic/alwaysLoad` pour les outils critiques ([Claude Code MCP](https://code.claude.com/docs/en/mcp)) : le coût contextuel d'un serveur riche devient maîtrisable. (c) Chrome expose son arbre UIA natif par défaut depuis Chrome 138 ([Chrome UIA](https://developer.chrome.com/blog/windows-uia-support-update)). (d) Zig 0.17.0 est installé et c'est la version exigée par Ghostty (`C:/dev/ghostty/build.zig.zon:7`), qui fournit une base de code de référence dans la version exacte. (e) Windows ouvre des connecteurs d'agents MCP (On-Device Registry en preview depuis Ignite 2025) : le pilotage du poste par MCP devient une voie standard.

## Overview

neo-compute est un binaire Zig unique, sans runtime, qui parle MCP sur stdio et donne à Claude Code la perception et l'action sur le bureau. Il expose deux familles d'outils. La première reproduit à l'identique les 17 membres du `computer_toolset_20260801` (noms et paramètres) pour profiter des comportements appris par le modèle. La seconde ajoute l'accessibilité (`ui_tree`, `ui_find`, `ui_act`) et les fenêtres (`window_list`, `window_focus`) : l'agent agit par identifiant d'élément sans coordonnées, et chaque action renvoie par défaut un delta d'arbre compact (médiane visée ≤ 150 tokens) après stabilisation de l'interface, au lieu d'un screenshot (environ 1 200 tokens).

L'architecture sépare un cœur mince, sans dépendance Windows, et un backend Windows. Le cœur contient le transport MCP écrit à la main (JSON-RPC délimité par newline), un registre d'outils dont les schémas JSON sont dérivés des types Zig au comptime, le moteur d'IDs stables et de diff, le sérialiseur compact, le pipeline image (réduction `@Vector`, encodage JPEG), la politique de sécurité, le journal d'audit, le bench et le selftest. Le backend implémente une interface unique (capture, entrée, accessibilité, fenêtres, kill switch), doublée d'un backend factice pour tester le cœur ; ce découpage prépare le portage Linux sans le construire. La mémoire suit une arena par requête réinitialisée par `reset(.retain_with_limit(N))`, avec zéro allocation du GPA sur le chemin chaud en régime établi. Sous Windows : bindings COM générés depuis win32metadata par un générateur maison, DXGI Desktop Duplication persistante par sortie (dirty rects réutilisés pour détecter la stabilisation), UIA sur un worker MTA dédié avec CacheRequest, SendInput, DPI Per-Monitor V2, hooks bas niveau pour le kill switch.

Le périmètre est Windows uniquement : 4 epics, 19 stories, 68 points. Le portage Linux fera l'objet d'un PRD séparé, construit sur Fedora une fois neo-compute validé sous Windows. Le premier story (US-001) est un spike qui valide que Zig pilote COM de façon fiable. Il porte le critère formel de bascule vers Rust (voir Rust Switch Gate) et passe avant tout investissement dans le cœur, ce qui borne le coût d'un changement de langage à une sonde.

## Goals

| Goal | Month-1 Target | Month-6 Target |
|------|---------------|----------------|
| Latence locale d'un screenshot (capture + réduction + encodage) | p95 < 30 ms | p95 < 20 ms (décision SIMD appliquée) |
| Latence d'un snapshot d'accessibilité de la fenêtre au premier plan (≤ 400 nœuds, apps natives) | p95 < 50 ms | p95 < 50 ms, et < 120 ms sur Chromium et Electron |
| Tokens par observation post-action (delta) | médiane ≤ 150 tokens | médiane ≤ 120 tokens |
| Allers-retours modèle par tâche sur la suite de référence, comparés au mode vision du même serveur | -30 % | -45 % |
| Taux de réussite sur la suite de tâches de référence | ≥ 80 % | ≥ 85 % |

## Target Users

### Arthur (développeur, utilisateur principal)
- **Role:** ingénieur et fondateur, pilote Claude Code au quotidien sous Windows 11 (desktop, deux écrans, double GPU).
- **Behaviors:** délègue à Claude Code via Bash, des serveurs MCP et Claude in Chrome ; travaille avec Zed, VS Code, Windows Terminal et des navigateurs.
- **Pain points:** aucune action GUI depuis la CLI sous Windows ; serveurs Python lents (200 à 500 ms par action rapportés par une source tierce, non vérifié) ; screenshots coûteux en tokens ; pas de contrôle fin de ce que l'agent peut toucher.
- **Current workaround:** Claude in Chrome pour le web uniquement, scripts PowerShell ou AutoHotkey ponctuels, ou l'action faite à la main.
- **Success looks like:** l'agent lit et pilote n'importe quelle app Windows avec moins de 1 s de temps serveur cumulé par tâche (hors stabilisation), et Arthur l'interrompt en moins de 100 ms d'une touche.

### Claude Code (agent consommateur des outils)
- **Role:** le modèle (Opus 5.5 et suivants) qui appelle les outils MCP.
- **Behaviors:** entraîné sur le toolset `computer` ; émet plusieurs `tool_use` par tour ; outils MCP différés par défaut ; parallélise les outils annotés `readOnlyHint`.
- **Pain points:** coordonnées décalées sous scaling DPI ; arbres Electron et Chromium qui saturent le contexte (avertissement à 10 000 tokens, plafond `MAX_MCP_OUTPUT_TOKENS` de 25 000) ; état périmé entre deux observations ; screenshots sans structure.
- **Current workaround:** re-capturer après chaque action et insérer des `wait` arbitraires.
- **Success looks like:** des IDs stables, un delta après chaque action, une stabilisation gérée par le serveur.

### Développeurs Claude Code sous Windows (secondaire)
- **Role:** utilisateurs de la CLI sans computer-use natif.
- **Behaviors:** utilisent Windows-MCP ou des scripts maison.
- **Pain points:** runtime Python à installer, latence, arbres bloquants.
- **Current workaround:** Windows-MCP, AutoHotkey, scripts.
- **Success looks like:** un binaire unique enregistré en une commande `claude mcp add`.

## Research Findings

Key findings that informed this PRD:

### Competitive Context
- **Claude Code `computer-use` intégré :** vision pure, CLI macOS uniquement, approbation par app et par session, Échap global consommé, terminal exclu des captures, une session à la fois. neo-compute reprend ces garde-fous, ajoute l'accessibilité d'abord et cible la CLI sous Windows.
- **Windows-MCP (CursorTouch) :** Python et UIA, CacheRequest, capture séquentielle anti-deadlock, snapshot borné, watchdog COM. neo-compute est natif, isole UIA sur un worker MTA unique, mesure chaque étape et renvoie des deltas.
- **Microsoft UFO2 :** hybride UIA + OmniParser, vérification de préconditions UIA avant chaque action. neo-compute reprend les préconditions, sans modèle de vision local.
- **Market gap:** aucun serveur computer-use natif, sans runtime, accessibilité d'abord, avec observations différentielles et budgets de latence mesurés, n'existe sous Windows pour Claude Code.

### Best Practices Applied
- Résolutions 1024x768 ou 1280x720, jamais au-delà de 1920x1080 ; coordonnées dans l'espace pixel du screenshot, facteur d'échelle conservé côté serveur.
- UIA appelé depuis un thread sans fenêtre en MTA, handlers ajoutés et retirés sur le même thread ; CacheRequest pour regrouper propriétés et patterns en un aller-retour cross-process.
- MCP : erreurs d'exécution dans le résultat avec `isError: true`, erreurs de protocole en JSON-RPC.
- Préconditions vérifiées avant chaque action (UFO2).
- Contenu à l'écran traité comme une injection potentielle, privilèges minimaux, confirmation humaine des actions à conséquences.

### Sources
- [Computer use tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool), [Vision](https://platform.claude.com/docs/en/build-with-claude/vision)
- [Claude Code MCP](https://code.claude.com/docs/en/mcp), [Claude Code env vars](https://code.claude.com/docs/en/env-vars), [Claude Code computer use](https://code.claude.com/docs/en/computer-use)
- [MCP 2025-11-25 schema](https://modelcontextprotocol.io/specification/2025-11-25/schema)
- [UIA threading](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading), [IUIAutomationCacheRequest](https://learn.microsoft.com/en-us/windows/desktop/api/uiautomationclient/nn-uiautomationclient-iuiautomationcacherequest), [IsBorderRequired](https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.isborderrequired)
- [Chrome UIA](https://developer.chrome.com/blog/windows-uia-support-update)
- [Windows-MCP](https://github.com/CursorTouch/Windows-MCP/releases), [UFO2](https://arxiv.org/html/2504.14603v2), [OSWorld-Human](https://arxiv.org/pdf/2506.16042), [zigwin32gen](https://gittrend.io/repo/marlersoft/zigwin32gen), [fpng benchmarks](https://github.com/nigeltao/qoir/blob/main/doc/full_benchmarks.txt)

*Full research sources available in project documentation.*

## Assumptions & Constraints

### Assumptions (to validate)
- **A1 :** Zig 0.17 pilote COM (UIA, DXGI, D3D11) de façon fiable avec des vtables générées : refcount, MTA, HRESULT, BSTR, VARIANT, SAFEARRAY. Non confirmé, car la std ne fournit ni `CoInitializeEx` ni `HRESULT`. Validé par US-001.
- **A2 :** le modèle utilise un miroir MCP du toolset aussi bien que le toolset natif. Non garanti : les comportements entraînés et le classifieur d'injection sont documentés pour le toolset de l'API, pas pour les outils MCP. Validé par US-016.
- **A3 :** un arbre élagué et différentiel réduit tokens et allers-retours face à la vision seule. Partiellement contredit par OSWorld-Human pour l'arbre brut. Validé par US-016.
- **A4 :** 50 ms p95 est tenable pour les apps natives avec CacheRequest ; Chromium et Electron peuvent dépasser ce budget au premier snapshot (construction de l'arbre du renderer). Mesuré en US-011 et US-014.
- **A5 :** DXGI Desktop Duplication fonctionne sur les deux écrans de la machine de référence (dGPU NVIDIA + iGPU AMD) si chaque duplication est créée sur l'adaptateur qui possède la sortie. Validé en US-006.
- **A6 :** libjpeg-turbo compilée par `zig cc` sans SIMD NASM encode du 1280x720 en < 12 ms p95. Mesuré en US-007.

### Hard Constraints
- Zig 0.17.0 exactement, la version installée (`C:\Users\Arthur\AppData\Local\Programs\zig\zig-x86_64-windows-0.17.0`) et celle de Ghostty. Montée de version uniquement par décision explicite consignée.
- Pas de `@cImport` (absent de Zig 0.17) : headers C via `b.addTranslateC`, sur le modèle de `C:/dev/ghostty/pkg/translate-c/build.zig`.
- Transport MCP stdio écrit à la main, sans SDK ; stdout réservé aux messages JSON-RPC (une ligne par message) ; logs sur stderr et fichier.
- Aucune connexion réseau, entrante ou sortante, depuis le serveur.
- Binaire unique sans runtime ni installateur en v1 ; dépendances C compilées par `build.zig` et liées statiquement.
- Sous Windows, Claude Code ferme stdin puis tue le process après 300 ms : toute entrée maintenue (touches, boutons) doit être relâchée dans ce délai.
- Cible unique : Windows 11 x64 (machine de référence 10.0.26300). Le cœur n'appelle aucune API Windows, pour préparer le portage Linux du PRD suivant.
- `C:\dev\ghostty` est une référence en lecture seule : ne jamais le modifier.
- Arthur est le seul contributeur visible : aucune attribution IA dans le code, les commits ou la documentation.

### Rust Switch Gate
La bascule vers Rust (crate `windows`) est décidée si au moins une condition est vraie. La décision et les mesures sont consignées dans `docs/decisions/0001-zig-vs-rust.md`.
1. US-001 échoue après 2 tentatives sur un critère bloquant : crash, vtable incorrecte, HRESULT mal propagé.
2. Le test de fuite de US-001 montre une dérive de private bytes > 5 MB ou de handles > 0 sur 10 000 itérations, sans correctif en 2 tentatives.
3. Pendant l'implémentation de ce PRD, 3 défauts distincts imputables à la couche COM Zig (bindings, durée de vie, apartment) exigent chacun plus de 2 tentatives de correction.
4. Le générateur (US-005) ne produit pas les interfaces requises, compilables en 0.17, après 2 sessions.

Une latence hors budget ne déclenche pas la bascule si la sonde témoin en C de US-001 mesure le même coût : le goulot est alors le provider UIA, pas le langage. Le cœur étant mince, la bascule coûte le moins cher avant la fin de EP-002 ; après EP-004, elle exige une réévaluation explicite.

## Quality Gates

These commands must pass for every user story:
- `zig fmt --check .` - formatage canonique Zig
- `zig build` - compilation du binaire et des outils pour la cible hôte
- `zig build test` - tests unitaires et d'intégration, filtrables avec `-Dtest-filter=<nom>`
- `zig build cross` - compile le cœur avec le backend factice pour x86_64-linux-gnu, pour qu'aucune dépendance Windows n'entre dans le cœur (créé en US-002, exigé à partir de US-002)
- `zig build bench -- --check bench/baseline.json` - aucun p95 au-dessus de 110 % de sa référence ni de son budget absolu (créé en US-004, exigé à partir de US-004)

Pour les stories qui touchent un backend plateforme :
- exécuter `neo-compute selftest` sur la machine de référence de l'OS concerné et joindre la sortie au story.

## Epics & User Stories

### EP-001: Gate Zig/Rust et cœur MCP portable

Prouver que Zig tient COM avant tout investissement, puis poser le cœur portable : transport MCP, registre d'outils comptime, bench, générateur de bindings.

**Definition of Done:** `docs/decisions/0001-zig-vs-rust.md` conclut sur le Rust Switch Gate avec mesures ; le binaire répond à `initialize` en < 50 ms à froid ; `zig build bench` produit un rapport p50/p95/p99 par étape ; les bindings générés compilent en Zig 0.17 et remplacent les vtables de la sonde.

#### US-001: Validate assumption: Zig 0.17 pilote COM de façon fiable
**Description:** En tant qu'Arthur, je veux une sonde Zig minimale qui appelle UIA et DXGI via des vtables COM écrites à la main afin de décider Zig ou Rust avant d'investir dans le cœur.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Étant donné l'exécutable `zig build probe`, quand il initialise COM en MTA et crée `CUIAutomation`, alors il lit Name, ControlType et BoundingRectangle de la fenêtre au premier plan et de ses descendants via un `IUIAutomationCacheRequest` et les écrit sur stderr.
- [ ] Quand la sonde acquiert 100 frames DXGI Desktop Duplication de chaque écran, alors chaque frame est copiée en BGRA à la résolution physique de sa sortie.
- [ ] Étant donné 10 000 itérations snapshot + frame, quand la sonde se termine, alors la dérive de private bytes est < 5 MB et celle du nombre de handles est 0, mesurées par `GetProcessMemoryInfo` et `GetProcessHandleCount`.
- [ ] Une sonde témoin en C compilée par `zig cc` effectue le même snapshot ; les p95 Zig et C sont consignés côte à côte.
- [ ] Étant donné la fermeture de la fenêtre cible pendant le snapshot (`UIA_E_ELEMENTNOTAVAILABLE`), quand l'appel échoue, alors la sonde renvoie une erreur Zig typée sans crash ni fuite.
- [ ] `docs/decisions/0001-zig-vs-rust.md` consigne les mesures, l'état de chaque condition du Rust Switch Gate et la décision.

#### US-002: Transport MCP stdio et cycle de vie
**Description:** En tant que Claude Code, je veux un serveur MCP stdio conforme afin de découvrir et appeler les outils sans SDK ni runtime.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] Étant donné `initialize` avec une version supportée, quand le serveur répond, alors il renvoie cette version, la capacité `tools` et un champ `instructions` ≤ 1 500 caractères ; étant donné une version inconnue, alors il renvoie sa version la plus récente.
- [ ] La liste des versions supportées est vérifiée contre la spec MCP publiée la plus récente au moment de l'implémentation (2025-11-25 confirmée, 2026-07-28 annoncée par Claude Code à vérifier).
- [ ] Chaque message est lu par `takeDelimiter('\n')` et copié dans l'arena de la requête ; chaque réponse est une ligne JSON compacte suivie d'un flush.
- [ ] Étant donné une ligne JSON invalide, alors le serveur renvoie l'erreur -32700 et continue de servir ; étant donné une méthode inconnue, alors -32601 ; étant donné un outil inconnu, alors -32602.
- [ ] Étant donné `notifications/cancelled` pour une requête en cours, alors l'outil s'arrête au prochain point de contrôle et aucune réponse n'est émise pour cette requête.
- [ ] Étant donné la fermeture de stdin, quand l'EOF est lu, alors le serveur relâche toute entrée maintenue et sort avec le code 0 en < 50 ms.
- [ ] L'arena est réinitialisée par `reset(.retain_with_limit(N))` ; un test avec allocateur comptant vérifie 0 allocation du GPA sur 1 000 `ping` après 100 `ping` de préchauffage.
- [ ] Le temps entre le lancement du process et la réponse à `initialize` est < 50 ms.
- [ ] `zig build cross` compile le cœur avec le backend factice pour x86_64-linux-gnu.

#### US-003: Registre d'outils comptime et schémas dérivés des types
**Description:** En tant qu'Arthur, je veux déclarer chaque outil comme une fonction Zig typée dont le schéma JSON et le parsing sont générés au comptime afin qu'aucun schéma ne diverge du code.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-002

**Acceptance Criteria:**
- [ ] Étant donné un struct d'arguments (entiers, flottants, booléens, enums, optionnels, slices, tableaux fixes), quand le registre compile, alors `tools/list` expose un `inputSchema` équivalent : types, `required` pour les champs non optionnels, `enum` pour les enums, bornes `minimum` et `maximum` déclarées dans le type.
- [ ] Les 17 membres de `computer_toolset_20260801` sont déclarés avec leurs noms et paramètres exacts (`coordinate`, `start_coordinate`, `region`, `scroll_direction`, `scroll_amount`, `text`, `repeat` de 1 à 100, `duration` ≤ 300) ; un test compare le schéma généré à `tests/fixtures/toolset_20260801.json`.
- [ ] `screenshot`, `zoom`, `cursor_position`, `ui_tree`, `ui_find` et `window_list` portent `readOnlyHint: true` et `idempotentHint: true` ; `screenshot`, `left_click`, `type`, `key`, `scroll`, `ui_tree` et `ui_act` portent `_meta["anthropic/alwaysLoad"]: true`.
- [ ] Une description d'outil > 300 caractères, ou un total des définitions > 3 000 tokens estimés, provoque une erreur de compilation.
- [ ] Étant donné des arguments invalides (`repeat: 0`, `scroll_direction: "diagonal"`, type faux), quand l'outil est appelé, alors le résultat porte `isError: true`, nomme le champ et la contrainte, et aucune action n'est exécutée.
- [ ] Les arguments sont parsés par `std.json.parseFromValueLeaky` dans l'arena, sans allocation hors arena.

#### US-004: Harnais de benchmark, selftest et estimation de tokens
**Description:** En tant qu'Arthur, je veux mesurer chaque étape du chemin chaud dès le premier jour afin que chaque budget soit un chiffre vérifié et que toute régression bloque le build.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-002

**Acceptance Criteria:**
- [ ] Chaque requête enregistre des timings par étape (parse, dispatch, capture, réduction, encodage, accessibilité, sérialisation, écriture) avec un timer monotone, sans allocation.
- [ ] `neo-compute bench <scénario> --iterations N` produit un rapport JSON avec p50, p95, p99, max et nombre d'allocations par étape.
- [ ] `zig build bench -- --check bench/baseline.json` échoue si un p95 dépasse 110 % de sa référence ou son budget absolu (screenshot 30 ms, snapshot 50 ms).
- [ ] Avec `--trace`, chaque résultat d'outil inclut une estimation de tokens : images par ceil(w/28) × ceil(h/28), texte par un ratio octets/token calibré une fois contre l'endpoint count_tokens et stocké dans `bench/token_calibration.json`.
- [ ] `neo-compute selftest` crée sa propre fenêtre de test, vérifie capture, souris, clavier, accessibilité et mapping DPI, et sort avec un code non nul en nommant le sous-test en échec.
- [ ] Étant donné une capacité indisponible (sortie sans duplication possible, app de référence absente), quand le bench la cible, alors il la marque `unsupported` sans faire échouer les autres scénarios.

#### US-005: Générateur de bindings Win32/COM depuis win32metadata
**Description:** En tant qu'Arthur, je veux générer les bindings Win32 et COM à partir des fichiers .winmd afin de ne maintenir que la liste des API utilisées, sans dépendre de zigwin32.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-001

**Acceptance Criteria:**
- [ ] `tools/winmdgen` parse le format ECMA-335 (tables TypeDef, MethodDef, Param, Field, CustomAttribute, blobs de signature) d'un `Windows.Win32.winmd` à version épinglée, avec hash vérifié au build.
- [ ] Étant donné la liste `bindings/windows.zon`, quand `zig build` s'exécute, alors il génère extern structs, vtables COM avec héritage IUnknown, constantes, IID et signatures `callconv(.winapi)` pour exactement ces API et leurs dépendances transitives.
- [ ] La liste initiale couvre : IUIAutomation, IUIAutomation2 (ConnectionTimeout, TransactionTimeout), IUIAutomationElement, IUIAutomationElementArray, IUIAutomationCacheRequest, IUIAutomationCondition, IUIAutomationTreeWalker, les patterns Invoke, Value, Toggle, ExpandCollapse, SelectionItem et ScrollItem, IDXGIFactory1, IDXGIAdapter1, IDXGIOutput1, IDXGIOutput5, IDXGIOutputDuplication, ID3D11Device, ID3D11DeviceContext, ID3D11Texture2D, SendInput et ses structs, SetProcessDpiAwarenessContext, GetDpiForMonitor, CoInitializeEx, SysAllocString, SysFreeString, VariantClear, SafeArray*.
- [ ] Un test compare tailles et offsets d'au moins 20 structs générées (INPUT, MOUSEINPUT, KEYBDINPUT, DXGI_OUTDUPL_FRAME_INFO, VARIANT, etc.) aux `sizeof` et `offsetof` d'un programme C compilé par `zig cc` contre les headers mingw-w64 fournis par Zig.
- [ ] Les vtables écrites à la main dans la sonde US-001 sont remplacées par les bindings générés et la sonde passe toujours.
- [ ] Étant donné une API absente du .winmd, quand le générateur s'exécute, alors le build échoue en nommant l'API et le nom existant le plus proche.
- [ ] La génération complète prend < 2 s et son résultat est mis en cache par le système de build.

---

### EP-002: Perception et action Windows

Capturer l'écran et injecter les entrées avec un mapping de coordonnées exact, dans les budgets, sur la machine de référence (deux écrans, double GPU).

**Definition of Done:** les 17 outils du toolset fonctionnent sur la machine de référence ; `screenshot` p95 < 30 ms ; erreur de clic ≤ 1 px physique aux DPI 100, 125, 150 et 200 % ; aucune touche ni aucun bouton maintenu après l'EOF de stdin.

#### US-006: Capture DXGI Desktop Duplication persistante
**Description:** En tant que Claude Code, je veux une capture d'écran persistante par sortie afin d'obtenir une frame en quelques millisecondes et de savoir quelles zones ont changé.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-005

**Acceptance Criteria:**
- [ ] Le backend crée une duplication par sortie sur l'adaptateur qui la possède (IDXGIFactory1, puis adaptateurs, puis sorties), y compris sur une machine dGPU NVIDIA + iGPU AMD.
- [ ] La duplication reste ouverte entre les appels ; étant donné un écran inchangé, quand une capture est demandée, alors la dernière frame en cache est renvoyée sans attendre de nouvelle frame.
- [ ] Les dirty rects et move rects de chaque frame sont exposés au cœur pour la stabilisation (US-015).
- [ ] Étant donné `DXGI_ERROR_ACCESS_LOST` (changement de mode, UAC, plein écran exclusif), quand il survient, alors la duplication est recréée en < 500 ms et la capture suivante réussit.
- [ ] Étant donné le bureau sécurisé actif, alors l'outil renvoie `isError: true` avec « Bureau sécurisé actif (UAC ou verrouillage) : capture impossible, réessaie après sa fermeture ».
- [ ] Étant donné `DXGI_ERROR_UNSUPPORTED` sur une sortie, alors l'erreur nomme la sortie et l'adaptateur et indique que le repli WGC n'est pas disponible en v1.
- [ ] Les écrans en rotation 90, 180 et 270 produisent une image correctement orientée.
- [ ] Capture seule p95 < 8 ms pour la sortie principale de la machine de référence.

#### US-007: Réduction SIMD, encodage JPEG et outils screenshot/zoom
**Description:** En tant que Claude Code, je veux des screenshots réduits à une taille recommandée et des zooms à pleine résolution afin de payer environ 1 200 tokens par image au lieu de plusieurs milliers.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-003, US-006

**Acceptance Criteria:**
- [ ] `screenshot` renvoie un bloc image JPEG dont le côté long fait 1280 px par défaut (configurable de 1024 à 1920), ratio conservé, et un bloc texte `display=<n> scale=<f> size=<w>x<h>`.
- [ ] Le paramètre optionnel `display` choisit l'écran ; par défaut, l'écran de la fenêtre au premier plan.
- [ ] La réduction BGRA utilise un filtre par aire vectorisé `@Vector` dans des buffers préalloués ; sur une mire de test, l'erreur maximale par canal est ≤ 2 face à une implémentation scalaire de référence.
- [ ] L'encodage passe par libjpeg-turbo compilée par `build.zig` (entrée `JCS_EXT_BGRA`, qualité 80) ; si le p95 d'encodage dépasse 12 ms, la mesure est consignée et la décision SIMD NASM ou encodeur Zig est ouverte.
- [ ] `zoom` avec `region: [x0,y0,x1,y1]` exprimée dans l'espace du dernier screenshot renvoie la région à résolution physique (côté long ≤ 1280 px), qualité 90.
- [ ] Étant donné une `region` inversée, vide ou hors écran, alors `isError: true` avec les bornes valides.
- [ ] Le facteur d'échelle et l'origine de chaque écran capturé sont conservés pour mapper toutes les coordonnées entrantes.
- [ ] Capture + réduction + encodage p95 < 30 ms depuis la résolution native de l'écran principal vers 1280 px de côté long.
- [ ] Aucune image ne dépasse 1920 px de côté long.

#### US-008: Souris, mapping de coordonnées et DPI Per-Monitor V2
**Description:** En tant que Claude Code, je veux que chaque clic tombe exactement là où je vise dans le screenshot afin de supprimer les décalages dus au scaling.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-007

**Acceptance Criteria:**
- [ ] Le process appelle `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` au démarrage, avant toute création de HWND, et consigne un échec sur stderr.
- [ ] `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click`, `mouse_move`, `left_click_drag`, `left_mouse_down`, `left_mouse_up`, `cursor_position` et `scroll` respectent les paramètres du toolset, modificateurs `text` inclus (shift, ctrl, alt, super).
- [ ] Les coordonnées sont converties de l'espace screenshot vers le bureau virtuel physique (`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`), y compris pour un écran secondaire à coordonnées négatives.
- [ ] Le selftest vérifie une erreur ≤ 1 px physique sur une fenêtre de calibration aux DPI 100, 125, 150 et 200 %.
- [ ] Étant donné une coordonnée hors de l'écran capturé, alors `isError: true` avec les bornes valides et aucun mouvement.
- [ ] Étant donné une fenêtre cible d'intégrité supérieure, quand une action la vise, alors l'outil renvoie `isError: true` « Fenêtre élevée : injection bloquée par UIPI » au lieu d'un succès silencieux.
- [ ] `scroll` envoie `MOUSEEVENTF_WHEEL` ou `MOUSEEVENTF_HWHEEL`, 120 unités par cran de `scroll_amount`.

#### US-009: Clavier, saisie Unicode et relâchement garanti des entrées
**Description:** En tant que Claude Code, je veux taper du texte et des raccourcis quelle que soit la disposition clavier afin qu'une saisie produise exactement le texte demandé.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] `key` accepte la syntaxe du toolset (`ctrl+s`, `alt+F4`, `Return`, `super`) et `repeat` de 1 à 100.
- [ ] `type` envoie le texte via `KEYEVENTF_UNICODE` par lots de 64 événements au plus par appel `SendInput`, emoji (paires UTF-16) et retours à la ligne inclus.
- [ ] Étant donné une disposition AZERTY active, quand `key` reçoit `ctrl+a`, alors l'action vise la touche logique « a » via `VkKeyScanEx` sur la disposition active, vérifié par le selftest.
- [ ] `hold_key` et `wait` respectent `duration` ≤ 300 s, émettent `notifications/progress` chaque seconde si un `progressToken` est fourni, et s'arrêtent sur `notifications/cancelled`.
- [ ] Un registre de toutes les touches et de tous les boutons enfoncés garantit leur relâchement en < 50 ms à l'EOF de stdin, à l'annulation, au kill switch et sur erreur.
- [ ] Étant donné un nom de touche inconnu, alors `isError: true` listant les 5 noms valides les plus proches.

#### US-010: Outils window_list et window_focus
**Description:** En tant que Claude Code, je veux lister et activer les fenêtres afin de cibler une application sans passer par un screenshot.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] `window_list` renvoie une ligne par fenêtre visible de premier niveau : handle court, titre tronqué à 80 caractères, exécutable, pid, écran, rectangle dans l'espace screenshot de son écran, rang z, drapeaux `elevated`, `minimized`, `cloaked`.
- [ ] Les fenêtres cloaked (autres bureaux virtuels, apps suspendues) sont exclues par défaut et incluses avec `include_hidden: true`.
- [ ] `window_focus` amène la fenêtre au premier plan malgré le foreground lock, restaure une fenêtre minimisée et vérifie le résultat via `GetForegroundWindow`.
- [ ] Étant donné un handle de fenêtre fermée, alors `isError: true` « Fenêtre fermée : rappelle window_list ».
- [ ] `window_list` p95 < 5 ms pour 50 fenêtres.

---

### EP-003: Observation accessibilité d'abord (Windows)

Remplacer le screenshot systématique par un arbre UIA élagué, des IDs stables, des deltas, des actions par élément et une stabilisation gérée côté serveur.

**Definition of Done:** `ui_tree` p95 < 50 ms (≤ 400 nœuds, apps natives) ; delta médian ≤ 150 tokens ; sur la suite de référence, -30 % d'allers-retours face au mode vision sans baisse du taux de réussite.

#### US-011: Snapshot UIA borné et sérialisation compacte
**Description:** En tant que Claude Code, je veux un arbre UIA élagué de la fenêtre active en une ligne par élément afin de comprendre l'interface pour quelques centaines de tokens.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-005, US-007

**Acceptance Criteria:**
- [ ] Toutes les opérations UIA s'exécutent sur un worker unique sans fenêtre, initialisé en MTA ; les handlers sont ajoutés et retirés sur ce même thread.
- [ ] `ui_tree` capture la fenêtre au premier plan, ou celle passée dans `window`, via `FindAllBuildCache` en ControlView avec un CacheRequest d'au plus 12 propriétés et les patterns actionnables.
- [ ] Limites par défaut : profondeur 25, 1 500 nœuds, 8 000 caractères ; l'élagage retire les nœuds hors écran, sans nom ni pattern actionnable, et fusionne les conteneurs à enfant unique ; la sortie signale les coupes (`… 312 nœuds élagués`).
- [ ] Format : `<id> <rôle> "<nom>" [=valeur] {états} @x,y,w,h`, indenté par profondeur, coordonnées dans l'espace screenshot de l'écran de la fenêtre, en-tête `display=<n> scale=<f>` ; un test golden fige le format.
- [ ] La valeur d'un élément `IsPassword` n'apparaît jamais (`[=•••]`).
- [ ] Étant donné un provider qui ne répond pas en 200 ms (`IUIAutomation2` TransactionTimeout), alors l'arbre partiel est renvoyé avec `{partial: timeout}` et le worker reste utilisable pour les autres fenêtres.
- [ ] Snapshot p95 < 50 ms pour ≤ 400 nœuds sur Explorateur, Bloc-notes, Paramètres et Calculatrice.

#### US-012: IDs stables et observations différentielles
**Description:** En tant que Claude Code, je veux des identifiants d'éléments stables et des deltas entre deux observations afin de ne relire que ce qui a changé.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-011

**Acceptance Criteria:**
- [ ] Chaque élément reçoit un ID court (`e` + entier en base 36) attribué à partir de son RuntimeId UIA ; un élément garde le même ID tant qu'il existe, pendant toute la session.
- [ ] Le moteur d'IDs et de diff vit dans le cœur portable, sans dépendance Windows, et est testé avec un backend factice.
- [ ] `ui_tree` avec `since: "last"` renvoie uniquement les ajouts (`+`), suppressions (`-`) et changements (`~` nom, valeur, états, position > 4 px) depuis le dernier snapshot de la même fenêtre.
- [ ] Étant donné un changement de fenêtre au premier plan, alors un snapshot complet de la nouvelle fenêtre est renvoyé, signalé par une ligne d'en-tête.
- [ ] Étant donné un delta plus long que le snapshot complet, alors le snapshot complet est renvoyé.
- [ ] Calcul du diff p95 < 3 ms pour 1 500 nœuds ; delta médian ≤ 150 tokens sur la suite de US-016.

#### US-013: Actions par élément ui_act et recherche ui_find
**Description:** En tant que Claude Code, je veux agir sur un élément par son ID afin de ne dépendre ni des coordonnées ni du rendu.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-012

**Acceptance Criteria:**
- [ ] `ui_act(id, action)` supporte `invoke`, `toggle`, `select`, `expand`, `collapse`, `set_value`, `focus` et `scroll_into_view` via les patterns UIA correspondants.
- [ ] Avant chaque action, les préconditions sont vérifiées (élément existant, activé, à l'écran, pattern supporté) ; une précondition violée renvoie `isError: true` en la nommant.
- [ ] Étant donné un ID d'élément détruit, alors `isError: true` « Élément e1k introuvable : rappelle ui_tree » et aucune action.
- [ ] Étant donné un pattern non supporté et `fallback: "click"`, alors un clic au centre de la bounding box est injecté et la réponse le signale.
- [ ] `ui_find(query)` cherche par rôle, nom (sous-chaîne insensible à la casse et aux accents) et état, et renvoie au plus 20 lignes au format de US-011.
- [ ] `set_value` sur un champ `IsPassword` fonctionne, mais la valeur n'apparaît dans aucune sortie ni aucun log.

#### US-014: Apps Chromium, Electron et grands arbres
**Description:** En tant que Claude Code, je veux un arbre utilisable sur Edge, Chrome et VS Code afin que les apps web et Electron ne saturent ni le contexte ni le budget de latence.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-012

**Acceptance Criteria:**
- [ ] Étant donné Edge ou Chrome ≥ 138 au premier plan, quand `ui_tree` est appelé, alors le contenu web est exposé via l'UIA natif, et la durée du premier snapshot après activation est mesurée et consignée.
- [ ] Étant donné VS Code au premier plan, alors l'arbre de l'éditeur et des panneaux est exposé ; si Electron n'expose rien, l'outil renvoie l'arbre natif et une ligne indiquant `screenshot` comme alternative.
- [ ] L'élagage par viewport ne garde que les nœuds web qui intersectent la zone visible, plus leurs ancêtres.
- [ ] Étant donné un arbre de 20 000 nœuds, alors l'arena reste < 32 MB et la sortie respecte la limite de 8 000 caractères.
- [ ] Snapshot p95 < 120 ms sur VS Code et sur Edge avec une page de référence fixe, hors premier snapshot.

#### US-015: Stabilisation côté serveur et observation post-action
**Description:** En tant que Claude Code, je veux que chaque action attende que l'interface se stabilise puis renvoie l'observation demandée afin de supprimer les `wait` arbitraires et un aller-retour par action.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-006, US-009, US-012

**Acceptance Criteria:**
- [ ] Après une action, le serveur considère l'interface stable quand aucune dirty rect n'apparaît sur deux acquisitions espacées d'au moins 50 ms, ou à l'expiration de `settle_timeout_ms` (défaut 1 500, max 10 000).
- [ ] Chaque outil d'action accepte `observe: "delta" | "screenshot" | "none"`, défaut `delta`, et renvoie l'observation après stabilisation.
- [ ] L'observation indique `settled in <n> ms` ou `settle timeout`.
- [ ] Étant donné une animation continue (vidéo, spinner), alors le délai expire et l'observation est renvoyée avec `settle timeout`, sans erreur.
- [ ] Le temps de stabilisation est mesuré séparément dans le bench et exclu des budgets de capture.

#### US-016: Suite de tâches agentiques et A/B vision contre accessibilité
**Description:** En tant qu'Arthur, je veux une suite reproductible de tâches Windows exécutée par `claude -p` afin de mesurer réussite, allers-retours et tokens, et de valider A2 et A3 par des chiffres.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-013, US-015

**Acceptance Criteria:**
- [ ] `evals/windows/` contient 20 tâches avec état initial scripté et vérification automatique de l'état final (fichiers, registre, valeurs UIA), sur Bloc-notes, Explorateur, Paramètres, Edge, VS Code et Calculatrice.
- [ ] Un runner exécute chaque tâche via `claude -p` avec la config MCP du projet, 3 répétitions, et enregistre réussite, appels d'outils, tours modèle, tokens d'entrée et durée.
- [ ] Le runner compare `--mode vision` (outils du toolset seuls, `observe: "screenshot"` par défaut) et `--mode a11y` (défaut), plus Windows-MCP à version épinglée comme baseline externe.
- [ ] Étant donné une tâche qui dépasse 10 minutes, alors elle est marquée échouée avec la cause `timeout` et la suite continue.
- [ ] `evals/reports/<date>.md` conclut sur A2 et A3 (validée, invalidée, non concluante) avec les chiffres.

---

### EP-004: Sécurité, contrôle humain et audit

Limiter l'agence par application, rendre l'interruption physique immédiate et garder une trace complète sans fuite de secrets.

**Definition of Done:** kill switch physique effectif en < 100 ms ; 0 valeur `IsPassword` dans les sorties, images et logs sur la suite de US-016 ; politique par application appliquée avant chaque action ; aucun import réseau dans le binaire.

#### US-017: Politique de contrôle par application
**Description:** En tant qu'Arthur, je veux attribuer un niveau de contrôle à chaque application afin que l'agent ne puisse pas taper dans un terminal ou un gestionnaire de mots de passe sans mon accord explicite.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-008

**Acceptance Criteria:**
- [ ] `%APPDATA%\neo-compute\policy.json`, ou le chemin passé par `--policy`, attribue un niveau par exécutable : `deny`, `observe`, `click` ou `full` ; le défaut est `full`.
- [ ] Les gestionnaires de mots de passe d'une liste versionnée dans le dépôt sont en `deny` par défaut ; les terminaux et IDE (Windows Terminal, conhost, VS Code, Zed) sont en `click` par défaut, car y taper revient à un accès shell hors des permissions Claude Code.
- [ ] Avant chaque action, l'application cible (fenêtre sous le point ou propriétaire de l'élément) est résolue et son niveau appliqué ; un refus renvoie `isError: true` « Politique : <app> est en mode <niveau> ».
- [ ] Une application en `deny` est masquée en noir dans les screenshots et absente de `ui_tree` et `window_list`.
- [ ] Étant donné un fichier de politique invalide, alors le serveur démarre en `observe` global et `instructions` le signale avec la ligne fautive.
- [ ] La résolution de politique coûte < 0,2 ms par action grâce à un cache pid vers niveau.

#### US-018: Kill switch physique et reprise de contrôle
**Description:** En tant qu'Arthur, je veux arrêter l'agent d'une touche ou en bougeant la souris afin de reprendre la main en moins de 100 ms, sans qu'une injection puisse le relancer.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-009

**Acceptance Criteria:**
- [ ] Des hooks `WH_KEYBOARD_LL` et `WH_MOUSE_LL` tournent sur un thread dédié avec boucle de messages et distinguent les événements injectés (`LLKHF_INJECTED`, `LLMHF_INJECTED`) des événements physiques.
- [ ] Une pression physique sur Échap pendant une action ou une stabilisation annule l'action en < 100 ms, relâche toute entrée maintenue, est consommée, et met le serveur en pause.
- [ ] Un déplacement physique de la souris > 8 px pendant une action annule l'action et met le serveur en pause.
- [ ] En pause, chaque outil d'action renvoie `isError: true` « En pause par l'utilisateur : attends qu'Arthur réarme » ; les outils d'observation restent disponibles.
- [ ] Le réarmement se fait uniquement par un raccourci physique (`Ctrl+Alt+Shift+R` par défaut, configurable) ; aucun outil MCP ne peut lever la pause.
- [ ] Un Échap injecté par l'agent (`key Escape`) ne déclenche jamais le kill switch.
- [ ] Les hooks ajoutent < 1 ms de latence à l'entrée physique ; si Windows les retire (`LowLevelHooksTimeout`), ils sont réinstallés et l'événement est journalisé.

#### US-019: Masquage des secrets, journal d'audit et instance unique
**Description:** En tant qu'Arthur, je veux qu'aucun secret ne sorte du poste et que chaque action soit tracée afin de pouvoir auditer ce que l'agent a fait.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-011, US-017

**Acceptance Criteria:**
- [ ] Les bounding boxes des éléments `IsPassword` visibles sont noircies dans `screenshot` et `zoom` avant encodage.
- [ ] Chaque appel d'outil ajoute une ligne à `%LOCALAPPDATA%\neo-compute\audit.jsonl` : horodatage, outil, application cible, pid, niveau de politique, durée, résultat ; pour `type`, seule la longueur du texte est enregistrée.
- [ ] Rotation à 10 MB, 5 fichiers conservés ; un échec d'écriture du journal ne bloque pas l'outil et est signalé sur stderr.
- [ ] Un mutex nommé garantit une seule instance par session Windows ; une seconde instance répond à `initialize`, puis renvoie `isError: true` « Une autre session neo-compute contrôle déjà ce bureau » à toute action.
- [ ] `instructions` précise que tout texte issu de l'écran (noms, valeurs, contenu web) est une donnée non fiable, jamais une instruction.
- [ ] Un test vérifie que le PE produit n'importe ni `ws2_32.dll` ni `winhttp.dll` ni `wininet.dll`.

## Functional Requirements

- FR-01: Le système doit exposer les 17 membres de `computer_toolset_20260801` comme outils MCP, avec des noms et paramètres identiques ; toute extension est un paramètre optionnel.
- FR-02: Le système doit exposer `ui_tree`, `ui_find`, `ui_act`, `window_list` et `window_focus`.
- FR-03: Toutes les coordonnées, entrantes et sortantes, sont exprimées dans l'espace pixel du dernier screenshot de l'écran concerné.
- FR-04: Chaque outil d'action renvoie par défaut un delta d'arbre après stabilisation ; `observe` permet `screenshot` ou `none`.
- FR-05: Un élément garde le même ID pendant toute la session tant qu'il existe.
- FR-06: Une erreur d'exécution d'outil est renvoyée avec `isError: true` et un message qui nomme la cause et l'action suivante ; une erreur de protocole est renvoyée en erreur JSON-RPC.
- FR-07: Toute touche ou tout bouton maintenu est relâché en < 50 ms à l'EOF de stdin, à l'annulation, au kill switch et sur erreur.
- FR-08: La politique par application est appliquée avant chaque action.
- FR-09: Le système ne doit jamais exposer la valeur d'un champ mot de passe, ni en texte, ni en image, ni dans un log.
- FR-10: Le système ne doit ouvrir aucune connexion réseau.
- FR-11: Le système ne doit exposer aucun outil d'exécution de commande ou de script.
- FR-12: Seul un geste physique de l'utilisateur peut lever la pause déclenchée par le kill switch.
- FR-13: Chaque appel d'outil est journalisé en JSONL sans le texte saisi.
- FR-14: Une seule instance contrôle un bureau à la fois.
- FR-15: Les outils d'observation portent `readOnlyHint` et `idempotentHint` ; les outils du noyau portent `anthropic/alwaysLoad`.
- FR-16: Une sortie texte d'outil fait au plus 8 000 caractères par défaut (configurable jusqu'à 40 000), sous le seuil d'avertissement de 10 000 tokens de Claude Code.
- FR-17: Une image renvoyée est un JPEG de 1920 px au plus côté long.
- FR-18: stdout ne contient que des messages JSON-RPC ; les logs vont sur stderr et dans un fichier.
- FR-19: `--mode vision` restreint le serveur aux outils du toolset pour les comparaisons A/B.
- FR-20: Les sous-commandes `bench` et `selftest` sont disponibles dans le binaire livré.

## Non-Functional Requirements

- **Performance:** screenshot (capture + réduction + encodage) p95 < 30 ms ; capture seule p95 < 8 ms ; snapshot d'accessibilité p95 < 50 ms pour ≤ 400 nœuds (apps natives), < 120 ms pour Chromium et Electron ; diff p95 < 3 ms pour 1 500 nœuds ; injection d'une action p95 < 5 ms hors stabilisation ; surcoût du transport (parse + dispatch + sérialisation) p95 < 1 ms ; réponse à `initialize` < 50 ms après le lancement.
- **Footprint:** binaire ReleaseFast strippé ≤ 3 MB ; RSS au repos < 15 MB, < 80 MB pendant la capture ; 0 allocation du GPA par requête en régime établi sur `screenshot`, `left_click` et `ui_tree` delta.
- **Security:** mitigations OWASP LLM01 (texte d'écran présenté comme donnée non fiable, politique par app), LLM02 (masquage `IsPassword`, audit sans texte saisi) et LLM06 (niveaux `deny`/`observe`/`click`/`full`, kill switch, aucun outil shell) ; 0 connexion réseau ; 0 fuite de valeur de mot de passe sur la suite de US-016.
- **Accessibility:** le serveur ne modifie aucun réglage d'accessibilité système ; Narrateur et NVDA fonctionnent pendant l'usage, vérifié une fois par version publiée.
- **Scalability:** jusqu'à 4 écrans et 7680x4320 par écran ; arbres de 20 000 nœuds traités avec une arena < 32 MB ; session de 8 h sans dérive de RSS > 10 MB.
- **Reliability:** recréation de la duplication après `DXGI_ERROR_ACCESS_LOST` en < 500 ms ; 0 crash sur 10 000 actions consécutives ; dérive < 5 MB de private bytes et 0 handle sur 10 000 opérations COM ; un provider bloqué n'affecte pas les appels vers les autres fenêtres.

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | Aucune fenêtre active | Bureau seul, toutes les fenêtres minimisées | `ui_tree` renvoie l'arbre borné du bureau et de la barre des tâches | « Aucune fenêtre active : arbre du bureau renvoyé » |
| 2 | Provider lent | App occupée, provider UIA qui ne répond pas | Arbre partiel après 200 ms, worker intact | `{partial: timeout}` en tête de sortie |
| 3 | Perte de capture | `DXGI_ERROR_ACCESS_LOST`, changement de mode, plein écran exclusif | Duplication recréée en < 500 ms, une nouvelle tentative | Aucun si la reprise réussit, sinon « Capture réinitialisée : réessaie » |
| 4 | Système sous charge | Compilation ou jeu à 100 % CPU/GPU (remplace « réseau dégradé », sans objet : aucun réseau) | Timings journalisés, stabilisation bornée par `settle_timeout_ms` | `settle timeout` dans l'observation |
| 5 | Fenêtre élevée | Cible lancée en administrateur (UIPI) | Action refusée avant injection | « Fenêtre élevée : injection bloquée par UIPI. Relance l'app sans élévation ou agis toi-même. » |
| 6 | Session inactive | Session RDP déconnectée ou changement rapide d'utilisateur | Capture et entrée refusées, reprise automatique au retour de la session | « Session Windows inactive : capture impossible tant que la session n'est pas au premier plan » |
| 7 | Bureau sécurisé | UAC, Ctrl+Alt+Suppr, écran de verrouillage | Capture et entrée refusées | « Bureau sécurisé actif : capture impossible, réessaie après sa fermeture » |
| 8 | Reprise de contrôle | Arthur bouge la souris (> 8 px) ou presse Échap pendant une action | Action annulée en < 100 ms, entrées relâchées, serveur en pause | « En pause par l'utilisateur : attends qu'Arthur réarme » |
| 9 | Élément périmé | Fenêtre ou élément détruit entre `ui_tree` et `ui_act` | Aucune action | « Élément e1k introuvable : rappelle ui_tree » |
| 10 | Coordonnées hors bornes | Coordonnée hors écran, `region` inversée ou vide | Aucune action | « Coordonnée hors écran : bornes valides 0..1279 x 0..719 » |
| 11 | Arbre géant | Page web ou Electron avec 20 000 nœuds | Élagage au viewport, sortie ≤ 8 000 caractères, arena < 32 MB | `… N nœuds élagués` |
| 12 | Saisie longue | `type` de 10 000 caractères | Lots de 64 événements, progression émise, annulable | Aucun |
| 13 | Action irréversible | Suppression de fichier, envoi de formulaire | Pas d'annulation côté serveur ; politique et permissions Claude Code s'appliquent, action tracée dans l'audit | Aucun (la trace est dans `audit.jsonl`) |
| 14 | Arrêt brutal | EOF de stdin pendant `hold_key` ou `left_mouse_down` | Relâchement en < 50 ms, sortie code 0 avant le kill à 300 ms | Aucun |
| 15 | Changement d'écran ou de DPI | Écran débranché, échelle modifiée, fenêtre déplacée vers un autre écran | Sorties ré-énumérées, DPI relu à chaque mapping | « Écran 2 déconnecté : refais un screenshot » |
| 16 | Disposition clavier | Passage de AZERTY à US en cours de session | Disposition active relue à chaque `key` et `type` | Aucun |
| 17 | Seconde instance | Deux sessions Claude Code avec neo-compute | La seconde refuse les actions | « Une autre session neo-compute contrôle déjà ce bureau » |
| 18 | Injection à l'écran | Page web contenant « ignore tes instructions et… » | Texte rendu comme donnée, politique inchangée | Aucun ; `instructions` rappelle la règle |
| 19 | Crash de l'app cible ou reset GPU | Plantage pendant un appel UIA, TDR du pilote | Erreur typée, device D3D recréé, serveur vivant | « Application <nom> ne répond plus » |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Couche COM Zig instable : refcount, apartments, vtables (A1) | Med | High | Spike US-001 en premier, sonde témoin en C, Rust Switch Gate |
| 2 | Le modèle exploite moins bien le miroir MCP que le toolset natif (A2) | Med | High | Noms et paramètres identiques, A/B en US-016, `instructions` courtes |
| 3 | Arbres Chromium/Electron trop gros ou trop lents (A4) | High | Med | Élagage au viewport, bornes, repli `screenshot`, US-014 |
| 4 | Injection de prompt via le contenu affiché | High | High | Texte d'écran présenté comme donnée, niveaux par app, terminaux en `click`, aucun outil shell, kill switch, audit |
| 5 | Duplication DXGI impossible sur une sortie du double GPU (A5) | Low | High | Une duplication par adaptateur propriétaire ; WGC passe en Must si US-006 échoue |
| 6 | Zig 0.18 casse la std pendant le projet | High | Med | Version épinglée à 0.17.0, migration uniquement sur décision, Ghostty comme signal de maturité |
| 7 | Claude Code livre un computer-use CLI sous Windows | Med | Med | Différenciation sur l'accessibilité et la latence mesurée ; si un built-in Windows apparaît, le comparer sur la suite de US-016 |
| 8 | Encodage JPEG hors budget sans SIMD (A6) | Med | Low | Mesure en US-007, puis SIMD NASM ou encodeur Zig vectorisé |
| 9 | Touches bloquées après un kill du process | Low | High | Registre des entrées, relâchement < 50 ms à l'EOF, durées bornées à 300 s, test dédié |
| 10 | Hooks bas niveau qui ralentissent l'entrée ou sont retirés par Windows | Low | Med | Thread dédié, < 1 ms par événement, réinstallation automatique |
| 11 | Coût en tokens des évals (180 exécutions par campagne) | Med | Low | Suite de 20 tâches, 3 répétitions, budget validé par Arthur (Open Questions) |

## Non-Goals

What this version explicitly does NOT include:

- **Modèle de vision local (OmniParser, OCR) :** coûteux en taille et en GPU ; le modèle Claude assure le grounding visuel. À revisiter si US-016 montre des échecs de grounding récurrents.
- **Outil d'exécution de commandes :** Claude Code a déjà Bash avec son propre système de permissions.
- **Transport HTTP ou pilotage à distance :** stdio local uniquement.
- **Bureau sécurisé et contournement d'UIPI (`uiAccess`) :** exigeraient une signature et une installation dans Program Files.
- **Inscription Windows ODR, signature de code Windows et distribution winget ou scoop :** revisitées après la v1 (Open Questions).
- **Repli Windows.Graphics.Capture, réduction sur GPU, outil `batch` et PNG sans perte :** classés Could, hors v1 sauf si une mesure les rend nécessaires (A5, A6).
- **Plusieurs agents simultanés sur un même bureau :** une seule instance par session.
- **Windows 10 :** non testé (fin de support en octobre 2025).
- **Portage Linux :** PRD séparé, construit sur Fedora (dual boot) une fois neo-compute validé sous Windows. Ce PRD se limite à garder le cœur sans dépendance Windows (`zig build cross`).
- **macOS :** hors périmètre ; le computer-use intégré de Claude Code couvre déjà la CLI macOS.

## Technical Considerations

Frame as questions for engineering input, not mandates:

- **Architecture:** backend Windows et backend factice sélectionnés au comptime (aucune indirection, code mort éliminé) ou interface dynamique par vtable ? Recommandé : comptime. Engineering to confirm feasibility.
- **Threads:** recommandé : trois threads sous Windows (stdio et dispatch, worker UIA en MTA, hooks avec boucle de messages), la capture DXGI restant sur le thread principal car `AcquireNextFrame` à timeout 0 ne bloque pas. Faut-il un thread de capture dédié si la stabilisation dépasse 50 ms par action ?
- **Data Model:** format ligne pour l'arbre ou JSON ? Recommandé : format ligne, plus compact ; `structuredContent` n'est pas documenté dans Claude Code, donc pas en v1. Trade-off : un parsing côté client impossible, accepté car le seul client est le modèle.
- **API Design:** les 17 outils du toolset plus 5 outils propres, soit 22 définitions. Faut-il fusionner `ui_find` dans `ui_tree` pour rester sous 3 000 tokens de définitions ? À trancher sur la mesure de US-003.
- **Timeouts UIA:** `IUIAutomation2` ConnectionTimeout et TransactionTimeout, ou un watchdog maison ? Recommandé : les propriétés `IUIAutomation2`, plus un budget par appel.
- **Bindings:** générateur maison guidé par une liste, ou fork de zigwin32gen si son support de Zig 0.17 est confirmé ? Recommandé : générateur maison (US-005), car seules quelques dizaines d'interfaces sont nécessaires.
- **Dependencies:** libjpeg-turbo, en version épinglée et compilée par `build.zig`. Faut-il activer son SIMD NASM (un outil de build en plus) ou écrire un encodeur Zig vectorisé ? À décider sur la mesure de US-007.
- **Config format:** JSON (std.json, déjà utilisé, éditable par humain et agent) ou ZON ? Recommandé : JSON.
- **MCP version:** 2025-11-25 confirmée ; Claude Code annonce un runtime sur le protocole 2026-07-28. Faut-il le supporter dès US-002 ? À vérifier sur la spec publiée.
- **Migration:** aucune (projet vierge). Pas de rétrocompatibilité requise. Retour arrière : le Rust Switch Gate.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Screenshot p95 (capture + réduction + encodage) | N/A (nouveau) ; Windows-MCP mesuré en US-016 | < 30 ms | Month-1 | `zig build bench` |
| Snapshot UIA p95, ≤ 400 nœuds | Windows-MCP mesuré en US-016 | < 50 ms | Month-1 | `zig build bench` |
| Tokens médians par observation post-action | 1 196 (screenshot 1280x720 en mode vision) | ≤ 150, puis ≤ 120 | Month-1, Month-6 | `--trace` et calibration count_tokens |
| Allers-retours modèle par tâche | Mode vision du même serveur (US-016) | -30 %, puis -45 % | Month-1, Month-6 | Runner de US-016 |
| Taux de réussite sur la suite de référence | Mode vision et Windows-MCP (US-016) | ≥ 80 %, puis ≥ 85 % | Month-1, Month-6 | Runner de US-016 |
| Temps serveur cumulé par tâche, hors stabilisation | N/A (nouveau) | < 1 s p95 | Month-1 | Durées de `audit.jsonl` |
| Tokens des définitions d'outils | ≈ 4 500 (overhead du toolset API) | ≤ 3 000 | Month-1 | count_tokens sur `tools/list` |
| Taille du binaire et RSS en capture | N/A (nouveau) | ≤ 3 MB et < 80 MB | Month-1 | Build ReleaseFast et `GetProcessMemoryInfo` |
| Apps de référence couvertes par le selftest et la suite | Aucune | 6 (Bloc-notes, Explorateur, Paramètres, Calculatrice, Edge, VS Code) | Month-1 | `neo-compute selftest` et runner de US-016 |

## Open Questions

- **Q1 :** quelles différences entre le protocole MCP 2026-07-28 (runtime v2 de Claude Code) et 2025-11-25 ? À vérifier pendant US-002, avant de figer la négociation de version.
- **Q2 :** Claude Code supporte-t-il l'elicitation MCP, ce qui permettrait un niveau de politique `confirm` (confirmation humaine par action) ? Non documenté. À vérifier par Arthur avant EP-004 ; cela décide si US-017 ajoute ce niveau.
- **Q3 :** faut-il viser l'inscription Windows ODR (agent connectors), avec signature de code et packaging ? Décision d'Arthur après la v1.
- **Q4 :** publication open source et licence ? Décision d'Arthur avant toute publication du dépôt.
- **Q5 :** quel budget en tokens pour les campagnes d'évals (20 tâches × 3 répétitions × 3 configurations = 180 exécutions) ? Décision d'Arthur avant US-016.
[/PRD]

