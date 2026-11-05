# 0009 : perception enrichie, mesures A7 et A9 (EP-005)

- Statut : appliqué ; US-022 et US-025 décidés par Arthur le 2026-11-05 (voir la fin)
- Date : 2026-11-05
- Story : US-022, US-023, US-024, US-025 (`tasks/prd-windows-mcp-parity.md`, hypothèses A7 et A9)

## A7 : lecture de RangeValue et Scroll (US-022)

Le critère prévoit une seconde requête `FindAllBuildCache` sur le sous-arbre, avec une condition OR sur `IsRangeValuePatternAvailable` et `IsScrollPatternAvailable`. Mesurée sur la barre des tâches (scénario `snapshot`), cette requête coûte environ 15 ms p95 à elle seule : le provider reparcourt tout l'arbre pour évaluer la condition. A7 (≤ 5 ms p95) est donc **fausse** pour cette technique.

Technique retenue, avec le même résultat pour le modèle :

- Le cache principal garde ses 12 propriétés. Il demande en plus les **patterns** RangeValue, Scroll et TextPattern (`position_patterns` dans `src/backend/windows/uia.zig`) : un pattern mis en cache n'est pas une propriété et ne coûte rien quand l'élément ne l'expose pas.
- Le parcours note les éléments dont le pattern est présent ; `readPositions` lit leurs six propriétés (valeur, minimum, maximum, lecture seule, pourcentages vertical et horizontal) par un `BuildUpdatedCache` par élément, 64 éléments au plus.
- Avant chaque aller-retour, la fenêtre racine de l'élément doit répondre à `WM_NULL` dans le timeout provider (200 ms, `responsive`) ; sinon, ou sur un `UIA_E_TIMEOUT`, la lecture s'arrête : les champs restants sont omis, l'arbre porte `{partial: timeout}` et la sélection n'est pas lue.

Implémentation littérale essayée à la demande d'Arthur (2026-11-05) : un `FindAllBuildCache` par racine, depuis le plus petit sous-arbre qui contient les éléments concernés, condition `IsRangeValuePatternAvailable` OR `IsScrollPatternAvailable`, les six valeurs et le RuntimeId en cache, aucune requête quand la lecture principale n'a trouvé aucun pattern. Mesures (`range and scroll round trip`, p95) : Bloc-notes 25,0 ms (total 55 ms, budget 50 ms), `notepad-menu` 40,1 ms (total 95 ms), Chrome 4,5 ms, `chrome-text` 4,2 ms. Dans le Bloc-notes, les deux éléments concernés n'ont pour ancêtre commun que la fenêtre, et la requête parcourt tout son arbre brut ; la restreindre à la vue contrôle (AND) ne change rien (25,9 ms). Le critère 7 est donc impossible à tenir avec cette technique, et la technique par élément est gardée.

Timeout observé pour la première fois (selftest `ui-range-timeout`, processus `selftest-stall`) : deux trackbars Win32 d'un autre processus ; le `TBM_GETRANGEMAX` du premier, dernier message de son aller-retour, bloque le thread 1,5 s. Trois constats :
- UI Automation n'applique pas `TransactionTimeout` à un aller-retour vers une fenêtre dont le thread s'arrête après la lecture principale : sans la vérification ci-dessus, le snapshot attendait 1,5 s et rendait toutes les plages ;
- un provider UIA natif lent dans `get_Value` (600 ms puis 1,5 s) est attendu en entier, sans `UIA_E_TIMEOUT` ;
- les 203 ms du selftest `ui-timeout` viennent de `responsive` avant la lecture, pas du timeout UIA.

Avec la vérification : arbre partiel en 219 à 222 ms sur trois passages, premier curseur avec sa plage, second sans. Un thread qui s'arrête au milieu d'un aller-retour reste attendu : seule une lecture sur un autre thread avec délai pourrait l'abandonner.

Surcoût mesuré lors de la validation finale, vérification `responsive` comprise (`bench: <scénario> range and scroll round trip`, p95) : barre des tâches (`snapshot`) 0 µs sur 200 snapshots (aucun élément concerné), Bloc-notes 518 µs, `notepad-menu` 969 µs, Chrome 341 µs, `chrome-text` 336 µs, Firefox 0 µs. Totaux p95 : `notepad` 32,9 ms, `notepad-menu` 44,8 ms, `chrome` 23,7 ms, `chrome-text` 31,0 ms ; `bench --check` sans régression.

## US-023 : racines du snapshot

- Ordre : la fenêtre au premier plan d'abord, puis les autres racines dans l'ordre z (`extraRoots` dans `src/backend/windows/window.zig`, 8 au plus). Une racine est retenue si elle est visible, non masquée (cloaked), de 4 px au moins, et soit possédée par la cible (chaîne `GW_OWNER`), soit un menu `#32768`, soit un popup du même thread sans `WS_CHILD`, sans barre de titre complète et sans `WS_EX_APPWINDOW`.
- Une fenêtre passée explicitement par `window` reçoit aussi ses racines.
- Les menus XAML du Bloc-notes vivent dans un hôte popup déjà lu dans l'arbre de la fenêtre : `alreadyRead` (RuntimeId de l'élément et de ses enfants) et l'ensemble `seen` évitent de les lire deux fois, et un hôte sans nom réduit à sa racine est retiré.
- `{modal}` : pour une racine supplémentaire, `WindowPattern.IsModal` ou un propriétaire désactivé ; pour la fenêtre elle-même, le propriétaire désactivé seulement.

## US-024 : texte des pages web

- Avec `text: true`, le sous-arbre du document est relu dans la vue contenu (`FindAllBuildCache` sur l'élément, cache filtré par `ContentViewCondition`) et remplace en place le sous-arbre de la vue contrôle.
- Chromium (Chrome 156.0.8078.80) n'expose pas le texte qui suit un lien dans un `<li>` comme nœud texte : il le replie dans le nom de l'élément de liste (« Article 1 : note de synthèse numéro 1 »). En mode texte, `prune` garde donc un conteneur non actionnable dont le nom est plus long que celui de son unique descendant gardé, et `uitree.textLine` compte ces lignes comme du texte (400 caractères, décompte des lignes omises).
- `page=` : Chrome expose ScrollPattern sur le document (vérifié ; Firefox non mesuré en mode texte). Un document plus court que son viewport n'est pas défilable (`VerticallyScrollable` faux, pourcentage -1) : il est affiché `page=0% début fin`, les deux bouts étant visibles.
- Le budget « `zig build bench -- chrome` avec `text: true` » est mesuré par un scénario distinct, `chrome-text`, pour garder la série historique de `chrome` comparable à sa baseline.

## A9 : Firefox (US-025)

Sonde du 2026-11-05 sur la machine de référence (scénario `zig build bench -- firefox`, profil neuf dans `.zig-cache/bench-firefox-profile`) :

- Version : **Mozilla Firefox 157.0** (x64, fr).
- Firefox expose son interface et son document par l'**UIA natif** : la fenêtre `MozillaWindowClass` porte la valeur `chrome://browser/content/browser.xhtml`, le document `neo-compute reference page` et ses liens, champs, case à cocher, liste déroulante et éléments de liste sont lus par le chemin UIA existant (495 éléments, `ui_tree` p95 environ 36 ms pour un budget de 150 ms). A9 est **vraie**, branche UIA.
- Conséquence initiale : le repli MSAA n'était pas construit. La revue de EP-005 l'a rouvert (section suivante), sur décision d'Arthur.
- Avec `accessibility.force_disabled = 1` dans `user.js`, Firefox n'expose que le cadre que Windows construit pour lui (9 éléments : fenêtre, barre de titre, boutons système ; ni barre d'outils ni document). Le backend reconnaît ce cas (`firefoxNoTree` : classe `MozillaWindowClass`, aucun `document` ni `toolbar`) et `ui_tree` ajoute « Firefox n'expose pas son arbre d'accessibilité : vérifie accessibility.force_disabled ou utilise screenshot ».
- Le scénario `firefox` écrit un `user.js` sans pages de premier lancement ni invite de navigateur par défaut, et renvoie « Firefox absent de la machine » quand `firefox.exe` manque.
- Avec `accessibility.force_disabled = 1`, observé de nouveau en revue : `ui_tree` renvoie le cadre (7 lignes) puis le message ci-dessus. Le message « Firefox absent de la machine » est observé avec un chemin d'exécutable volontairement faux : le scénario sort en `unsupported` sans faire échouer les autres.

## US-025 : Firefox sans UIA natif (revue de EP-005)

Sondes de revue du 2026-11-05, profils jetables, préférence `accessibility.uia.enable = 0` acceptée par Firefox (reprise dans `prefs.js`) :

- **Windows sert alors Firefox par son proxy MSAA vers UIA.** La description du fournisseur (`UIA_ProviderDescriptionPropertyId`) de la fenêtre et du document nomme `Microsoft: MSAA Proxy (IAccessible2)` ; avec l'UIA natif, elle nomme `Unidentified Provider (unmanaged:xul.dll)`. Le chemin UIA existant lit le document, mais le proxy dégrade la sortie : les feuilles de texte (rôle MSAA `ROLE_SYSTEM_TEXT`, sans `STATE_SYSTEM_FOCUSABLE`) deviennent des `edit`, donc des libellés qui passent pour des champs, et environ 530 éléments d'une page Nouvel onglet préchargée et cachée sont lus puis remontés par `ui_find` (`{offscreen} @0,0,0,0`). Le proxy pose bien `IsPassword` sur un champ `STATE_SYSTEM_PROTECTED` (état `0x20100000`), et ses RuntimeId (`2a.<hwnd>.4.<identifiant Firefox>`) restent identiques d'une lecture à l'autre.
- **Un parcours MSAA direct est hors budget.** Sonde C (`AccessibleObjectFromWindow(OBJID_CLIENT)`, puis rôle, nom, état, position et `AccessibleChildren` par nœud, 20 passes) : page de référence 750 nœuds, 4 116 appels, p95 948 ms, soit environ 220 µs par appel entre processus ; page du mot de passe 428 nœuds, p95 546 ms. Le budget de US-025 est 150 ms.
- **Lecture par le proxy, mesurée en C** (12 propriétés et patterns du cache principal) : vue contrôle p50 146 à 166 ms ; vue contrôle restreinte aux éléments à l'écran, p50 127 à 131 ms. L'UIA natif lit la même page en 24 ms.

Technique retenue par Arthur (voie 1, « hybride ») :

- Le proxy est détecté avant la lecture, par une lecture de `ProviderDescription` sur la fenêtre d'une classe `MozillaWindowClass` (`windowProxied` dans `src/backend/windows/uia.zig`).
- Une fenêtre servie par le proxy est lue avec un cache à part (`msaaCache`) : les 12 propriétés du cache principal, plus le rôle et l'état MSAA (`UIA_LegacyIAccessibleRolePropertyId`, `UIA_LegacyIAccessibleStatePropertyId`), sur la vue contrôle restreinte aux éléments à l'écran. Le cache principal reste à 12 propriétés ; le proxy dérive déjà toutes ses propriétés du rôle et de l'état MSAA.
- `fixMsaa` reclasse en `text` un `edit` de rôle `ROLE_SYSTEM_TEXT` non focusable, traite `STATE_SYSTEM_PROTECTED` comme un mot de passe (valeur retirée), et retire un sous-arbre hors écran sans rectangle.
- Sur un élément lu par le proxy, `ui_act` `invoke` appelle `LegacyIAccessiblePattern.DoDefaultAction`, que le proxy transmet à `accDoDefaultAction` ; `set_value` renvoie « Action set_value indisponible sur cet élément Firefox : clique puis utilise type ».
- Un parcours `IAccessible` propre à neo-compute n'est pas construit : il coûterait environ six fois le budget pour les mêmes données.

Mesures après la mise en œuvre (`zig build bench -- firefox-msaa`, profil `.zig-cache/bench-firefox-msaa-profile`) : 214 éléments, 151 lignes, p50 123 ms, p95 132 ms pour 150 ms, corrections 70 µs. `firefox` (UIA natif) : p95 44 ms. Vérifications par le serveur sur une page jetable, UIA natif coupé :
- libellés en `text`, deux `edit` (identifiant, mot de passe), comme avec l'UIA natif ;
- `ui_tree` `since: last` sans changement : IDs stables ;
- `invoke` coche la case et déclenche le `onclick` du bouton ;
- `set_value` renvoie le message ci-dessus ;
- le champ mot de passe, peint en magenta, est noir sur 1 830 pixels sur 1 830 dans `screenshot`, contre 12 sur 1 830 à côté ;
- la valeur aléatoire du champ n'apparaît dans aucune sortie.

## Points soumis à Arthur

1. **US-022, décidé par Arthur le 2026-11-05** : implémentation littérale exigée si elle est possible. Elle ne l'est pas (Bloc-notes 55 ms p95 pour un budget de 50 ms, mesures ci-dessus) : la technique par élément reste, critère 1 amendé dans le PRD (version 1.2), et le critère 5 tient grâce à la vérification `responsive`.
2. **US-025, voie 1 décidée par Arthur le 2026-11-05** : critères 3 et 4 amendés dans le PRD (données MSAA lues par le proxy UIA et `LegacyIAccessible`, clé = RuntimeId du proxy).
