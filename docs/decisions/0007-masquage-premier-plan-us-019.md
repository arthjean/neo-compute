# 0007 : masquage des champs mot de passe limité à la fenêtre au premier plan

- Statut : décidé par Arthur le 2026-11-04
- Date : 2026-11-04
- Story : US-019 (critère 1), EP-004 (Definition of Done)

## Constats

Le critère 1 de US-019 demande de noircir les bounding boxes des éléments `IsPassword` « visibles » dans `screenshot` et `zoom`. L'implémentation (`src/backend/windows/uia.zig`, `secrets`) ne cherche ces éléments que dans la fenêtre au premier plan : un champ mot de passe d'une fenêtre d'arrière-plan visible à l'écran n'est pas noirci. La revue de EP-004 a donc classé ce critère en FAIL.

Un champ `IsPassword` n'affiche que des puces : sa valeur n'est pas dans les pixels, masquée ou non. Le seul cas où elle l'est, un champ révélé par le bouton « afficher », échappe aussi au masquage au premier plan dans les navigateurs, qui passent alors le champ en texte (`IsPassword` faux). Étendre le scan à toutes les fenêtres visibles coûterait un `FindAllBuildCache` par fenêtre et par capture ; Chrome ou VS Code en arrière-plan dépasseraient le budget de 30 ms de `screenshot` (le seul scan du premier plan a dû être restreint à la vue contrôle pour tenir : étape `mask` passée de 52 ms à 2,4 ms p95).

Les fenêtres des applications classées `deny` (US-017) restent noircies quelle que soit leur position, au premier plan ou non (`policy.deniedRects`) : un gestionnaire de mots de passe se protège par la politique, pas par ce masquage.

La première campagne de la tâche canari (`evals/results/2026-11-04_225114`) a trouvé un défaut : en mode vision, la toute première capture d'un Chrome neuf gardait les champs mot de passe (7 245 pixels de leur couleur). Chromium ne construit son arbre web qu'après la première requête UIA, 10 à 30 ms plus tard ; le scan, fait avant, ne voyait aucun champ. En mode a11y, `ui_tree` avait réveillé Chrome avant la capture. Correction : sur une fenêtre Chromium, le scan attend l'élément document (pas de 10 ms, 300 ms au plus) et, s'il ne vient pas, noircit la fenêtre entière.

## Décision

1. Le critère 1 de US-019 s'entend « éléments `IsPassword` de la fenêtre au premier plan ». Le masquage ne couvre pas les fenêtres d'arrière-plan ; une application qui affiche des secrets en clair se classe `deny`.
2. La preuve « 0 valeur `IsPassword` sur la suite de US-016 » de la DoD de EP-004 passe par une tâche canari ajoutée à la suite (`chrome-password`) : un champ prérempli d'une valeur aléatoire que le modèle ne connaît pas, un champ où il saisit un mot de passe donné, et une vérification qu'aucune des deux valeurs n'apparaît dans les résultats d'outils ni dans le journal d'audit, et qu'aucun pixel des champs ne subsiste dans les captures. Les 20 tâches existantes ne contiennent aucun champ mot de passe : une campagne sur elles seules prouverait « 0 fuite » sans rien à fuir.
3. Si un besoin de masquage en arrière-plan apparaît, la voie retenue n'est pas un scan par capture mais un index des champs mot de passe tenu à jour par les événements UIA (structure et propriétés), hors du chemin de capture. Elle fera l'objet d'une story distincte.
