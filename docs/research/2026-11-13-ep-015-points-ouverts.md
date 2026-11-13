# Recherche : les sept points ouverts après la revue de EP-015 (capture d'une fenêtre recouverte)

- Date : 2026-11-13
- Objet : réunir les faits qui permettent de trancher les sept points laissés à Arthur après la revue de EP-015 (décision 0013, « Points soumis à Arthur » et « Revue de EP-015 »). Ce document constate et propose ; rien n'est implémenté, aucun code n'a été modifié.
- Sources : sources primaires seulement, sauf mention « piste ». Microsoft Learn (clés M1 à M20), code de Chromium (miroir officiel GitHub, branche `main` lue le 2026-11-13, commit `144ac3d5`), code de WebRTC, de VS Code (`3c1448be`) et de WinUI, documentation Anthropic (A1, A2), code ou documentation des outils de mesure (P1 à P6), et le dépôt lui-même. La liste des adresses est en section 9.
- Méthode : lecture seule. Les fichiers sources ont été téléchargés puis cherchés par `grep`, pour citer des lignes exactes. Aucun selftest, bench ni sonde n'a été lancé (ils prennent la main sur le bureau). Seuls trois tests du cœur sur le backend factice ont tourné (`zig build test -Dtest-filter=...`, section 7). Trois sous-agents de recherche web ont préparé les points 1, 2 et 5 ; chaque fait qui porte une recommandation a été relu dans sa source.

Statut de chaque ligne :

| Statut | Sens |
|---|---|
| vérifié | lu par moi dans la source primaire, à l'endroit cité |
| vérifié (délégué) | cité mot pour mot par un sous-agent depuis la source primaire, non relu |
| mesure du dépôt | chiffre ou constat consigné dans ce dépôt (décision, code, test) |
| déduit | conclusion tirée de ce qui a été lu ; aucune ligne ne le dit |
| piste | source secondaire (blog, forum, dépôt tiers) : à confirmer avant de s'y fier |

Vocabulaire. UI Automation (UIA) est l'interface d'accessibilité de Windows : un client y lit l'arbre des contrôles d'une fenêtre. Le niveau d'intégrité est l'étiquette de privilège d'un processus (moyen pour une application normale, élevé pour « Exécuter en tant qu'administrateur »). UIPI (User Interface Privilege Isolation) est la règle de Windows qui empêche un processus d'agir sur les fenêtres d'un processus plus privilégié. `PrintWindow` est l'appel Win32 qui demande l'image d'une fenêtre ; DWM (Desktop Window Manager) est le compositeur de Windows, qui garde une image de chaque fenêtre. L'occlusion est le fait qu'une fenêtre soit entièrement cachée par d'autres. Le p95 d'une série de mesures est la valeur que 95 % des mesures ne dépassent pas ; le p50 est la médiane. La virtualisation DPI est l'étirement par Windows d'une application qui ne sait pas dessiner à l'échelle de son écran.

## 1. Balayage des mots de passe qui échoue : l'image part sans masque

Réponse courte : Microsoft documente qu'un client UIA d'intégrité moyenne « ne peut pas accéder » à l'interface d'un processus élevé, mais ne dit ni sous quelle forme (erreur ou arbre vide), ni si `PrintWindow` franchit cette frontière. Ce qu'un masque manqué expose est limité : un champ mot de passe standard dessine des puces, pas le texte. Le texte clair n'est à l'image que si l'utilisateur a activé « afficher le mot de passe ». L'invariant FR-09 reste absolu ; le refus est la lecture cohérente.

### 1.1 Ce que fait le code

| Fait | Source | Statut |
|---|---|---|
| `secrets` rend 0 rectangle, sans erreur, quand la fenêtre n'est pas `responsive` ou n'existe plus | `src/backend/windows/uia.zig:1225` | vérifié |
| Quand `findSecrets` échoue, `secrets` écrit « screenshot not masked » sur stderr et rend 0 | `src/backend/windows/uia.zig:1233-1236` | vérifié |
| `captureWindow` ne distingue pas « aucun champ » de « balayage en échec » : il lit `secretRects()` et encode | `src/core/screen.zig:253-258` | vérifié |
| Le seul cas refusé est le rectangle qui couvre toute la fenêtre (arbre web absent) | `src/core/screen.zig:254-257` | vérifié |
| La capture et le balayage vérifient chacun de leur côté que la fenêtre répond (`window.answers` pour l'un, `responsive` pour l'autre) : une fenêtre peut passer le premier et échouer au second | `src/backend/windows/capture.zig:418`, `uia.zig:1225` | déduit |
| Le backend sait déjà qu'une fenêtre est élevée (drapeau `elevated` de `window_list`, refus UIPI des actions) | `src/core/actions.zig:14`, `:67`, `tasks/prd-neo-compute.md:300` | vérifié |
| La limite est consignée et laissée à Arthur | `docs/decisions/0013-mode-arriere-plan.md:471` | mesure du dépôt |

### 1.2 (a) Un client UIA d'intégrité moyenne face à une fenêtre élevée

| Fait | Source | Statut |
|---|---|---|
| « An application that doesn't have UIAccess in the manifest starts with medium IL and cannot access elevated ("medium+" IL) process UI. » | M2 | vérifié |
| Pour accéder à un processus plus élevé, il faut le drapeau `UIAccess` du manifeste, une signature et une installation dans un emplacement protégé ; « UIAccess is not enough for a process to move up through the IL boundary » | M2 | vérifié |
| « The UI automation program will not be able to drive the graphics UI of elevated applications on the desktop without the ability to bypass restrictions that UIPI implements. » | M1 | vérifié |
| UIPI est appliqué « in the SendMessage and related window message functions » ; un processus moins privilégié ne peut pas envoyer de message à une fenêtre plus privilégiée : « These APIs return success but silently drop the window message. » | M1 | vérifié |
| Tous les messages ne sont pas bloqués : « "read" type messages, for example WM_GETTEXT, can be sent from a lower-privilege to a higher-privilege window. However, write type messages, such as WM_SETTEXT, are blocked. » | M1 | vérifié |
| `window.answers` et `responsive` reposent sur un message : face à une fenêtre élevée, un message abandonné en silence peut fausser leur réponse dans un sens ou dans l'autre | M1, `src/backend/windows/capture.zig:418` | déduit |

Non confirmé : la forme de l'échec. Aucune page lue ne dit si `ElementFromHandle` ou `FindAll` rendent une erreur (laquelle), ou réussissent avec un arbre vide ou partiel. Le code traite les deux de la même façon aujourd'hui : 0 rectangle, image non masquée.

### 1.3 (b) `PrintWindow` sur une fenêtre élevée

| Fait | Source | Statut |
|---|---|---|
| La page de `PrintWindow` ne documente que `PW_CLIENTONLY` et ne dit rien des niveaux d'intégrité | M3 | vérifié |
| « The application that owns the window referenced by hWnd processes the PrintWindow call [...]. The application receives a WM_PRINT message » | M3 | vérifié |
| `PW_RENDERFULLCONTENT` n'est pas documenté par Microsoft. Chromium l'écrit : « The PW_RENDERFULLCONTENT flag is undocumented, but works starting in Windows 8.1. It allows for capturing the contents of the window that are drawn using DirectComposition. » | `chromium:ui/snapshot/snapshot_win.cc:41-45` | vérifié |
| WebRTC utilise le même drapeau pour la même raison (applications à rendu DirectComposition) | `webrtc:modules/desktop_capture/win/window_capturer_win_gdi.cc:301-314` | vérifié |
| Ce que UIPI laisse partagé entre niveaux : « Desktop window, which actually owns the screen surface », le presse-papiers, la table d'atomes. Peindre sur la fenêtre d'un processus plus élevé « is not blocked by UIPI » | M1 | vérifié |
| La liste de ce que UIPI bloque (validation de handle, `SendMessage` et `PostMessage`, hooks de thread, hooks journal, injection de DLL) ne contient aucune lecture de pixels | M1 | vérifié |
| Lire les pixels d'une fenêtre élevée (écran, DWM) n'est donc pas bloqué par UIPI ; pour `PrintWindow`, cela dépend de la voie : la voie `WM_PRINT` passe par un message, la voie `PW_RENDERFULLCONTENT` par l'image que tient DWM | M1, M3 | déduit |

Non confirmé : le résultat réel de `PrintWindow(…, PW_RENDERFULLCONTENT)` depuis un processus d'intégrité moyenne sur une fenêtre élevée (succès, échec ou image noire). Aucune source primaire ne le dit. Une sonde le mesure en une minute : la machine de référence a une cible prête (iCUE tourne élevé, d'après la mémoire du projet), à restaurer d'abord puisqu'elle est minimisée.

### 1.4 (c) Ce qu'un champ mot de passe dessine, et ce que dit `IsPassword` quand il est révélé

| Contrôle | Ce qu'il dessine | `IsPassword` quand le texte est révélé | Source | Statut |
|---|---|---|---|---|
| EDIT Win32 avec `ES_PASSWORD` | « Displays an asterisk (*) for each character typed » | Sans objet tant que le style est là | M5 | vérifié |
| EDIT Win32, case « afficher » de l'application | `EM_SETPASSWORDCHAR` à zéro : le contrôle « displays the characters typed by the user », et « The ES_PASSWORD style is removed » | Le style disparaît ; `IsPassword` devient donc faux et le balayage ne masque plus rien, même quand il réussit | M6 (le lien entre le style et `IsPassword` est déduit) | vérifié, puis déduit |
| `PasswordBox` XAML et WinUI | Puces. `PasswordRevealMode` vaut `Peek` par défaut (« The user must continuously press the button to view the password ») ; `Visible` montre le texte | Toujours vrai : `IsPasswordCore` rend `TRUE` sans condition | M15 (délégué) ; `microsoft-ui-xaml:dxaml/xcp/dxaml/lib/PasswordBoxAutomationPeer_Partial.cpp:76-85` | vérifié |
| `<input type=password>` Chromium et Edge | Puces. Le bouton de révélation intégré (`PasswordRevealEnabled`, Alt+F8) appelle `SetShouldRevealPassword` et laisse le type à `password` | Toujours vrai : `IsPasswordField` ne teste que `FormControlType == kInputPassword`, qui donne l'état `kProtected`, que `UIA_IsPasswordPropertyId` renvoie | `chromium:third_party/blink/renderer/core/html/forms/password_input_type.cc:152-187`, `…/modules/accessibility/ax_object.cc:3603-3607`, `…/ax_node_object.cc:2450-2451`, `ui/accessibility/platform/ax_platform_node_win.cc:5594-5597` | vérifié |
| Site web qui bascule le champ en `type=text` pour « afficher » | Texte clair | Faux, par la même ligne : le champ n'est plus un `kInputPassword` | `…/ax_object.cc:3603-3607` | déduit |
| Définition de la propriété | `IsPassword` « indicates whether the automation element contains protected content or a password » | | M7 | vérifié |

Conséquence (déduit) : un masque manqué sur un champ non révélé expose le nombre de puces, pas le mot de passe. Le masque protège vraiment dans deux cas : un `PasswordBox` ou un champ Chromium en cours de révélation. Dans les deux autres cas de révélation (case « afficher » Win32, site qui passe en `type=text`), le balayage ne voit plus de champ mot de passe, qu'il réussisse ou non : cette fuite existe indépendamment du point posé ici.

### 1.5 (d) Outils comparables et exclusion de capture

| Fait | Source | Statut |
|---|---|---|
| `SetWindowDisplayAffinity` : `WDA_MONITOR` montre la fenêtre sans contenu « everywhere else », `WDA_EXCLUDEFROMCAPTURE` (Windows 10 2004) la retire entièrement | M4 (délégué pour les deux citations) | vérifié (délégué) |
| Cette protection ne vaut que pour « a specific set of public operating system features and APIs » et seulement quand DWM compose le bureau | M4 | vérifié |
| Ce n'est pas une garantie : « unlike a security feature or an implementation of Digital Rights Management (DRM), there is no guarantee [...] » | M4 | vérifié |
| Une fenêtre `WDA_EXCLUDEFROMCAPTURE` est absente des images DXGI et GDI | `AGENTS.md` (mesure de la décision 0011) | mesure du dépôt |
| Recall (Microsoft) ne masque pas : il renonce à l'image. « snapshots won't be saved when potentially sensitive information is detected » ; sa liste de types filtrés contient « General Password » | M16 | vérifié (délégué) |
| Windows.Graphics.Capture passe par un sélecteur système et une bordure jaune autour de l'élément capturé | M17 | vérifié (délégué) |
| Anthropic ne prescrit aucun masquage, mais recommande d'éviter « giving the model access to sensitive data, such as account login information » | A1 | vérifié |

Mesuré après la recherche (2026-11-13, machine de référence, fenêtre WinForms de 320x200 à fond magenta, script PowerShell hors dépôt) : `PrintWindow` avec `PW_RENDERFULLCONTENT` rend une image entièrement noire d'une fenêtre qui porte `WDA_MONITOR` ou `WDA_EXCLUDEFROMCAPTURE` (0 pixel non noir sur 4 000 échantillonnés, contre 3 680 sans le drapeau d'affinité). Sans `PW_RENDERFULLCONTENT` (voie `WM_PRINT`), l'affinité est ignorée : 3 998 pixels sur 4 000 dans les trois cas. Le serveur n'utilise que `PW_RENDERFULLCONTENT` (`src/backend/windows/capture.zig`) : une fenêtre qui refuse la capture (gestionnaire de mots de passe) reçoit donc « Capture noire », jamais son image. La fenêtre mesurée appartenait au processus appelant ; une fenêtre d'un autre processus n'a pas été mesurée.

### 1.6 Options

| Option | Ce qu'elle fait | Coût | Faiblesse |
|---|---|---|---|
| A. Refuser quand le masque n'est pas garanti (recommandée) | Le balayage rend trois issues (champs trouvés, aucun champ, échec). `captureWindow` refuse sur échec, sur fenêtre élevée (drapeau déjà connu) et sur fenêtre qui ne répond pas au balayage, avec un message qui nomme la cause et la suite (`ui_tree`, ou relancer sans élévation) | Petit : une issue de plus dans `secrets`, le backend factice, deux tests du cœur, un contrôle de selftest. Aucun coût à l'exécution | Une erreur UIA passagère fait refuser une capture qui aurait été sûre : l'agent réessaie |
| B. Refuser seulement la fenêtre élevée | Refus sur le drapeau `elevated`, le reste inchangé | Très petit | L'erreur UIA sur une fenêtre normale part toujours sans masque |
| C. Laisser tel quel et documenter | Comme le screenshot d'écran depuis US-019 | Nul | FR-09 (« jamais dans une image ») ne tient plus que si le balayage réussit |
| D. Noircir toute la fenêtre | Image noire | Nul | Déjà écartée pour l'arbre web : une image noire n'apprend rien |

Recommandation : A, pour la capture de fenêtre. Le refus ne coûte rien quand tout va bien, et une fenêtre élevée est de toute façon hors de portée des actions (refus UIPI existant). C'est aussi le choix de Recall : renoncer à l'image plutôt que la laisser partir. Le screenshot d'écran des modes a11y et vision relève d'une décision déjà prise (0007) et n'est pas rouvert ici.

## 2. Bruit du gate de bench sur `bg-act`

Réponse courte : aucune des sources primaires lues ne soutient un p95 unique comparé à une seule valeur à 110 %. Elles s'appuient sur la médiane ou le minimum, sur plusieurs séries, sur un seuil tiré du bruit mesuré, et sur l'alternance ancien et nouveau code. Le dépôt possède déjà deux de ces mécanismes (référence « pire de 5 passes », comparaison alternée avec `HEAD` faite à la main en revue).

### 2.1 Ce que fait le gate

| Fait | Source | Statut |
|---|---|---|
| Un étage échoue quand son p95 dépasse 110 % de sa référence et l'écart 1 µs | `src/core/bench.zig:401`, `:416` | vérifié |
| `--write-baseline` enregistre le pire p95 de 5 passes (`mergeWorstP95`), « so the 110 % rule flags regressions rather than jitter » | `src/core/bench.zig:418-434`, `src/main.zig:268-269` | vérifié |
| `snapshot` et `ui_tree` passent aussi sous 110 % d'un témoin C mesuré autour de la série (relatif au provider) | `src/core/bench.zig:304-310`, `:402-410`, décision 0010 partie 2 | vérifié |
| Décision 0010 : Arthur a préféré des scénarios relatifs à une baseline réenregistrée, parce que le code qui avait fixé la référence mesurait lui-même plus haut | `docs/decisions/0010-fr25-et-bench-relatif-ep-006.md:55-63` | vérifié |
| `bg-act` : 200 itérations par série ; référence 2 549 µs, limite 2 804 µs | `src/backend/windows/bench.zig:274`, `bench/baseline.json:49-58` | vérifié |
| p95 de `bg-act` dans la passe complète, sans changement de son code : 2 355 (revue EP-013), 2 765 (revue EP-014), 2 750, 2 846, 2 644, 2 718 (EP-015), 2 880 au pire de 5 passes | `docs/decisions/0013-mode-arriere-plan.md:308`, `:374`, `:440`, `:465` | mesure du dépôt |
| Séries isolées alternées : `HEAD` 2 314 à 2 782 µs, EP-015 2 310 à 2 662 µs ; médianes 1 680 à 1 793 et 1 724 à 1 759 µs | `docs/decisions/0013-mode-arriere-plan.md:440` | mesure du dépôt |
| Le p95 varie donc de 22 % entre séries (2 355 à 2 880), la médiane de 2 à 7 % | calcul sur les deux lignes ci-dessus | déduit |
| En fin de passe complète, tout le processus est environ 25 % plus lent qu'en série isolée | `AGENTS.md`, `docs/decisions/0013-mode-arriere-plan.md:438` | mesure du dépôt |

Non confirmé : le régime dans lequel la référence de `bg-act` a été prise à EP-012 (série isolée ou passe complète). Le commit `0a591d0` l'a écrite ; la décision ne le dit pas.

### 2.2 Ce que disent les outils de mesure

| Fait | Source | Statut |
|---|---|---|
| benchstat (Go) résume par la médiane et compare par un test de rang : « median for summaries, and the Mann-Whitney U-test for A/B comparisons » (test de Mann-Whitney : il dit si deux séries de mesures viennent de la même distribution, sans supposer sa forme) | P1 `main.go:352-353` | vérifié |
| « Each benchmark should be run at least 10 times » ; plus loin : « at least 10, ideally 20 » | P1 `main.go:19-20`, `:380` | vérifié |
| « It's also important that noise is evenly distributed across benchmark runs. The best way to do this is to interleave before and after runs » | P1 `main.go:373-374` | vérifié |
| « "statistically significant" is not the same as "large" » : un test seul ne dit pas si l'écart compte | P1 `main.go:125` | vérifié |
| Google Benchmark : le test U de `compare.py` « requires **LARGE** (no less than 9) number of repetitions to be meaningful! » | P2 `docs/tools.md:342` | vérifié |
| LLVM LNT agrège les échantillons par le minimum (`aggregation_fn=stats.safe_min`), ignore les écarts sous 1 % (`MIN_PERCENTAGE_CHANGE = .01`) et annule un changement que Mann-Whitney juge « same » | P3 `analysis.py:18`, `:206-207`, `:240` | vérifié |
| rustc-perf tire le seuil du bruit passé de chaque test : « A test result is significant if the relative change percentage is considered an outlier against historical data », borne `Q3 + (interquartile_range * 3)` (l'écart interquartile, IQR, est la largeur de la moitié centrale des mesures) | P4 `comparison-analysis.md:40-44` | vérifié |
| Criterion.rs compare par rééchantillonnage (bootstrap) et test T ; seuil de bruit par défaut 1 %, seuil de signification 0,05 ; déconseille de se fier à des mesures d'horloge sur une machine partagée | P5 | vérifié (délégué) ; la méthode d'analyse est vérifiée |
| Skia Perf propose des détecteurs par médiane (`PercentMedianStep`), par taille d'effet (`CohenStep`) et `MannWhitneyU` ; Pinpoint répond « different », « same » ou demande plus de données | P6 | vérifié (délégué) |
| Aucune de ces sources ne parle de p95 ou de p99 | P1 à P6 | vérifié (délégué) |

Non confirmé : une phrase de première main disant qu'un percentile de queue demande plus d'échantillons que la médiane. C'est vrai en statistique (sur 200 itérations, le p95 est fixé par les 10 plus lentes) et les mesures du dépôt le montrent, mais aucune source lue ne l'écrit. Les pages de Chromium sur la surveillance des performances n'ont pas été lues.

### 2.3 Options

| Option | Appui | Coût | Faiblesse |
|---|---|---|---|
| 1. Reprendre la référence de `bg-act` seule : pire p95 de 5 passes complètes | Règle du dépôt (`mergeWorstP95`, AGENTS.md, déjà appliquée à `bg-capture`). Aucun appui externe | 5 passes complètes sur le bureau ; décision d'Arthur (Boundaries) | Élargit le seuil : la limite passe vers 3 170 µs (110 % de 2 880), une vraie régression de 15 à 20 % du p95 courant passe. Une nouvelle série dépasse le pire de 5 avec une chance sur 6 ; la marge de 10 % par-dessus la réduit sans l'annuler |
| 2. Gate sur le p50 à 110 %, p95 tenu par le budget absolu et une limite relative plus large | benchstat (médiane), Skia (`PercentMedianStep`) ; mesures du dépôt (médiane 2 à 7 %, p95 22 %) | Format de `bench/baseline.json` étendu (références p50), `check`, `compare`, `writeBaseline` et leurs tests ; baseline réécrite pour tous les scénarios (décision d'Arthur) ; les gates du PRD sont formulés en p95 | Une régression de la seule queue n'est vue que par la limite large |
| 3. Rejouer le scénario en échec, jusqu'à 3 séries, garder le meilleur p95 | Partiel : LNT agrège par le minimum, parce que le bruit ne fait qu'ajouter du temps | 2 séries de plus au pire (environ 15 s de leurre chacune) ; quelques lignes dans `main.zig` | Fausse alerte de 1 sur 3 ramenée à environ 1 sur 27 si les séries sont indépendantes, mais une régression proche du seuil passe aussi plus souvent |
| 4. Test de Mann-Whitney contre des échantillons enregistrés | benchstat, Google Benchmark, LNT, Pinpoint | L'unité doit être la série, pas l'itération (le bruit est entre séries) : 9 à 10 séries par gate et par scénario, et leurs p95 stockés | Trop long pour un gate de routine ; convient à une vérification à la demande |
| 5. Seuil par scénario tiré de son propre bruit | rustc-perf (borne IQR), Pinpoint (effet rapporté à l'IQR) | La baseline garde les p95 de chaque passe, pas seulement le pire ; `check` calcule la borne ; tests | Plus de code ; un scénario bruité reçoit un gate large. Sur les sept p95 connus de `bg-act`, `Q3 + 1,5 × IQR` donne environ 3 150 µs : presque la limite de l'option 1 |
| 6. Comparaison alternée avec `HEAD` quand le gate échoue | benchstat (« interleave before and after runs »), conception de Pinpoint | Une copie de `HEAD` construite à part (`git archive` plus `zig-pkg/`), temps doublé. Déjà fait à la main en revue de EP-015 | Procédure, pas un gate : elle départage, elle ne remplace pas la référence |

Recommandation : option 1 tout de suite, à la demande d'Arthur, parce qu'elle applique la règle que le dépôt s'est donnée et que la comparaison alternée de la revue montre que EP-015 ne ralentit pas `bg-act`. Écrire l'option 6 comme la marche à suivre quand le gate échoue sur un chemin non modifié. Si un second scénario montre le même symptôme, passer à l'option 5 : un seuil tiré du bruit mesuré de chaque scénario remplace alors la marge fixe de 110 %, qui est la vraie cause.

## 3. La ligne « l'image peut être figée »

Réponse courte : la ligne est juste, et le code de Chromium l'explique. Une fenêtre jugée recouverte passe sa page à l'état « cachée », qui ne produit plus d'images ; `PrintWindow` ne prévient pas Chromium, il lit l'image que DWM a gardée. VS Code désactive ce calcul par une option de démarrage. Un réglage côté utilisateur existe pour Chrome : la politique `WindowOcclusionEnabled`.

| Fait | Source | Statut |
|---|---|---|
| Le calcul d'occlusion des fenêtres natives est activé par défaut sous Windows : `BASE_FEATURE(kCalculateNativeWinOcclusion, base::FEATURE_ENABLED_BY_DEFAULT)` | `chromium:ui/base/ui_base_features.cc:38-40` | vérifié |
| L'état calculé arrive à `WindowTreeHost::SetNativeWindowOcclusionState`, qui le diffuse à ses observateurs | `chromium:ui/aura/window_tree_host.cc:390-413` | vérifié |
| La vue du contenu web suit l'état de sa fenêtre : `OCCLUDED` donne `Visibility::OCCLUDED`, `HIDDEN` donne `Visibility::HIDDEN` | `chromium:content/browser/web_contents/web_contents_view_aura.cc:1000-1010`, `:1449-1453` | vérifié |
| Une page qui n'est pas `VISIBLE` et que rien ne capture passe à `PageVisibilityState::kHidden` | `chromium:content/browser/web_contents/web_contents_impl.cc:5304-5327` | vérifié |
| Le commentaire du code : « the Page and other classes do not expect to be producing frames when the Page is hidden » | `chromium:content/browser/web_contents/web_contents_impl.cc:5404-5410` | vérifié |
| La politique d'entreprise le dit en clair : Chrome « will detect when a window is covered by other windows, and will suspend work painting pixels » | `chromium:components/policy/resources/templates/policy_definitions/Miscellaneous/WindowOcclusionEnabled.yaml` | vérifié |
| Cette politique (`WindowOcclusionEnabled`, Chrome Windows depuis la version 90) s'applique sans redémarrage (`dynamic_refresh: true`) ; à `false`, Chrome « will not detect when a window is covered ». L'ancienne `NativeWindowOcclusionEnabled` est dépréciée (versions 84 à 100) | même fichier, et `…/NativeWindowOcclusionEnabled.yaml` | vérifié |
| L'option `--disable-backgrounding-occluded-windows` remet `OCCLUDED` à `VISIBLE` ; elle est décrite comme faite pour les tests | `chromium:content/public/common/content_switches.cc:90-93`, `content/browser/web_contents/web_contents_impl.cc:12895-12903` | vérifié |
| VS Code démarre avec `--disable-features=CalculateNativeWinOcclusion` : « Disable native window occlusion tracker » | `vscode:src/mainImpl.ts:369-373` | vérifié |
| Seule la capture vidéo faite par Chromium lui-même garde une fenêtre recouverte « visible » (`video_capture_count_for_occlusion_tracking_ > 0`) | `chromium:ui/aura/window_tree_host.cc:396-401`, `:757-759` | vérifié |
| Ni la fenêtre principale ni la fenêtre du contenu web ne traitent `WM_PRINT` ou `WM_PRINTCLIENT` : leurs tables de messages n'en contiennent pas | `chromium:ui/views/win/hwnd_message_handler.h` (table : `WM_GETOBJECT` ligne 472, `WM_PAINT` ligne 547), `content/browser/renderer_host/legacy_render_widget_host_win.h:83-85` ; recherche de `WM_PRINT` sans résultat dans les quatre fichiers | vérifié |
| Chromium utilise lui-même `PrintWindow` avec `PW_RENDERFULLCONTENT` pour ses instantanés, « because it works even when the window's partially occluded » | `chromium:ui/snapshot/snapshot_win.cc:41-47` | vérifié |
| Une demande `PrintWindow` venue de l'extérieur ne force donc aucune image : Chromium n'en est pas informé, et rien dans ce chemin ne touche l'état d'occlusion | lignes ci-dessus | déduit |
| Chrome recouvert : 0 pixel changé après une action délivrée, 153 une fois en vue ; VS Code à jour | `docs/decisions/0013-mode-arriere-plan.md:410`, `:463` | mesure du dépôt |
| Une bande de 16 px en vue suffit à garder Chrome à jour | `AGENTS.md` (EP-014, sonde US-058) | mesure du dépôt |
| Le calcul ignore en général les fenêtres `WS_POPUP` qui ne sont ni de Chromium ni la barre des tâches | `chromium:ui/aura/native_window_occlusion_tracker_win.cc:815-823` | vérifié |

Non confirmé : que Edge porte la même politique sous le même nom (non lu) ; qu'une application Electron autre que VS Code laisse le calcul actif (la documentation d'Electron ne décrit l'occlusion que pour macOS, `electron:docs/api/browser-window.md:121-126` ; la note du 2026-11-13 sur agent-desktop rapporte Obsidian figé quand il est recouvert).

Options :

| Option | Coût | Faiblesse |
|---|---|---|
| A. Garder la ligne telle quelle (recommandée) | Nul | Aucune connue : elle dit la cause et le remède, et cesse pour une application qui prouve qu'elle rend recouverte (FR-47) |
| B. Garder la ligne et documenter le réglage côté utilisateur (README ou `instructions`) : politique `WindowOcclusionEnabled` à `false` pour Chrome | Une phrase de documentation. Le serveur n'écrit pas le registre | Chrome dessine alors même caché : la politique existe « to reduce CPU and power consumption » |
| C. Retirer la ligne | Nul | L'agent lit une image d'avant son action comme si elle était à jour : il conclut que l'action a échoué |
| D. Lancer Chrome avec `--disable-features=CalculateNativeWinOcclusion` par `app_launch` | Changement de contrat et de politique de lancement | Sans effet si Chrome tourne déjà (le nouveau processus rend la main à l'ancien) |

Recommandation : A, avec B en complément. La ligne est exacte au regard du code de Chromium.

## 4. Le refus « arbre web non construit »

Réponse courte : le refus est justifié, mais son conseil est à moitié juste. Le balayage est déjà la requête UIA qui déclenche la construction de l'arbre ; appeler `ui_tree` n'y ajoute qu'un délai. Pour une fenêtre recouverte, c'est la bande visible qui compte : Chromium envoie bien le mode d'accessibilité à une page recouverte, mais cette page ne fait plus les mises à jour qui construisent l'arbre.

| Fait | Source | Statut |
|---|---|---|
| La fenêtre du contenu web répond à `WM_GETOBJECT` : pour `UiaRootObjectId`, elle note la demande et rend son fournisseur UIA si celui-ci est activé | `chromium:content/browser/renderer_host/legacy_render_widget_host_win.cc:364-433` | vérifié |
| Le fournisseur UIA est activé par défaut (`uia_provider_enabled_ = true`) ; il n'est coupé que si un outil incompatible est détecté. Le drapeau `kUiaProvider` n'existe plus sur `main`, et la politique `UiAutomationProviderEnabled` est dépréciée (versions 125 à 146) | `chromium:ui/accessibility/platform/ax_platform.h:248-250`, `ax_platform.cc:118-132`, `components/policy/…/Accessibility/UiAutomationProviderEnabled.yaml` | vérifié |
| L'arbre web n'est demandé qu'après usage : lire des propriétés dans le contenu web active `kAXModeBasic` (« enable basic web accessibility support »), soit `kNativeAPIs` plus `kWebContents` | `chromium:content/browser/accessibility/browser_accessibility_state_impl.cc:517-522`, `ui/accessibility/ax_mode.h:236-239` | vérifié |
| Le mode n'est appliqué qu'à une page non cachée : « Only update the WebContents if it is not hidden [...] else the WebContents will be updated when it is revealed » | `chromium:content/browser/accessibility/browser_accessibility_state_impl.cc:699-702` | vérifié |
| « Cachée » veut dire ici `Visibility::HIDDEN` (fenêtre minimisée ou masquée). Une fenêtre recouverte est `OCCLUDED` : elle reçoit le mode | même fichier `:586-590`, `:699-702` ; section 3 | vérifié, puis déduit |
| Dans la page, l'arbre d'accessibilité se met à jour avec le rendu : « A visual update will force accessibility to be updated as well », et le code programme une mise à jour visuelle | `chromium:third_party/blink/renderer/modules/accessibility/ax_object_cache_impl.cc:4266-4287` | vérifié |
| Une page recouverte est `kHidden` et ne produit plus d'images (section 3) : l'arbre demandé n'arrive donc pas tant qu'elle reste entièrement recouverte | lignes ci-dessus | déduit |
| Chrome recouvert fige son arbre : 0 action sur 20 se lit dans l'arbre, toutes sont délivrées | `tasks/prd-background-mode.md:668`, `AGENTS.md` (EP-014) | mesure du dépôt |
| `--force-renderer-accessibility` fixe le mode au démarrage, avec une valeur facultative parmi `basic`, `form-controls`, `complete`, `screen-reader` et `on-screen`. Il ne change rien au gel d'une page recouverte, qui tient au rendu (déduit) | `chromium:content/browser/accessibility/browser_accessibility_state_impl.cc:326-346` | vérifié |
| Le balayage attend déjà l'arbre : il relance `findSecrets` toutes les 10 ms pendant 300 ms, puis masque toute la fenêtre | `src/backend/windows/uia.zig:1226-1253` | vérifié |
| Sur un Chrome en vue et neuf, le document arrive 10 à 30 ms après la première requête | `src/backend/windows/uia.zig:1250-1251` | mesure du dépôt |
| Sur une application Electron à froid (Obsidian), agent-desktop a mesuré 10 à 25 s avant l'arbre complet | `docs/research/2026-11-13-agent-desktop-cohabitation.md` (ligne A16-11) | mesure tierce consignée |

Non confirmé : un délai d'activation documenté. Le code de Chromium ne donne aucun chiffre ; seules les deux mesures ci-dessus existent. Non lu : la suite de la chaîne dans le processus de rendu (qu'une page `kHidden` ne serve aucune mise à jour visuelle est admis par le commentaire de la section 3, pas suivi ligne à ligne).

Options :

| Option | Coût | Faiblesse |
|---|---|---|
| A. Garder le refus, corriger le conseil (recommandée) : mettre la bande visible en premier, « réessaie » ensuite, et retirer ou rendre facultatif « Appelle ui_tree » | Un texte et son test (`src/core/screen.zig:257`, `src/core/capture_test.zig:102`) | Aucune connue |
| B. Garder le message actuel | Nul | Sur une fenêtre recouverte, l'agent appelle `ui_tree`, n'obtient rien de plus et réessaie en vain s'il n'a pas lu la parenthèse |
| C. Allonger l'attente du balayage pour la capture (au-delà de 300 ms) | Une constante ; chaque capture d'un Chromium sans arbre attend plus | Ne change rien pour une fenêtre recouverte ; utile seulement pour une application lente à froid |
| D. Laisser partir l'image sans masque | Nul | Contraire à FR-09, et au point 1 |

Recommandation : A. Formulation possible : « Capture indisponible : l'arbre web de <exe> n'est pas construit, ses champs mot de passe ne peuvent pas être masqués. Si la fenêtre est recouverte, laisse une bande d'au moins 16 px visible avec window_set, puis réessaie ; sinon réessaie dans un instant. »

## 5. Fenêtre mise à l'échelle par Windows

Réponse courte : le test du code est le bon d'après la documentation, et le refus est prudent : WebRTC constate que l'image rendue par `PrintWindow` pour une application étirée est plus petite que son rectangle de fenêtre. Aucun réglage ne produit la situation sans un écran au-dessus de 100 % ; le plus simple est de passer le second écran à 125 % le temps de la mesure. La fenêtre de test « non consciente du DPI » existe déjà dans le selftest.

### 5.1 (a) Quel espace de coordonnées répond

| Fait | Source | Statut |
|---|---|---|
| Quand une fenêtre est étirée, Windows convertit les réponses de certaines API « to the coordinate space of the calling thread » | M9 | vérifié |
| Un processus par écran (per-monitor) voit « the raw pixels of each display » | M9 | vérifié |
| Microsoft reconnaît que la liste des API converties « is not currently sufficiently documented » | M9 | vérifié |
| « GetWindowRect is virtualized for DPI. » | M8 | vérifié |
| « unlike the Window Rect, the DWM Extended Frame Bounds are not adjusted for DPI » | M8 | vérifié |
| UIA : « The UI Automation API does not use logical coordinates » ; `BoundingRectangle` est en pixels physiques | M13 | vérifié |
| Le serveur est per-monitor v2 (contrôle `dpi` du selftest) : pour lui, `GetWindowRect`, le cadre DWM et les rectangles UIA sont tous en pixels physiques, même pour une cible étirée | `src/backend/windows/selftest.zig:426-430`, lignes ci-dessus | déduit |
| Pour une application étirée, l'image de `PrintWindow` ou de `BitBlt` est « smaller than `original_rect` and `cropped_rect` » ; sans correction, « Part of the captured desktop frame will be black ». WebRTC lit la taille du contexte graphique de la fenêtre et remet les rectangles à cette échelle | `webrtc:modules/desktop_capture/win/window_capturer_win_gdi.cc:241-262` | vérifié |
| Ce même code appelle ensuite `PrintWindow` avec `PW_RENDERFULLCONTENT` et garde la correction d'échelle | même fichier `:301-314`, `:394` | vérifié |
| Le refus du code repose sur ce constat : l'image serait à la résolution propre de la cible, où aucun rectangle du bureau ne s'applique | `src/backend/windows/capture.zig:408-411`, `:423` | vérifié |

Non confirmé : aucune page Microsoft ne dit ce que `PrintWindow` rend pour une cible étirée, ni si `PW_RENDERFULLCONTENT` change la taille de l'image. Le commentaire de WebRTC est la seule source de première main, et il date d'avant l'usage général de ce drapeau. Une réponse à une question Microsoft Q&A (piste) confirme que la documentation est muette.

### 5.2 (b) Le test `GetDpiForWindow` contre `GetDpiForMonitor`

| Fait | Source | Statut |
|---|---|---|
| `GetDpiForWindow` rend 96 pour une fenêtre non consciente, « The system DPI » pour une fenêtre consciente du système, le DPI de son écran pour une fenêtre per-monitor | M11 | vérifié |
| `GetDpiForMonitor` dépend de l'appelant : 96 pour un appelant non conscient, « The actual DPI value set by the user for that display » pour un appelant per-monitor | M12 | vérifié |
| Une fenêtre consciente du système est « automatically scaled up or down by the system when the DPI changes from the system value » ; une fenêtre non consciente est étirée « on any other DPI setting » que 96 | M10 | vérifié |
| Le test « DPI de la fenêtre différent du DPI effectif de son écran » est donc la condition que la documentation donne pour l'étirement, à condition que l'appelant soit per-monitor | M10, M11, M12, `src/backend/windows/capture.zig:482-489` | déduit |
| `DPI_AWARENESS_CONTEXT_UNAWARE_GDISCALED` « behaves similarly to DPI_AWARENESS_CONTEXT_UNAWARE » avec un meilleur rendu GDI | M10 | vérifié |
| Qu'une telle fenêtre rende 96 à `GetDpiForWindow`, et ce que `PrintWindow` en rend, n'est écrit nulle part | | déduit, non confirmé |
| Pour une fenêtre enfant, `GetDpiForWindow` rend le DPI de la fenêtre de premier niveau | M14 | vérifié |
| Depuis Windows 10 1607, la conscience DPI se règle par fenêtre de premier niveau ; créer une fenêtre après `SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_UNAWARE)` lui donne ce contexte | M9, M14 | vérifié |
| Une fenêtre per-monitor à cheval sur deux écrans peut, le temps du passage, avoir un DPI différent de l'écran que `MonitorFromWindow` choisit : refus à tort, sans gravité | `src/backend/windows/capture.zig:487` | déduit |

### 5.3 (c) Exercer ce chemin sur une machine à deux écrans à 100 %

| Moyen | Marche sans écran au-dessus de 100 % ? | Source | Statut |
|---|---|---|---|
| Fenêtre de test créée sous `DPI_AWARENESS_CONTEXT_UNAWARE` | Non : à 96 ppp, rien n'est étiré. Windows n'étire que « on a display set to >100% scaling » | M10, M14 | vérifié |
| Cette fenêtre existe déjà : `TestWindow.dpi_unaware`, utilisée par le contrôle `dpi-unaware` du selftest | Sert dès qu'un écran est au-dessus de 100 % | `src/backend/windows/test_window.zig:126`, `:575`, `src/backend/windows/selftest.zig:672-675`, `:1188` | vérifié |
| Passer un écran à 125 % dans Paramètres | C'est le moyen : il crée l'écran qu'il faut. Un changement d'échelle étire aussitôt les applications conscientes du système (« if the display scale factor otherwise changes, Windows will bitmap scale the application's windows ») | M9 | vérifié |
| Couche de compatibilité (`__COMPAT_LAYER`, valeurs `DPIUNAWARE`, `GDIDPISCALING`, `HIGHDPIAWARE`) | Non : elle change la conscience DPI d'un processus, pas l'échelle d'un écran | aucune source primaire trouvée | déduit, non confirmé |
| Registre `LogPixels` et `Win8DpiScaling` | Change l'échelle du système, avec « Require logoff/logon » ; document de l'ère Windows 8.1 | M19 | vérifié (délégué) |
| `DisplayConfigSetDeviceInfo` avec les types non documentés -3 (lire) et -4 (écrire), sans fermeture de session | Changerait l'échelle par programme | dépôt tiers `imniko/SetDPI`, correctifs Wine | piste |
| Session Bureau à distance avec `desktopscalefactor` (100 à 500) | Oui en principe, dans une autre session ; propriété annoncée comme dépréciée | M18 | vérifié (délégué) |
| Écran virtuel (exemple IddCx de Microsoft) | Créerait un écran de plus, à régler ensuite ; installation et signature d'un pilote | `microsoft/Windows-driver-samples`, dossier `video/IndirectDisplay` | vérifié (délégué) pour l'existence ; le reste déduit |

Non confirmé : que 125 % soit proposé par Windows 11 sur chaque écran de 2560x1440 (les seuils lus sont ceux de Windows 8.1) ; qu'une session Bureau à distance offre la capture DXGI dont le selftest a besoin.

Options :

| Option | Coût | Faiblesse |
|---|---|---|
| A. Garder le refus et l'exercer une fois (recommandée) : second écran à 125 %, fenêtre `dpi_unaware` dessus, un contrôle `bg-capture-scaled` qui attend le refus et se saute seul quand aucun écran n'est au-dessus de 100 % | Un contrôle de selftest ; une manipulation d'Arthur (changer l'échelle, la remettre) | Le contrôle ne tourne pas dans la configuration habituelle |
| B. Mesurer en plus, dans la même séance, ce que rendent `GetWindowRect`, le cadre DWM, le rectangle UIA et la taille de l'image `PrintWindow` | Une sonde courte | Aucune : elle dit si la capture peut être supportée plutôt que refusée |
| C. Supporter la capture d'une fenêtre étirée (remise à l'échelle comme WebRTC) | Code de capture et de correspondance des coordonnées, à valider sur écran à l'échelle | Chemin jamais mesuré ici ; à ne faire qu'après B |
| D. Laisser tel quel | Nul | Un chemin de refus jamais exécuté peut être faux dans les deux sens |

Recommandation : A et B dans la même séance. Le refus est le bon comportement par défaut d'après WebRTC ; C se décide sur les chiffres de B.

## 6. `observe: screenshot` en mode arrière-plan

Réponse courte : le contrat Anthropic ne connaît pas `observe` (c'est une extension du serveur) mais sa documentation recommande exactement ce geste : joindre une image au résultat d'une action pour économiser un aller-retour. Le motif du refus actuel (« montrerait l'écran de l'utilisateur ») n'est plus vrai depuis US-061. Une image de fenêtre coûte de 300 à 1 200 tokens, contre 90 pour un delta médian.

| Fait | Source | Statut |
|---|---|---|
| Le refus actuel et son motif : « observe screenshot montrerait l'écran de l'utilisateur, pas ta fenêtre cible » ; le commentaire dit que la décision revient à Arthur | `src/core/tools.zig:26-29` | vérifié |
| La branche `screenshot` de l'observation capture l'écran (`screen.screenshot(ctx, null)`) et, si la capture échoue, rend déjà l'action suivie de « Observation indisponible » | `src/core/a11y.zig:1869-1874` | vérifié |
| FR-42 : en mode arrière-plan, `screenshot` et `zoom` « ne renvoient que la fenêtre cible, mots de passe masqués » | `tasks/prd-background-mode.md:706` | vérifié |
| US-061 ne demande pas l'observation par image ; les Non-Goals ne l'excluent pas | `tasks/prd-background-mode.md:564-583`, `:780-793` | vérifié |
| FR-45 interdit au modèle de quitter le mode ou d'autoriser une action intrusive ; une capture de fenêtre est de classe `none` | `tasks/prd-background-mode.md:709`, `src/core/tools.zig:40-43` | vérifié |
| Le contrat des 17 outils ne contient pas `observe` : `screenshot` y a un schéma vide, les clics n'ont que `coordinate` et `text` | `tests/fixtures/toolset_20260801.json:5-17` | vérifié |
| `ui_act`, `window_set` et `app_launch` ne font pas partie des 17 outils : leur `observe` n'est tenu que par le PRD | `src/core/tools.zig:587`, `tasks/prd-background-mode.md:191` | vérifié |
| Anthropic : pour les actions autres que `screenshot` et `zoom`, « a short text such as OK is enough » | A1 | vérifié |
| Anthropic : « Claude typically finishes a batch with screenshot so it can observe the outcome [...]. When a batch doesn't end with one, your application can attach a screenshot as an extra image block on the last result in the batch [...], which saves a round trip » | A1 | vérifié |
| Anthropic propose de demander au modèle : « After each step, take a screenshot and carefully evaluate if you have achieved the right outcome » | A1 | vérifié |
| Coût d'une image : « An image, therefore, costs ⌈width / 28⌉ × ⌈height / 28⌉ visual tokens » | A2 | vérifié |
| Une image dans un résultat d'outil qui dépasse les limites du modèle est refusée, pas réduite : c'est à l'application de la réduire | A2 | vérifié |
| Le PRD utilise la même formule et vise « environ 1 200 tokens par image » | `tasks/prd-neo-compute.md:198`, `:244` | vérifié |
| Image d'un écran de 2560x1440 réduite à 1280x720 : 46 × 26 = 1 196 tokens. Avec `--screenshot-size 1920` : 69 × 39 = 2 691 | calcul par la formule A2 | déduit |
| Image d'une fenêtre : elle est à l'échelle du screenshot de son écran. Fenêtre de 1100x800 (taille de la sonde) : 550x400, soit 20 × 15 = 300 tokens. Fenêtre maximisée : environ 1 150 | `src/core/display.zig:268-281`, formule A2 | déduit |
| Delta après action : médiane de 90 tokens (23 à 215) ; contenu remplacé ou premier arbre : 900 à 1 900 tokens | `docs/decisions/0005-instructions-et-mesure-ep-003.md:13` | mesure du dépôt |
| Médiane de 96 tokens par delta au 2026-11-03, cible 150 au plus | `tasks/prd-background-mode.md:842` | mesure du dépôt |
| Capture d'une fenêtre de 2560x1440 recouverte : 30 ms au p95 | `docs/decisions/0013-mode-arriere-plan.md:430` | mesure du dépôt |

Arguments pour l'autoriser :
- Un aller-retour de moins quand l'agent veut voir le résultat, ce que la documentation Anthropic recommande.
- La seule vérification possible pour une application dont l'arbre dit peu (dessin, canevas).
- Le motif du refus est devenu faux, et le même paramètre marche dans les deux autres modes : un refus qui ment est pire qu'un refus.
- Le coût reste au choix de l'appelant : l'observation par défaut reste `delta`.

Arguments contre :
- De 3 à 13 fois le coût d'un delta médian, à chaque action si l'agent en prend l'habitude.
- Sur un Chromium recouvert, l'image jointe juste après l'action est celle d'avant (point 3) : c'est le cas où elle trompe le plus. La note « image figée » l'accompagne, mais l'agent paie une image qui ne prouve rien.
- La capture peut être refusée (arbre web non construit, fenêtre élevée, fenêtre étirée) alors que l'action a eu lieu : le résultat doit le dire sans passer pour un échec de l'action. La branche existante le fait déjà.
- C'est une extension de contrat du mode : PRD à amender (FR-42 ou une story), décision 0013 à compléter.

Options :

| Option | Coût | Faiblesse |
|---|---|---|
| A. Autoriser : en mode arrière-plan, `observe: screenshot` rend la capture de la fenêtre cible (recommandée) | Une branche dans `observeWith`, la table `observe_intrusive` retirée de trois outils, tests du cœur, un contrôle `selftest --background` ; amendement du PRD | Les arguments contre ci-dessus |
| B. Garder le refus, corriger son message (« utilise screenshot après l'action ») | Un texte | Un aller-retour de plus pour le même résultat |
| C. Garder tel quel | Nul | Le message affirme une chose fausse |

Recommandation : A. Garder `delta` par défaut et dire dans les `instructions` du mode que l'image coûte plus et qu'elle peut être figée sur un Chromium recouvert.

## 7. Fixtures de `tools/list`

Réponse courte : vérifié, rien d'autre n'a changé. Les deux fixtures ne diffèrent de `HEAD` que par la propriété optionnelle `window` de `screenshot` et de `zoom` ; la fixture du contrat est intacte, et le test de contrat accepte une propriété en plus tant qu'elle est optionnelle.

| Fait | Source | Statut |
|---|---|---|
| `git diff --stat -- tests/fixtures` : deux fichiers, une ligne chacun | commande exécutée | vérifié |
| Une fois retirées les deux chaînes `,"window":{"type":"string","description":"Handle: that window alone, even covered"}` (83 octets) et `,"window":{"type":"string","description":"Handle: region of that window's screenshot"}` (86 octets), chaque fixture est identique à `HEAD` à l'octet près | `sed` puis `cmp` contre `git show HEAD:…` | vérifié |
| `tests/fixtures/toolset_20260801.json` est identique à `HEAD` (`git diff --quiet`) ; dernier commit qui y touche : `c88fe46` | commande exécutée | vérifié |
| Dans le contrat, `screenshot` a `"properties": {}` et `zoom` a `region` seule, requise | `tests/fixtures/toolset_20260801.json:5-8` | vérifié |
| Le test de contrat compare chaque propriété de la fixture (type, enum, items, bornes) et la liste `required` ; une propriété absente de la fixture est une extension, qui doit seulement ne pas être requise (FR-01) | `src/core/registry_test.zig:69-115`, `:117-132` | vérifié |
| `window` est optionnelle dans les deux outils (`?[]const u8 = null`) ; `screenshot` portait déjà l'extension `display` | `src/core/tools.zig:44-47`, `:66-69` | vérifié |
| Les fixtures de `tools/list` sont comparées à l'octet près à la sortie du registre | `src/core/background_test.zig:144-152` | vérifié |
| `zig build test -Dtest-filter="computer_toolset_20260801"` : 2 tests sur 2 passent ; `-Dtest-filter="tools/list"` : 2 sur 2 ; codes de sortie 0 | commandes exécutées le 2026-11-13 | vérifié |
| FR-22, sortie de `-Dtest-filter="budgets"` (code de sortie 0) : « tools/list: 9849 bytes, about 4030 tokens (limit 4500); alwaysLoad definitions about 1339 tokens (limit 1500) » | commande exécutée | vérifié |
| Même sortie pour le mode arrière-plan : « background tools/list: 4921 bytes, about 2014 tokens (limit 4500); alwaysLoad definitions about 732 tokens (limit 1500) » | commande exécutée | vérifié |
| Effet du paramètre : la liste a11y passe de 9 680 à 9 849 octets, soit environ 69 tokens de plus (ratio 2,444 octets par token de `bench/token_calibration.json`) ; `screenshot` étant toujours chargé, environ 34 de ces tokens entrent dans le budget `alwaysLoad` | `wc -c` sur les deux versions, calcul | déduit |
| Marge restante : environ 470 tokens sur le total, 161 sur `alwaysLoad` | calcul | déduit |

Rien à trancher sur le fond. Le seul point d'attention est la marge `alwaysLoad` : 161 tokens, soit quatre ou cinq paramètres décrits de cette taille.

## 8. Synthèse

| Point | Option recommandée | Confiance | Ce qui changerait la recommandation |
|---|---|---|---|
| 1. Balayage en échec | Refuser la capture de fenêtre quand le masque n'est pas garanti (échec du balayage, fenêtre élevée, fenêtre qui ne répond pas) | Bonne | Une sonde montrant que `PrintWindow` échoue déjà sur toute fenêtre élevée (le refus ne servirait alors que l'erreur passagère), ou des refus fréquents sur des fenêtres saines |
| 2. Bruit de `bg-act` | Reprendre sa seule référence sur 5 passes complètes, à la demande d'Arthur ; comparaison alternée avec `HEAD` comme marche à suivre en cas d'échec ; seuil tiré du bruit si un second scénario fait de même | Moyenne | Une comparaison alternée montrant une vraie régression ; un second scénario bruité (passer alors au seuil par scénario) |
| 3. Ligne « image figée » | La garder, et documenter la politique `WindowOcclusionEnabled` comme réglage côté utilisateur | Bonne | Un changement de Chromium qui ferait répondre une fenêtre recouverte à une capture externe |
| 4. Refus « arbre web » | Garder le refus, réécrire le conseil : bande visible d'abord, `ui_tree` facultatif | Bonne | Une mesure montrant qu'un appel `ui_tree` fait venir l'arbre d'un Chromium recouvert là où le balayage n'y arrive pas |
| 5. Fenêtre étirée | Garder le refus ; l'exercer et mesurer en une séance avec le second écran à 125 % et la fenêtre `dpi_unaware` existante | Moyenne | La mesure : si l'image de `PrintWindow` a la taille physique, le refus est inutile ; si elle a la taille propre de la cible, supporter la remise à l'échelle devient possible |
| 6. `observe: screenshot` | L'autoriser en mode arrière-plan avec la capture de la fenêtre cible, `delta` restant le défaut | Moyenne | La campagne US-063 montrant que l'agent en abuse (coût) ou se trompe sur des images figées |
| 7. Fixtures | Rien à changer : le seul écart est `window`, optionnel et compatible avec le contrat | Haute | Rien de prévisible |

## 9. Sources

Microsoft Learn :

- M1 : Windows Integrity Mechanism Design, <https://learn.microsoft.com/en-us/previous-versions/dotnet/articles/bb625963(v=msdn.10)>
- M2 : Security Considerations for Assistive Technologies, <https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-securityoverview>
- M3 : PrintWindow, <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-printwindow>
- M4 : SetWindowDisplayAffinity, <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowdisplayaffinity>
- M5 : Edit Control Styles, <https://learn.microsoft.com/en-us/windows/win32/controls/edit-control-styles>
- M6 : EM_SETPASSWORDCHAR, <https://learn.microsoft.com/en-us/windows/win32/controls/em-setpasswordchar>
- M7 : Automation Element Property Identifiers, <https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-automation-element-propids>
- M8 : GetWindowRect, <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect>
- M9 : High DPI Desktop Application Development on Windows, <https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows>
- M10 : DPI_AWARENESS_CONTEXT, <https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context>
- M11 : GetDpiForWindow, <https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow>
- M12 : GetDpiForMonitor, <https://learn.microsoft.com/en-us/windows/win32/api/shellscalingapi/nf-shellscalingapi-getdpiformonitor>
- M13 : UI Automation and Screen Scaling, <https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-screenscaling>
- M14 : Mixed-Mode DPI Scaling and DPI-aware APIs, <https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-improvements-for-desktop-applications>
- M15 (délégué) : PasswordBox.PasswordRevealMode, <https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.xaml.controls.passwordbox.passwordrevealmode>
- M16 (délégué) : filtrage de Recall, <https://support.microsoft.com/en-us/windows/filtering-apps-websites-and-sensitive-information-in-recall-a4c28bee-e200-4a4a-b60d-c0522b404a5b> et <https://learn.microsoft.com/windows/client-management/recall-sensitive-information-filtering>
- M17 (délégué) : Screen capture (Windows.Graphics.Capture), <https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture>
- M18 (délégué) : propriétés RDP, <https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties>
- M19 (délégué) : réglages DPI par le registre (Windows 8.1), <https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-8.1-and-8/dn528846(v=win.10)>
- M20 (délégué) : politique UIAccess, <https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-10/security/threat-protection/security-policy-settings/user-account-control-only-elevate-uiaccess-applications-that-are-installed-in-secure-locations>

Les pages M2 à M14 ont été lues dans leur source Markdown (dépôts `MicrosoftDocs/win32` et `MicrosoftDocs/sdk-api`), M1 dans sa page HTML.

Code :

- `chromium:` renvoie à <https://github.com/chromium/chromium/blob/144ac3d55942c0be6bb854711b22ffd5a646e506/> suivi du chemin (miroir officiel de chromium.googlesource.com). Les fichiers ont été lus sur `main` quelques minutes avant de relever ce commit : un décalage d'une ou deux lignes est possible.
- `webrtc:` renvoie à <https://webrtc.googlesource.com/src/+/refs/heads/main/> suivi du chemin.
- `vscode:` renvoie à <https://github.com/microsoft/vscode/blob/3c1448be1e02e8b4005233b8a447db03558d5029/> suivi du chemin.
- `microsoft-ui-xaml:` renvoie à <https://github.com/microsoft/microsoft-ui-xaml/blob/main/> suivi du chemin.
- `electron:` renvoie à <https://github.com/electron/electron/blob/main/> suivi du chemin.

Anthropic :

- A1 : Computer use tool, <https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool>
- A2 : Vision, section « Resolution and token cost », <https://platform.claude.com/docs/en/build-with-claude/vision>

Outils de mesure :

- P1 : benchstat, <https://github.com/golang/perf/blob/master/cmd/benchstat/main.go>
- P2 : Google Benchmark, <https://github.com/google/benchmark/blob/main/docs/tools.md>
- P3 : LLVM LNT, <https://github.com/llvm/llvm-lnt/blob/main/lnt/server/reporting/analysis.py>
- P4 : rustc-perf, <https://github.com/rust-lang/rustc-perf/blob/master/docs/comparison-analysis.md>
- P5 : Criterion.rs, <https://bheisler.github.io/criterion.rs/book/analysis.html> (lu) et <https://docs.rs/criterion/latest/criterion/struct.Criterion.html> (délégué)
- P6 (délégué) : Skia Perf et Pinpoint, <https://skia.googlesource.com/buildbot/+/main/perf/go/stepfit/stepfit.go> et <https://skia.googlesource.com/buildbot/+/main/pinpoint/go/compare/compare.go>

## 10. Lacunes de cette recherche

- Une seule mesure a été faite sur le bureau, après la recherche : l'affinité d'affichage face à `PrintWindow` (section 1.5). Deux questions n'ont de réponse que par une sonde, courte : ce que UIA rend d'une fenêtre élevée (erreur ou arbre vide) et ce que `PrintWindow` rend d'une fenêtre élevée. Une troisième demande un écran au-dessus de 100 % (point 5).
- Les lignes « vérifié (délégué) » viennent de sous-agents de recherche et n'ont pas été relues : Recall, Windows.Graphics.Capture, `PasswordRevealMode`, les propriétés RDP, le registre DPI de Windows 8.1, les valeurs par défaut de Criterion.rs, Skia Perf et Pinpoint. Aucune recommandation ne repose sur elles seules.
- Chromium : la chaîne côté processus de rendu (page `kHidden`, donc plus de mise à jour visuelle, donc plus de mise à jour de l'arbre) est déduite de deux commentaires du code et des mesures du dépôt, pas suivie ligne à ligne. L'endroit où la politique `WindowOcclusionEnabled` est lue par le navigateur n'a pas été retrouvé ; seule sa définition a été lue.
- Edge n'a pas été lu : ses politiques et son bouton de révélation sont supposés suivre Chromium.
- Le lien entre le style `ES_PASSWORD` et la valeur de `IsPassword` pour un EDIT Win32 n'a pas été lu dans une source : le fournisseur UIA des contrôles Win32 n'est pas public.
- Les pages de Chromium sur la surveillance des performances, BenchmarkDotNet et le dépôt de performances de .NET n'ont pas été lus.
- La première exécution du test filtré `budgets` a affiché, après ses deux lignes de mesure, une ligne « failed command » avec un code de sortie 0 ; la seconde exécution n'a rien affiché (résultat en cache). Les tests filtrés lancés ensuite avec `--summary all` passent tous.
