# Recherche : agent-desktop face à la cohabitation en arrière-plan (stabilisation, premier plan, Chromium recouvert)

- Date : 2026-11-13
- Objet : établir, à partir du code, comment agent-desktop traite sur Windows trois problèmes : savoir quand la cible a fini de changer après une action, réagir quand la cible prend le premier plan, lire l'arbre d'une fenêtre Chromium ou Electron recouverte. C'est un constat de ce que le code fait aujourd'hui, pas une revue de conception. Rien n'est implémenté ni recommandé.
- Sources : le dépôt local `C:\dev\agent-desktop` seul (Rust, commit `2f650705`, 2026-11-12) : le code de `crates/core`, `crates/windows` et `src`, puis ses propres documents quand ils consignent une mesure ou une décision (`probes/windows/FINDINGS.md`, `skills/agent-desktop-windows/`, `CONCEPTS.md`, `CHANGELOG.md`, `tests/e2e-windows/`). Aucune source externe.
- Méthode : lecture seule (Read, Grep, Glob) ; rien n'a été compilé ni exécuté. Chaque ligne porte « vérifié » (le code ou le document cité a été lu à la ligne indiquée) ou « déduit » (conclusion tirée de ce qui a été lu, qu'aucune ligne ne dit). Une absence est « vérifié » quand une recherche sur tout le dépôt ne renvoie rien. Quand un document et le code divergent, le code fait foi et l'écart est noté en section 4. La note du 2026-11-11 a été relue d'abord et n'est pas répétée.

Les chemins sont relatifs à `C:\dev\agent-desktop`.

Vocabulaire. Un WinEvent est une notification d'accessibilité que Windows diffuse à tout processus qui la demande par `SetWinEventHook`. Un événement UI Automation (UIA) n'arrive qu'à un client qui a enregistré un objet de rappel (un « gestionnaire »). Un pattern UIA est une action sémantique offerte par un contrôle (Invoke, Toggle, Value). Le premier plan est la fenêtre qui reçoit le clavier. Un HWND est l'identifiant Windows d'une fenêtre. Une sonde est un script du dépôt qui mesure un comportement réel et consigne le résultat dans `FINDINGS.md`. « Headless » est le mode par défaut d'agent-desktop : aucune prise de focus, aucun mouvement de curseur.

## 1. Savoir quand la cible a fini de changer

Réponse courte : sur Windows, agent-desktop n'écoute aucun événement. Il ne stabilise pas la fenêtre après une action : il relit l'élément visé (actions à état) ou ne relit rien (clic), puis rend la main. Toutes les attentes sont des relectures périodiques de l'arbre UIA ou de la liste des fenêtres.

### 1.1 Source de changement

| Fait | Source | Statut |
|---|---|---|
| Aucun appel à `SetWinEventHook` dans tout le dépôt, sondes comprises. Les deux seules occurrences de « WinEvent » sont la cmdlet `Get-WinEvent` et un commentaire de test | `probes/windows/16-observation/census.ps1:181`, `crates/windows/src/tree/live_read_edit_tests.rs:20` | vérifié |
| Aucun gestionnaire d'événements UIA dans le produit. `AddAutomationEventHandler`, `AddPropertyChangedEventHandler` et `AddFocusChangedEventHandler` n'existent que dans deux sondes C# | `probes/windows/08-uia3-com.cs:723-729`, `probes/windows/26-shell-surfaces/shell-probe.cs:184-191` | vérifié |
| Le cœur prévoit un abonnement optionnel : `subscribe_wait` rend `Ok(None)` par défaut, avec le commentaire « Without a subscription the same predicates run with bounded polling » | `crates/core/src/adapter/system.rs:147-155` | vérifié |
| Seul l'adaptateur Linux implémente `subscribe_wait` ; aucune occurrence sous `crates/windows` | `crates/linux/src/system/adapter.rs:30` | vérifié |
| Même avec un abonnement, un réveil n'est qu'un indice pour relire, « never evidence that it matched » | `crates/core/src/wait/wait_wakeup.rs:3-12` | vérifié |
| Sans abonnement, l'ordonnanceur des attentes dort 100 ms entre deux relectures | `crates/core/src/commands/wait_scheduler.rs:5`, `:22-35` | vérifié |
| Aucun pixel ne sert à décider. Les captures avant et après action sont des pièces de trace | `crates/core/src/ref_action/mod.rs:199-236` | vérifié |

### 1.2 Après une action

| Fait | Source | Statut |
|---|---|---|
| Clic : `InvokePattern.Invoke`, puis `LegacyIAccessible.DoDefaultAction` en repli. Le résultat est « livré, non vérifié » ; le clic n'est pas dans la liste des actions relues | `crates/windows/src/actions/dispatch.rs:192-213`, `crates/core/src/actions/action.rs:87-93`, `crates/core/src/actions/post_action.rs:13-16` | vérifié |
| Seul complément après click, expand, select ou press : une lecture unique et immédiate des « surfaces » du processus (fenêtres, fenêtre au premier plan, dialogue modal, menu ouvert), jointe au résultat. Aucune attente ne la précède | `crates/core/src/actions/action.rs:121-135`, `crates/core/src/ref_action/mod.rs:160-163`, `:174-186` | vérifié |
| Actions à état (set-value, clear, type, toggle, check, uncheck, expand, collapse) : relecture de l'élément visé toutes les 50 ms, plafond 400 ms, arrêt dès que la postcondition tient | `crates/core/src/actions/post_action.rs:55-74` | vérifié |
| Texte tapé par touches : la boucle dépasse 400 ms tant que la valeur change encore et que le délai de l'action le permet | `crates/core/src/actions/post_action.rs:58-69`, `:141-149` | vérifié |
| L'adaptateur Windows vérifie d'abord lui-même : Toggle 600 ms au plus, valeur stable 200 ms, pas 25 ms ; Select 600 ms ; Expand et Collapse 200 ms ; ScrollIntoView 800 ms | `crates/windows/src/actions/toggle_state.rs:14-16`, `:273-303`, `select.rs:20-21`, `disclosure.rs:19-20`, `scroll_into_view.rs:40-41` | vérifié |
| Ces boucles ne lisent que l'élément visé : rien ne dit que le reste de la fenêtre a fini de changer | `crates/core/src/actions/post_action.rs:55`, `:71` | déduit |
| `--wait-for` et `--wait-for-gone` : l'attente du sélecteur part après le relâchement du verrou d'interaction (verrou entre processus qui sérialise les actions), sur la fenêtre source de la référence | `crates/core/src/commands/helpers.rs:146-148`, `:165-189` | vérifié |
| Avant l'action, la « stabilité » exigée est celle des bornes de l'élément : 3 lectures identiques à 0,5 px près sur au moins 34 ms, lues toutes les 17 ms | `crates/core/src/actionability/stability_sampler.rs:4-6`, `:40`, `crates/core/src/ref_action/mod.rs:263-304` | vérifié |
| Cible recouverte : quand le contrôle offre un pattern de clic, la livraison est « Semantic » et le test d'occlusion par point n'est pas exécuté. Mesure consignée : le clic agit à travers une fenêtre posée par-dessus (`clicked#1`) | `crates/core/src/actionability/requirements.rs:37-56`, `tests/e2e-windows/scenarios/Acceptance.ps1:13-20` | vérifié |

### 1.3 Attendre un élément, attendre sa disparition

| Fait | Source | Statut |
|---|---|---|
| `--wait-for <role:text>` et `--wait-for-gone` (snapshot et actions par référence) : recherche du sélecteur dans l'arbre UIA de la fenêtre, profondeur brute 50, premier résultat, répétée par l'ordonnanceur à 100 ms | `src/cli/post_action_wait.rs:5-25`, `crates/core/src/commands/wait_selector.rs:151-170`, `crates/core/src/commands/selector_observation.rs:53-66` | vérifié |
| « Disparu » : une observation complète sans correspondance, ou le processus propriétaire terminé. Une observation incomplète ne compte pas et relance | `crates/core/src/commands/wait_selector.rs:83-88`, `:230-236` | vérifié |
| Résultat de disparition : `matched_selector`, `gone: true`, `target_absent: true`, `elapsed_ms`. À l'expiration : `TIMEOUT`, `kind: "wait_timeout"`, dernière erreur et `snapshot_id` d'un instantané de diagnostic borné à 600 ms | `crates/core/src/commands/wait_selector.rs:15`, `:172-197`, `:308-315`, `crates/core/src/commands/wait_timeout.rs:150-177` | vérifié |
| `wait --element <ref>` avec prédicat `exists`, `enabled`, `visible`, `actionable` ou `value` : re-résolution de la référence puis lecture, pas 100 ms | `crates/core/src/commands/wait_element.rs:34-99`, `crates/core/src/commands/wait_predicate.rs:26-45` | vérifié |
| `wait --text` reconstruit un instantané complet à chaque tour ; `wait --window` relit `list_windows` toutes les 100 ms | `crates/core/src/commands/wait.rs:223-283`, `:151-188` | vérifié |
| `wait --event` (`window-opened`, `window-closed`, `app-launched`, `app-terminated`, `focus-changed`, `surface-appeared`, `surface-dismissed`) : différence entre deux inventaires, pas un événement. Sur Windows, un inventaire est une passe `EnumWindows` plus un instantané ToolHelp, plus un balayage des dialogues modaux et menus du processus nommé | `crates/core/src/wait/event_kind.rs:33-43`, `crates/core/src/commands/wait_event.rs:10-14`, `:80-125`, `crates/windows/src/system/signal/signal_inventory.rs:14-16`, `crates/windows/src/system/signal/signals.rs:39-63` | vérifié |
| Dans un `batch`, l'inventaire de référence est pris juste avant l'entrée qui agit, pour qu'un dialogue ouvert par un clic soit vu par le `wait` suivant | `src/batch/execution.rs:30`, `:101`, `tests/e2e-windows/scenarios/Surfaces.ps1:96-120` | vérifié |
| `wait --menu` et `--menu-closed` : sondage toutes les 50 ms d'un prédicat à trois sources | `crates/windows/src/system/wait.rs:10`, `:60-87`, `crates/windows/src/system/menu/menu_state.rs:24-37` | vérifié |

### 1.4 Délais et pas

| Quoi | Valeur | Source | Statut |
|---|---|---|---|
| `--wait-timeout` et `wait --timeout` par défaut | 30 000 ms | `src/main.rs:237-241`, `src/cli_args/system.rs:10-12` | vérifié |
| Plafond de tout délai d'attente | 24 h | `crates/core/src/wait/wait_budget.rs:7` | vérifié |
| Délai par défaut d'une opération, d'un snapshot, d'une tentative de résolution de référence | 5 000 ms, 3 000 ms, 4 000 ms | `crates/core/src/wait/deadline.rs:8`, `crates/core/src/snapshot/mod.rs:162`, `crates/core/src/refs/ref_resolve_deadline.rs:11` | vérifié |
| Sondage avant action | 16 ms si seule la stabilité manque, 100 ms sinon | `crates/core/src/ref_action/ref_action_poll.rs:17`, `:89-99`, `crates/core/src/refs/ref_resolve_deadline.rs:10` | vérifié |
| Délais UIA côté client : connexion, transaction | 2 000 ms, 20 000 ms | `crates/windows/src/tree/automation.rs:30`, `:33`, `:190-203` | vérifié |
| Sonde « la fenêtre pompe-t-elle ses messages » (`SendMessageTimeoutW(WM_NULL)`) avant `ElementFromHandle` | 2 000 ms au plus | `crates/windows/src/tree/automation.rs:18`, `:243-246`, `:272-289` | vérifié |

Aucune « période de silence » n'existe : le mot n'a de sens qu'avec des événements. Les seules fenêtres de stabilité sont celles de 1.2 (bornes sur 34 ms, état de Toggle sur 200 ms).

### 1.5 Par framework d'interface

| Fait | Source | Statut |
|---|---|---|
| Aucune branche par framework dans les attentes ni dans la relecture après action. Hors tests, `FrameworkId` n'est lu que par la détection de menu et les notifications | `crates/windows/src/system/menu/menu_state.rs`, `menu_state_chromium.rs`, `crates/windows/src/notifications/read.rs` | vérifié |
| Détection de menu par famille : drapeaux `GetGUIThreadInfo` (menus Win32 classiques), fenêtre outil portant un élément Menu (WPF), élément Menu de framework `Chrome` (Chromium et Electron) | `crates/windows/src/system/menu/menu_state.rs:11-37`, `menu_state_chromium.rs:21-26` | vérifié |
| Une racine Chromium, reconnue par la classe `Chrome_WidgetWin_1`, est le seul cas où une lecture attend que l'arbre grossisse (section 3) | `crates/windows/src/tree/chromium.rs:13`, `:27-33` | vérifié |
| WPF lu avant la création de son pair d'automation : le fournisseur générique reste lié et la fenêtre montre zéro enfant. Consigné comme piège ; aucune parade dans le code (aucune occurrence de `HwndWrapper` sous `crates/`) | `probes/windows/FINDINGS.md:61`, `skills/agent-desktop-windows/references/chromium-and-electron.md:47-56` | vérifié |
| WinUI 3, MSIX : jamais mesurés, faute d'hôte. La machine de mesure est Windows Server 2019, build 17763 | `probes/windows/FINDINGS.md:39-40`, `:145`, `:407`, `skills/agent-desktop-windows/references/shell-and-overlay.md:148-154` | vérifié |

### 1.6 Sondes et mesures consignées

| Sonde | Ce qui est mesuré | Chiffres | Source | Statut |
|---|---|---|---|---|
| A8-1, `08-uia3-com.ps1` | Quels événements UIA arrivent, sur une seule fenêtre de test (pile COM) | 7 gestionnaires, 557 événements en 20 répétitions : `Value` 318, `Name` 180, focus 42, fenêtre fermée 10, ouverte 7. Jamais reçus : `Invoke_Invoked`, `Text_TextChanged`, `ElementSelected`, ni les changements de `ToggleState`, `HasKeyboardFocus`, `RangeValue` | `probes/windows/FINDINGS.md:123`, `probes/windows/08-uia3-com.ps1:279` | vérifié |
| A8-2 | Ordre des événements | Événements de fenêtre absents dans 12 répétitions sur 20, 6 ordres distincts | `probes/windows/FINDINGS.md:124` | vérifié |
| A8-3 | Coût du retrait des gestionnaires, côté client | 72,49 ms sous charge ; 86 184 ms sur un flux calme après masquage et réaffichage de fenêtres, contre 63,75 ms sans ce va-et-vient | `probes/windows/FINDINGS.md:125` | vérifié |
| A8-4 | Threads de rappel | Rappels sur 4 threads distincts, dont le thread d'enregistrement | `probes/windows/FINDINGS.md:126` | vérifié |
| A23-6 | Coût d'un inventaire de `wait --event` | Médiane 3,32 ms ; 14,08 ms avec 5 reprises forcées | `probes/windows/FINDINGS.md:409` | vérifié |
| A23-7 | Coût du prédicat de menu | Drapeaux classiques 16,74 ms, balayage UIA 6,84 ms (médianes) | `probes/windows/FINDINGS.md:410` | vérifié |
| A19-8 | Coût d'une écriture par pattern, relecture comprise | 204 à 226 ms au minimum sur la machine de mesure | `probes/windows/FINDINGS.md:317` | vérifié |
| A4-6, A7-4 | Mouvement propre de la cible | Un arbre Electron passe seul de 13 à 15 nœuds sans action ; Explorer met jusqu'à 20 s à refléter un changement de fichiers | `probes/windows/FINDINGS.md:93`, `:117` | vérifié |

Ce que le dépôt laisse ouvert sur ce point :
- Aucune mesure ne dit quel framework signale quoi par quel canal : A8-1 porte sur une seule fenêtre de test, portée `app/provider` (vérifié, `probes/windows/FINDINGS.md:123`).
- Aucun coût d'abonnement mesuré dans l'application cible : A8-3 mesure le client (vérifié, même ligne ; absence d'autre mesure : déduit).
- A8-1 décrit une commande `watch` adossée aux gestionnaires UIA ; elle n'existe pas dans le produit (vérifié : aucune occurrence sous `src/cli`).
- Chromium, WinUI 3 et les menus XAML restent hors des mesures de détection de menu (vérifié, `probes/windows/FINDINGS.md:406-407`, `:518`).

## 2. La cible prend le premier plan

Réponse courte : il n'existe aucune garde, aucune détection automatique et aucune restauration du premier plan de l'utilisateur. agent-desktop évite les appels dont il a mesuré qu'ils déplacent le premier plan (refus par politique), et signale après coup, une seule fois, quelle fenêtre du processus cible est au premier plan. Si un clic ouvre un dialogue qui passe devant, rien ne le ramène derrière.

### 2.1 Ce que le code fait

| Fait | Source | Statut |
|---|---|---|
| Politique par défaut : `allow_focus_steal: false`, `allow_cursor_move: false` | `crates/core/src/actions/interaction_policy.rs:10-15`, `:43-47` | vérifié |
| `SetFocus` UIA est refusé en headless avec `POLICY_DENIED`, message « SetFocus moves the desktop foreground window on Windows », détail `foreground_effect: true` et les deux sondes en preuve | `crates/windows/src/actions/focus.rs:29-36`, `:98-107` | vérifié |
| Le client UIA est créé à partir de `CUIAutomation8`, mais seulement pour régler `SetConnectionTimeout` et `SetTransactionTimeout` | `crates/windows/src/tree/automation.rs:168-203` | vérifié |
| `AutoSetFocus` n'apparaît nulle part dans le dépôt (code, sondes, documents) | recherche insensible à la casse de `AutoSetFocus` | vérifié |
| Les patterns sont donc appelés avec le réglage par défaut du client. Si un appel de pattern donne le focus à sa cible, rien ici ne l'empêche | `crates/windows/src/tree/automation.rs:190-203` | déduit |
| Aucune lecture du premier plan autour d'une action sémantique : ni avant, ni après. `GetForegroundWindow` ne sert qu'à l'inventaire des fenêtres, aux surfaces, à l'entrée clavier « headed » et aux surfaces du shell | `crates/windows/src/system/window/window_ops.rs:209-210`, `crates/windows/src/tree/surfaces.rs:99-100`, `crates/windows/src/system/key_dispatch.rs:241-250`, `crates/windows/src/system/shell/shell_surface_open.rs:267-270` | vérifié |
| Aucune restauration : dans le code Rust, le seul identifiant du genre `previous_foreground` est dans un test, et `crates/` ne contient hors tests aucun `AttachThreadInput`, `AllowSetForegroundWindow`, `LockSetForegroundWindow`, `BringWindowToTop`, `SwitchToThisWindow` | `crates/windows/src/system/window/frame_identity_settings_tests.rs:50-61` (seule occurrence, test) | vérifié |
| Le seul appel `SetForegroundWindow` du produit amène la cible devant, pour l'entrée physique `--headed` et `focus-window` : 2 tentatives séparées de 25 ms, succès jugé par relecture, puis confirmation 2 lectures sur 750 ms | `crates/windows/src/system/window/window_activate.rs:28-29`, `:123-154`, `:248-272`, `crates/core/src/system/window_focus.rs:5-7`, `:24-59` | vérifié |
| Après une action `--headed`, le premier plan d'avant n'est pas remis | même recherche que ci-dessus | vérifié |
| Aucune distinction entre un changement fait par l'utilisateur et un changement fait par l'application : la question n'est posée nulle part | absence de tout code de garde | déduit |

### 2.2 Ce que l'agent reçoit

| Fait | Source | Statut |
|---|---|---|
| Le résultat d'un click, expand, select ou press porte `surfaces` : pour le processus cible, chaque fenêtre (`window`), celle au premier plan (`focused`), un dialogue modal (`sheet`, lu par `WindowIsModal`) et un menu ouvert (`menu`) | `crates/core/src/actions/action_result.rs:14-18`, `crates/windows/src/tree/surface_inventory.rs:14-21`, `:34-57`, `:127-151` | vérifié |
| Cette lecture est faite une fois, dès le retour de l'appel. Le commentaire la dit « purely informational » ; un échec de lecture donne une liste vide | `crates/core/src/ref_action/mod.rs:174-186` | vérifié |
| Un dialogue qui apparaît après le retour n'est vu que si l'agent le demande : `--wait-for`, `wait --window`, `wait --event window-opened` ou `surface-appeared`. Le guide le dit pour « Save As » (10,9 s mesurées entre le clic et le fichier sur disque) | `skills/agent-desktop-windows/references/troubleshooting.md:185-198`, `:209-212` | vérifié |
| `wait --event focus-changed` rapporte un changement de fenêtre au premier plan, par différence d'inventaires. C'est une commande à lancer, pas une surveillance | `crates/core/src/wait/signals.rs:89-115`, `crates/windows/src/system/signal/signal_inventory.rs:196-205` | vérifié |
| Aucun journal ni champ de résultat ne dit « le premier plan a changé pendant l'action » | lecture de `crates/core/src/ref_action/mod.rs:138-171` | déduit |
| `Invoke` est appelé directement, sans thread ni délai propre. Un fournisseur qui ne rend la main qu'à la fermeture d'un dialogue modal bloquerait l'appel jusqu'au délai de transaction UIA (20 s) | `crates/windows/src/actions/chain.rs:239-248`, `crates/windows/src/tree/automation.rs:33` | déduit |

### 2.3 Refus et limites documentées

| Fait | Source | Statut |
|---|---|---|
| Refusés en headless parce qu'ils prennent le premier plan : `focus`, les surfaces du shell (`open-system-surface`), les notifications quand le centre est fermé | `crates/core/src/adapter/system.rs:157-166`, `skills/agent-desktop-windows/SKILL.md:36`, `:77-83` | vérifié |
| `press --app` vers une application qui n'est pas devant échoue sans rien envoyer : « Windows SendInput cannot deliver to a background process » | `crates/windows/src/system/key_dispatch.rs:80-92`, `:163-176` | vérifié |
| Le guide déconseille `focus-window` (« it steals the user's foreground ») et propose `restore` pour une fenêtre minimisée | `skills/agent-desktop-windows/SKILL.md:53-56` | vérifié |
| `restore` appelle `ShowWindowAsync(SW_RESTORE)`, sans drapeau de non-activation ni relecture du premier plan ; seul le déplacement ou redimensionnement porte `SWP_NOACTIVATE` | `crates/windows/src/system/window/window_op.rs:163-187`, `:217-226` | vérifié |
| `launch` crée le processus avec une structure `STARTUPINFOW` par défaut : aucune demande d'affichage sans activation. L'option `--activate` n'est lue que par l'adaptateur macOS | `crates/windows/src/system/launch.rs:201-233`, `crates/macos/src/system/launch.rs:32` | vérifié |

### 2.4 Sondes et mesures consignées

| Sonde | Ce qui est mesuré | Résultat | Source | Statut |
|---|---|---|---|---|
| A3-4 (pile .NET) et A19-5 (pile COM du produit) | `SetFocus` sur un élément d'une fenêtre d'arrière-plan | Le premier plan passe à la cible, sans appel à `SetForegroundWindow` | `probes/windows/FINDINGS.md:81`, `:314` | vérifié |
| A19-1, A19-6 | Invoke, Toggle, SetValue, ExpandCollapse, Select, `DoDefaultAction` sur les fenêtres de test WPF et WinForms | Réussis « non-foreground » | `probes/windows/FINDINGS.md:310`, `:315` | vérifié |
| `NonInterference.ps1` | Curseur et `GetForegroundWindow` lus avant et après 11 commandes sémantiques, avec vérification de l'effet | Le test échoue si l'un des deux bouge. Local seulement, hors CI | `tests/e2e-windows/scenarios/NonInterference.ps1:23-42`, `:82-83`, `:111-118`, `tests/e2e-windows/README.md:83-84` | vérifié |
| Scénario « sheet » | Un clic qui ouvre un dialogue modal, puis `wait --event surface-appeared` | Le dialogue est détecté ; le premier plan n'est pas lu dans ce scénario | `tests/e2e-windows/scenarios/Surfaces.ps1:52-93`, `:104-120` | vérifié |
| A21-6 | `SetForegroundWindow` sans concurrence | 0 réussite sur 5 à la première comme à la seconde tentative ; d'où le budget de 2 et le jugement par relecture | `probes/windows/FINDINGS.md:343` | vérifié |
| A24-16 | Activation d'une fenêtre d'intégrité supérieure | `focus-window` réussit : l'activation dépend du verrou de premier plan de Windows, pas du niveau d'intégrité | `probes/windows/FINDINGS.md:444` | vérifié |
| A24-5 | Fenêtre Electron minimisée puis réaffichée par `SW_SHOWNOACTIVATE` | `foreground_after_restore_not_activate: true` : la fenêtre est au premier plan après un affichage « sans activation ». La ligne ne commente pas ce champ | `probes/windows/FINDINGS.md:432`, `probes/windows/24-fixture-e2e/03-chromium-target.ps1:573-575` | vérifié |
| A29-1 | Fenêtre de l'indicateur de curseur | Avec `WS_EX_NOACTIVATE` et `SW_SHOWNOACTIVATE`, jamais au premier plan ; sans, elle le prend dès l'affichage | `probes/windows/FINDINGS.md:567` | vérifié |

Ce que le dépôt laisse ouvert sur ce point :
- Le cas « un clic sémantique ouvre un dialogue qui prend le premier plan » n'est mesuré par aucune sonde : la cible du test de non-interférence est un bouton qui change un texte (vérifié, `tests/e2e-windows/scenarios/NonInterference.ps1:23`).
- Aucune mesure d'un Invoke bloqué par un dialogue modal (déduit : aucune ligne de `FINDINGS.md` lue n'en parle).
- La concurrence pour le premier plan n'a pas pu être montée sur la machine de mesure (vérifié, `probes/windows/FINDINGS.md:343`, `crates/windows/src/system/window/window_activate.rs:17-27`).

## 3. Fenêtres Chromium et Electron recouvertes

Réponse courte : agent-desktop n'active rien et ne contourne rien. Il compte sur le fait que la première connexion UIA lance la construction de l'arbre dans Chromium, détecte un arbre « coquille » (32 nœuds ou moins) et relit jusqu'à épuisement du délai. Pour une fenêtre recouverte, il n'a aucun code : seulement un avertissement dans le guide, qui demande d'amener la cible devant ou de minimiser ce qui la couvre.

### 3.1 Activation de l'accessibilité web

| Fait | Source | Statut |
|---|---|---|
| Aucun drapeau n'est ajouté au lancement. `--force-renderer-accessibility` n'apparaît dans le code Windows que dans un message d'aide | `crates/windows/src/tree/chromium.rs:95-106` | vérifié |
| Aucun envoi explicite de `WM_GETOBJECT` ni appel MSAA : le produit appelle `ElementFromHandle` sur le HWND, et c'est UIA qui interroge la fenêtre | `crates/windows/src/tree/automation.rs:215-252` | vérifié |
| « L'activation » Windows est une attente : noter que le processus a été vu, dormir 50 ms. Le commentaire dit que la connexion UIA a déjà déclenché la construction | `crates/windows/src/system/adapter.rs:68-88` | vérifié |
| Arbre coquille : racine de classe `Chrome_WidgetWin_1`, parcours complet (non coupé par la profondeur), racine de type fenêtre, 32 nœuds visités ou moins | `crates/windows/src/tree/chromium.rs:13`, `:19`, `:50-52`, `:71-74`, `crates/windows/src/tree/observe.rs:101-104` | vérifié |
| Sur une coquille, l'adaptateur rend une erreur « activation requise » tant que le délai permet un autre parcours ; le cœur relit avec un recul de 25 ms doublé jusqu'à 400 ms | `crates/windows/src/tree/observe.rs:105-116`, `:134-136`, `crates/core/src/tree/renderer_accessibility.rs:13-14`, `:29-46` | vérifié |
| À court de délai : `ACTION_FAILED`, « The Chromium tree is still thin after its accessibility build settled », avec un détail qui nomme `--force-renderer-accessibility` et `snapshot --timeout-ms` | `crates/windows/src/tree/observe.rs:157-167`, `crates/windows/src/tree/chromium.rs:100-106` | vérifié |
| `--force-electron-a11y` ne force rien : il fait rendre l'arbre mince tel quel au lieu de l'erreur | `crates/windows/src/tree/observe.rs:106-108`, `crates/core/src/locator/live_locator/observation_request.rs:32-35` | vérifié |
| `launch --cdp` ajoute `--remote-debugging-port` et `--remote-debugging-address=127.0.0.1`, puis passe la main à un client CDP (protocole de débogage de Chrome). agent-desktop ne parle pas CDP lui-même | `crates/core/src/commands/launch.rs:28-39`, `:71-92`, `apps/docs/content/docs/guides/chromium-and-electron.mdx:7` | vérifié |

### 3.2 Recouverte, minimisée, sur un autre écran

| Fait | Source | Statut |
|---|---|---|
| Aucun traitement de l'occlusion native de Chromium (le mécanisme par lequel Chromium arrête le rendu d'une fenêtre qu'il juge entièrement recouverte) : `CalculateNativeWinOcclusion`, `disable-features` et `disable-backgrounding` sont absents de tout le dépôt ; « native-window occlusion » n'apparaît que dans les sondes, comme cause supposée | `probes/windows/FINDINGS.md:60`, `probes/windows/11-electron-activation.ps1:290`, `probes/windows/01-tree-dump.ps1:695` | vérifié |
| Aucun déplacement, redimensionnement ou bande laissée visible pour garder la cible « vue » : le produit ne déplace une fenêtre que sur commande explicite (`move-window`, `resize-window`) | `crates/windows/src/system/window/window_op.rs:64-70` | déduit |
| Le seul traitement est un texte : une fenêtre Chromium entièrement recouverte peut garder indéfiniment son nombre de nœuds de premier contact ; consigne à l'agent d'amener la cible devant ou de minimiser les fenêtres qui la couvrent | `skills/agent-desktop-windows/references/chromium-and-electron.md:40-45`, `skills/agent-desktop-windows/references/troubleshooting.md:11` | vérifié |
| La consigne « amener la cible devant » contredit le mode par défaut, qui interdit de prendre le premier plan | `skills/agent-desktop-windows/SKILL.md:53-56` | déduit |
| Arbre figé : aucune détection propre. Une coquille recouverte est traitée comme une coquille pas encore prête, donc relue jusqu'au délai, puis l'erreur « still thin » | `crates/windows/src/tree/observe.rs:105-116` | déduit |
| Un arbre figé au-dessus de 32 nœuds, ou figé après un premier chargement complet, n'est pas reconnu : le seuil est le seul critère | `crates/windows/src/tree/chromium.rs:19`, `:50-52` | déduit |
| Fenêtre minimisée (toute application) : chaque élément est marqué `offscreen` par un test `IsIconic` sur la fenêtre propriétaire, et les actions par référence échouent. Remède documenté : `restore` | `crates/windows/src/tree/minimized.rs:16-24`, `:82-87`, `crates/windows/src/tree/live_read.rs:80-82`, `:134-135`, `skills/agent-desktop-windows/SKILL.md:53-56` | vérifié |
| Autre écran : aucun code propre à Chromium. La machine de mesure n'a qu'un écran | `probes/windows/FINDINGS.md:144` | vérifié |
| Menus et dialogues Chromium : menu DOM détecté par le framework `Chrome` ; dialogue modal exposé comme surface `sheet` par `WindowIsModal` | `crates/windows/src/system/menu/menu_state_chromium.rs:1-26`, `crates/windows/src/tree/surfaces.rs:130-142` | vérifié |

### 3.3 Sondes et mesures consignées

Toutes les mesures portent sur Obsidian 1.12.7 (Chromium 142, Electron 39.8.3) ou Cursor. Edge, Chrome, VS Code, Slack et Teams sont absents de la machine de mesure (vérifié, `probes/windows/FINDINGS.md:47`, `:439`, `:519`).

| Sonde | Ce qui est mesuré | Chiffres | Source | Statut |
|---|---|---|---|---|
| A1-4, `11-electron-activation.ps1` | Arbre exposé sans drapeau, deux piles clientes | 172 nœuds stabilisés dans les 4 cas (pile × drapeau) | `probes/windows/FINDINGS.md:58` | vérifié |
| A1-5 | Premier contact | 13 nœuds contre 172, soit 13,2 fois moins. Avec le drapeau, le premier contact varie (141 et 164 relevés) | `probes/windows/FINDINGS.md:59` | vérifié |
| A1-6 | Obsidian recouvert par Notepad, Paramètres et Explorer | Reste au compte de premier contact pendant 8 s puis 16 s, trois passages de suite. Minimiser les fenêtres couvrantes le débloque. Cause non isolée : l'occlusion native de Chromium est « the obvious candidate, unproven » | `probes/windows/FINDINGS.md:60`, `probes/windows/11-electron-activation.ps1:290` | vérifié |
| A16-11 | Délai de stabilisation à froid | 12 nœuds puis 165 ; 10 à 25 s. Recouverte : « holds the shell indefinitely ». Un client neuf est nécessaire pour voir l'arbre grossi | `probes/windows/FINDINGS.md:234` | vérifié |
| A24-5 | Minimisée contre réaffichée sans activation | 9 nœuds contre 30, sans document ouvert | `probes/windows/FINDINGS.md:432` | vérifié |
| A24-11 | Contenu web réel | 262 références, arbre complet ; 6 `STALE_REF` sur 8, défaut d'identité corrigé depuis | `probes/windows/FINDINGS.md:438`, `:271` | vérifié |
| A26-13 | Nouvelle session | Arbre resté à 34 nœuds ou moins pendant 60 s malgré des relances ; attribué au risque d'occlusion de A1-6 | `probes/windows/FINDINGS.md:520` | vérifié |
| A28-3 | Troisième tentative, lecture seule | 109 nœuds dès le départ, puis à 15 s et 30 s | `probes/windows/FINDINGS.md:547` | vérifié |
| Scénario e2e Chromium | Snapshot et clic sémantique sur Obsidian | Exécuté sous le verrou `ForegroundStage`, cible devant ; délai de snapshot 15 000 ms | `tests/e2e-windows/scenarios/Chromium.ps1:27-31`, `:113-114` | vérifié |

Ce que le dépôt laisse ouvert sur ce point :
- La cause du gel sous recouvrement n'est pas établie, et aucune parade n'est essayée (vérifié, `probes/windows/FINDINGS.md:60`).
- Aucune mesure d'une action sémantique sur une fenêtre Chromium recouverte : A1-6 avertit qu'une telle mesure « may be measuring nothing » (vérifié, même ligne).
- Aucune mesure sur Chrome, Edge ou VS Code, ni sur un second écran ou un autre bureau virtuel (vérifié pour l'absence d'hôtes, `probes/windows/FINDINGS.md:144`, `:439` ; bureau virtuel : interface `IVirtualDesktopManager` abandonnée, `:232`).

## 4. Écarts relevés

Entre la note du 2026-11-11 et le code :

| Affirmation de la note | Ce que dit le code | Source | Statut |
|---|---|---|---|
| « Après l'action : relecture toutes les 50 ms pendant 400 ms au plus » | Vrai pour les actions à état seulement. Le clic n'est pas relu ; le texte tapé peut dépasser 400 ms ; l'adaptateur Windows ajoute ses propres fenêtres (jusqu'à 800 ms) avant celle du cœur | `crates/core/src/actions/post_action.rs:13-16`, `:58-69`, `crates/windows/src/actions/scroll_into_view.rs:40` | vérifié |
| « L'action n'est jamais rejouée » | `check` et `uncheck` appellent `Toggle` jusqu'à deux fois quand le premier appel a changé l'état sans atteindre la cible (case à trois états) | `crates/windows/src/actions/toggle_state.rs:185-206`, `:305-319` | vérifié |
| `press` rangé parmi les actions refusées en headless par `POLICY_DENIED` | La politique de base de `press` autorise la prise de focus ; vers une application d'arrière-plan, l'échec est `ACTION_FAILED` sans envoi, pas `POLICY_DENIED` | `crates/core/src/actions/action.rs:163-170`, `crates/windows/src/system/key_dispatch.rs:163-176` | vérifié |
| Commit `54855b62` | Le dépôt est à `2f650705`. Les lignes citées par la note qui ont été relues sont encore justes (`post_action.rs:56-57`, `chromium-and-electron.md:40-45`, `FINDINGS.md:81`, `:314`) | lecture directe | vérifié |

Entre les documents d'agent-desktop et son code :

| Document | Code | Source | Statut |
|---|---|---|---|
| Le guide dit que l'arbre grossi n'est visible qu'à une lecture neuve, pas au client qui a lancé la construction | La boucle de stabilisation relit dans le même processus avec le même client, gardé par thread | `skills/agent-desktop-windows/references/chromium-and-electron.md:22-25`, `crates/windows/src/tree/automation.rs:144-156`, `crates/core/src/tree/renderer_accessibility.rs:29-46` | vérifié |
| Conséquence : si le guide a raison, la relecture interne peut ne jamais voir l'arbre complet | aucune mesure du produit sur ce point | | déduit |
| Le guide dit que la boucle de vérification « never runs the action again » | Second `Toggle` possible, voir ci-dessus | `skills/agent-desktop-windows/references/troubleshooting.md:134-137` | vérifié |
| A23-6 juge le coût d'inventaire contre « a 200ms poll interval » | Le pas réel est 100 ms | `probes/windows/FINDINGS.md:409`, `crates/core/src/commands/wait_scheduler.rs:5` | vérifié |
| `FINDINGS.md` renvoie à `docs/phases.md` pour le contrat de chaque ligne | Le fichier est absent du dépôt | `probes/windows/FINDINGS.md:7-8` | vérifié |

## 5. Lacunes de cette recherche

- Rien n'a été exécuté : chaque comportement est lu dans le code, aucun n'est observé. Les binaires et les sondes d'agent-desktop prennent la main sur le bureau.
- Les chiffres des sondes viennent des lignes de `FINDINGS.md` ; les fichiers de capture JSON n'ont pas été rouverts pour les recouper.
- `docs/phases.md` manque : les renvois KTD, R et P2-O des sondes n'ont pas pu être suivis, ni les décisions qu'ils portent.
- Non lus en entier : `crates/windows/src/system/menu/menu_state.rs` après la ligne 140, les corps de `select.rs`, `disclosure.rs` et `scroll_into_view.rs` (constantes seulement), `crates/core/src/actionability/receives_events.rs` et `evaluate.rs`. Que le test d'occlusion soit sauté pour une livraison sémantique repose sur `requirements.rs:37-56` et sur le commentaire mesuré de `Acceptance.ps1:13-20`, pas sur une lecture de `evaluate.rs`.
- `src/batch/execution.rs` n'a été vu que par recherche (lignes 30 et 101) : le moment exact où l'inventaire de référence est pris vient du commentaire de `Surfaces.ps1:96-99`.
- L'effet réel de `SW_RESTORE` et d'un lancement par `CreateProcessW` sur le premier plan n'est pas mesuré par le dépôt pour le produit ; la section 2.3 ne décrit que les appels.
- Le comportement de `AutoSetFocus` par défaut et le blocage d'`Invoke` par un dialogue modal sont des faits Windows que ce dépôt ne mesure pas : les lignes qui en parlent sont « déduit ».
- Les adaptateurs macOS et Linux n'ont pas été lus, sauf pour constater que Linux seul implémente `subscribe_wait`.
