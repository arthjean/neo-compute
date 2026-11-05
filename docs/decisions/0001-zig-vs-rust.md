# 0001 : Zig ou Rust pour la couche COM

- Statut : décidé, **Zig 0.17.0 retenu**
- Date : 2026-11-03
- Story : US-001 (sonde), complété par US-005 (bindings générés)
- Machine : Windows 11 Pro 10.0.26300, 2 écrans 2560x1440 sur RTX 4070 Ti SUPER, iGPU AMD Radeon sans sortie active

## Contexte

Le PRD suppose (A1) que Zig 0.17 pilote COM de façon fiable alors que la std ne fournit ni `CoInitializeEx` ni `HRESULT`. La sonde `zig build probe` (`probe/probe.zig`) appelle UIA et DXGI Desktop Duplication par des vtables COM, d'abord écrites à la main (`probe/com_manual.zig`), puis générées depuis win32metadata (US-005). Une sonde témoin en C (`probe/probe_c.c`, `zig build probe-c`) exécute le même snapshot contre les headers mingw-w64 livrés avec Zig.

Commande de référence, build ReleaseFast :

```
zig build -Doptimize=ReleaseFast
zig-out/bin/probe.exe --leak 10000 --samples 200 --frames 100
zig-out/bin/probe_c.exe 200 taskbar
```

La sortie complète du run de référence est dans [`0001-probe-run.txt`](0001-probe-run.txt) (lignes d'éléments tronquées).

## Mesures

| Critère US-001 | Mesure | Seuil | Résultat |
|---|---|---|---|
| Snapshot UIA de la fenêtre au premier plan via `IUIAutomationCacheRequest` (Name, ControlType, BoundingRectangle) | 66 éléments lus et écrits sur stderr | lecture complète | OK |
| 100 frames DXGI par écran, copie BGRA à la résolution physique | `\\.\DISPLAY1` 100/100, `\\.\DISPLAY2` 100/100, 2560x1440 BGRA | 100 par écran | OK |
| Dérive private bytes sur 10 000 itérations snapshot + frame | +3 176 KB (`GetProcessMemoryInfo`, après 200 itérations de préchauffage) | < 5 MB | OK |
| Dérive de handles sur 10 000 itérations | -5 (`GetProcessHandleCount`) | 0 | OK |
| Fenêtre fermée pendant le snapshot | 100/100 `error.ElementNotAvailable`, handles -2 sur la seconde moitié | erreur typée, ni crash ni fuite | OK |

Latence du même snapshot (barre des tâches `Shell_TrayWnd`, 34 éléments, 200 échantillons), runs entrelacés :

| Run | C p50 | C p95 | Zig p50 | Zig p95 |
|---|---|---|---|---|
| 1 | 30,5 ms | 47,8 ms | 24,4 ms | 34,5 ms |
| 2 | 21,4 ms | 23,7 ms | 22,8 ms | 24,5 ms |
| 3 | 21,7 ms | 23,5 ms | 22,9 ms | 24,9 ms |

Zig et C paient le même coût, à la variance du système près : le goulot est le provider UIA d'Explorer, pas le langage. Le premier run des deux côtés a été perturbé par la charge de la machine.

## Observations

1. **Un défaut de vtable, corrigé à la première tentative.** Le premier lancement a planté (`Segmentation fault at address 0x7535` dans `uiautomationcore.dll`) : les index de `IUIAutomation` avaient été relevés en base 1, ce qui décalait `CreateCacheRequest` d'un slot (appel de `CreateTrueCondition`). C'est une erreur de transcription manuelle, exactement ce que le générateur de US-005 supprime, pas un défaut de Zig.
2. **`FindAllBuildCache` sur une fenêtre détruite renvoie `S_OK` et un tableau vide.** Seule une lecture non cachée (`get_CurrentName`) renvoie `UIA_E_ELEMENTNOTAVAILABLE` (0x80040201). Le snapshot se termine donc par une lecture de vivacité de la racine. À reprendre dans US-011.
3. **Tendance mémoire à surveiller.** La dérive reste sous le seuil, mais elle est linéaire, environ 0,3 MB par 1 000 itérations (149 092 KB à 2 000, 151 540 KB à 10 000). Extrapolée à une session de 8 h, elle pourrait dépasser la NFR de 10 MB. À attribuer (cache client UIA ou sonde) dans le worker UIA de US-011.
4. **A5 partiellement validée.** Les deux sorties actives appartiennent à la RTX 4070 Ti SUPER ; l'iGPU AMD n'expose aucune sortie attachée sur cette machine, donc le cas « duplication sur l'iGPU » n'a pas pu être exercé. US-006 doit le reprendre si un écran est branché sur l'iGPU.
5. Sur la fenêtre au premier plan (un terminal GPUI dont l'arbre change en continu), le provider renvoie parfois `UIA_E_ELEMENTNOTAVAILABLE` en cours de boucle, côté C comme côté Zig. L'erreur remonte typée, sans crash.

## État du Rust Switch Gate

| # | Condition | État |
|---|---|---|
| 1 | US-001 échoue après 2 tentatives sur un critère bloquant | Non : un crash de vtable (erreur de transcription), corrigé à la première correction |
| 2 | Dérive > 5 MB ou handles > 0 sur 10 000 itérations | Non : +3,2 MB, -5 handles |
| 3 | 3 défauts distincts imputables à la couche COM Zig, chacun > 2 tentatives | Compteur : 3 défauts (index de vtable, type de `UIA_E_ELEMENTNOTAVAILABLE`, comparaison signée de `UIA_E_TIMEOUT` en revue EP-005), 1 tentative chacun, donc 0 défaut au-delà de 2 tentatives. À tenir à jour jusqu'à la fin du PRD |
| 4 | Le générateur US-005 ne produit pas les interfaces requises en 2 sessions | Faux : toutes les interfaces de la liste sont générées en 1 session (section US-005) |

## Décision

Rester sur Zig 0.17.0. Aucune condition de bascule n'est vraie, et la sonde C mesure le même coût de snapshot que Zig. La condition 3 reste ouverte pendant tout le PRD ; la bascule devient coûteuse après EP-002.

## US-005 : bindings générés

`tools/winmdgen` lit `Windows.Win32.winmd` (Microsoft.Windows.SDK.Win32Metadata 71.0.37-preview, nupkg téléchargé depuis nuget.org par `build.zig` dans le cache de build, non redistribué car sous licence Windows SDK, SHA-256 vérifié avant extraction) et émet `win32.zig` pour la liste `bindings/windows.zon` et sa fermeture transitive : 6 823 lignes, 33 vtables COM complètes, les autres interfaces atteintes en `opaque` avec leur IID. La génération prend 172 à 199 ms (3 runs) ; un `zig build bindings` sans changement prend 138 ms, sortie servie depuis le cache.

`probe/com_manual.zig` est supprimé : la sonde importe le module généré. Run de référence sur les bindings générés (`docs/decisions/0001-probe-run-generated.txt`) : 100/100 frames sur les 2 sorties, snapshot UIA de la barre des tâches p50 24,2 ms et p95 27,5 ms, 100/100 `UIA_E_ELEMENTNOTAVAILABLE` typés, 10 000 itérations avec une dérive de +3 016 KB et de -5 handles. Mêmes conclusions que le run manuel.

Le test de layout (`tests/layout_test.zig`) compare 29 structs générées, plus de 100 champs, aux `sizeof`/`offsetof` d'un programme C compilé par `zig cc` contre mingw-w64 : aucun écart. Deux constats sur la couche COM :

1. **La transcription manuelle était fausse, le généré est juste.** Le `MSG` de `probe/com_manual.zig` portait un champ `lPrivate` absent de l'ABI x64 de la metadata ; il ne cassait rien car la sonde ne lisait jamais au-delà de `pt`.
2. **Deuxième défaut COM, corrigé à la première tentative.** Après la bascule, la sonde comptait 0/100 erreurs typées : la metadata type `UIA_E_ELEMENTNOTAVAILABLE` en `u32` (0x80040201) alors que `HRESULT` est un `i32`. La comparaison se fait désormais sur les bits (`@as(u32, @bitCast(hr))`), dans la sonde et dans `src/backend/windows/com.zig`. Compté au titre de la condition 3, avec 1 tentative.

Conclusion US-005 : la condition 4 est fausse, la condition 3 compte 2 défauts résolus chacun en 1 tentative. La décision « rester sur Zig 0.17.0 » tient.

## Revue EP-005 : troisième défaut COM

La revue de EP-005 (2026-11-05) a trouvé dans `readPositions` (`src/backend/windows/uia.zig`, US-022) la comparaison `com.lastHr() == @as(w.HRESULT, @bitCast(@as(u32, w.UIA_E_TIMEOUT)))` : un `u32` comparé à un `i32` négatif. Zig compile cette comparaison entre signes différents et la rend toujours fausse (sonde : `false`), si bien qu'un timeout du provider ne posait jamais `{partial: timeout}`. Même cause que le deuxième défaut (metadata `UIA_E_*` en `u32`, `HRESULT` en `i32`), nouvelle occurrence : comptée au titre de la condition 3, corrigée à la première tentative. `com.lastWas(code: u32)` remplace la comparaison à la main ; un `HRESULT` signé passé à sa place est refusé à la compilation.
