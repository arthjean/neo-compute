# 0004 : budget Explorateur lié au provider, substitutions et baseline (EP-003)

- Statut : décidé, approuvé par Arthur le 2026-11-04
- Date : 2026-11-03
- Story : US-011, US-014, US-016 (EP-003)

## Constats

Mesures du 2026-11-03 sur la machine de référence, détaillées dans `bench/apps.md` :

- Explorateur, dossier `bench` du dépôt, 114 à 119 éléments UIA : snapshot p95 de 78 à 112 ms selon les runs, au-dessus du budget de 50 ms. La sonde témoin C de US-001 (`probe/probe_c.c`, 3 propriétés en cache au lieu de 12 et 6 patterns) mesure 91 à 163 ms p95 sur la même fenêtre. Le coût est celui du provider de l'Explorateur, pas du langage : l'hypothèse A4 ne tient pas pour lui.
- Bloc-notes 35 ms, Paramètres 31 ms, Calculatrice 17 ms (installée le 2026-11-03 depuis le Microsoft Store, 11.2607) : sous 50 ms.
- Edge n'est pas installé (seuls des restes sans `msedge.exe` sous `Program Files (x86)\Microsoft\Edge`). Chrome 156 utilise le même moteur et le même provider UIA.
- `window_list` : le binaire de HEAD varie de 315 à 798 µs p95 sur cette machine, autant que le binaire courant. La référence de 376,8 µs était un tirage bas.
- Le toolset natif de computer use n'est pas accessible à `claude -p` sous Windows avec un abonnement : la CLI le propose en research preview sur macOS, en session interactive seulement ([computer use, Claude Code](https://code.claude.com/docs/en/computer-use.md)) ; le toolset de l'API exige une clé API ([computer use tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool.md)).

## Décision

1. Le budget Explorateur de US-011 devient relatif au provider : le snapshot p95 du serveur passe s'il est sous 50 ms, ou sinon s'il reste dans 110 % de la sonde C mesurée sur la même fenêtre. Le scénario `bench explorer` lance `zig-out/bin/probe_c.exe` avant et après la série et compare à la moyenne des deux (`provider_bound` dans `src/core/bench.zig`). Les autres budgets restent absolus.
2. Chrome remplace Edge pour les critères de US-014 et les tâches de US-016.
3. La baseline de `window_list` est réenregistrée (pire p95 de 5 runs, 601,1 µs au total, sous le budget absolu de 5 ms). Les autres références ne changent pas.
4. Le scénario `transport` appelle `key` avec `observe: "none"` : il mesure le transport, et les scénarios `diff` et `ui_tree` mesurent l'observation.

## Question ouverte

A2 compare le miroir MCP au toolset natif, qui n'est pas exécutable ici sans clé API. La campagne de US-016 ne peut donc conclure sur A2 qu'indirectement (mode `vision` contre `a11y` et Windows-MCP). La reformulation de A2 revient à Arthur.
