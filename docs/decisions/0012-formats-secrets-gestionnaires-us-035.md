# 0012 : formats de secret posés par les gestionnaires de mots de passe (A11)

- Statut : constaté ; aucun changement de contrat
- Date : 2026-11-09
- Story : US-035, hypothèse A11 et risque 8 (`tasks/prd-windows-mcp-parity.md`)

## Sonde du 2026-11-09 (machine de référence)

Windows 11 build 26300. Gestionnaire installé : Proton Pass, en deux installations (paquet MSIX `ProtonPass` 1.41.1.0, et installation Squirrel `%LOCALAPPDATA%\ProtonPass`, `app-1.36.1` et `app-1.37.0`). La sonde ne dit pas laquelle a servi. Aucun autre gestionnaire de `policy.password_managers` n'est installé.

Arthur a lancé `neo-compute clipboard-probe 120` puis copié un mot de passe depuis Proton Pass. La sonde ne lit jamais le contenu :

```
clipboard-probe: seq 10564 owner ? (pid 0): CF_UNICODETEXT, CanUploadToCloudClipboard=0, CanIncludeInClipboardHistory=0, CF_LOCALE, CF_TEXT, CF_OEMTEXT -> refused by clipboard (CanUploadToCloudClipboard)
```

## Constat

1. **A11 est vérifiée pour Proton Pass.** Il pose `CanUploadToCloudClipboard` et `CanIncludeInClipboardHistory` à 0, et ni `ExcludeClipboardContentFromMonitorProcessing` ni `Clipboard Viewer Ignore`. `clipboard get` refuse donc le contenu par les marqueurs (`secretMarker` dans `src/backend/windows/clipboard.zig`).
2. **Le contenu n'a pas de propriétaire.** `GetClipboardOwner` renvoie null (pid 0) : Proton Pass ouvre le presse-papiers sans fenêtre propriétaire. Le refus par application `deny` (US-035, troisième critère) ne peut pas s'appliquer à ce contenu, et le message de refus nomme « une application inconnue ».

## Conséquence

Pour Proton Pass, la protection repose seulement sur les marqueurs. Le risque 8 reste ouvert pour un gestionnaire qui, comme Proton Pass, écrit sans propriétaire et ne poserait aucun marqueur (Bitwarden selon le fil de forum cité par A11, non installé ici) : ni les marqueurs ni la politique `deny` ne le couvriraient. Aucun changement n'est fait : relancer la sonde quand un autre gestionnaire est installé, et ajouter ses lignes ici.
