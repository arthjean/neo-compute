# Recherche : cohabitation en arrière-plan, cinq décisions ouvertes après EP-012

- Date : 2026-11-12
- Objet : vérifier ou corriger les cinq recommandations laissées à Arthur par la revue de EP-012 (stabilisation sur les applications XAML, issue d'audit `other`, entrée physique et garde de premier plan, langue des libellés, Chrome recouvert). Rien n'est implémenté.
- Sources : Microsoft Learn, code de WinUI 3 (`microsoft-ui-xaml`, commit `beaeb752`), code de Chromium (commit `5e720d04`, main du 2026-11-12, et point de branche de Chrome 156), code de Cua, NVDA, Playwright, Puppeteer, Electron, VS Code, Firefox, code local de neo-compute, d'agent-desktop et de Windows-MCP.
- Méthode : trois sous-agents de recherche, un par domaine de sources, briefés par des questions et sans la recommandation à vérifier. Chaque rapport marque ses lignes « vérifié » (source lue), « vérifié* » (lue par un lecteur délégué, citation non relue) ou « inféré ». Les affirmations qui portent une décision ont été relues à la source par l'agent principal (section 1).

Vocabulaire : un WinEvent est une notification d'accessibilité que Windows diffuse à tout processus qui la demande. Un événement UI Automation (UIA) n'est envoyé qu'à un client qui s'y est abonné par un objet de rappel. XAML désigne ici l'interface des applications UWP et WinUI (Calculatrice, Paramètres). L'occlusion est le fait, pour Chromium, de considérer sa fenêtre comme entièrement recouverte et d'arrêter son rendu.

## 1. Recoupements faits par l'agent principal

| Affirmation | Relue dans | Résultat |
|---|---|---|
| XAML ne lève un événement UIA que si un client UIA écoute ce type d'événement | `microsoft-ui-xaml@beaeb752:dxaml/xcp/core/core/elements/AutomationPeer.cpp:1514-1531` (`ListenerExists`, `RaiseAutomationEvent`) | confirmé |
| XAML envoie les `StructureChanged` en lot juste après la passe de rendu, si un client y est abonné, avec le commentaire « Doing it here also guarantees that the tree is not changing anymore » ; ce bloc est sous `isRenderEnabled` | `microsoft-ui-xaml@beaeb752:dxaml/xcp/core/dll/xcpcore.cpp:6748`, `:6795-6813` | confirmé |
| Chromium ne compte pas une fenêtre `WS_POPUP` comme occultante, sauf ses propres fenêtres et la barre des tâches | `chromium@5e720d04:ui/gfx/win/hwnd_util.cc:248-253` | confirmé |
| Le leurre du selftest et des sondes est une fenêtre `WS_POPUP` | `src/backend/windows/decoy_window.zig:96` | confirmé |
| Cua enveloppe l'appel UIA dans `EnableWindow(hôte, FALSE)` pour les hôtes XAML et Chromium, et tient la restauration pour bloquée sans UIAccess | `trycua/cua:libs/cua-driver/rust/crates/platform-windows/src/uia/fg_bypass.rs` (main, lu le 2026-11-12) | confirmé |
| `Invoke` doit revenir sans bloquer, « particularly critical for controls that [...] launch a modal dialog » : sinon le client reste bloqué jusqu'à la fermeture du dialogue ; côté client, « this behavior depends on the implementation » | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/nf-uiautomationcore-iinvokeprovider-invoke ; https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationinvokepattern-invoke | confirmé |

## 2. Conséquences pour les cinq décisions

1. **Stabilisation XAML.** Les WinEvents ne peuvent pas porter les changements de structure ni de nom d'une application XAML : le pont UIA vers MSAA ne traduit que le focus, la valeur, la sélection, quatre états et les menus. Le seul canal par lequel XAML signale ces changements est l'abonnement UIA, et il porte un signal de fin de passe de rendu. Reste à mesurer : son comportement sous recouvrement total, son délai, son coût, et un rappel recevant un `VARIANT` par valeur en Zig. La relecture d'arbre pour processus « muets » est l'état de l'art des outils existants (délais fixes ou relecture bornée), pas une avancée.
2. **Issue `other`.** Les schémas de journalisation lus séparent « autre » de « inconnu » et rangent la cause à côté de l'issue. `other` mêle aujourd'hui trois cas connus ou inconnus distincts.
3. **Entrée physique.** Aucun raccourci documenté ne change le premier plan par une lettre, un chiffre ou Entrée seuls ; ces touches agissent en revanche sur un dialogue qui vient de s'activer. Aucun signal ne porte la cause d'un changement de premier plan : l'attribution est une corrélation. `EVENT_SYSTEM_FOREGROUND` donne l'instant du changement, et un `Invoke` peut rester bloqué par un dialogue modal.
4. **Langue des libellés.** Aucune source externe ; aucune décision antérieure du dépôt ne fixe la langue des libellés (`docs/decisions/0011` n'en parle pas).
5. **Chrome recouvert.** La cause du constat des sondes (aucun document web sous le leurre) n'est pas l'occlusion : le leurre `WS_POPUP` n'occulte pas pour Chromium. Le montage sous-estime donc l'occlusion réelle, où une fenêtre ordinaire de l'utilisateur arrête le rendu et fige l'arbre. VS Code coupe lui-même cette détection, ce qui explique son bon résultat.

Les sections suivantes sont les trois rapports, avec leurs sources ligne par ligne.

## 3. Événements UIA et stabilisation sans pixels

Lu le 2026-11-12. Le code XAML cité est celui de WinUI 3 (dépôt microsoft-ui-xaml, commit beaeb752) ; le XAML système de la Calculatrice et des Paramètres n'est pas public.

### Résumé

1. XAML ne lève un événement UIA que pour un type auquel un client UIA s'est abonné. Un hook WinEvent ne reçoit que ce que le pont UIA vers MSAA traduit : focus, valeur, sélection, quatre états, menus. Ni structure, ni nom.
2. Un abonnement UIA exige un objet COM côté client : `IUnknown` et une méthode `Handle*` par interface, depuis un thread MTA (appartement COM multithread), avec des rappels sur des threads non UI.
3. Dans WinUI 3, `StructureChanged` part après la passe de rendu et le changement de `Name` pendant la mise en page. La Calculatrice annonce son affichage par une notification. Délai et comportement d'une fenêtre recouverte : non documentés.
4. Aucune API documentée ne dit qu'un thread UI tiers a fini : `WaitForInputIdle` ne sert qu'une fois, `WM_NULL` prouve seulement que la file de messages tourne, ETW demande des droits de session.
5. Aucun outil établi ne détecte la stabilité d'un arbre : délais fixes, relecture bornée d'une postcondition, attentes explicites.

### 1. Pourquoi XAML se tait côté WinEvents

| Fait | Source | Statut |
|---|---|---|
| `UIAClientsAreListening(event)` exige `UiaClientsAreListening()` et un compteur non nul pour cet événement | https://github.com/microsoft/microsoft-ui-xaml/blob/beaeb752d7e51f5ae1621a530dab7f8f4d66ebcd/dxaml/xcp/win/shared/UIAWindow.cpp#L1569-L1683 | vérifié |
| Les compteurs montent dans `AdviseEventAdded`, appelé quand un client commence à écouter | même fichier `#L1271-L1322` ; https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/nn-uiautomationcore-irawelementprovideradviseevents | vérifié |
| Sans écouteur, `RaiseAutomationEvent` ne fait rien et `Button::OnClick` ne crée pas le peer | https://github.com/microsoft/microsoft-ui-xaml/blob/beaeb752d7e51f5ae1621a530dab7f8f4d66ebcd/dxaml/xcp/core/core/elements/AutomationPeer.cpp#L1514-L1531 ; `dxaml/xcp/dxaml/lib/Button_Partial.cpp#L73-L81` | vérifié |
| `UiaClientsAreListening` : « TRUE if a client has subscribed to events ». Rien sur les hooks WinEvent | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcoreapi/nf-uiautomationcoreapi-uiaclientsarelistening | vérifié |
| Le pont traduit focus, `ValueProperty` (`EVENT_OBJECT_VALUECHANGE`), sélection, menus, `STATECHANGE` pour CHECKED, UNAVAILABLE, COLLAPSED, EXPANDED. Aucune ligne structure ou nom | https://learn.microsoft.com/en-us/windows/win32/winauto/appendix-g--active-accessibility-bridge-to-ui-automation | vérifié |
| Les événements du pont portent `idObject > 0` sur un HWND à fournisseur UIA | https://source.dot.net/UIAutomationClient/MS/Internal/Automation/WinEventWrap.cs.html | vérifié |
| Le système génère les WinEvents des contrôles à HWND ; les éléments XAML n'en ont pas | https://learn.microsoft.com/en-us/windows/win32/winauto/what-are-winevents | vérifié, seconde moitié inférée |
| Mesure : Paramètres `SetValue` donne 0x800E en 3 à 7 ms ; Invoke seulement 0x8001 (DESTROY, sans doute un HWND) après 236 à 292 ms ; Calculatrice rien | `docs/decisions/0013-events-probe-run.txt:45`, `:66-67` | vérifié, lecture inférée |

### 2. Abonnement UIA côté client

| Fait | Source | Statut |
|---|---|---|
| `AddAutomationEventHandler(eventId, element, scope, cacheRequest, handler)` : un événement par appel | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation-addautomationeventhandler | vérifié |
| `HandleStructureChangedEvent(sender, changeType, runtimeId)` ; `runtimeId` seulement pour `ChildRemoved` | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationstructurechangedeventhandler-handlestructurechangedevent | vérifié |
| `HandlePropertyChangedEvent(sender, propertyId, VARIANT newValue)` : `VARIANT` par valeur ; propriétés listées à l'abonnement | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationpropertychangedeventhandler-handlepropertychangedevent | vérifié |
| Focus : global, sans portée. Notification : `IUIAutomation5`, Windows 10 1709 | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation-addfocuschangedeventhandler ; https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation5-addnotificationeventhandler | vérifié |
| `IUIAutomation6` (1809) : groupes de gestionnaires recommandés ; `CoalesceEvents` et `ConnectionRecoveryBehavior` désactivés par défaut ; retrait de groupe asynchrone | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nn-uiautomationclient-iuiautomation6 ; https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation6-addeventhandlergroup ; https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation6-get_coalesceevents | vérifié |
| Portée descendants : un seul gestionnaire à la racine. Tous les changements ne lèvent pas d'événement (proxys Win32) | https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-eventsforclients | vérifié |
| Thread MTA sans fenêtre ; rappel « always called on a non-UI thread » ; STA peut empêcher le retrait ; ajout et retrait depuis un seul thread | https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading | vérifié |
| Modifier un gestionnaire depuis son rappel : non supporté. Un événement peut arriver après le retrait : objet à garder jusqu'au compteur zéro | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation-removealleventhandlers | vérifié |
| Certains événements partent sans changement d'état | https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-eventsoverview | vérifié |
| Exemple Microsoft : `QueryInterface` (IUnknown et l'interface), `AddRef`/`Release` atomiques, `Handle*`. Ni `IAgileObject` ni `IMarshal` ; NVDA idem en C++ | https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-howto-implement-event-handlers ; https://github.com/nvaccess/nvda/blob/af55fb6b6485f08757733aa7cd1d6f30e8a19563/nvdaHelper/local/UIAEventLimiter/rateLimitedEventHandler.cpp#L184-L212 | vérifié, « non requis » inféré |
| NVDA : thread MTA dédié, coalescence activée, file sur un thread séparé pour ne jamais bloquer UIA, aucun abonnement `StructureChanged` | https://github.com/nvaccess/nvda/blob/af55fb6b6485f08757733aa7cd1d6f30e8a19563/source/UIAHandler/__init__.py#L493-L638 | vérifié |
| NVDA : enregistrement global, « performance is significantly degraded » ; des WinEvents convertis peuvent figer la bibliothèque cliente | https://github.com/nvaccess/nvda/blob/af55fb6b6485f08757733aa7cd1d6f30e8a19563/user_docs/en/userGuide.md#L4229-L4234 ; `__init__.py#L502-L503` | vérifié |
| S'abonner change le fournisseur : XAML compare `Name` à chaque mise en page et enregistre chaque entrée ou sortie d'élément | https://github.com/microsoft/microsoft-ui-xaml/blob/beaeb752d7e51f5ae1621a530dab7f8f4d66ebcd/dxaml/xcp/core/core/elements/uielement.cpp#L5427-L5437 ; `dxaml/xcp/core/hw/hwwalk.cpp#L1437-L1443` | vérifié |
| Local : client déjà MTA sur `CUIAutomation8` ; objets COM clients exclus ; un défaut COM compte pour la condition 3 | `src/backend/windows/uia.zig:243`, `:357` ; `tasks/prd-background-mode.md:114` ; `docs/decisions/0001-zig-vs-rust.md:56` | vérifié |

### 3. Couverture des trous mesurés

| Fait | Source | Statut |
|---|---|---|
| Structure : levée en lot juste après la passe de rendu, si abonné (« guarantees that the tree is not changing anymore ») | https://github.com/microsoft/microsoft-ui-xaml/blob/beaeb752d7e51f5ae1621a530dab7f8f4d66ebcd/dxaml/xcp/core/dll/xcpcore.cpp#L6795-L6813 | vérifié |
| Ce bloc exige le rendu actif, lié à la visibilité XAML. Effet d'un recouvrement total : non établi | même fichier `#L6748`, `#L9801` ; `dxaml/xcp/core/inc/corep.h#L1487` | vérifié, à sonder |
| Plus de 20 changements sous un parent : un seul `ChildrenInvalidated`. Réordonnancement jamais signalé | https://github.com/microsoft/microsoft-ui-xaml/blob/beaeb752d7e51f5ae1621a530dab7f8f4d66ebcd/dxaml/xcp/core/core/elements/AutomationEventsHelper.cpp#L107-L120 ; `#L195-L198` ; `dxaml/xcp/core/inc/AutomationEventsHelper.h#L6-L12` | vérifié |
| `Name`, `IsEnabled`, `IsOffscreen`, `ItemStatus` : levés pendant `UpdateLayout` si abonné ; le premier passage mémorise sans lever | `AutomationPeer.cpp#L1774-L1843` ; `dxaml/xcp/core/layout/LayoutManager.cpp#L259` | vérifié |
| Calculatrice : affichage annoncé par `RaiseNotificationEvent` | https://github.com/microsoft/calculator/blob/79e1ac53bba690cdf930e5dcd6ed9dbc4cbfb128/src/Calculator.ViewModels/Common/Automation/NarratorNotifier.cs#L59 | vérifié |
| WinUI 3 1.7.3 ne livrait aucun `PropertyChanged(Name)` ; corrigé en 1.8.0 | https://github.com/microsoft/microsoft-ui-xaml/issues/10645 | attesté, secondaire |
| Aucun identifiant d'événement ne signifie « changements terminés » ; aucun délai documenté | https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-event-ids | vérifié |

### 4. Autres signaux sans pixels

| Fait | Source | Statut |
|---|---|---|
| `WaitForInputIdle` : « waits only once » ; les appels suivants reviennent aussitôt | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-waitforinputidle | vérifié |
| `SendMessageTimeout(WM_NULL)` revient quand la procédure de fenêtre a traité le message : la file tourne, rien de plus | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessagetimeoutw | vérifié, limite inférée |
| `IsHungAppWindow` : seuil de 5 s, « not intended for general use » | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-ishungappwindow | vérifié |
| `GetGUIThreadInfo` : fenêtres active, focus, capture, caret ; aucun indicateur d'occupation | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo | vérifié |
| `BuildUpdatedCache` : nouvel élément au cache rafraîchi, coût non documenté ; relecture locale : 276 ms | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-buildupdatedcache ; `docs/decisions/0013-mode-arriere-plan.md:139` | vérifié |
| ETW : fournisseurs `Microsoft-Windows-UIAutomationCore` et `Microsoft-Windows-XAML` présents (`logman query providers`) ; session réservée aux administrateurs et à Performance Log Users | https://learn.microsoft.com/en-us/windows/win32/api/evntrace/nf-evntrace-starttracew | vérifié |
| `DwmFlush` ne concerne que les changements de l'appelant | https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmflush | vérifié |

### 5. Ce que font les outils établis

| Fait | Source | Statut |
|---|---|---|
| WinAppDriver : code fermé ; la FAQ prescrit `Thread.Sleep` | https://github.com/microsoft/WinAppDriver/blob/09e3f7111eb2fae2b4eff0ab058cc7a5dbc14d02/Docs/FAQ.md#L103 | vérifié |
| FlaUI : pause fixe de 100 ms ; `UntilResponsive` = `WM_NULL` puis 20 ms | https://github.com/FlaUI/FlaUI/blob/fd7cc64ab01908a0ae4cc7d05e704caa34f98d16/src/FlaUI.Core/Input/Wait.cs#L19-L25 | vérifié |
| pywinauto : `invoke()` attend `after_invoke_wait` (0,1 s) ; `WaitForInputIdle` retiré (« useful only while an app is starting ») | https://github.com/pywinauto/pywinauto/blob/46b1b0ae8b6cc1a5cb066ada7f88e44677231a47/pywinauto/controls/uiawrapper.py#L542-L558 ; `pywinauto/windows/win32functions.py#L852-L855` | vérifié |
| Playwright : stable = même boîte englobante sur deux images d'animation, vérifié avant l'action | https://playwright.dev/docs/actionability | vérifié |
| UFO : règle le délai pywinauto (0 par défaut), sonde `is_enabled` toutes les 0,5 s | https://github.com/microsoft/UFO/blob/eae3c0a8d168c47cb10df0652e293e092eda1078/ufo/automator/ui_control/controller.py#L31-L40 ; `#L395-L403` | vérifié |
| Power Automate : action explicite « Wait for window content » ; mode simulé limité sur XAML ; aucune stabilisation automatique décrite | https://learn.microsoft.com/en-us/power-automate/desktop-flows/actions-reference/uiautomation | vérifié |
| agent-desktop : relit l'élément toutes les 50 ms, 400 ms au plus, jusqu'à la postcondition ; aucun événement | `C:\dev\agent-desktop\crates\core\src\actions\post_action.rs:56-74` | vérifié |
| Windows-MCP : outil d'attente et pauses fixes | `C:\dev\Windows-MCP\src\windows_mcp\tools\input.py:428` | vérifié |
| Aucun de ces outils n'a de voie propre à XAML | lignes ci-dessus | inféré |

### Ce qui reste à mesurer

- Calculatrice et Paramètres recouverts, client abonné : quels événements arrivent (`Notification`, `PropertyChanged(Name)`, `StructureChanged`), avec quel délai et quel taux.
- La passe de rendu XAML tourne-t-elle sous recouvrement total ?
- Le 0x800E des Paramètres vient-il du pont seul ou d'un autre client UIA abonné sur la machine ?
- Équivalence entre le XAML système et le code WinUI 3 lu.
- Ajout et retrait d'un gestionnaire face à un fournisseur figé : durée, blocage.
- Volume d'événements et coût CPU imposé à l'application.
- En Zig : rappel recevant un `VARIANT` par valeur sur un thread UIA.
- Identité des événements 0x11E à 0x120 des Paramètres.

### Contradictions trouvées

- `0013-mode-arriere-plan.md:119` écrit que rien ne passe par les WinEvents pour XAML ; la même sonde montre 0x800E pour les Paramètres, conforme à l'annexe G.
- Learn fait correspondre `EVENT_OBJECT_CREATE` et `StructureChanged` (https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-msaa), mais l'annexe G ne traduit aucun événement de structure.
- Learn situe le passage aux événements groupés entre deux et cinq enfants (https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/ne-uiautomationcore-structurechangetype) ; XAML le fixe à 20.
- Le code lève `Name` automatiquement, l'issue 10645 montre une version qui ne le livrait pas.

## 4. Premier plan, attribution, prévention, restauration

### Résumé

1. Aucun signal documenté ne porte la cause d'un changement de premier plan : l'attribution reste une corrélation entre `EVENT_SYSTEM_FOREGROUND` et les hooks bas niveau, avec des ambiguïtés.
2. Aucun raccourci documenté ne change de fenêtre par une lettre, un chiffre ou Entrée seuls ; ces touches agissent en revanche sur un dialogue fraîchement activé.
3. Les règles du verrou sont documentées, sauf deux points : le sens de « last input event » et le franchissement du verrou par UIA (`AutoSetFocus`), seulement mesuré.
4. Prévention sans élévation ni injection : rien de documenté ne vise un processus tiers ; `WH_CBT` exige une DLL ; Cua mesure un bouclier `EnableWindow` non documenté.
5. La restauration retenue repose sur la file d'entrée du premier plan ; ses risques documentés sont ceux d'`AttachThreadInput` ; un seul outil comparable (Cua) restaure.

Statut : « vérifié » = lu par moi ; « vérifié* » = lu par un lecteur délégué, citation non relue ; « inféré ».

### 1. Gestes de l'utilisateur

| Fait | Source | Statut |
|---|---|---|
| Clic dans une fenêtre inactive : `WM_MOUSEACTIVATE` ; la fenêtre peut refuser (`MA_NOACTIVATE`) | https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mouseactivate | vérifié |
| Changements « du système » cités : touche ALT, clic sur une fenêtre d'arrière-plan | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-locksetforegroundwindow | vérifié |
| Raccourcis listés : Alt+Tab, Alt+Esc, Ctrl+Alt+Tab, Win, Ctrl+Esc, Win+chiffre, Win+Tab, Win+T/B/D/M/Home/Bas, Win+Ctrl+flèches, Win+A/N/S/E/R/X/V, Alt+F4, Ctrl+Shift+Esc. Aucun n'emploie une lettre, un chiffre ou Entrée seuls ; Alt+Shift+Esc absent | https://support.microsoft.com/en-us/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec | vérifié* |
| Une touche enregistrée par `RegisterHotKey` donne le droit de premier plan à son application | https://devblogs.microsoft.com/oldnewthing/20090226-00/?p=19013 (commentaire Microsoft) | vérifié |
| Minimiser ou fermer la fenêtre active fait monter une autre fenêtre | https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles | vérifié |
| Suivi de fenêtre active : un mouvement de souris seul active la fenêtre survolée | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow | vérifié |
| Tactile et stylet produisent des messages souris (signature `0xFF515700`) ; leur passage par `WH_MOUSE_LL` n'est pas documenté | https://learn.microsoft.com/en-us/windows/win32/tablet/system-events-and-mouse-messages | vérifié |
| Frappe ordinaire : effet indirect seulement (l'application active ouvre une fenêtre ou lance un processus) | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow | inféré |
| Dialogue : ENTER envoie `WM_COMMAND` (IDOK ou bouton par défaut), ESC `IDCANCEL`, un mnémonique seul clique un bouton, ESPACE pousse le bouton focalisé | https://learn.microsoft.com/en-us/windows/win32/dlgbox/dlgbox-programming-considerations | vérifié* |

### 2. Verrou de premier plan

| Fait | Source | Statut |
|---|---|---|
| Conditions : aucun menu actif, pas de verrou posé, puis l'une de : délai expiré, appelant au premier plan, lancé par lui, aucune fenêtre de premier plan, dernière entrée reçue, débogage ; refus possible malgré tout ; sinon clignotement | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow | vérifié |
| `AllowSetForegroundWindow` : l'appelant doit avoir le droit ; perdu à la prochaine entrée non destinée au bénéficiaire | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-allowsetforegroundwindow | vérifié |
| Délai « following user input » ; ici 200000 ms et 7 clignotements (`HKCU\Control Panel\Desktop`, lu le 2026-11-12) | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow | vérifié |
| « Last input event » non défini sur Learn ; un message qui n'est pas une entrée ne donne aucun droit, lancer un programme le donne | https://devblogs.microsoft.com/oldnewthing/20090220-00/?p=19083 | vérifié |
| Le droit appartient à la file d'entrée de premier plan ; l'activation est asynchrone | https://devblogs.microsoft.com/oldnewthing/20161118-00/?p=94745 | vérifié |
| `AutoSetFocus` : « set focus to the element » avant l'action ; rien sur le verrou. Mesuré : franchit le verrou | https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation2-put_autosetfocus ; `docs/decisions/0013-mode-arriere-plan.md:50` | vérifié |
| Dialogue ouvert par Invoke, `AutoSetFocus` coupé : aucune règle documentée ne lie un appel UIA à un droit ; le montage local le donne explicitement | `docs/decisions/0013-mode-arriere-plan.md:144` | inféré |
| Cua mesure un `SetForegroundWindow(self)` des hôtes XAML et Chromium pendant Invoke | https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-windows/src/uia/fg_bypass.rs | vérifié |

### 3. Signaux d'attribution

| Fait | Source | Statut |
|---|---|---|
| `EVENT_SYSTEM_FOREGROUND` : `hwnd` = nouvelle fenêtre ; aucun champ de cause | https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants | vérifié |
| `idEventThread` : description vide ; `dwmsEventTime` : heure de génération | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nc-winuser-wineventproc | vérifié |
| Hors contexte : file, asynchrone, ordre garanti, délai non chiffré | https://learn.microsoft.com/en-us/windows/win32/winauto/out-of-context-hook-functions | vérifié |
| `SWITCHSTART/END` : Alt+Tab pressé puis relâché, `hwnd` visé ; `OBJECT_FOCUS`, `MINIMIZEEND` : aucune cause | https://learn.microsoft.com/en-us/windows/win32/winauto/event-constants | vérifié |
| `HSHELL_WINDOWACTIVATED` : fenêtres sans propriétaire seulement (un dialogue possédé y échappe) ; `RUDEAPPACTIVATED` non décrit ; API « not intended for general use » | https://learn.microsoft.com/en-us/windows/win32/winmsg/shellproc ; https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-registershellhookwindow | vérifié |
| `GetLastInputInfo` : tick de la session, `SendInput` compris ; ni périphérique ni cible | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getlastinputinfo | vérifié |
| `GetGUIThreadInfo(0)` : fenêtres active, focus, capture, menu du thread de premier plan | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo | vérifié |
| Hook bas niveau : appelé avant le dépôt en file ; `pt` écran ; drapeau `INJECTED` ; retiré sans avis après dépassement (1000 ms au plus) | https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelmouseproc | vérifié |
| `WindowFromPoint` ignore les fenêtres cachées ou désactivées | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-windowfrompoint | vérifié |
| « Activation par clic » : `CBTACTIVATESTRUCT.fMouse`, `WA_CLICKACTIVE`, visibles dans le processus de la fenêtre seulement | https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-cbtactivatestruct | vérifié |
| `RIDEV_INPUTSINK` : entrée reçue hors premier plan, `hDevice` par périphérique ; ni cible ni drapeau d'injection | https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-rawinputdevice | vérifié |
| Combinaison : clic non injecté dont la fenêtre sous le point est X, ou Alt/Win enfoncé, daté avant l'événement = utilisateur ; aucune entrée = programme. Ambiguïtés : frappe sans rapport simultanée, clic sur la barre des tâches, raccourci enregistré, lancement au clavier, tactile, hook retiré | lignes ci-dessus | inféré |

### 4. Prévention

| Fait | Source | Statut |
|---|---|---|
| `LockSetForegroundWindow` : réservé au processus de premier plan ; levé par ALT ou un clic | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-locksetforegroundwindow | vérifié |
| Job : aucun `JOB_OBJECT_UILIMIT_*` ne vise l'activation ; `HANDLES` coupe handles USER, diffusions et hooks hors job | https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-jobobject_basic_ui_restrictions | vérifié |
| Autre bureau : un seul reçoit l'entrée ; messages et hooks limités au même bureau ; UIA entre bureaux non documenté | https://learn.microsoft.com/en-us/windows/win32/winstation/desktops | vérifié |
| Session enfant ou bureau virtuel (préversion) : Power Automate ; droits administrateur pour l'activer | https://learn.microsoft.com/en-us/power-automate/desktop-flows/run-desktop-flows-pip | vérifié |
| `WS_EX_NOACTIVATE` posé de l'extérieur (refusé seulement vers un niveau UIPI supérieur) : bloque le clic, pas `SetForegroundWindow` | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowlongptrw | vérifié |
| `DWMWA_CLOAK` : invisible, toujours composée ; effet sur l'activation non documenté | https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute | vérifié |
| `SPI_SETFOREGROUNDLOCKTIMEOUT` échoue si l'appelant ne peut pas changer le premier plan | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfow | vérifié |
| `WH_CBT` : retour 1 sur `HCBT_ACTIVATE` empêche l'activation, mais hors de son processus le hook doit être dans une DLL injectée | https://learn.microsoft.com/en-us/windows/win32/winmsg/cbtproc ; https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowshookexw | vérifié |
| `EnableWindow(hôte, FALSE)` autour de l'appel UIA : 0 vol sur 507 (XAML), sans effet sur WPF ; la fenêtre refuse alors l'entrée | https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-windows/src/uia/fg_bypass.rs | vérifié |

### 5. Restauration

| Fait | Source | Statut |
|---|---|---|
| `AttachThreadInput` : partage focus et état clavier, remet l'état des touches à zéro, interdit entre bureaux | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-attachthreadinput | vérifié |
| File partagée : `SetForegroundWindow` attend que l'ancienne fenêtre traite `WM_ACTIVATE` ; blocage si son thread ne pompe plus | https://devblogs.microsoft.com/oldnewthing/20130607-00/?p=4143 | vérifié |
| `SetActiveWindow` exige la file de l'appelant ; premier plan seulement si « its application is in the foreground » | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setactivewindow | vérifié |
| `BringWindowToTop` active une fenêtre de premier niveau ; rien sur le premier plan | https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-bringwindowtotop | vérifié |
| `SwitchToThisWindow` : « not intended for general use » ; aucun contournement des règles | https://devblogs.microsoft.com/oldnewthing/20111107-00/?p=9183 | vérifié* |
| UIA `SetFocus` : « Sets the keyboard focus » ; sans effet mesuré sur une fenêtre de premier niveau | `docs/decisions/0013-mode-arriere-plan.md:150` | vérifié |
| Local : `SetForegroundWindow` refusé 20/20 même attaché ; voie retenue 100/100, 8,8 ms au plus | `docs/decisions/0013-mode-arriere-plan.md:149` ; `src/backend/windows/window.zig:234` | vérifié |
| Voie non injectée plus directe : aucune trouvée | pages ci-dessus | inféré |

### 6. Systèmes comparables

| Fait | Source | Statut |
|---|---|---|
| agent-desktop : `SetForegroundWindow`, deux essais, aucune restauration ; `allow_focus_steal: false` hors mode headed | `C:\dev\agent-desktop\crates\windows\src\system\window\window_activate.rs:28` ; `C:\dev\agent-desktop\crates\core\src\actions\interaction_policy.rs:12` | vérifié |
| Windows-MCP : attache aux deux threads, `AllowSetForegroundWindow(-1)`, aucune restauration | `C:\dev\Windows-MCP\src\windows_mcp\desktop\service.py:664` | vérifié |
| Cua : bouclier `EnableWindow` ; échelon « foreground » avec restauration ; dit la restauration bloquée sans UIAccess | https://github.com/trycua/cua/blob/main/libs/cua-driver/rust/crates/platform-windows/src/uia/fg_bypass.rs | vérifié |
| UFO : `set_focus()` avant l'action, aucune restauration | https://github.com/microsoft/UFO/blob/main/ufo/automator/ui_control/controller.py | vérifié* |
| WinAppDriver : la FAQ ne traite pas le premier plan ; demandes d'utilisateurs seulement (attesté, secondaire) | https://github.com/microsoft/WinAppDriver/blob/master/Docs/FAQ.md | vérifié |

### 7. Taxonomie d'audit

Les sources gardent un champ d'issue grossier et un champ de cause séparé ; elles divergent sur la valeur fourre-tout. SP 800-92 n'a pas pu être lu.

| Fait | Source | Statut |
|---|---|---|
| « Result status » (Success, Fail, Defer) et « Reason » séparés | https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html | vérifié* |
| AU-3 : « Outcome of the event », succès ou échec et résultats propres à l'événement ; aucune valeur fourre-tout (miroir secondaire de SP 800-53) | https://csf.tools/reference/nist-sp-800-53/r5/au/au-3/ | vérifié* |
| `error.type` : valeur de repli `_OTHER`, valeurs propres permises | https://opentelemetry.io/docs/specs/semconv/attributes-registry/error/ | vérifié* |
| `0 Unknown`, `99 Other`, valeur d'origine dans un champ voisin | https://schema.ocsf.io/1.3.0/classes/authentication | vérifié* |
| `unknown` réservé au résultat inconnu ; `event.reason` séparé | https://www.elastic.co/docs/reference/ecs/ecs-event | vérifié* |
| Événement 4625 : Status, Sub Status, Failure Reason, une valeur par cause | https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/auditing/event-4625 | vérifié* |

### Ce qui reste à mesurer

- Sens de `idEventThread` et délai réel de `EVENT_SYSTEM_FOREGROUND` sur le build 26300.
- `SWITCHSTART/END` avec l'Alt+Tab de Windows 11 ; `hwnd` reçu lors d'un clic sur la barre des tâches.
- Tactile et stylet vus ou non par `WH_MOUSE_LL`.
- Règle qui laisse passer un dialogue après Invoke hors montage, notamment après 200 s sans entrée.
- Bouclier `EnableWindow` reproduit ici ; touche tenue par l'utilisateur pendant `restoreForeground`.

### Contradictions trouvées

- Chen 2016 et `service.py:664` (un thread attaché obtient le droit) contre la mesure locale : refus 20/20.
- Cua (restauration bloquée sans UIAccess) contre la mesure locale : 100/100 sans UIAccess.
- Cua attribue le vol à l'hôte XAML ; la mesure locale à `AutoSetFocus` (0/5 une fois coupé, `0013:57`).
- `WS_EX_NOACTIVATE` : « should not be activated through programmatic access », puis « use SetActiveWindow or SetForegroundWindow ».

## 5. Chromium recouvert et arbre d'accessibilité

### Résumé

1. Une page dont le WebContents est OCCLUDED ou HIDDEN a un compositeur invisible : plus de BeginMainFrame, or l'arbre d'accessibilité se construit et se sérialise dans cette étape. Attendre ne change rien ; seuls une action ou un hit test forcent une sérialisation.
2. Le leurre local est une fenêtre `WS_POPUP`, que le traqueur d'occlusion de Chromium (156 et main) ne compte pas comme occultante : la cause du constat US-040/US-047 n'est pas établie par les sources, elle reste à mesurer.
3. L'accessibilité web s'allume à la demande, sur une requête UIA de propriété (Name, ControlType...) visant un noeud web. Fournisseur UIA natif par défaut depuis Chrome 138, pas d'extinction automatique par défaut, aucun mode envoyé à une fenêtre minimisée.
4. Seul levier pris en charge : la stratégie `WindowOcclusionEnabled` (Chrome 90+, Edge 89+). `--disable-backgrounding-occluded-windows` est nommé « ForTesting » mais passé par Playwright, Puppeteer et chromedriver. `--force-renderer-accessibility` ne lève pas l'occlusion.
5. VS Code désactive `CalculateNativeWinOcclusion` au démarrage, ce qui le distingue de Chrome ; Electron seul garde le défaut de Chromium. Firefox a son propre traqueur, effet sur l'arbre inféré (ralenti, pas arrêté).

### Références

- `CR:` chromium/src, commit `5e720d04` (main, 160.0.8159.0, 2026-11-12), lu par le miroir GitHub au même SHA. URL : `https://chromium.googlesource.com/chromium/src/+/5e720d048e1d38a8fde57f9b9bad8cfe58372afd/<chemin>`. « M156 » : ligne relue au point de branche de Chrome 156 (`c50edc42`, 2026-09-29).
- `EL:` electron@295785f, `VS:` vscode@35cffba, `PW:` playwright@6d772de, `PP:` puppeteer@70669de, `FF:` firefox main `5fb56bef` (github.com, 2026-11-12).
- `NC:` `C:\dev\neo-compute`, `AD:` `C:\dev\agent-desktop`. V = vérifié, I = inféré.

### 1. Occlusion native

| Fait | Source | |
|---|---|---|
| `CalculateNativeWinOcclusion` activé par défaut, inactif avec `--headless` | `CR:ui/base/ui_base_features.cc:40`, `CR:ui/aura/window_tree_host.cc:488-494` (M156) | V |
| Région de départ = écran virtuel ; fenêtres parcourues du haut vers le bas, chaque occultante soustraite ; fenêtre Chromium OCCLUDED si soustraire son `GetWindowRect` ne change rien | `CR:ui/aura/native_window_occlusion_tracker_win.cc:462-467,731-753` | V |
| Occultante : visible, non minimisée, sans `WS_EX_TRANSPARENT`, sans `WS_EX_TOOLWINDOW`, `WS_EX_LAYERED` seulement si opaque sans colorkey, région rectangulaire, non « cloaked », et non `WS_POPUP` (sauf classes `Chrome_WidgetWin_*`, `Shell_TrayWnd`). Le processus ne compte pas | `CR:ui/gfx/win/hwnd_util.cc:167-256` (M156 : 126-210) | V |
| Minimisée : HIDDEN. Autre bureau virtuel, écran verrouillé ou éteint : OCCLUDED | même traqueur `:479-485,226-227` | V |
| Recalcul 16 ms après un WinEvent (FOREGROUND, SHOW/HIDE, MOVESIZE, STATECHANGE, CLOAKED, LOCATIONCHANGE) ; pas de REORDER ; événements des popups ignorés | même traqueur `:35,619-652,815-822` | V |
| OCCLUDED : page `kHidden` (sauf capture, picture-in-picture), widget masqué, compositeur du renderer invisible, `Chrome_RenderWidgetHostHWND` reparenté sous une fenêtre cachée ; doc : « rendering stops, and js is throttled » | `CR:content/browser/web_contents/web_contents_impl.cc:5304-5327`, `CR:content/browser/renderer_host/render_widget_host_view_aura.cc:788-836` (M156), `CR:third_party/blink/renderer/platform/widget/widget_base.cc:1612-1632`, `CR:docs/windows_native_window_occlusion_tracking.md:8-9` | V |
| Un WebContents jamais devenu visible n'est pas basculé en OCCLUDED, et `WasShown` n'est pas appelé | `web_contents_impl.cc:12905-12922` (M156) | V |

### 2. Arbre d'une page masquée

| Fait | Source | |
|---|---|---|
| Mise à jour et sérialisation AX tournent dans `RunPostLifecycleSteps`, appelé par `DidBeginMainFrame` | `CR:third_party/blink/renderer/core/frame/local_frame_view.cc:1109-1120,3341-3393` (M156) | V |
| `ScheduleAXUpdate` ne fait que demander une mise à jour visuelle | `CR:third_party/blink/renderer/modules/accessibility/ax_object_cache_impl.cc:4266-4287` (M156) | V |
| Aucun BeginMainFrame si le compositeur est invisible | `CR:cc/scheduler/scheduler_state_machine.cc:486-488` (M156) | V |
| Page masquée : ni arbre initial ni mise à jour | `scheduler_state_machine.cc:486-488` | I |
| `PerformAction` et `HitTest` appellent `UpdateAXForAllDocuments`, qui valide et sérialise sans frame ; l'effet de l'action repasse par `ScheduleAXUpdate` | `CR:content/renderer/accessibility/render_accessibility_impl.cc:240,323-340` (M156), `ax_object_cache_impl.cc:1057-1076` | V, suite I |
| Incertain : aucun autre chemin lu ne pousse l'arbre sans frame, lecture non exhaustive | `ax_object_cache_impl.cc:3472-3580` | I |

### 3. Activation

| Fait | Source | |
|---|---|---|
| `kNativeAPIs`, `kWebContents`, `kInlineTextBoxes`, `kExtendedProperties`, `kScreenReader` ; « basic » = les deux premiers | `CR:ui/accessibility/ax_mode.h:39-103,238-252` | V |
| `WM_GETOBJECT` `UiaRootObjectId` rend le fournisseur par `UiaReturnRawElementProvider` ; la racine n'allume que `kNativeAPIs` | `CR:ui/views/win/hwnd_message_handler.cc:2332-2352`, `CR:ui/accessibility/platform/ax_fragment_root_win.cc:355-363` | V |
| Le web s'allume quand `GetPropertyValue` vise un noeud web avec Name, ControlType, AutomationId, IsOffscreen... (pas BoundingRectangle, RuntimeId, IsEnabled) | `CR:ui/accessibility/platform/ax_platform_node_win.cc:8928-9040` | V |
| MSAA : leurre `EVENT_SYSTEM_ALERT`, sans effet tant que le nom n'est pas lu | `CR:content/browser/renderer_host/legacy_render_widget_host_win.cc:301-319`, `CR:ui/accessibility/platform/ax_platform.cc:201-232` | V |
| Fournisseur UIA actif par défaut ; depuis Chrome 138 pour les navigateurs Chromium (billet du 2025-08-14) ; stratégie `UiAutomationProviderEnabled` 125 à 146. Edge : aucune source Microsoft trouvée | `CR:ui/accessibility/platform/ax_platform.h:250` (M156), https://developer.chrome.com/blog/windows-uia-support-update | V |
| Mode non envoyé à un WebContents HIDDEN, envoyé à un OCCLUDED | `CR:content/browser/accessibility/browser_accessibility_state_impl.cc:586-592,699-702` (M156) | V |
| Extinction 5 min après masquage : `ProgressiveAccessibilityPhase2`, désactivé par défaut | même fichier `:294-295,622-661`, `CR:content/common/features.cc:682-685` | V |
| Délai sur Chrome visible : 10 à 30 ms. Obsidian : 13 noeuds puis 172, 10 à 25 s à froid | `NC:src/backend/windows/uia.zig:954-955`, `AD:skills/agent-desktop-windows/references/chromium-and-electron.md:16-18` | V |

### 4. Commutateurs et stratégies

| Fait | Source | |
|---|---|---|
| `--force-renderer-accessibility` (valeurs `basic`, `form-controls`, `complete`, `screen-reader`, `on-screen`) : mode initial, figé si une valeur est donnée. Sans effet sur l'occlusion | `browser_accessibility_state_impl.cc:323-357` | V |
| `--disable-backgrounding-occluded-windows` : OCCLUDED traité comme VISIBLE ; constante `...ForTesting` | `web_contents_impl.cc:12895-12903` (M156), `CR:content/public/common/content_switches.cc:90-93` | V |
| `--disable-features=CalculateNativeWinOcclusion` : pas de suivi natif ; drapeau interne, non documenté | `window_tree_host.cc:488-494` | V |
| `--disable-renderer-backgrounding` : seul usage lu = priorité du processus | `CR:content/browser/renderer_host/render_process_host_impl.cc:1464-1475` | V, portée I |
| `WindowOcclusionEnabled` (Chrome Windows 90+ ; `NativeWindowOcclusionEnabled` 84 à 100, dépréciée), lue à la création de la fenêtre. Edge 89+, `SOFTWARE\Policies\Microsoft\Edge` | `CR:components/policy/resources/templates/policy_definitions/Miscellaneous/WindowOcclusionEnabled.yaml`, `CR:chrome/browser/ui/views/frame/browser_desktop_window_tree_host_win.cc:245-250`, https://learn.microsoft.com/en-us/deployedge/microsoft-edge-browser-policies/windowocclusionenabled | V |
| Playwright et Puppeteer passent `--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`, `--disable-background-timer-throttling` ; chromedriver le premier et le troisième. Motif absent de leur source ; Chromium : « avoid nondeterministic behavior » | `PW:packages/playwright-core/src/server/chromium/chromiumSwitches.ts:66-84`, `PP:packages/puppeteer-core/src/node/ChromeLauncher.ts:226-239`, `CR:chrome/test/chromedriver/chrome_launcher.cc:87-99` | V |

### 5. Electron et VS Code

| Fait | Source | |
|---|---|---|
| VS Code ajoute `CalculateNativeWinOcclusion` à `disable-features` ; chaîne présente dans la 1.145.2 installée | `VS:src/mainImpl.ts:370-373`, `...\Microsoft VS Code\c4453f8ea4\resources\app\out\mainImpl.js` | V |
| `editor.accessibilitySupport` règle le mode lecteur d'écran de l'interface, pas l'arbre Chromium | `VS:src/vs/platform/accessibility/browser/accessibilityService.ts:146-147` | V |
| Electron : aucune mention d'occlusion dans sa liste de fonctionnalités, défaut Chromium conservé | `EL:shell/browser/feature_list.cc` | I |
| `backgroundThrottling: false` pose `disable_hidden_` : `WasHidden` ignoré | `EL:patches/chromium/disable_hidden.patch`, `EL:shell/browser/api/electron_api_web_contents.cc:3030` | V |
| VS Code recouvert : 100 % des changements signalés, médiane 23 ms | `NC:docs/decisions/0013-mode-arriere-plan.md:117` | V |

### 6. États sans commutateur

| Fait | Source | |
|---|---|---|
| Partiellement visible : VISIBLE dès qu'une partie du `GetWindowRect` (bordures invisibles comprises) reste découverte | traqueur `:731-753` | V, bordures I |
| Écran secondaire : même règle, la région couvre l'écran virtuel entier | traqueur `:462-467` | V |
| Entièrement hors écran : OCCLUDED ; une bande découverte à l'écran : VISIBLE | traqueur `:749-751` | I |
| Sous une fenêtre non opaque, outil, popup ou « cloaked » : VISIBLE | `hwnd_util.cc:167-256` | V |
| Fenêtre capturée en vidéo : état forcé à VISIBLE | `window_tree_host.cc:392-394` | V |

### 7. Événements

| Fait | Source | |
|---|---|---|
| WinEvents web émis par le gestionnaire côté navigateur, créé avec `kNativeAPIs` et alimenté seulement si le renderer sérialise ; événements UIA levés si le fournisseur est actif | `CR:ui/accessibility/platform/browser_accessibility_manager_win.cc:767-873`, `CR:content/browser/renderer_host/render_frame_host_impl.cc:14353-14360,14464-14488` | V |
| S'abonner à un événement UIA incrémente des compteurs, sans changer le mode | `ax_fragment_root_win.cc:255-270,454-465` | V |
| Un hook WinEvent hors contexte n'atteint aucun code de Chromium ; seuls `WM_GETOBJECT` et les appels COM comptent | `legacy_render_widget_host_win.cc:364-405` | I |

### 8. Firefox

| Fait | Source | |
|---|---|---|
| Traqueur propre, activé par défaut (`widget.windows.window_occlusion_tracking.enabled`) | `FF:widget/windows/WinWindowOcclusionTracker.cpp`, `FF:modules/libpref/init/StaticPrefList.yaml:21694` | V |
| L'occlusion recalcule la visibilité du contexte de navigation ; l'arbre suit les ticks du refresh driver, ralenti à 1 image/s quand inactif | `FF:xpfe/appshell/AppWindow.cpp:2585-2600`, `FF:accessible/base/NotificationController.cpp:489`, `FF:layout/base/nsRefreshDriver.cpp:1376` | V, lien I |

### Ce qui reste à mesurer

- Chrome sous le leurre est-il OCCLUDED ? Comparer leurre `WS_POPUP` et `WS_OVERLAPPEDWINDOW` ; relancer avec chaque commutateur de la section 4 ; chercher un enfant `Chrome_RenderWidgetHostHWND` visible sous la fenêtre (absent quand le widget est masqué).
- Chrome a-t-il été visible avant d'être glissé sous le leurre (`NC:src/backend/windows/bg_probe.zig:763-778`) ?
- Arbre construit fenêtre visible, puis recouverte : les mises à jour suivent-elles ?
- Une action UIA sur une page masquée force-t-elle la sérialisation, et son effet arrive-t-il ?
- Bande visible minimale, écran secondaire, hors écran.
- Edge, autres applications Electron, Chrome 156 publié, essais Finch, Firefox recouvert.

### Contradictions trouvées

- Le leurre est `WS_POPUP` (`NC:src/backend/windows/decoy_window.zig:96`) : selon `hwnd_util.cc` il n'occulte pas, alors que la décision 0013 (`:69,121`) attribue le constat au recouvrement.
- `CR:docs/accessibility/browser/uiautomation.md:5-6` dit le fournisseur UIA « under development » ; le code et le billet Chrome le disent actif par défaut.
- La stratégie se déclare `dynamic_refresh: true` ; le code la lit à la création de la fenêtre, avec un TODO.
- Le commentaire de `--disable-renderer-backgrounding` (« never told [...] hidden ») dépasse le seul usage lu.
- Le PRD (A19, risque 2) traite Chromium et Electron en bloc ; VS Code coupe l'occlusion, Obsidian non (`AD:probes/windows/FINDINGS.md:60`, cause non isolée).

