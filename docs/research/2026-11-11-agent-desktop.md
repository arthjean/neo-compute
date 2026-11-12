# Recherche : agent-desktop et le mode arrière-plan de neo-compute

- Date : 2026-11-11
- Objet : ce que neo-compute doit faire pour agir en arrière-plan comme agent-desktop, sans capture d'écran et sans prendre la souris ni le clavier, puis les axes pour le dépasser.
- Sources : code de neo-compute (commit `509fe6f`), code d'agent-desktop (`C:\dev\agent-desktop`, commit `54855b62`, version 1.2.0), documentation Microsoft Learn et Chromium.
- Méthode : six sous-agents d'exploration en lecture seule et un sous-agent web. Chaque rapport a été recoupé dans le code avant d'être retenu. Aucune ligne de code produit n'a été modifiée.

Les chemins `ad:` sont relatifs à `C:\dev\agent-desktop`, les autres à ce dépôt.

## 1. Ce que fait réellement agent-desktop sur Windows

| Fait | Source |
|---|---|
| CLI Rust sans état : un processus par commande, une enveloppe JSON par appel, état sur disque dans `~/.agent-desktop`. Pas de daemon. | `ad:README.md:128`, `ad:src/main.rs:78-122` |
| Mode « headless » par défaut : politique `allow_focus_steal=false`, `allow_cursor_move=false`. `--headed` est le seul interrupteur vers l'entrée physique. | `ad:crates/core/src/actions/interaction_policy.rs:4-47`, `ad:README.md:70-71` |
| Aucune technique d'entrée en arrière-plan. Les actions sémantiques appellent un pattern UI Automation (UIA), les actions physiques appellent `SendInput`. Le seul `PostMessage` du produit est `WM_CLOSE`. | grep de `ad:crates/windows/src`, `ad:crates/windows/src/system/close.rs:329` |
| Actions sans interférence : click (Invoke puis `LegacyIAccessible.DoDefaultAction`), set-value, clear, toggle, check, uncheck, expand, collapse, select, scroll, scroll-to. | `ad:crates/windows/src/actions/dispatch.rs:56-147`, `:223-249` |
| Actions refusées en headless (`POLICY_DENIED`) : type, press, right-click, double-click, triple-click, focus, hover, drag, mouse-*. | `ad:skills/agent-desktop-windows/SKILL.md:35-38`, `:65-73`, `:95` |
| `SetFocus` UIA déplace le premier plan : mesuré deux fois, donc classé « headed ». | `ad:probes/windows/FINDINGS.md:81` (A3-4), `:314` (A19-5) |
| Une fenêtre recouverte est pilotable, une fenêtre minimisée ne l'est pas. | `ad:skills/agent-desktop-windows/SKILL.md:53-56` |
| Chromium et Electron : une fenêtre entièrement recouverte peut garder indéfiniment un arbre tronqué. | `ad:skills/agent-desktop-windows/references/chromium-and-electron.md:40-45` |
| Snapshot en JSON, références `@<snapshot>:eN` stockées dans `refmap.json`, ré-identifiées à chaque commande par chemin puis prédicat complet. Deux contrôles identiques sont refusés (`AMBIGUOUS_TARGET`). | `ad:crates/core/src/refs/resolve_saved_ref.rs:28-47`, `ad:skills/agent-desktop-windows/SKILL.md:96` |
| Avant l'action : contrôles visible, stable, activé, éditable, reçoit les événements, sondés jusqu'à 5 s, avec un défilement automatique. | `ad:crates/core/src/actionability/requirements.rs:14-35`, `ad:crates/core/src/ref_action/mod.rs:91-127` |
| Après l'action : relecture toutes les 50 ms pendant 400 ms au plus, verdict `delivered_verified`, `delivered_unverified` ou échec de vérification. L'action n'est jamais rejouée. | `ad:crates/core/src/actions/post_action.rs:56-57`, `ad:skills/agent-desktop-windows/references/troubleshooting.md:132-155` |
| Capture d'écran : commande séparée, Windows.Graphics.Capture puis `PrintWindow`. Elle sert de preuve, jamais de ciblage. | `ad:crates/windows/src/system/capture/capture_modern.rs:27-29`, `ad:docs/faq.md:9` |
| Test de non-interférence : position du curseur et fenêtre au premier plan lues avant et après chaque commande sémantique, avec vérification de l'effet. Local uniquement, hors CI. | `ad:tests/e2e-windows/scenarios/NonInterference.ps1:5-16`, `ad:tests/e2e-windows/README.md:79-84` |
| Entrées maintenues (`key-down`, `mouse-down`) refusées faute de daemon. | `ad:README.md:128` |
| MCP : chaque appel relance le binaire en processus enfant. | `ad:src/mcp/call.rs:26` |
| Coût mesuré d'une commande entière : `snapshot --app notepad.exe -i` 143 à 185 ms, `list-windows` 60 à 76 ms (une machine, sept essais). | `ad:probes/windows/24-fixture-e2e/captures/cost-baseline-devbox.json` |
| Empreinte : 166 paquets dans `Cargo.lock`, 2 774 fichiers Rust, binaire non signé sur Windows, plafond CI de 15 Mo. Pas de garde de performance en CI. | `ad:Cargo.lock`, `ad:skills/agent-desktop-windows/references/troubleshooting.md:62` |

## 2. Où en est neo-compute

Acquis :

- `ui_tree`, `ui_find` et `ui_act` existent. `ui_act` agit par identifiant d'élément via les patterns UIA : invoke, toggle, select, expand, collapse, set_value, focus, scroll_into_view (`src/backend/windows/uia.zig:1084-1097`).
- Les éléments restent vivants entre deux appels (pointeurs COM gardés, 4 fenêtres) : pas de ré-identification sur disque (`src/backend/windows/uia.zig:260-286`).
- Format ligne compact et delta `since: "last"` (`src/core/uitree.zig:402-405`, `:638-695`). Delta médian après action : 96 tokens (`evals/reports/2026-11-03.md`).
- `ui_tree` en régime établi : p95 de 17 à 35 ms sur Notepad, Calculatrice, Paramètres, Chrome, VS Code (`bench/apps.md:12-19`).
- Politique par application, audit, masquage des mots de passe, refus des cibles élevées, fenêtres figées détectées.
- `window_set` déplace sans activer (`SWP_NOACTIVATE`, `src/backend/windows/window.zig:313-332`).

Obstacles à l'arrière-plan, vérifiés dans le code :

1. Le kill switch s'arme pour tout outil d'action, `ui_act` compris, stabilisation incluse (`src/core/mcp.zig:457-459`). Un mouvement de souris physique de plus de 8 px ou un Échap physique met alors le serveur en pause jusqu'au réarmement (`src/core/control.zig:43-50`, `src/backend/windows/hooks.zig:187-214`).
2. La stabilisation après action lit les pixels de l'écran dans le rectangle de la fenêtre cible (`src/core/a11y.zig:600-673`). Si la cible est recouverte, c'est l'activité de l'utilisateur qui est mesurée.
3. `ui_find wait_ms` relance sa recherche sur les mêmes changements de pixels (`src/core/a11y.zig:413-483`).
4. `ui_tree` et `ui_find` sans `window` lisent la fenêtre au premier plan, donc celle de l'utilisateur (`src/backend/windows/uia.zig:366`). Le delta renvoie un arbre complet dès que le premier plan change (`src/core/a11y.zig:228`).
5. L'indicateur de contrôle encadre chaque écran pendant toute action (`src/core/indicator.zig:16-22`).
6. `ui_act focus` appelle `SetFocus` (`src/backend/windows/uia.zig:1085`), qui déplace le premier plan d'après les sondes d'agent-desktop.
7. `fallback: "click"` injecte un vrai clic (`src/core/a11y.zig:573-581`).
8. `app_launch` ouvre avec `SW_SHOWNORMAL` (`src/backend/windows/shell.zig:387-403`).
9. Toute la saisie clavier et souris passe par `SendInput` (`src/backend/windows/input.zig:13`).
10. La capture est par écran entier (DXGI, repli GDI) : une fenêtre recouverte ne peut pas être capturée (`src/backend/windows/capture.zig`, `bindings/windows.zon`).
11. Aucune surface CLI : MCP stdio uniquement (`src/main.zig:22-66`).

## 3. Liste complète des travaux

### Lot A : contrat d'arrière-plan

- A1. Classer chaque outil : sans interférence, prend le premier plan, entrée physique. Annotation à côté de `read_only` (`src/core/registry.zig:21-24`, `src/core/tools.zig`).
- A2. Politique d'arrière-plan : refuser avant tout effet un outil intrusif, avec un message qui nomme la cause et l'action suivante (FR-06). Activation à décider (mode serveur ou niveau de politique).
- A3. Reclasser `ui_act focus` comme intrusif.
- A4. Refuser `fallback: "click"` en arrière-plan.
- A5. Lancer une application sans lui donner le premier plan, et vérifier que le premier plan n'a pas changé.
- A6. `window_set` : restaurer et maximiser sans activer (`src/backend/windows/window.zig:336-359`).
- A7. Fenêtre cible de session : un outil sans `window` vise la cible de l'agent, jamais la fenêtre de l'utilisateur. Le delta se cale sur cette cible.

### Lot B : cohabitation avec l'utilisateur

- B1. Kill switch : ne plus armer le déclenchement souris ni avaler Échap pour une action sans interférence. Garder un geste de pause explicite (FR-12).
- B2. Indicateur : signal discret limité à la fenêtre cible, ou aucun, en arrière-plan (décision 0011).
- B3. Stabilisation sans pixels : relecture UIA de la cible ou événements, quand la cible n'est pas visible.
- B4. Attentes sans pixels pour `ui_find wait_ms`, et attente de disparition (non-objectif actuel du PRD de parité, ligne 565).
- B5. Garde d'exécution : après chaque action d'arrière-plan, vérifier que le premier plan et le curseur n'ont pas bougé, et le dire dans le résultat.

### Lot C : actions sémantiques

- C1. `check` et `uncheck` idempotents (lecture de l'état avant Toggle).
- C2. Défilement sémantique par `ScrollPattern` (neo-compute ne fait que le lire, `src/backend/windows/uia.zig:671-683`).
- C3. `set_value` numérique sur `RangeValuePattern` (curseurs).
- C4. Sélection par nom dans un conteneur : déplier, réaliser l'élément, sélectionner, replier.
- C5. Chaînes de repli : Invoke puis `DoDefaultAction` pour toutes les applications (aujourd'hui réservé à Firefox via MSAA), Toggle puis Invoke, ExpandCollapse puis Invoke.
- C6. `scroll_into_view` : repli par le `ScrollPattern` d'un ancêtre quand `ScrollItem` manque.
- C7. Attente automatique des préconditions et défilement automatique (aujourd'hui erreur immédiate, `src/core/a11y.zig:558-570`).
- C8. Verdict de livraison : vérifié, non vérifié, contredit, plus « non délivré, réessai sûr ».
- C9. Sonde : menus et dialogues ouverts sur une fenêtre non active.

### Lot D : perception

- D1. Exploration par sous-arbre (`root: <id>`) et vue squelette pour les grandes applications (plafond actuel de 8 000 caractères).
- D2. Lecture d'une propriété d'un seul élément, sans relire l'arbre.
- D3. `ui_find` : recherche par valeur, texte exact, comptage.
- D4. Sonde et parade pour Chromium et Electron recouverts.
- D5. Sonde : première lecture d'une fenêtre WPF juste après son lancement.

### Lot E : passe visuelle en arrière-plan

- E1. Capture d'une fenêtre recouverte, par `PrintWindow` ou Windows.Graphics.Capture, en paramètre optionnel `window` de `screenshot` et `zoom`.
- E2. Masquage des mots de passe et des applications `deny` sur ce chemin.

### Lot F : surface CLI

- F1. CLI au-dessus du serveur persistant (décision : canal local, FR-10, FR-14).
- F2. Skill qui enseigne la boucle observer, agir, vérifier.
- F3. Lot d'actions en un seul appel.

### Lot G : preuve

- G1. `selftest` de non-interférence : curseur, premier plan et focus clavier inchangés autour de chaque action, effet vérifié, fenêtre leurre au premier plan.
- G2. Suite d'évals d'arrière-plan avec activité utilisateur simulée.
- G3. Scénarios de bench pour une action d'arrière-plan et sa stabilisation.

## 4. Axes pour dépasser agent-desktop

- S1. Serveur persistant : éléments vivants, pas de refus sur contrôles jumeaux, pas de reparcours de fenêtre à chaque action.
- S2. Entrées maintenues avec relâche garantie (agent-desktop les refuse).
- S3. Coût en tokens : lignes et deltas contre arbre JSON sans diff.
- S4. Saisie de texte en arrière-plan par échelons : `ValuePattern`, puis messages de contrôle Win32 ciblés (`EM_REPLACESEL`, `WM_SETTEXT`) pour les contrôles classiques. Limite documentée : un message clavier posté ne met pas à jour l'état des touches et contourne les IME.
- S5. Raccourcis résolus en actions : retrouver l'élément qui porte la touche d'accès ou d'accélération et l'invoquer.
- S6. Isolation forte : session enfant Windows ou bureau dédié, pour l'entrée réelle sans interférence. agent-desktop n'a pas de bac à sable sur Windows.
- S7. Attentes pilotées par événements (`SetWinEventHook` hors contexte), avec repli par relecture.
- S8. Parade à l'occlusion Chromium.
- S9. Plusieurs fenêtres pilotées en parallèle.
- S10. Restauration du premier plan si une application cible le vole.
- S11. Minimalisme mesuré : binaire unique, deux dépendances, garde de performance déjà en place, binaire signé.
- S12. Passe visuelle différentielle par fenêtre.

## 5. Faits Windows vérifiés sur sources primaires

| Fait | Statut | Source |
|---|---|---|
| Les pages Invoke, SetValue et SetFocus ne posent aucune condition de premier plan. | Non documenté, à sonder | <https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-setfocus> |
| Gestionnaires d'événements UIA : thread MTA sans fenêtre, ajout et retrait sur le même thread, un seul thread. | Documenté | <https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading> |
| `SetWinEventHook` hors contexte : le thread appelant doit avoir une boucle de messages. | Documenté | <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook> |
| Windows.Graphics.Capture : `CreateForWindow` depuis Windows 10 1903. Capture d'une fenêtre recouverte ou minimisée non décrite. Retirer la bordure demande un consentement et une capacité déclarée. | Partiel, à sonder | <https://learn.microsoft.com/en-us/uwp/api/windows.graphics.capture.graphicscapturesession.isborderrequired> |
| `PW_RENDERFULLCONTENT` absent de la page `PrintWindow`. | Non documenté, à sonder | <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow> |
| Session enfant : session Bureau à distance en boucle locale liée à la session de l'utilisateur, depuis Windows 8, une seule à la fois, créée par le contrôle ActiveX RDP. Éditions prises en charge non précisées. | Partiel, à sonder | <https://learn.microsoft.com/en-us/windows/win32/termserv/child-sessions> |
| Bureaux : seul le bureau d'entrée reçoit la saisie de l'utilisateur. Les messages ne passent qu'entre processus du même bureau. | Partiel | <https://learn.microsoft.com/en-us/windows/win32/winstation/desktops> |
| Chromium : une fenêtre recouverte voit son rendu arrêté et son JavaScript ralenti. Les fenêtres d'un autre bureau virtuel comptent comme recouvertes. L'effet sur l'arbre d'accessibilité n'est pas décrit. | Partiel, à sonder | <https://chromium.googlesource.com/chromium/src/+/main/docs/windows_native_window_occlusion_tracking.md> |
| Chrome active UIA natif par défaut depuis la version 138. | Documenté | <https://developer.chrome.com/blog/windows-uia-support-update> |
| `SendInput` est soumis à UIPI et sa valeur de retour ne signale pas ce blocage. | Documenté | <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput> |
| Messages clavier postés : état des touches non mis à jour, IME contournés. Microsoft recommande UI Automation ou `SendInput`. | Documenté | <https://devblogs.microsoft.com/oldnewthing/20250319-00/?p=110979> |

## 6. Décisions à prendre par Arthur

1. Arrière-plan comme mode par défaut, ou mode à activer (comportement de politique).
2. Kill switch en arrière-plan : quel geste de pause, FR-12 et décision 0008 point 5.
3. Indicateur en arrière-plan (décision 0011).
4. Nouvelles valeurs de `ui_act.action` et nouveaux paramètres optionnels (contrat d'outils).
5. Surface CLI et canal local entre CLI et serveur (FR-10, FR-14).
6. Notifications et surfaces système : toujours hors périmètre ou non.
7. Pilotage parallèle de plusieurs fenêtres (non-objectif « plusieurs agents »).
8. Exposition à la Rust Switch Gate : gestionnaires d'événements UIA (objets COM implémentés côté client) et Windows.Graphics.Capture (interfaces WinRT absentes de win32metadata).

## 7. Limites de cette recherche

- Les comparaisons de latence viennent de machines et de méthodes différentes : elles sont indicatives.
- Non lus chez agent-desktop : `live_locator` en détail, navigation de menus, notifications, zones 10 à 18 et 23 à 28 de `FINDINGS.md`.
- Tout ce qui est marqué « à sonder » reste une hypothèse tant qu'une sonde ne l'a pas mesuré sur la machine de référence.
