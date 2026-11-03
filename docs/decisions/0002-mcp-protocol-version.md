# 0002 : versions du protocole MCP supportées

- Statut : décidé pour la v1, à réévaluer
- Date : 2026-11-03
- Story : US-002 (répond à la question ouverte Q1 du PRD)

## Vérification

Faits relevés le 2026-11-03 sur les sources officielles :

- La version courante publiée est **2026-07-28** ([versioning](https://modelcontextprotocol.io/specification/versioning), [release GitHub « Latest »](https://github.com/modelcontextprotocol/modelcontextprotocol/releases)). Les versions précédentes publiées sont 2025-11-25, 2025-06-18, 2025-03-26 et 2024-11-05.
- 2026-07-28 **supprime `initialize`**, `notifications/initialized` et `ping`. Chaque requête porte `_meta["io.modelcontextprotocol/protocolVersion"]`, une méthode `server/discover` obligatoire expose versions, capacités et `instructions`, et chaque résultat porte `resultType` ([changelog 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog)).
- Un serveur « dual-era » PEUT continuer à répondre à `initialize` et suivre les règles historiques pour ce process stdio.
- Inchangés : le framing stdio (un message JSON par ligne, stdout réservé au protocole, logs sur stderr), la forme de `notifications/cancelled` et `notifications/progress`, les annotations d'outil (`readOnlyHint`, `idempotentHint`) et le code -32602 pour un outil inconnu ([stdio](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio), [tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)).

## Décision

neo-compute implémente l'ère `initialize` : 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05 (`supported_versions` dans `src/core/mcp.zig`). Une version demandée connue est renvoyée telle quelle ; une version inconnue reçoit 2025-11-25. `server/discover` répond -32601.

Raison : le critère d'acceptation de US-002 est formulé sur `initialize`, et supporter 2026-07-28 change la négociation, l'enveloppe de chaque résultat et `tools/list` (`ttlMs`, `cacheScope`). C'est un changement de contrat produit, pas une correction technique, donc il revient à Arthur.

## Compatibilité client vérifiée

Claude Code 2.1.317 se connecte au serveur : `claude mcp add -s local neo-compute-check -- C:/dev/neo-compute/zig-out/bin/neo-compute.exe` puis `claude mcp list` affiche `neo-compute-check: ... - ✔ Connected` (2026-11-03, entrée retirée ensuite). Le client se rabat donc sur `initialize` face à un serveur sans `server/discover`.

Si une version future de Claude Code exige 2026-07-28, ajouter le mode dual-era devient une story à part entière.
