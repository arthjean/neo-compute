# 0003 : preuves indirectes acceptées pour EP-002

- Statut : décidé par Arthur le 2026-11-03
- Date : 2026-11-03
- Story : US-006 et US-008 (EP-002)

## Contexte

Trois critères d'acceptation de US-006 et deux de US-008 exigent un état matériel ou système que la machine de référence (Windows 11 Pro 10.0.26300, 2 écrans 2560x1440 à 96 dpi sur RTX 4070 Ti SUPER, iGPU sans sortie active) ne peut pas produire de façon reproductible, ou qui demande un geste humain.

## Décision

| Critère | Preuve retenue | Preuve directe |
|---|---|---|
| US-006 : écrans en rotation 90, 180 et 270 | Test unitaire `rotated panels come back in desktop orientation` (`src/core/image.zig`) sur la correspondance texture vers bureau de l'échantillon Microsoft DXGIDesktopDuplication (`DisplayManager.cpp`, `SetDirtyVert`), appliquée aux pixels et aux dirty/move rects | Non exécutée : faire pivoter un écran puis `screenshot` |
| US-006 : `DXGI_ERROR_ACCESS_LOST`, recréation en < 500 ms | Sous-test selftest `access-lost` : recréation forcée de la duplication (440 à 540 µs), capture suivante réussie ; le chemin `AccessLost` d'`acquire` rappelle la même recréation | Non exécutée : changement de mode ou invite UAC pendant une capture |
| US-006 : bureau sécurisé actif | Message implémenté (`secureDesktopActive`, `OpenInputDesktop` et `UOI_NAME`), renvoyé sur `E_ACCESSDENIED` ou bureau autre que `Default` | Non exécutée : invite UAC ou Ctrl+Alt+Suppr pendant un `screenshot` |
| US-006 : `DXGI_ERROR_UNSUPPORTED` | Message implémenté, nomme la sortie et l'adaptateur, sortie conservée hors duplication | Impossible sur cette machine : aucune sortie ne refuse la duplication |
| US-008 : erreur ≤ 1 px à 125 et 200 % | Selftest `mouse` (coordonnées physiques en Per-Monitor V2, donc indépendantes de l'échelle) et `dpi-unaware` (fenêtre héritée non DPI-aware, erreur ≤ 1 px logique), exécutés à 100 % et à 150 % | Optionnelle : relancer `selftest` à 125 et 200 % |

Exécutées le 2026-11-03 : le selftest complet à 150 % d'échelle (144 dpi, `mouse` 0 px, `dpi-unaware` 0,33 px logique) et le sous-test `uipi` contre un terminal administrateur ouvert sur l'écran 0 (injection refusée avant envoi).

## Conséquences

Une régression de rotation, de reprise réelle après perte ou de message UAC ne serait détectée que par l'usage. À revérifier si un écran est branché sur l'iGPU AMD (A5) ou si un écran pivoté est ajouté au poste.
