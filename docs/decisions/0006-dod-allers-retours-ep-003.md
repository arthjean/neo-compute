# 0006 : cible d'allers-retours de EP-003 reportée après le PRD

- Statut : décidé par Arthur le 2026-11-04
- Date : 2026-11-04
- Story : EP-003 (Definition of Done), US-016

## Constats

Campagne complète du 2026-11-03 (`evals/results/2026-11-03_231815`, `evals/reports/2026-11-03.md`) : 20 tâches, 3 répétitions, modes a11y, vision et Windows-MCP, modèle claude-opus-5-5, 180 exécutions.

| Mesure | a11y | vision | Écart |
|---|---|---|---|
| Tours modèle, médiane | 8 | 9 | -11 % |
| Appels d'outils, médiane | 7 | 8 | -12,5 % |
| Tours modèle, moyenne | 9,48 | 9,92 | -4 % |
| Réussite | 100 % | 100 % | 0 |

La DoD de EP-003 demande -30 % d'allers-retours face au mode vision sans baisse du taux de réussite : non atteinte. Les 6 stories passent leurs critères, et les autres volets de la DoD tiennent (`ui_tree` p95 sous 50 ms, Explorateur dans 110 % de la sonde C selon la décision 0004 ; delta dans la page médian de 96 tokens selon la décision 0005).

Les tâches de la suite sont courtes (8 à 9 tours) et le mode vision les réussit toutes : la marge est faible. Le nombre de tours dépend surtout de la conception des outils (contenu des deltas, observation post-action, actions composées), pas de la latence locale.

## Décision

1. Le volet « -30 % d'allers-retours » sort de la DoD de EP-003. La DoD garde : réussite sans baisse face au mode vision, et allers-retours mesurés et consignés par la campagne de US-016. EP-003 passe à DONE.
2. La cible de -30 % (puis -45 %) de la table Goals est conservée. Elle sera visée après la fin du PRD, une fois EP-004 livré, car ses confirmations humaines peuvent ajouter des tours.
3. Les chiffres ci-dessus servent de référence à la prochaine campagne, lancée avec `evals/run.ps1` sur le même harnais. Une suite enrichie de tâches longues (formulaires à plusieurs étapes, navigation profonde, listes longues) pourra s'y ajouter, sans retirer les 20 tâches actuelles.
