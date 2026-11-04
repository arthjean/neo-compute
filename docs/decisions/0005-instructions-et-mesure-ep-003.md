# 0005 : instructions par mode, mesure du delta et plancher du bench (EP-003)

- Statut : décidé, approuvé par Arthur le 2026-11-04
- Date : 2026-11-03
- Story : US-012, US-016 (EP-003)

## Constats

Pilote du 2026-11-03 (`evals/reports/2026-11-03.md`, 5 tâches, modes a11y et vision, 1 répétition, 10 réussites sur 10) :

- En mode a11y, le modèle commence par `window_list` puis `window_focus` pour trouver la fenêtre : 2 à 3 appels sur 7, alors que `ui_tree` sans `window` lit déjà la fenêtre au premier plan. Les instructions ne le disaient pas.
- Le mode vision recevait les mêmes `instructions`, qui recommandent `ui_tree`, `ui_find` et `ui_act`, outils qu'il ne liste pas : un biais dans l'A/B.
- Les observations du mode a11y forment deux populations : les deltas dans la page (médiane 90 tokens, de 23 à 215) et le contenu remplacé, c'est-à-dire la première lecture d'une fenêtre ou un changement de page dans Paramètres (`+31 -51`, `+59 -27`, de 900 à 1 900 tokens). La médiane unique (176) dépend surtout de la proportion de navigations dans la suite.
- Bench : sous la microseconde, la règle des 110 % mesure la résolution du chronomètre (`ui_tree.write` 0,4 contre 0,3 µs). `transport` a la même distribution sur HEAD et sur l'arbre courant, et sa référence de 69 µs tombait dans le bruit de la machine.

## Décision

1. Instructions `initialize` du mode a11y : ajout de « Start with ui_tree: without window it reads the foreground window, so call window_list only to find or switch to another window. » Le mode vision a ses propres instructions, sans outil d'accessibilité (`vision_instructions` dans `src/core/mcp.zig`). Les noms et paramètres d'outils ne changent pas.
2. Critère US-012 : la médiane de 150 tokens porte sur les deltas dans la page. Le contenu remplacé (arbre complet, ou delta qui ajoute et retire au moins 10 éléments chacun) est mesuré à part, sans autre seuil que la règle existante : jamais plus long que l'arbre complet. Classement dans `evals/run.ps1`, rapport dans `evals/report.ps1`.
3. Bench : un p95 n'est une régression que s'il dépasse 110 % de sa référence d'au moins 1 µs (`min_regression_us` dans `src/core/bench.zig`).
4. La baseline `transport` est réenregistrée (pire p95 de 5 runs, 82,8 µs au total). Les autres références ne changent pas.
5. La campagne US-016 complète (20 tâches, 3 répétitions, modes a11y, vision et Windows-MCP) tourne avec `--model claude-opus-5-5`, après ces corrections, sur des tâches écrites avant tout résultat.

## Ajout : cadence de `type` (campagne interrompue)

La campagne lancée le 2026-11-03 à 18 h 31 a été arrêtée après 82 exécutions sur 180 (mémoire de la machine saturée). Deux échecs a11y de `notepad-append` montrent un défaut du serveur, pas du modèle : `type "Fin du document."` écrit `Fin ddddocument.` dans le Bloc-notes. Reproduit sans modèle, en JSON-RPC direct : 3 échecs sur 4 (`Fin du .........`). TranslateMessage lit le caractère d'un `VK_PACKET` dans le dernier paquet du thread, pas dans le message : une cible qui pompe en retard lit tous les caractères en attente comme le dernier envoyé. Mesuré dans le Bloc-notes, un caractère toutes les 4 ms en perd encore, 8 ms et plus les écrit tous ; deux `SendMessageTimeout(WM_NULL)` par caractère ne synchronisent pas (le Bloc-notes ne traite pas la saisie au rythme de sa pompe de premier plan).

6. `type` envoie un caractère par appel `SendInput` (une paire UTF-16 reste entière, 4 événements au plus) puis attend `type_pace_ns`, 10 ms sous Windows (`src/backend/windows.zig`), 0 sur le backend de test. L'attente passe par `ctx.sleep`, donc reste annulable ; la progression part tous les 100 caractères. Le critère US-009 (« lots de 64 événements au plus ») tient. Coût : 10 000 caractères prennent environ 100 s au lieu d'une fraction de seconde. Après correctif : 8 réussites sur 8 sur la même reproduction.
7. Les 82 exécutions tournaient sur l'ancien `type` : la campagne repart de zéro sur le serveur corrigé (`evals/results/2026-11-03_231815`). Coupée à son tour à 137 exécutions pour la même raison, elle est reprise avec `run.ps1 -Resume`, sur le même serveur, jusqu'aux 180.
