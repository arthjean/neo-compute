# 0013 : contrat du mode arrière-plan

- Statut : décidé par Arthur le 2026-11-12
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
  - Texte du libellé en mode arrière-plan : « neo-compute agit en arrière-plan : <raccourci> met en pause » (US-046).

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
