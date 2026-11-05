# 0010 : types refusés par app_launch et bench de la barre des tâches relatif au provider (EP-006)

- Statut : décidé par Arthur le 2026-11-05, appliqué
- Date : 2026-11-05
- Story : US-029 (`tasks/prd-windows-mcp-parity.md`, FR-25, version 1.3) ; gate de bench de EP-006 (US-026, `window_list` et la barre des tâches)

# Partie 1 : FR-25, liste 2 et AssocIsDangerous

## Constat

La revue de EP-006 a montré que la liste versionnée 1 de US-029 et `PATHEXT` laissaient passer des types qui exécutent du code, installent quelque chose ou ouvrent une connexion dès qu'on les ouvre :

- aide compilée (`.chm`, du HTML avec script), thèmes (`.theme`, `.themepack`, `.deskthemepack`, qui chargent ressources et curseurs distants), utilitaires de résolution des problèmes (`.diagcab`, `.diagpkg`, `.diagcfg`) ;
- paquets d'applications (`.msix`, `.msixbundle`, `.appx`, `.appxbundle`, `.appinstaller`) ;
- fichiers de recherche et de paramètres du shell (`.library-ms`, `.search-ms`, `.searchconnector-ms`, `.settingcontent-ms`) ;
- scripts d'interpréteurs installés, qui enregistrent leur propre extension (`.py`, `.pyw`, `.pyz`, `.pyzw`, `.sh`, `.bash`, `.jar`, `.ahk`, `.au3`) ;
- trouvés par la sonde ci-dessous : sites épinglés (`.website`, cousin de `.url`), compléments Office (`.xll` chargé par Excel, `.vsto`), applications de navigateur (`.xbap`, de la famille de `.application`), connexions Bureau à distance (`.rdp`).

## Décision

1. **Liste 2.** Les extensions ci-dessus s'ajoutent à la liste 1 (`denied_extensions` dans `src/core/launch.zig`, critère de US-029 dans le PRD).
2. **Contrôle dynamique.** Après la résolution du nom long, un fichier est refusé si Windows classe son type comme dangereux (`AssocIsDangerous` : sa liste intégrée et `FTA_AlwaysUnsafe`) ou si la commande par défaut de son extension exécute le fichier lui-même (`"%1" %*`, cas de `.pif`). Le backend l'expose par `unsafeType`, sur le thread STA du shell ; si le shell est occupé, le type est refusé.
3. Le message reste celui de US-029 : « app_launch n'ouvre que des documents et des dossiers : <ext> refusé ».

## Sonde du 2026-11-05 (machine de référence)

`AssocIsDangerous` par extension :

- classées dangereuses : `.inf`, `.gadget`, `.chm`, `.theme`, `.library-ms`, `.settingcontent-ms`, `.pif`, `.scr`, `.exe`, `.ws`, `.wsc`, `.sct`, `.iso`, `.vhd`, `.vhdx`, `.img` ;
- non classées : `.txt`, `.log`, `.pdf`, `.md`, `.docx`, `.png`, `.json`, `.zip`, `.html`, `.ini`, `.mht`, et aussi `.diagcab`, `.msix`, `.appx`, `.appinstaller`, `.search-ms`, `.py`, `.sh`, `.jar`, `.ahk`, `.xll`, `.website`, `.xbap`, `.vsto`, `.rdp`.

Les deux mécanismes se complètent : la liste couvre ce que Windows ne classe pas, et `AssocIsDangerous` couvre ce que la liste ne nomme pas, en particulier les images disque (`.iso`, `.vhd`, `.vhdx`, `.img`), dont le montage contourne la Mark of the Web. Les documents courants ne sont pas touchés.

Vérifié par le serveur réel sur des fichiers jetables : `.gadget`, `.iso`, `.inf` (dynamique), `.theme`, `.py`, `.msix`, `.search-ms`, `.website` (liste) sont refusés, et aucun processus n'est lancé. Test du cœur : `.gadget` (refusé par le seul contrôle dynamique du backend factice) dans `src/core/windows_test.zig` ; chaque extension des listes 1 et 2 dans `src/core/launch.zig`.

## Limite connue

Un interpréteur dont l'extension ne figure dans aucune liste et que Windows ne classe pas (par exemple `.rb` ou `.pl` associés à leur interpréteur) reste ouvert. Une prochaine story pourrait refuser tout type dont la commande par défaut lance un interpréteur connu (`python.exe`, `java.exe`, `node.exe`, `wscript.exe`, etc.).

# Partie 2 : bench de la barre des tâches relatif au provider

## Constat

À la revue de EP-006, `zig build bench -- --check bench/baseline.json` échouait sur les deux seuls scénarios qui lisent la barre des tâches : `snapshot` de 27 à 38 ms p95 et `ui_tree` de 38 à 40 ms, pour des références de 24,0 ms et 29,9 ms (EP-003). Tous les autres scénarios passaient, et les budgets absolus (50 ms) tenaient.

Mesures alternées du 2026-11-05 (`zig build bench -- snapshot`, p95) :

| Arbre | p95 |
|---|---|
| EP-006 (arbre de travail) | 28,0 à 38,1 ms |
| HEAD (207a6e4, EP-005) | 28,1 à 28,7 ms |
| Avant EP-005 (0fbb05b) | 30,0 à 32,9 ms |
| Commit qui a enregistré la baseline (3a15756, EP-003) | 31,1 à 32,1 ms |

Le code qui a fixé 24,0 ms en mesure aujourd'hui 31 à 32 : c'est l'état de la machine qui a changé, pas le code. La sonde C de US-001 (3 propriétés) n'a pas bougé (22 ms p50, 23,6 à 24,5 ms p95, comme en US-001), mais la lecture complète, elle, a ralenti chez le provider de la barre des tâches.

Pour s'en assurer, `probe/probe_c.c` gagne un mode `full` : la même lecture que le tour principal du snapshot de neo-compute (`FindAllBuildCache` sur l'élément fenêtre, sous-arbre de la vue contrôle, 12 propriétés et 9 patterns en cache). En alternance, ce témoin suit neo-compute : 32,9 contre 32,6 ms, 38,9 contre 35,0 ms, et 54,4 contre 40,9 ms sur un tour bruité. Neo-compute ne coûte pas plus que le provider pour la même lecture.

## Décision (Arthur, 2026-11-05 : scénarios relatifs plutôt que baseline réenregistrée)

1. `snapshot` et `ui_tree` sont **relatifs au provider** (`provider_relative` dans `src/core/bench.zig`). Autour de chaque série, le bench lance `probe_c.exe <n> <hwnd> full` avant et après, avec autant d'échantillons que la série, et garde la moyenne des deux p95.
2. Un étage UIA de ces scénarios (`accessibility`, `dispatch`, `total`) au-dessus de 110 % de sa référence passe encore s'il reste sous 110 % de ce témoin. Le rapport l'écrit (`provider-relative`). Sans témoin, la comparaison reste stricte.
3. Les autres étages (`parse`, `diff`, `serialize`, `write`), les budgets absolus et les autres scénarios ne changent pas. `bench/baseline.json` n'est pas réécrit.

## Validation

Bench complet après le dernier changement : `snapshot` 35,7 ms pour un témoin de 35,5 ms, `ui_tree` 36,7 ms pour 37,0 ms, « no regression against bench/baseline.json ». Tests du cœur dans `src/core/bench_test.zig` : un étage UIA passe sous le témoin, échoue au-dessus ou sans témoin ; `diff` reste strict ; le budget de 50 ms reste absolu ; un autre scénario ignore le témoin.
