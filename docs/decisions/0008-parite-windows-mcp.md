# 0008 : parité avec Windows-MCP, périmètre retenu

- Statut : décidé par Arthur le 2026-11-05
- Date : 2026-11-05
- Story : PRD `tasks/prd-windows-mcp-parity.md`

## Constats

Windows-MCP (CursorTouch, v0.8.8, commit 9ab92bc, `C:\dev\Windows-MCP`) n'est pas une dépendance d'exécution de neo-compute : il sert uniquement de référence au mode `windows-mcp` des évals (`evals/run.ps1`, venv épinglé par `evals/windows-mcp.lock.txt`), avec PowerShell, Registry, FileSystem, Process et Scrape exclus.

L'exploration de son code (2026-11-05) recense 21 outils. neo-compute en couvre 9 (Click, Type, Scroll, Move, Shortcut, Wait, Screenshot, MultiSelect et MultiEdit par composition), 6 en partie (Snapshot, WaitFor, App, DisplayInventory, ControlStatus, Scrape par le navigateur) ; Clipboard et Notification manquent. Seuls PowerShell (FR-11) et le fetch HTTP de Scrape (FR-10) tombent sous le contrat : FileSystem, Registry et Process, écrits en natif, n'exécutent aucune commande.

## Décision

1. **Intégration.** Les fonctions retenues sont écrites nativement dans neo-compute, sans clone séparé ni reprise des noms d'outils de Windows-MCP : un seul binaire, une seule politique, un seul audit, un seul kill switch, un seul worker UIA.
2. **Référence d'éval.** Windows-MCP reste épinglé dans `evals/` comme référence indépendante. C'est une dépendance de développement, absente du binaire livré.
3. **Outils système.**
   - PowerShell : non porté ; FR-11 inchangé. Claude Code fournit déjà un shell avec ses permissions et son sandbox.
   - Scrape : seule la lecture de la page par l'arbre d'accessibilité du navigateur est portée, dans `ui_tree`. Le fetch HTTP ne l'est pas ; FR-10 inchangé.
   - FileSystem : les opérations de fichiers ne sont pas portées (Read, Write et Edit de Claude Code gardent leurs permissions par chemin et leurs checkpoints). Seule l'ouverture d'un document ou d'un dossier par son application par défaut est retenue, dans `app_launch`.
   - Registry : lecture seule, outil `registry_read`.
   - Process : pas d'outil générique. La fermeture est rattachée aux fenêtres (`window_set`), `TerminateProcess` seulement avec `force` et pour une application au niveau `full`.
   - Clipboard : get et set de texte ; la lecture est refusée quand le contenu porte un format posé par les gestionnaires de mots de passe.
   - Notification : reportée.
4. **Contrat.** Quatre nouveaux outils à chargement différé : `window_set`, `app_launch`, `clipboard`, `registry_read`. `ui_find` reçoit un paramètre optionnel `wait_ms`. `window_list` gagne un en-tête des écrans. `window_focus` et les 17 outils du toolset ne changent pas. La politique gagne une section `system` pour les outils sans fenêtre cible.
5. **Contrôle humain.** Pas de blocage des entrées physiques : l'humain garde la priorité (kill switch, FR-12). Un indicateur visuel, exclu des captures, signale les actions de l'agent.
6. **Lancement.** Pas de `launch_executable` : `app_launch` lance les applications du menu Démarrer et ouvre des documents, et refuse les exécutables et les scripts.
