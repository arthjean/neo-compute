# 0011 : exclusion de capture et conception de l'indicateur de contrôle (EP-008)

- Statut : appliqué ; le point 3 (cinq fenêtres par écran au lieu d'une) décidé par Arthur le 2026-11-09, critère de US-034 amendé
- Date : 2026-11-09
- Story : US-033 (hypothèse A8) et US-034 (`tasks/prd-windows-mcp-parity.md`)

## Sonde du 2026-11-09 (machine de référence)

Windows 11 build 26300, deux écrans 2560x1440 à 96 dpi, NVIDIA GeForce RTX 4070 Ti SUPER. Le selftest `capture-exclusion` (`src/backend/windows/selftest.zig`, fenêtre de `exclusion_probe.zig`) pose une fenêtre layered, topmost, transparente aux clics et de couleur unie (200x120) au-dessus de la fenêtre de test, puis la capture par DXGI et par GDI :

| Mesure | Sans affinité (témoin) | `WDA_EXCLUDEFROMCAPTURE` |
|---|---|---|
| Pixels de la fenêtre dans la frame DXGI | 100 % | 0 % (fenêtre de test dessous : 100 %) |
| Pixels de la fenêtre dans la capture GDI (`BitBlt` + `CAPTUREBLT`) | 100 % | 0 % (dessous : 100 %) |
| Dirty rects DXGI sur sa zone en 1 s, repeinte à 30 Hz (rects/frames) | 30/30 | 30/30 |
| Dirty rects, affichée puis masquée toutes les 100 ms | non mesuré | 9/9 |
| Dirty rects au repos | 0/0 | 0/0 |

`SetWindowDisplayAffinity` réussit et `GetWindowDisplayAffinity` relit `0x11`.

**A8 est validée pour la moitié pixels et invalidée pour la moitié dirty rects** : une fenêtre exclue n'apparaît dans aucune capture, mais chacun de ses changements produit un dirty rect DXGI sur sa zone, exactement comme une fenêtre capturée.

Seconde mesure, faite en écrivant US-034 : une fenêtre de la taille de l'écran, découpée par `SetWindowRgn` au cadre et à l'étiquette, produit à chaque apparition un dirty rect de **tout l'écran** (2560x1440, sur chacun des deux écrans), quelle que soit sa région. Un `left_click` sur la fenêtre de test immobile se stabilisait alors en 72 ms au lieu de 57 ms : l'apparition de l'indicateur comptait comme un changement.

## Décision

1. **Exclusion par `WDA_EXCLUDEFROMCAPTURE`.** Les fenêtres de l'indicateur ne sont ni masquées ni réaffichées autour des captures. Si l'affinité est refusée au démarrage, l'indicateur n'est pas créé : l'échec est journalisé sur stderr et tous les outils restent disponibles (un indicateur visible dans les captures serait pire que pas d'indicateur).
2. **Indicateur statique.** Aucune animation : il ne change qu'aux transitions d'état (action, fin du délai de 1 s, pause, réarmement), ce qui satisfait le critère « reste statique pendant la stabilisation » de US-034.
3. **Cinq fenêtres par écran au lieu d'une.** Quatre bandes de 4 px le long des bords et la boîte de l'étiquette, chacune une petite fenêtre layered. DWM salit le rectangle entier d'une fenêtre : une bande ne salit que ses 4 px. Le comportement visible ne change pas (un cadre et une étiquette par écran, transparents aux clics, jamais activés, exclus des captures) ; le premier critère de US-034, qui disait « une fenêtre layered par écran », est amendé en ce sens. Windows-MCP (`src/windows_mcp/desktop/control_overlay.py`, commit `9ab92bc`) fait de même : quatre bandes par écran, plus le halo et le texte de son bandeau, chacun dans sa fenêtre.
4. **Échos retirés des dirty rects.** Après un changement de l'indicateur, les dirty rects DXGI entièrement couverts par ses bandes ou ses étiquettes sont retirés de la capture (`dropEchoes`) : au premier regard sur l'écran après le changement, même plusieurs secondes plus tard (DXGI accumule les dirty rects jusqu'au regard suivant), et à tout regard dans les 150 ms (DWM compose le changement au rafraîchissement suivant). La stabilisation et l'attente de `ui_find` ne voient donc pas l'indicateur. Un dirty rect qui déborde de l'indicateur est gardé entier.

5. **Fenêtres construites en arrière-plan.** Le thread de l'indicateur crée ses dix fenêtres après le démarrage du serveur : les attendre ajoutait environ 10 ms à `initialize` (p50 20 ms au lieu de 10 ms). Un arrêt pendant la construction l'interrompt, pour que la sortie après la fin de stdin reste immédiate.

## Mesures après la décision (selftest du 2026-11-09)

- `indicator-settle` : un `left_click` sur la fenêtre de test immobile se stabilise en 56 ms (médiane de trois) quand l'indicateur apparaît, contre 52 ms observateur détaché ; tolérance 8 ms, alors qu'un écho non retiré coûtait environ 15 ms.
- `indicator-echo` : 14 dirty rects retirés à l'apparition, 12 à la disparition regardée 1,5 s plus tard, aucun restant sur l'indicateur.
- `indicator-capture` : aucun point du cadre ou de l'étiquette dans les frames DXGI et GDI ; affinité levée, les mêmes points sont ambre (dessinés sur les deux écrans).
- `indicator-cost` : sur 400 changements d'état (début et fin d'action, déclenchement et réarmement du kill switch), p95 138 µs et maximum 449 µs pour le thread appelant (budget 2 ms) ; appel de hook le plus lent 1,3 µs (budget 1 ms).
- `indicator-brief` et `indicator-rebuild` (ajoutés à la revue d'EP-008) : une action finie avant le réveil du thread de l'indicateur s'affiche quand même et disparaît 1 023 ms après sa fin (l'époque de `Control` dit qu'elle a eu lieu) ; un changement d'écran pendant le délai de 1 s reconstruit les dix fenêtres, qui disparaissent 1 040 ms plus tard au lieu de rester affichées.
- Démarrage : `initialize` p50 10,6 ms avec l'indicateur, 10,1 ms avec `--no-indicator` ; sortie après la fin de stdin p95 6 ms (`process_test`).

## Conséquences

- Un vrai changement de l'écran confiné à une bande de 4 px ou à la boîte de l'étiquette, au même moment qu'un changement de l'indicateur, est ignoré par la stabilisation. Risque accepté : la zone est minime et la fenêtre de temps courte.
- Cinq fenêtres par écran pèsent quelques kilo-octets de surfaces DWM, contre environ 15 Mo par écran 2560x1440 pour une fenêtre plein écran.
- Q9 (indicateur visible pendant toute la session) reste ouverte.
