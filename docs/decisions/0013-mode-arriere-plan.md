# 0013 : contrat du mode arrière-plan

- Statut : décidé par Arthur le 2026-11-12, amendé le 2026-11-13 (dernière section)
- Date : 2026-11-12
- Story : US-039 (décisions) et US-040 (sonde des primitives), PRD `tasks/prd-background-mode.md`

## Décisions de contrat

Les cinq décisions de l'Overview du PRD, chacune posée à Arthur le 2026-11-12 avec l'option recommandée et son alternative. Sa réponse est citée telle qu'il l'a choisie.

1. **Mode à activer.** Le mode arrière-plan se lance par `--mode background` ; le défaut reste `a11y` jusqu'au rapport de la campagne US-063. Réponse d'Arthur (2026-11-12) : « Opt-in, défaut a11y ».
2. **Pause par bascule.** En mode arrière-plan, le mouvement de souris et Échap ne déclenchent plus la pause. Le raccourci de réarmement (`--rearm-key`, défaut Ctrl+Alt+Maj+R) devient une bascule : il met en pause quand le serveur tourne et lève la pause quand il est en pause. FR-12 ne change pas : seul un geste physique lève la pause. Réponse d'Arthur (2026-11-12) : « Bascule du raccourci de réarmement ».
3. **Indicateur réduit au libellé.** En mode arrière-plan, pendant une action et 1 s après, seul le libellé s'affiche sur l'écran principal, sans les quatre bandes de cadre. Réponse d'Arthur (2026-11-12) : « Libellé seul ».
4. **Extensions de contrat.** `ui_act` reçoit les actions `check`, `uncheck` et `scroll`, et étend `value` (nombre sur un élément à plage, nom avec `select` sur un conteneur). `ui_tree` reçoit `root` et `depth`. `ui_find` reçoit `gone` et les termes `id:` et `value:`. `screenshot` et `zoom` reçoivent `window`. Tous sont optionnels ; les 17 outils du toolset restent conformes à `tests/fixtures/toolset_20260801.json`. L'accord vaut pour EP-013 à EP-015, sans nouvelle question par epic. Réponse d'Arthur (2026-11-12) : « Tout accepter ».
5. **Modes existants inchangés.** Les modes `a11y` et `vision` gardent leur kill switch (souris au-delà de 8 px, Échap), leur indicateur (cadre et libellé), leur stabilisation par pixels et leur liste d'outils. Réponse d'Arthur (2026-11-12) : « Inchangés ».

## Questions ouvertes du PRD

- **Q10** (l'arrière-plan devient-il le mode par défaut ?) : non pour l'instant. Le défaut reste `a11y` ; la question se rouvre sur le rapport de US-063. Réponse d'Arthur (2026-11-12) : « Opt-in, défaut a11y ».
- **Q11** (geste de pause) : le raccourci de réarmement en bascule, pas de second raccourci. Réponse d'Arthur (2026-11-12) : « Bascule du raccourci de réarmement ».
- **Q12** (indicateur du mode arrière-plan) : le libellé seul. Réponse d'Arthur (2026-11-12) : « Libellé seul ». Q9 du PRD de parité (indicateur visible pendant toute la session) reste ouverte.
- **Q13** (WinRT pour Windows.Graphics.Capture si `PrintWindow` ne suffit pas) : reportée. Elle se tranche sur les mesures de la sonde US-060 ; si A20 est infirmée, US-061 passe `BLOCKED` et la question est reposée. Réponse d'Arthur (2026-11-12) : « Reporter à la clôture de US-060 ».
- **Q17** (`clipboard` `get` en mode arrière-plan) : permis, sous la politique `system.clipboard` existante. `clipboard` reste listé (9 outils) ; `mode: "set"` est refusé. Réponse d'Arthur (2026-11-12) : « Permis, sous system.clipboard ».

Q14 à Q16 ne relèvent pas de US-039 : elles se posent après US-063 (Q14, Q16) et après la livraison 2 (Q15).

## Ce qui reste en vigueur, ce qui est amendé

- **FR-12** reste vrai dans les trois modes : aucun outil MCP ne lève une pause.
- **Décision 0008, point 5** (pas de blocage des entrées physiques, l'humain garde la priorité, kill switch et indicateur) reste en vigueur telle quelle dans les modes `a11y` et `vision`. En mode arrière-plan, le principe tient (l'humain garde la priorité, aucune entrée n'est bloquée) mais ses moyens changent : la pause vient du raccourci (point 2 ci-dessus) et l'indicateur se réduit (point 3).
- **Décision 0011** est amendée pour le seul mode arrière-plan :
  - point 3 (cinq fenêtres par écran) : en mode arrière-plan, une seule fenêtre, la boîte du libellé, sur l'écran principal ; les quatre bandes ne sont pas affichées ;
  - points 1, 2, 4 et 5 (exclusion par `WDA_EXCLUDEFROMCAPTURE` et absence d'indicateur si elle est refusée, indicateur statique, échos retirés des dirty rects, construction en arrière-plan) : inchangés dans les trois modes.
  - Texte du libellé en mode arrière-plan : « neo-compute is acting in the background: <raccourci> pauses » (US-046 ; en français jusqu'à l'amendement du 2026-11-13).

## Sonde US-040

Mesures du 2026-11-12 sur la machine de référence, par `neo-compute bg-probe` (`src/backend/windows/bg_probe.zig`). Sortie complète : `0013-probe-run.txt`.

**À lire d'abord.** Avec le client COM d'origine, tous les patterns UIA sauf `ScrollItem.ScrollIntoView` font passer la fenêtre cible devant l'utilisateur : A15 est infirmée pour Invoke sur 5 applications. La cause est un réglage d'UI Automation (`AutoSetFocus`), pas les patterns : une fois ce réglage coupé, aucun pattern ne change le premier plan. Le critère d'arrêt de US-040 (A15 infirmée pour Invoke ou `SetValue` sur plus de 2 applications) était donc atteint avec le client d'origine ; le travail a continué parce que la cause est levée par une correction technique mesurée. Choix soumis à Arthur à la revue de EP-011, avec les limites restantes (Chrome recouvert, document du Bloc-notes, VS Code). Réponse d'Arthur (2026-11-12) : « Valider ». Restent intrusifs : `SetFocus` (5/5 partout), l'ouverture d'un document dans le Bloc-notes (5/5), et la restauration d'une fenêtre minimisée par `SC_RESTORE` (5/5).

### Méthode

- Une fenêtre leurre d'un second processus neo-compute tient le premier plan, focus clavier dans son champ. La cible est non active et recouverte par le leurre. Chaque primitive est jouée 5 fois ; chaque répétition écrit l'effet lu sur la cible, le premier plan, le focus clavier et le curseur, avant et après.
- **Contrôle de validité.** Windows laisse un processus prendre le premier plan s'il descend de celui qui a reçu la dernière entrée de l'utilisateur. Lancée depuis un terminal, la sonde a ce droit, et toute mesure serait fausse. Le leurre frappe donc lui-même une touche (F15) : le droit passe au leurre. Avant chaque cible, la ligne `control` vérifie que `SetForegroundWindow` appelé par la sonde échoue. Elle échoue sur les sept cibles.
- Applications : fenêtre de test, Bloc-notes, Calculatrice, Paramètres, Explorateur, Chrome (profil séparé), VS Code. Aucune n'est notée `skipped`.

### Constat principal : `AutoSetFocus`

UI Automation donne le focus à la cible de chaque appel de pattern et amène sa fenêtre au premier plan, même à travers le verrou de premier plan. Ce comportement est un réglage, `AutoSetFocus` (interface `IUIAutomation2`), actif par défaut. L'objet COM que neo-compute créait (`CUIAutomation`) n'expose pas `IUIAutomation2` sur ce Windows 11 (`QueryInterface` renvoie `E_NOINTERFACE`). L'objet `CUIAutomation8` l'expose. Le mode arrière-plan crée donc sa session UIA depuis `CUIAutomation8` et coupe `AutoSetFocus`.

Changements de premier plan sur le nombre de répétitions (« - » : aucun élément de ce type dans l'application) :

| Pattern | `AutoSetFocus` par défaut | `AutoSetFocus` coupé |
|---|---|---|
| `SetFocus` | à chaque répétition sur les 6 cibles mesurées | 5/5 sur les 6 cibles mesurées |
| Invoke | test 5/5, Bloc-notes 5/5, Calculatrice 5/5, Paramètres 4/4, Explorateur 5/5 | 0/5 sur test, Bloc-notes, Calculatrice, Paramètres, Explorateur, VS Code |
| Toggle | test 5/5, VS Code 5/5 | test 0/5, VS Code 0/5 |
| `ValuePattern.SetValue` | test 5/5, Paramètres 5/5 | test 0/5, Paramètres 0/5 |
| Expand, Collapse | test 5/5, Bloc-notes 5/5, Explorateur 5/5, VS Code 5/5 et 4/5 | 0/5 partout |
| `SelectionItem.Select` | Bloc-notes, Calculatrice, Paramètres, VS Code 5/5 | 0/5 partout |
| `ScrollItem.ScrollIntoView` | 0/5 partout | 0/5 partout |

Avec `AutoSetFocus` coupé, l'effet est lu sur la cible 5/5 pour chaque pattern, sauf sur VS Code : Expand de la barre de menus sans effet (0/5), Collapse 4/5, Toggle sans effet lisible (5/5 non lisibles).

### Verdicts

- **A14 : validée.** `SetFocus` UIA déplace le premier plan 5/5 sur la fenêtre de test et les cinq applications où un élément a été mesuré, quel que soit le réglage. `ui_act focus` est donc une variante intrusive.
- **A15 : infirmée avec le client d'origine, validée avec le client d'arrière-plan.** Avec `CUIAutomation8` et `AutoSetFocus` coupé, Invoke, Toggle, Value, ExpandCollapse, SelectionItem et ScrollItem agissent sur une fenêtre non active et recouverte sans changer le premier plan ni le focus, sur la fenêtre de test, le Bloc-notes, la Calculatrice, les Paramètres, l'Explorateur et VS Code. **Chrome n'est pas mesuré** : recouvert par le leurre, il n'expose aucun document web dans son arbre après 8 s (cela relève de A19 et de US-058).
- **A16 : validée sur le Bloc-notes, infirmée sur un menu Win32 classique.** Le menu Fichier du Bloc-notes ouvert par Expand est encore ouvert après 2 s, son élément se lit dans le snapshot, et le premier plan ne change pas. Sur la fenêtre de test (menu `HMENU` classique), l'appel Expand échoue et rien ne s'ouvre.
- **A17 : validée pour la Calculatrice et pour la plupart des états, infirmée sur trois points.**
  - Lancement de la Calculatrice : fenêtre en 350 à 425 ms, sous le leurre, 0 changement sur 5 par chacune des quatre voies (`IApplicationActivationManager` avec `AO_NONE`, `ShellExecuteEx` avec `SW_SHOWNORMAL`, `SW_SHOWNOACTIVATE`, `SW_SHOWMINNOACTIVE`).
  - `SW_SHOWMINNOACTIVE`, `SW_SHOWMAXIMIZED`, `SC_MAXIMIZE` posté, `SW_SHOWNOACTIVATE` depuis l'état maximisé, `SC_RESTORE` posté depuis l'état maximisé : 0 changement sur 5, sur les sept cibles.
  - **Infirmée, document texte.** Un fichier `.log` ouvert dans le Bloc-notes prend le premier plan 5/5 par les trois voies `ShellExecuteEx` : le Bloc-notes s'active lui-même. `app_launch` le signale par la ligne « Notepad.exe a pris le premier plan » ; le rendre à l'utilisateur relève de US-050.
  - **Infirmée, `SC_RESTORE` posté depuis l'état minimisé** : 5/5 sur les sept cibles. Le mode ne l'utilise pas.
  - **Infirmée puis corrigée, `SW_SHOWNOACTIVATE` depuis l'état minimisé.** Il prend le premier plan, malgré le verrou, exactement quand la fenêtre minimisée est encore la fenêtre active de son propre thread (10 changements sur 10 dans cet état, 0 sur 60 hors de cet état). Une commande système que la fenêtre traite elle-même (`SC_MAXIMIZE`, `SC_RESTORE` postés) la laisse dans cet état. `SW_MINIMIZE` ne le lève pas (3 changements sur 3, mesure intermédiaire absente du fichier joint). Masquer la fenêtre puis la réafficher (`SW_HIDE` puis `SW_SHOWNOACTIVATE`) le lève : 0 changement sur 35 restaurations dans cet état, sur les sept cibles. `window_set` suit cette voie (`restoreQuiet` dans `window.zig`), et seulement dans cet état.
  - La garde qui rend le premier plan en moins de 200 ms n'existe pas encore (US-050).

### Classement retenu pour US-041

- Variantes intrusives de `ui_act`, refusées : `action: "focus"` et `fallback: "click"`. Les autres actions sont sans interférence avec la session d'arrière-plan.
- Si `CUIAutomation8` ou `IUIAutomation2` manque, `ui_act` refuse d'agir en mode arrière-plan au lieu d'agir en prenant le focus.
- `window_set` : `minimized` par `SW_SHOWMINNOACTIVE`, `normal` par `SW_SHOWNOACTIVATE` (précédé de `SW_HIDE` dans l'état décrit ci-dessus), `maximized` par `SC_MAXIMIZE` posté. Une prise de premier plan constatée après coup est dite dans le résultat.
- `app_launch` : `ShellExecuteEx` avec `SW_SHOWNOACTIVATE` dans tous les cas, une application empaquetée passant par `shell:AppsFolder\<AUMID>` (seule voie qui demande de ne pas activer ; `IApplicationActivationManager` avec `AO_NONE` reste la voie des modes `a11y` et `vision`). La prise de premier plan par l'application est dite dans le résultat ; Windows ne nomme aucune fenêtre au premier plan pendant une bascule, la lecture est donc refaite pendant 200 ms au plus.

### Points ouverts

1. **Délais UIA jamais appliqués.** `put_TransactionTimeout` et `put_ConnectionTimeout` passent par `IUIAutomation2`, que `CUIAutomation` n'expose pas : ils n'ont jamais été appliqués, dans aucun mode. Les appliquer revient à créer `CUIAutomation8` partout, ce qui change le comportement des modes `a11y` et `vision` et leur bench. Non fait : la décision est à Arthur. Si elle est prise, la correction compte pour la condition 3 de la décision 0001.
2. **Régime des droits de premier plan.** Toutes les mesures valent quand le verrou tient pour le serveur. Un serveur dont le lanceur vient de recevoir une entrée garde brièvement le droit de prendre le premier plan ; ce second régime n'est pas mesuré en entier.
3. **Chrome recouvert** n'expose pas son document web : aucun pattern mesuré (US-058).
4. **VS Code** : Expand de la barre de menus sans effet, Toggle sans effet lisible.
5. **Liste déroulante Win32 ouverte** : tant qu'elle l'est, la lecture de l'arbre de la fenêtre de test échoue (`FindAllBuildCache`, `E_FAIL`). La sonde et le selftest la referment ; le cas n'est pas mesuré sur une application tierce.
6. **`SW_HIDE` bref** : pendant la restauration décrite plus haut, la fenêtre disparaît un instant de la barre des tâches. Si le serveur était tué entre les deux appels, elle resterait masquée.

## Sonde US-047

Mesures du 2026-11-12 sur la machine de référence, par `neo-compute events-probe` (`src/backend/windows/events_probe.zig`). Sortie complète : `0013-events-probe-run.txt`.

**À lire d'abord.** A18 est infirmée : la Calculatrice ne signale aucun de ses changements d'arbre par WinEvent, et les Paramètres en signalent 65 % dans les 200 ms. Le plancher de relecture de la stabilisation (US-048) vaut donc 250 ms.

### Méthode

- Même montage que la sonde US-040 : leurre d'un second processus au premier plan, cible non active et recouverte, `AutoSetFocus` coupé.
- Écoute par `SetWinEventHook(EVENT_MIN, EVENT_MAX)` hors contexte (`WINEVENT_OUTOFCONTEXT` : Windows poste les événements au thread qui écoute, sans injecter de code dans l'application), filtrée par processus. Une fenêtre UWP est écoutée sur deux processus : son cadre (`ApplicationFrameHost.exe`) et l'application qu'il héberge. Les événements du curseur (`OBJID_CURSOR`) et ceux des fenêtres de l'indicateur sont écartés.
- Par cible : 3 s au repos, puis 20 actions tirées de ses éléments (Invoke, Toggle, `ValuePattern.SetValue`, Expand), chacune annulée ensuite. L'arbre est haché avant l'action et 500 ms après ; une action compte quand ce hachage change. Elle est « signalée » si au moins un événement arrive dans les 200 ms.

### Résultats

| Cible | Actions | Arbre changé | Signalées < 200 ms | Taux | Premier événement, médiane | p95 | Événements/s au repos |
|---|---|---|---|---|---|---|---|
| Fenêtre de test | 20 | 10 | 10 | 100 % | 0,8 ms | 1,4 ms | 0,0 |
| Bloc-notes | 20 | 20 | 20 | 100 % | 3,6 ms | 4,3 ms | 0,0 |
| Calculatrice | 20 | 16 | 0 | 0 % | aucun | aucun | 0,0 |
| Paramètres | 20 | 20 | 13 | 65 % | 3,8 ms | 244,1 ms | 0,0 |
| Explorateur | 20 | 20 | 20 | 100 % | 7,7 ms | 10,0 ms | 0,0 |
| Chrome | 0 | non mesuré | | | | | 0,0 |
| VS Code | 20 | 20 | 20 | 100 % | 23,0 ms | 48,2 ms | 0,0 |

- **Calculatrice** : 16 Invoke changent l'arbre, aucun événement en 500 ms. Une application XAML ne lève ses événements d'accessibilité que pour un client UIA abonné. Sans abonné, rien ne passe par les WinEvents ; avec un abonné, UI Automation en traduit une partie en WinEvents (amendement du 2026-11-13 : 90 % des changements de la Calculatrice).
- **Paramètres** : `SetValue` est signalé en 3 à 7 ms (13 sur 13) ; Invoke l'est seulement après 236 à 292 ms (0 sur 7 dans les 200 ms).
- **Chrome** : même limite que pour la sonde US-040. Recouvert par le leurre, il n'expose aucun document web après 8 s, donc aucun élément à actionner. Il ne compte pas dans le verdict (US-058).
- **Fenêtre de test** : Invoke ne change pas l'arbre (10 actions hors décompte) ; Toggle et `SetValue` sont signalés en moins de 2 ms.
- Au repos, aucune cible n'émet d'événement : le thread d'écoute ne coûte rien tant que la cible est immobile.

### Verdict

- **A18 : infirmée** pour la Calculatrice (0 %) et les Paramètres (65 %), validée pour la fenêtre de test, le Bloc-notes, l'Explorateur et VS Code (100 %). Seuil : 95 %.
- **Plancher de relecture : 250 ms** (`reread_floor_ms` dans `src/core/session.zig`).
- Conséquence pour US-048 : sur une application XAML, le silence des WinEvents ne prouve pas que la cible est stable. La règle du PRD (stable après 50 ms sans événement) est appliquée telle quelle ; le plancher ne joue que si l'attente dure. Point laissé à Arthur dans le rapport de EP-012.

## Mesures de EP-012

Mesures du 2026-11-12 sur la machine de référence (Windows 11, build 26300), par `neo-compute selftest --background` et `zig build bench`.

### Stabilisation (US-048)

- Une action sans effet se stabilise en 62,3 ms p95 sous un leurre repeint toutes les 15 ms (contrôle `bg-settle-covered`, 30 actions, budget 150 ms) ; 55,7 ms p95 au bench (`bg-settle`, référence enregistrée : 64,1 ms, la pire de cinq séries). L'étape `capture` vaut 0.
- Un contrôle Win32 `STATIC` dont le texte change ne lève aucun WinEvent : l'arbre change, la stabilisation ne le voit pas. Même cause que pour la Calculatrice (sonde US-047). La cible « qui change sans cesse » du selftest signale donc elle-même ses changements (`NotifyWinEvent`), comme une application qui informe ses clients d'accessibilité.
- Règle appliquée : stable après 50 ms sans événement. Le plancher (relecture de l'arbre toutes les 250 ms, stable après deux lectures identiques) joue quand les événements ne cessent pas, ou quand Windows refuse le hook ; le résultat porte alors « stabilisation par relecture » (276 ms mesurés).
- Le thread d'écoute consomme 0,001 % d'un cœur au repos.

### Garde de premier plan (US-050)

Montage : une application d'un autre processus (`selftest-popup`) ouvre, sur Invoke, un dialogue qui appelle `SetForegroundWindow`. Le leurre, au premier plan, lui en donne le droit avant chaque action (`AllowSetForegroundWindow`). Le dialogue passe devant le leurre 20 fois sur 20.

| Voie de restauration, sans `SendInput` | Résultat sur 20 |
|---|---|
| `SetForegroundWindow` seul | refusé 20 fois |
| `AttachThreadInput` au thread du premier plan, puis `SetForegroundWindow` | attache réussie, appel refusé 20 fois |
| `SetFocus` UI Automation sur la fenêtre de premier niveau | appel réussi, premier plan inchangé 20 fois |
| `SetFocus` UI Automation sur le champ qui avait le focus | le premier plan revient au processus du leurre, mais Windows nomme le champ, pas la fenêtre, comme fenêtre de premier plan |
| Le thread du serveur et celui de la fenêtre de l'utilisateur rejoignent la file d'entrée du premier plan, puis `BringWindowToTop` et `SetActiveWindow` | premier plan et focus rendus 20 fois, 7,5 ms au plus |

La dernière voie est retenue (`restoreForeground` dans `window.zig`). La question du PRD (« `SetForegroundWindow` seul, puis `AttachThreadInput`, sans l'étape `SendInput` ? ») reçoit donc la réponse : non, aucune des deux ne suffit sur ce Windows. Les messages d'activation sont envoyés aux deux fenêtres ; aucune n'est touchée si son thread ne répond pas en 200 ms, et la restauration est alors dite refusée.

Le contrôle `bg-guard-restore` du selftest répète la voie retenue 100 fois, comme le demande le PRD (fiabilité : au moins 95 % de 100) : premier plan rendu 100 fois sur 100, 8,8 ms au plus (revue de EP-012).

Coût de la garde quand le premier plan est intact : 1,2 µs p95 sur 1 000 actions (budget 100 µs).

Choix d'implémentation à confirmer par Arthur (points 1 et 2 tranchés par l'amendement du 2026-11-13) :

1. **Cinquième issue d'audit, `other`.** Le PRD en nomme quatre (`intact`, `restored`, `refused`, `user`). Un premier plan qui change sans entrée de l'utilisateur et sans que le processus cible le prenne (une autre application passe devant, ou l'utilisateur était déjà dans une fenêtre du processus cible) n'est aucune des quatre : il est noté `other`, sans ligne dans le résultat et sans restauration. Il en va de même quand les hooks sont absents : rien ne distingue alors le geste de l'utilisateur de celui de l'application.
2. **Entrée physique.** Compte comme entrée de l'utilisateur toute frappe et tout appui de bouton de souris vus par les hooks pendant l'action, stabilisation comprise. Un mouvement de souris seul ne compte pas. Conséquence : si l'utilisateur tape pendant que la cible prend le premier plan, rien n'est restauré, et le résultat porte la ligne « entrée de l'utilisateur ».
3. **Champ `mode` de l'audit** : écrit sur chaque ligne, dans les trois modes.

### Pause et indicateur (US-045, US-046)

- Le raccourci met le serveur en pause en 1,0 ms et l'action en cours rend la main 25 ms après la frappe. Échap et 500 px de souris pendant une action ne déclenchent rien, et Échap n'est pas consommée.
- Un raccourci tenu ne bascule qu'une fois : le clavier répète la touche tant qu'elle est enfoncée, et chaque répétition levait puis remettait la pause. Les répétitions sont consommées sans effet jusqu'au relâchement (défaut corrigé à la revue de EP-012, contrôle `bg-kill-chord` avec trois répétitions).
- Le libellé du mode est en français (« neo-compute agit en arrière-plan : Ctrl+Alt+Shift+R met en pause »), comme l'écrit le PRD (US-046) ; le libellé de pause existant reste en anglais. Harmonisé en anglais par l'amendement du 2026-11-13.

## Amendement du 2026-11-13

Cinq points laissés à Arthur à la revue de EP-012, vérifiés à la source (`docs/research/2026-11-12-cohabitation-arriere-plan.md`), puis tranchés. Réponse d'Arthur (2026-11-13) aux cinq recommandations : « Ok vas-y ». Mesures du 2026-11-13 sur la machine de référence.

### 1. Stabilisation des applications XAML : événements UI Automation

**Décision.** Le serveur s'abonne aux événements UI Automation de la fenêtre cible quand elle est un cadre UWP (`ApplicationFrameWindow`), et additionne leur compteur à celui des WinEvents. La contrainte du PRD « aucun objet COM côté client » est levée pour les seuls gestionnaires d'événements de `src/backend/windows/uia_events.zig`.

**Les gestionnaires.** Quatre objets COM (structure, propriétés, événements simples, notifications), statiques, jamais libérés (compteur de références constant), construits sur les vtables générées. Un gestionnaire incrémente un compteur et rend la main ; il ne fait aucun appel UIA et ne lit aucun texte porté par l'événement. L'ajout et le retrait passent par le thread UIA du serveur ; une fenêtre qui ne répond pas n'est ni abonnée ni désabonnée tant qu'elle ne répond pas.

**Sonde.** `neo-compute events-probe`, étendue : même montage que US-047 (leurre au premier plan, cible recouverte), deux tours par cible, chacun avec 5 actions sans abonnement puis les mêmes actions et 5 autres avec abonnement. Sortie complète : `0013-uia-events-probe-run.txt`.

| Cible | Arbre changé | Signalé par WinEvents < 200 ms | Signalé par UIA < 200 ms | L'un ou l'autre | Premier événement UIA, médiane / p95 | Ajout, retrait | Cycles de la cible par action, sans / avec (mêmes actions) |
|---|---|---|---|---|---|---|---|
| Fenêtre de test (Win32) | 10 | 100 % | 50 % | 100 % | 3,4 / 3,9 ms | 9,1 ms, 1,2 ms | 12,9 / 34,2 M (cible dans le processus de la sonde : compte le client) |
| Bloc-notes | 20 | 100 % | 100 % | 100 % | 19,8 / 25,9 ms | 8,4 ms, 6,5 ms | 312 / 409 M |
| Calculatrice | 10 | 90 % | 100 % | 100 % | 6,5 / 7,4 ms | 7,9 ms, 1,9 ms | 13,1 / 19,1 M |
| Paramètres | 20 | 100 % | 100 % | 100 % | 9,7 / 10,5 ms | 7,6 ms, 2,3 ms | 444 / 96 M (premier bloc à froid) |
| Explorateur | 20 | 100 % | 60 % | 100 % | 41,1 / 209,3 ms | 10,6 ms, 2,1 ms | 142 / 660 M |
| Chrome | non mesuré | | | | | | |
| VS Code | 20 | 100 % | 100 % | 100 % | 24,3 / 49,8 ms | 7,9 ms, 2,5 ms | 176 / 261 M |

- Sans abonnement (sonde US-047), les WinEvents signalaient 0 % des changements de la Calculatrice et 65 % de ceux des Paramètres. Avec l'abonnement, les événements UIA en signalent 100 %, premier événement en moins de 11 ms. Les taux WinEvents de ce tableau pour ces deux cibles sont mesurés abonnement actif : c'est l'abonnement qui fait lever les événements que UI Automation traduit ensuite en WinEvents.
- Au repos, aucune cible n'émet d'événement UIA.
- Rappel Zig avec un `VARIANT` passé par valeur : 596 événements de propriété reçus, 0 avec un type inattendu.
- **Coût pour la cible.** L'abonnement fait travailler la cible à chacun de ses événements : 4,6 fois les cycles processeur sur l'Explorateur, 1,3 à 1,5 fois sur le Bloc-notes, VS Code et la Calculatrice, pour les mêmes actions. Sur les cibles où les WinEvents signalent déjà tout, ce coût n'achète rien.

**Écart avec la recommandation approuvée, puis abonnement appris.** La recommandation disait : si la sonde passe, les événements UIA deviennent la source première partout et les WinEvents le complément. La sonde passe sur le signal mais montre ce coût. L'abonnement n'est donc pas posé partout. Il l'est d'emblée sur un cadre UWP, les deux seules cibles où les WinEvents échouent, et ailleurs seulement quand l'application le demande par ce qu'elle fait : le serveur s'abonne à une application dont l'arbre a changé deux fois de suite sans qu'aucun événement ne bouge son compteur, et il retire l'abonnement pour de bon si deux changements de plus restent sans événement (`treeObserved` dans `src/backend/windows.zig`). Le cœur signale au backend chaque arbre montré en mode arrière-plan, avec « changé ou non ». La règle couvre ainsi les îlots XAML et WinUI 3 sans liste de classes de fenêtres, et ne coûte rien aux applications que leurs WinEvents décrivent déjà. Le plancher de relecture (250 ms) est inchangé. Réponse d'Arthur (2026-11-13), après relecture de l'approche d'agent-desktop : « Ok vas-y ».

**Retrait des gestionnaires.** agent-desktop a mesuré un retrait de 86 s après masquage puis réaffichage de la fenêtre, contre 64 ms sans (`probes/windows/FINDINGS.md`, A8-3, Windows Server 2019, sept gestionnaires dont focus et ouverture de fenêtre). Le retrait de neo-compute passe par le thread UIA du serveur : un retrait lent bloquerait `ui_tree` et `ui_act`. Mesure par `neo-compute events-probe churn` (sortie : `0013-uia-churn-probe-run.txt`), sur la fenêtre de test, une application Win32 d'un autre processus et la Calculatrice : fenêtre laissée 1 s, masquée et réaffichée 10 fois, minimisée et restaurée 10 fois, dialogue ouvert et fermé 10 fois, fenêtre fermée pendant l'abonnement. Retrait le plus lent : 5,4 ms ; ajout : 4,7 à 21,9 ms ; l'arbre se lit normalement pendant l'abonnement. Les 86 s ne se reproduisent pas avec des gestionnaires limités au sous-arbre de la fenêtre.

**Limite de l'abonnement appris.** Aucune application WinUI 3 ou à îlot XAML n'a été mesurée : le contrôle `bg-events-learn` prouve la règle sur un libellé Win32 qui change sans rien signaler (abonnement après 2 changements, retrait au cinquième, les gestionnaires ne signalant rien).

**Selftest.** `bg-settle-xaml` : 10 Invoke sur un chiffre de la Calculatrice recouverte, chacun lève des événements UIA (37 en tout) et se stabilise dessus, session inchangée.

**Rust Switch Gate, condition 3.** Aucun défaut de la couche COM Zig : les gestionnaires ont fonctionné au premier essai. Le compteur de la décision 0001 ne change pas.

### 2. Issues d'audit de la garde

`other` est remplacée par trois issues : `third_party` (une autre application passe devant d'elle-même), `same_app` (l'utilisateur était déjà dans une fenêtre du processus cible), `unknown` (hooks d'entrée absents : rien ne distingue le geste de l'utilisateur de celui de l'application). Aucune n'est restaurée ni ne porte de ligne dans le résultat.

### 3. Garde de premier plan

- **Geste.** Seul un geste capable de changer la fenêtre de premier plan arrête la restauration : un clic hors de la fenêtre de l'utilisateur, ou une touche avec Alt ou Win (Alt+Tab, Alt+Échap et Ctrl+Échap compris), pendant l'action ou dans les 500 ms qui la précèdent. Une frappe ordinaire ne compte plus : elle ne change aucune fenêtre de premier plan, et c'est elle qui tomberait dans le dialogue de la cible.
- **Restauration sur l'événement.** Le thread des WinEvents écoute `EVENT_SYSTEM_FOREGROUND` et rend le premier plan pendant que l'action attend encore. Le regard en fin d'action reste le filet. Trois restaurations au plus par action ; au-delà, la cible est laissée devant et le résultat le dit.
- **Constat.** L'événement arrive avant que `GetForegroundWindow` nomme la nouvelle fenêtre (213 événements sur 213 dans la trace du selftest). Restaurer à cet instant ne fait rien. Le thread retient la fenêtre, et un minuteur de 10 ms agit dès qu'elle est réellement devant (abandon après 250 ms).
- **Mesures** (`bg-guard-restore`, 100 actions pendant que l'utilisateur tape) : premier plan rendu 100 fois sur 100, 100 fois depuis l'événement, avant la fin de l'action. Le dialogue reste devant 39,7 ms au plus, de son événement à la fin de la restauration (budget 200 ms) ; la restauration seule prend 18,1 ms au plus. `bg-guard-user` : après Alt+Tab ou un clic sur la barre des tâches, le dialogue est laissé devant 4 fois sur 4 ; après un clic dans la fenêtre de l'utilisateur, le premier plan est rendu 2 fois sur 2. Coût quand le premier plan est intact : 2,3 µs p95 sur 1 000 actions.
- **Non adopté.** Le bouclier de Cua (`EnableWindow(FALSE)` sur la fenêtre de l'utilisateur pendant l'appel UIA) : il modifie la fenêtre de l'utilisateur.
- **Garde prolongée.** Un Invoke asynchrone appelé avec `observe: "none"` rend la main en 1 ms, et son dialogue passe devant quand aucun outil ne tourne plus. La garde reste donc armée 2 s après la fin de l'action (`linger_ms` dans `src/core/guard.zig`), avec la même règle d'attribution et le même plafond. Le résultat de l'action étant déjà parti, l'appel suivant, quel qu'il soit, porte la ligne « Premier plan pris par <exe> après l'action précédente, rendu à <exe> » (ou « : Windows a refusé la restauration »), et sa ligne d'audit le champ `guard_late`. 2 s plutôt qu'une garde permanente : l'attribution à l'action s'affaiblit avec le temps. Réponse d'Arthur (2026-11-13) : « Ok vas-y ». Contrôle `bg-guard-late` : 5 dialogues tardifs sur 5 rendus, dialogue devant 41,0 ms au plus, ligne présente dans l'appel suivant.
- **agent-desktop** n'a ni détection ni restauration du premier plan, et n'écoute aucun événement sur Windows (note `docs/research/2026-11-13-agent-desktop-cohabitation.md`).

### 4. Libellé du mode

« neo-compute is acting in the background: Ctrl+Alt+Shift+R pauses », en anglais comme le libellé de pause. PRD (US-046) et point « Décision 0011 » ci-dessus amendés.

### 5. Chrome et Electron

- Chromium ignore une fenêtre `WS_POPUP` dans son calcul d'occlusion (`ui/gfx/win/hwnd_util.cc`). Le leurre des selftests et des sondes était `WS_POPUP` : l'absence de document web sous lui (sondes US-040 et US-047) ne venait donc pas de l'occlusion. Le leurre est désormais une fenêtre à cadre (`WS_CAPTION | WS_THICKFRAME`).
- Sous le leurre à cadre, Chrome n'expose toujours aucun document web après 8 s. La cause reste à établir par US-058 : occlusion réelle cette fois, ou accessibilité web qui ne s'active qu'à une requête UIA visant un nœud web.
- Mesures d'agent-desktop à reprendre dans US-058 (`probes/windows/FINDINGS.md`, A1-5 et A1-6, sur Obsidian) : au premier contact l'arbre a 13 nœuds contre 172 une fois construit, sans drapeau ; recouverte par d'autres fenêtres, l'application reste à son compte du premier contact, et minimiser ces fenêtres la débloque. US-058 doit donc séparer « arbre pas encore construit » de « arbre figé par recouvrement ».
- PRD amendé : A19 et le risque 2 séparent Chromium d'Electron (VS Code désactive `CalculateNativeWinOcclusion`) ; US-058 mesure si une action UIA force la mise à jour de l'arbre et la plus petite bande visible suffisante ; US-059 calcule l'occlusion avec les règles de Chromium. `app_launch` n'ajoute aucun drapeau par défaut.

## Mesures de EP-013

Mesures du 2026-11-13 sur la machine de référence (Windows 11, build 26300), par `neo-compute selftest --background` et `zig build bench`. Les extensions de contrat appliquées sont celles du point 4 des décisions de contrat : actions `check`, `uncheck` et `scroll`, `value` étendu (nombre sur un élément à plage, nom avec `select` sur un conteneur, forme de défilement). Aucune autre modification de contrat.

### Forme du résultat (US-055)

- Première ligne : « `<action> <id>` : vérifié (`<état lu>`) », « `<action> <id>` : délivré, effet non vérifiable » ou « `<action> <id>` : contredit, état lu `<état>`. L'action est partie : ne la rejoue pas sans relire l'arbre. » (`isError`). Une action sans objet répond « déjà coché », « déjà en bas », « déjà en vue », sans erreur. Ce qui s'est passé en plus suit après « ; » : « par LegacyIAccessible.DoDefaultAction », « par Invoke », « 2 bascules », « conteneur `<id>` », « entrée `<id>` », « activé après N ms », « amené en vue ».
- L'ancien « ok : `<action> <id>` » disparaît. Un refus garde « Aucune action exécutée. ».
- L'audit reçoit `"verdict"` : `verified`, `unverifiable`, `contradicted` ou `noop`. Un refus n'en porte pas.
- La valeur de `set_value` est comparée par empreinte (`uitree.textHash`), jamais écrite ; un champ mot de passe n'est pas relu (FR-09).

### Coût (FR-22)

| Mesure | Résultat | Budget |
|---|---|---|
| `bg-act` (`toggle` sans observation), p95 de l'étape accessibilité | 2 513 µs | 2 545 µs de référence, 110 % au plus |
| `bg-settle`, p95 de l'étape `settle` | 65 478 µs | 64 061 µs de référence, 110 % au plus |
| Relecture du verdict, `bg-verdict` (40 bascules, fenêtre du même processus, Debug) | p95 1 587 µs, médiane 1 008 µs | < 10 ms p95 |
| Attente d'un bouton activé après 500 ms, `bg-wait-enabled` | action partie après 512 ms | relecture toutes les 100 ms |

- Un aller-retour UI Automation vers une fenêtre d'un autre processus coûte environ 0,3 ms ; le nombre de propriétés lues dans un aller-retour ne compte pas (cache de 14 propriétés réduit à 8 : même temps). Le chemin d'une action est donc compté en allers-retours : une lecture en cache avant l'action, l'appel du pattern pris sur la copie que cette lecture a laissée (`read_copy`, sans `GetCurrentPattern`), une propriété relue après. Trois allers-retours contre quatre avant EP-013 (`IsEnabled`, `IsOffscreen`, `GetCurrentPattern`, l'appel).
- Première version (lecture complète avant et après, `GetCurrentPattern` entre les deux) : `bg-act` à 2 842 µs dans la passe complète, hors budget. La baseline n'a pas été réécrite.
- `ctx.sleep` dort par tranches de 10 ms que Windows arrondit à son battement de 15,6 ms : une période de 100 ms demandée ainsi dure environ 156 ms. Les relectures de EP-013 visent une heure d'horloge (`sleepUntil`). Les autres attentes du serveur gardent `ctx.sleep` (hors périmètre de l'epic).

### Constats sur les contrôles Win32

- **Action par défaut et InvokePattern.** Tout contrôle Win32 standard qui a une action par défaut MSAA a aussi `InvokePattern` : bouton (« Appuyer »), case à cocher et case à trois états (« Cocher »), bouton radio, entrée de liste (« Double clic »). C'est vrai par les proxys natifs de UI Automation et par son pont MSAA sur un objet oleacc (`CreateStdAccessibleProxy`, classe « Button »). Le repli `DoDefaultAction` de US-051 ne sert donc qu'aux fournisseurs qui déclarent `LegacyIAccessible` sans `Invoke` (Chromium sur un élément cliquable, par exemple). `bg-legacy` le prouve sur un contrôle de la fenêtre de test qui a son propre fournisseur (`legacy_control.zig`).
- **Entrée de liste.** `Invoke` sur une entrée de `LISTBOX` d'une fenêtre non active échoue (`0x80131509`, opération invalide). `ui_act` renvoie l'erreur ; le repli de US-051 ne joue que sans `InvokePattern`.
- **Liste déroulante Win32.** L'arbre de la fenêtre se lit liste ouverte (les entrées sont trouvées), mais `FindAll` rend alors 16 fois la dernière des 3 entrées, sous le même RuntimeId : les entrées sont dédoublonnées par RuntimeId. `Collapse` vaut annulation : l'entrée sélectionnée liste ouverte est abandonnée. La séquence du PRD (déplier, sélectionner, replier) est suivie, puis l'entrée est relue une fois le conteneur replié et sélectionnée de nouveau si elle a été abandonnée (« sélection refaite conteneur replié »). Session inchangée pendant toute la séquence (`bg-select-name`).
- **Curseur.** Le `TRACKBAR` expose `RangeValue` en écriture, sans `Value` : `set_value` passe par `RangeValuePattern.SetValue`, la position relue par `TBM_GETPOS` est exacte.
- **Liste.** La `LISTBOX` expose `ScrollPattern` : les crans, les pages, `top`, `bottom` et le pourcentage passent, et la position lue est « scroll=N %,h0 % » (l'axe horizontal existe, à 0).
- **Fenêtre de test.** Les contrôles de EP-013 (case à trois états, bouton activé plus tard, contrôle hérité) ne sont créés que pour le selftest (`TestWindow.actions`). Présents dans la fenêtre du bench, ils coûtent à eux seuls 25 % à `bg-act` (3 188 µs) et 12 % à `bg-settle` : le bench mesure la fenêtre sur laquelle sa référence a été prise.

### Points soumis à Arthur (2026-11-13)

1. **Sélection par nom sans déplier : mesurée, sans effet sur Win32.** Idée : lire d'abord les entrées conteneur replié et ne déplier que si le nom n'y est pas, pour ne pas montrer la liste. Arthur a donné son accord sous réserve de la mesure (2026-11-13 : « Ok vas-y »). Mesure du 2026-11-13 : liste déroulante Win32 repliée, `FindAll` ne rend aucune entrée, ni en vue de contrôle ni en vue brute ; la liste s'ouvre donc quand même, et la sélection est refaite après le repli comme avant. Le changement a été retiré : le critère de US-053 et le code restent ceux de la séquence du PRD. Les deux pistes qui restaient (messages natifs Win32, options d'un `<select>` replié dans Chrome) sont mesurées dans « Exploration du 2026-11-13 » ci-dessous.
2. **Repli quand `Invoke` échoue : laissé en l'état.** `DoDefaultAction` n'est pas tenté quand `Invoke` existe mais échoue (entrée de liste Win32) : le PRD ne le demande que sans `InvokePattern`, rien ne mesure qu'il réussirait, et `select` couvre l'entrée de liste. Accord d'Arthur sur cette recommandation (2026-11-13 : « Ok vas-y »).

### Exploration du 2026-11-13 : choisir une entrée sans ouvrir la liste

Sondes hors dépôt (fenêtre Win32 d'un autre processus qui journalise les avis reçus par son propriétaire ; page `<select>` dans Chrome, profil à part, dont le titre reflète la valeur et le nombre d'événements `change`). Aucun code du produit n'a changé.

**Win32 (`ComboBox`, `ListBox`).**

| Voie | Liste ouverte | Sélection | Avis reçu par l'application |
|---|---|---|---|
| `ui_act select` avec un nom (UI Automation : déplier, `Select`, replier) | oui | changée | `CBN_DROPDOWN`, `CBN_SELENDCANCEL`, `CBN_CLOSEUP` ; jamais `CBN_SELCHANGE` |
| `ui_act set_value` sur la liste déroulante (`ValuePattern.SetValue`) | non | changée (par le texte) | aucun |
| `ui_act select` sur une entrée de `LISTBOX` | sans objet | changée | aucun (`LBN_SELCHANGE` absent) |
| Messages natifs : `CB_GETLBTEXT` pour lire, `CB_SETCURSEL`, puis `WM_COMMAND` `CBN_SELCHANGE` au parent | non | changée | `CBN_SELCHANGE` |

- Les messages natifs lisent les 3 entrées d'un autre processus en 0,3 ms et changent la sélection en 0,3 à 0,6 ms, premier plan et focus inchangés, sur `CBS_DROPDOWNLIST` comme sur `CBS_DROPDOWN`. `CB_SETCURSEL` seul ne prévient personne : l'avis au parent est à envoyer à part.
- Par UI Automation, la sélection d'une liste Win32 change sans que l'application en soit prévenue : une application qui réagit au changement (champs dépendants, bouton activé) ne réagit pas, alors que `ui_act` répond « vérifié (sélectionné) ». `Toggle` sur une case prévient bien (`BN_CLICKED`).
- Limites de la voie native : classes `ComboBox` et `ListBox` à chaînes seulement (pas les listes dessinées par le propriétaire sans `CBS_HASSTRINGS`, pas `ComboBoxEx32`), et refus par UIPI vers une fenêtre élevée, comme UI Automation.

**Chrome (`<select>`).**

- Menu fermé : aucun descendant, ni en vue de contrôle ni en vue brute. Les options n'existent qu'une fois le menu ouvert. `ValuePattern.SetValue` est accepté (non lecture seule) et ne change rien.
- Chrome au premier plan : `ui_act select` avec un nom réussit (valeur changée, la page reçoit `change` et `input`), un nom inconnu est refusé avec les entrées.
- Chrome visible mais non actif, session d'arrière-plan : `Expand` part et le menu ne s'ouvre pas (« contredit, état lu replié ») ; `select` avec un nom échoue sans rien changer, premier plan inchangé. Avec un client qui laisse UI Automation donner le focus, le menu s'ouvre et la sélection réussit, mais Chrome prend le premier plan.
- Conclusion : aucune voie sans interférence pour un `<select>` de Chrome non actif. À reprendre dans US-058 et US-059 avec les autres limites de Chromium en arrière-plan.

**Décidé.** La voie native pour `select` sur `ComboBox` et `ListBox` Win32 est retenue : un second mécanisme à côté de UI Automation, limité aux messages de sélection de ces deux classes (FR-46). Réponse d'Arthur (2026-11-13) à « Veux-tu que je l'écrive dans le PRD ? » : « Oui vas-y ». PRD 1.3 : EP-017, US-064, A22, risque 14, questions Q18 et Q19. Le code attend l'implémentation de US-064 ; EP-013 reste tel que livré.

## Revue de EP-013 (2026-11-13)

Trois corrections, sans changement de contrat :

- **Case qui n'atteint pas l'état demandé en 2 bascules.** Le résultat suit la forme de US-055 comme les autres : « `check <id>` : contredit, état lu `<état>` après 2 bascules, sans atteindre « coché ». L'action est partie : ne la rejoue pas sans relire l'arbre. »
- **Pause ou annulation pendant la relecture.** Une relecture coupée avant ses 400 ms ne contredit rien : l'audit enregistre `unverifiable`, plus `contradicted`.
- **Pause ou annulation pendant qu'une liste dépliée se remplit** (`select` avec un nom). Le conteneur est replié et aucun `Select` ne part ; avant, l'entrée était encore sélectionnée après la pause.

Inventaire de la recherche revu : les 11 actions sans interférence d'agent-desktop ont leur équivalent dans `ui_act` (click : `invoke` et son repli `DoDefaultAction` ; set-value et clear : `set_value`, valeur vide comprise ; toggle, check, uncheck, expand, collapse, select, scroll ; scroll-to : `scroll_into_view`).

Mesures de la revue : `bg-act` 2 355 µs (référence 2 545 µs), `bg-settle` 65 217 µs (référence 64 061 µs), `bg-verdict` 1 290 µs au p95.

## Sonde US-058 et mesures de EP-014

Mesures du 2026-11-13 sur la machine de référence, par `neo-compute occlusion-probe` (sortie complète : `0013-occlusion-probe-run.txt`, tableau dans `bench/apps.md`), `neo-compute selftest --background` et les tests du cœur. Les extensions de contrat appliquées sont celles du point 4 : `root` et `depth` sur `ui_tree`, les termes `id:` et `value:` de `ui_find`. Aucune autre modification de contrat.

### Méthode

Chaque lancement démarre un processus neuf (profil isolé pour Chrome), place sa fenêtre de 1100x800 dans une situation avant toute requête UI Automation, puis envoie un `ui_act toggle` à froid et un à chaud par un serveur `--mode background`, pendant qu'une fenêtre leurre encadrée d'un autre processus tient le premier plan (Chromium ignore une fenêtre `WS_POPUP` dans son calcul d'occlusion). Une action compte quand son effet se lit dans l'arbre en moins de 1 s. 10 lancements par situation, 5 situations, soit 20 actions par cellule.

### Résultats

| Cible | Visible inactive | Entièrement recouverte | Recouverte sauf 16 px | Autre écran | Minimisée |
|---|---|---|---|---|---|
| Chrome 156 | 100 %, p95 89 ms | 0 % | 100 %, p95 82 ms | 100 %, p95 82 ms | 0 % |
| VS Code | 95 %, p95 288 ms | 95 %, p95 289 ms | 100 %, p95 291 ms | 100 %, p95 286 ms | 0 % |

- **Chrome recouvert ou minimisé ne construit pas son arbre web.** Premier contact : 37 nœuds, le cadre seul ; 150 une fois construit. Recouvert, l'élément visé n'entre jamais dans l'arbre en 4 s de relectures (0 lancement sur 10). Ce n'est donc pas « pas encore construit » : rappeler `ui_tree` ne construit rien.
- **L'action part quand même.** Les 20 actions envoyées à un Chrome recouvert ou minimisé, sur un arbre construit puis recouvert, ont toutes été délivrées : leur effet s'est lu dès la fenêtre revenue en vue. `ui_act` répond « contredit » parce que l'arbre relu n'est plus à jour, pas parce que l'action a échoué. Une action UI Automation ne force pas la mise à jour.
- **Découvrir débloque.** Remise en vue, la fenêtre construit son arbre en 290 ms (médiane) ; restaurée depuis l'état minimisé, en 25 ms.
- **Une bande suffit.** Avec 16 px en vue, 20 actions sur 20 ; la plus petite bande essayée, 1 px, a tenu sur 4 actions de 4. La recommandation reste 16 px : une marge sur les bordures invisibles et l'arrondi des angles.
- **VS Code ne se fige pas recouvert.** Il désactive le calcul d'occlusion de Chromium. Ses deux actions manquées, une visible et une recouverte, sont perdues par VS Code lui-même (aucun effet une fois en vue) : le taux est le même dans les deux situations. Minimisé, il se fige comme Chrome.
- **`<select>` de Chrome.** Fermé, il ne liste aucune entrée ; `expand` est contredit (il reste replié), visible comme recouvert ; `collapse` échoue (`hr=0x80131509`). VS Code n'a pas de liste déroulante dans sa fenêtre : non mesuré.
- **WPF.** La fenêtre montre ses 11 nœuds, contrôles compris, dès la première lecture, 0 ms après son apparition (première lecture 90 à 103 ms), sur 3 lancements de 3 : pas d'arbre vide du provider générique à attendre.

### Verdict

**A19 est réfutée pour Chrome** (0 % recouvert, seuil 95 %) et **validée pour VS Code** (95 %). La situation la moins coûteuse qui atteint 95 % pour Chrome est la bande visible de 16 px (100 %), devant l'autre écran (100 %) ; c'est celle que US-059 recommande.

### Signalement (US-059)

- `{occluded}` sur l'en-tête d'une racine, dans `ui_tree` et `ui_find`, et dans les drapeaux de `window_list`, quand plus rien de la fenêtre ne se voit sous les fenêtres au-dessus. Sont ignorées : les fenêtres minimisées, masquées (cloaked), traversées par les clics (`WS_EX_TRANSPARENT`), translucides ou à couleur clé, à région complexe, et celles de l'indicateur.
- Une cible `Chrome_WidgetWin_*` est jugée comme Chromium se juge : sur les rectangles de fenêtre (bordures invisibles comprises) et sans les fenêtres que son calcul ignore (popups et fenêtres outils, hors barre des tâches et popups de Chromium). Une autre fenêtre est jugée sur les cadres visibles, toute fenêtre opaque comptée.
- Cible Chromium recouverte : `ui_tree` termine par « Fenêtre recouverte : Chromium suspend son rendu, l'arbre peut être figé. Déplace-la avec window_set pour qu'une bande d'au moins 16 px reste visible (window_list donne les rectangles des fenêtres au-dessus), ou sur un autre écran. » La ligne remplace le conseil « rappelle ui_tree dans 1 s », suit un delta, et s'ajoute au résultat d'un `ui_act` contredit.
- `Code.exe` reçoit le drapeau sans la ligne : la liste des applications Electron mesurées sans gel tient dans `a11y.zig` (`renders_covered`).
- Constat sur les vraies fenêtres : Chrome recouvert par le leurre porte le drapeau et la ligne ; avec 16 px en vue, ni l'un ni l'autre, comme Chromium le calcule ; VS Code recouvert porte le drapeau seul.

### Coûts

| Mesure | Résultat | Budget |
|---|---|---|
| `ui_tree` avec `root` sur l'élément fenêtre de la fenêtre de test, p95 | 30,9 ms (arbre entier : 31,5 ms) | 50 ms, p95 de l'arbre entier |
| `ui_find id:<id>` sur la fenêtre de test, p95 | 0,87 ms, CPU du processus 0,78 ms | 10 ms |
| `ui_find id:<id>` sur Chrome et VS Code, p95 | 0,69 à 0,92 ms | 10 ms |
| Lecture de l'empilement et calcul d'occlusion, 51 fenêtres au-dessus de la cible (62 dans l'empilement), p95 | 0,14 ms | 1 ms |
| `window_list` au bench (ReleaseFast), `dispatch` p95, drapeau compris | 0,43 à 0,61 ms | 110 % de la référence de 0,61 ms |
| Définitions `alwaysLoad` | environ 1 305 tokens | 1 500 |
| `tools/list` | environ 3 961 tokens | 4 500 |

Mesures en build Debug sauf le bench, provider de la fenêtre de test dans le même processus. `window_list` lit l'empilement dans l'énumération de sa propre liste : un calcul par fenêtre listée le portait à 3,4 ms, une seconde énumération à 0,81 ms.

### Points soumis à Arthur

1. **Fenêtre Chromium minimisée.** Elle n'est pas « recouverte » et ne porte pas `{occluded}`, mais elle se fige de la même façon (0 %). `ui_tree` ajoute pour elle « Fenêtre minimisée : Chromium suspend son rendu, l'arbre peut être figé. Restaure-la avec window_set state normal, une bande d'au moins 16 px visible. » Le PRD ne demande que le cas recouvert : ligne à garder ou à retirer. **Décidé (2026-11-13) : gardée**, pour toute fenêtre Chromium minimisée, VS Code compris (PRD 1.4, US-059).
2. **Terme entre guillemets de `ui_find`.** Le nom entier doit être égal, sans tenir compte de la casse ni des accents, comme les mots. Avant, un terme entre guillemets était une sous-chaîne à plusieurs mots. **Accepté (2026-11-13)** : c'est le critère de US-057, et ni les évals ni les instructions ne dépendaient de l'ancien sens.
3. **Plus de 20 correspondances.** La première ligne « <n> correspondances, 20 affichées » remplace la dernière ligne « … <n> autres résultats : précise la requête. ».
4. **`<select>` de Chrome** : sans effet par ExpandCollapse même visible. À verser à Q18. **Décidé (2026-11-13)** : dans la tâche d'éval de US-062, la liste déroulante devient une liste Win32 et la case d'une page Chrome reste ; le `<select>` d'une page Chromium fenêtre non active est une limite connue (PRD 1.4, Non-Goals).

## Revue de EP-014 (2026-11-13)

Une correction, sans changement de contrat :

- **Fenêtre VS Code minimisée.** La sonde la mesure figée comme Chrome (0 action sur 20, arbre jamais construit en place), mais seule une cible soumise au calcul d'occlusion recevait la ligne « Fenêtre minimisée ». Toute fenêtre `Chrome_WidgetWin_*` minimisée la reçoit désormais, `Code.exe` compris ; recouverte, VS Code garde le drapeau sans ligne.

Sonde relancée après la correction (`occlusion-probe chrome vscode reps=1`) : Chrome recouvert ou minimisé 0 %, bande de 16 px et autre écran 100 %, A19 réfutée ; VS Code recouvert 100 %, A19 validée ; VS Code minimisé 0 %, ligne présente. `ui_tree` avec `root` sur le plus grand conteneur de VS Code : 70 lignes, 3 675 caractères, sous le plafond de 8 000.

Mesures de la revue : `bg-tree-root` 32,0 ms au p95 (arbre entier 33,1 ms), `bg-reread` 0,99 ms, `bg-occlusion-cost` 0,18 ms avec 51 fenêtres au-dessus ; au bench, `window_list` 507 µs (référence 601 µs), `ui_tree` 31 426 µs (référence 29 926 µs), `bg-act` 2 765 µs (référence 2 549 µs), `bg-settle` 54 242 µs sur `settle` (référence 64 061 µs).

Limite connue, non corrigée : `renders_covered` ne nomme que `Code.exe`. Une autre application Electron qui désactive le calcul d'occlusion (VS Code Insiders, Cursor) recevrait à tort la ligne « Fenêtre recouverte ».

### Décisions d'Arthur après la revue (2026-11-13)

Réponse d'Arthur aux quatre recommandations de la revue : « Ok vas-y ». Les points 1, 2 et 4 ci-dessus portent leur décision. La limite de `renders_covered` ne se règle pas en allongeant la liste : une action lue « vérifié » sur une fenêtre recouverte prouve que l'application rend recouverte, et l'avertissement cesse alors pour elle pendant la session, comme l'abonnement UI Automation s'apprend par observation (US-048). C'est une idée de conception, pas une mesure : la story US-065 (EP-018, PRD 1.4) commence par la sonde de l'hypothèse A23 (aucune action lue « vérifié » sur un Chrome recouvert, élément du document web) et s'arrête si elle est infirmée.
