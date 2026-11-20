# 0014 : choix structurants du portage Linux

- Statut : décidé, avant le PRD du portage
- Date : 2026-11-20
- Source : audit `docs/research/2026-11-20-audit-portage-linux.md`, section 14. Arthur a validé les treize recommandations et ajouté une exigence (D14).

Chaque décision renvoie aux constats de l'audit qui la fondent. Les décisions D3, D4, D6, D7, D13 et D14 touchent le contrat produit (outils, sécurité, politique) ; les autres fixent l'architecture.

## D1. Périmètre de la première version

- GNOME (Mutter) est l'environnement de référence : chaque gate Linux y tourne.
- KDE (KWin) et wlroots (sway, labwc, Hyprland, niri) entrent dans le même PRD. Sous wlroots, le mode arrière-plan n'est pas garanti : aucun protocole ne donne l'ordre d'empilement des fenêtres (audit 4.3).
- X11 natif et COSMIC restent hors de la première version. Sous GNOME, les applications Xwayland passent par le compositeur comme les autres (audit 4.5).

## D2. Extension GNOME Shell

- Obligatoire pour le mode arrière-plan. Les modes a11y et vision fonctionnent sans elle, avec un fonctionnement réduit que le serveur annonce : RemoteDesktop, ScreenCast et AT-SPI.
- Embarquée dans le binaire, à la même version, installée et activée par une commande explicite `neo-compute setup`, jamais au démarrage du serveur. L'installation demande une reconnexion sous Wayland (audit 10).
- Elle n'accepte que les appels du serveur, vérifiés par `GetConnectionUnixProcessID`. Le serveur vérifie de son côté que le nom appartient au propriétaire de `org.gnome.Shell` (audit 11).
- Sous KDE, un script KWin chargé à chaque session par `/Scripting` tient le même rôle, sans rien installer (audit 4.2).

## D3. API privées des compositeurs plutôt que portails

- Par défaut : `org.gnome.Mutter.RemoteDesktop` et `ScreenCast`, KWin EIS, `ScreenShot2` et scripting, sans dialogue. C'est la parité avec `SendInput`. Le portail ne donne ni liste de fenêtres ni mode arrière-plan, et un dialogue interromprait les evals sans surveillance.
- L'entrée passe par le protocole EI, que Mutter, KWin et le portail RemoteDesktop fournissent tous par `ConnectToEIS`. Si GNOME réserve un jour ces API au portail (gnome-shell #3943), seule l'obtention du descripteur change.
- Le portail est le repli pour COSMIC et les compositeurs inconnus.
- La protection reste celle de Windows : kill switch, politique par application, indicateur.

## D4. Lecture de l'entrée physique (FR-12)

- Jamais le groupe `input` par défaut : il donne la lecture de tous les claviers.
- GNOME : l'extension lit le périphérique d'origine de chaque événement. C'est la première sonde du portage, et le mode arrière-plan comme l'entrée réelle (D14) en dépendent.
- X11 : `sourceid` des événements bruts XI2 (mesuré, audit 4.5).
- KDE : raccourci de pause par kglobalaccel, et détection par soustraction des frappes que le serveur a lui-même injectées.
- wlroots : evdev, sur activation explicite et déclarée par l'utilisateur.

## D5. Nom D-Bus d'Orca

Le serveur ne prend jamais `org.gnome.Orca.KeyboardMonitor` : un lecteur d'écran lancé ensuite ne pourrait plus le prendre. La position du pointeur vient de l'extension sous GNOME (0,21 ms mesuré) et du script KWin sous KDE (`workspace.cursorPos`, à mesurer).

## D6. `registry_read`

Absent de `tools/list` sous Linux. Il ne fait pas partie des 17 outils de `computer_toolset_20260801`. Un lecteur dconf natif pourra venir plus tard comme outil séparé, si les evals en montrent le besoin.

## D7. Textes et identifiants

- Les descriptions des outils ajoutés et les `instructions` MCP sont propres à chaque OS, choisies à la compilation. Les 17 outils restent identiques à `tests/fixtures/toolset_20260801.json`.
- Les identifiants de fenêtre restent des entiers affichés en hexadécimal. Le backend Linux fait correspondre ces entiers aux identifiants du compositeur dans une table de session (UUID KWin, id Mutter, id de toplevel). Le contrat ne change pas.

## D8. Politique et audit

- Politique : `$XDG_CONFIG_HOME/neo-compute/policy.json` ; audit : `$XDG_STATE_HOME/neo-compute/audit.jsonl`.
- Une application s'identifie par son identifiant d'application : le `.desktop`, lu dans le cgroup systemd `app-gnome-<id>-<pid>.scope` comme le fait le portail, ou l'identifiant Flatpak. S'y ajoute le chemin de `/proc/<pid>/exe`. Jamais par `comm`, tronqué à 15 caractères et modifiable par le processus.
- Les listes par défaut sont à refaire pour Linux : gestionnaires de mots de passe, terminaux (Paneflow compris), éditeurs de code.

## D9. Saisie des caractères absents de la disposition (GNOME)

- Aucun caractère n'est perdu en silence. Chaque caractère est vérifié contre la disposition que publie le clavier EI avant l'envoi ; Mutter abandonne sans erreur un keysym absent (audit 4.1).
- La saisie Unicode d'IBus (Ctrl+Maj+U) est à sonder sur une vraie session. Si elle couvre GTK, Qt et Chrome, elle sert de voie sans effet de bord.
- Sinon, le presse-papiers de la session RemoteDesktop, en sauvegardant puis restaurant tous les formats du presse-papiers de l'utilisateur.
- `RemoteDesktop.SetKeymap` n'est jamais appelé : il fait planter Mutter 51.1 (audit 4.1).

## D10. Capture sous GNOME

- La capture par l'extension est à sonder d'abord (`Meta.WindowActor`, pixels transmis par memfd) : sans PipeWire, sans indicateur de partage, compatible avec un binaire statique.
- ScreenCast avec libpipewire chargée à l'exécution sert de repli. Il est aussi la seule voie qui fait redessiner un client recouvert (audit 4.1).
- Pas de client PipeWire natif.

## D11. Indicateur de partage d'écran de GNOME

Si l'extension capture, il ne s'allume pas. Quand ScreenCast sert, il est accepté, et un clic de l'utilisateur sur cet indicateur coupe le flux. Le serveur traite cet arrêt comme une pause du kill switch : c'est un geste physique.

## D12. Gate de bascule vers Rust

La condition 3 de `0001-zig-vs-rust.md` s'étend à la couche des bibliothèques C sous Linux : threads et tampons de PipeWire, durée de vie des descripteurs de fichiers. D-Bus, Wayland, X11 et EI sont parlés en Zig natif, à partir de descriptions XML épinglées et générées comme les liaisons Win32 (audit 8).

## D13. Activation de l'accessibilité

- S'abonner aux événements AT-SPI fait écrire `toolkit-accessibility=true` par at-spi2-core 2.62. C'est accepté, et `setup` le signale. Le serveur ne remet jamais la clé à `false`.
- `app_launch` ajoute `--force-renderer-accessibility` aux navigateurs Chromium et aux applications Electron qu'il lance. Coût mesuré : 20 à 45 % de processeur en plus pour Chrome sur une page animée, avec un écouteur.
- Face à un Chrome lancé sans ce drapeau, `ui_tree` en donne la cause et propose de le relancer par `app_launch` (FR-06).

## D14. Souris et clavier réels sous GNOME

Exigence ajoutée par Arthur. Sous GNOME, l'agent pilote la vraie souris et le vrai clavier : les 17 outils du toolset, entrées tenues comprises, envoient des événements qui traversent le compositeur comme ceux d'un périphérique physique.

Raison : une passe visuelle a souvent besoin d'un vrai comportement de souris et de clavier, par exemple un survol, un glisser-déposer, un canevas, un raccourci global ou une application sans arbre d'accessibilité. agent-desktop refuse toute commande de pointeur sur une application Wayland, faute de connaître la position des fenêtres (`crates/linux/src/input/deliver.rs:39-79`). computer-use-linux passe par uinput, qui exige un accès à `/dev/uinput`.

Ce que l'audit a mesuré et ce que l'implémentation doit respecter :

- Transport : le canal EI de la session RemoteDesktop de Mutter. Son pointeur absolu couvre chaque écran sans flux ScreenCast. `NotifyPointer*` sert de repli. Position exacte au sous-pixel ; 0,3 à 0,4 ms de l'injection à l'événement reçu par l'application ; boutons 272, 273, 274 ; défilement continu et par crans (audit 4.1).
- Visée :
  - sur l'image, coordonnées de capture converties en coordonnées logiques par l'échelle de l'écran (pixel = logique × échelle, mesuré à 1,5 et 2) ;
  - sur un élément de l'arbre, rectangle de la fenêtre donné par l'extension, plus coordonnées AT-SPI relatives à la fenêtre (audit 5.2). L'écart entre le cadre Mutter et l'origine des coordonnées `WINDOW` d'une fenêtre à décorations côté client reste à mesurer.
- Pièges mesurés :
  - un clic sans mouvement préalable dans une session neuve est perdu : un mouvement précède toujours le premier clic ;
  - la première touche après `Start` est perdue : la session est amorcée avant la première action ;
  - un keysym absent de la disposition est abandonné en silence (D9).
- Entrées tenues : Mutter relâche tout en 0,65 à 3 ms quand le client meurt ou se déconnecte, mais pas quand il est figé (SIGSTOP). Le serveur relâche lui-même sur SIGINT, SIGTERM, SIGHUP, à l'EOF, à l'annulation et sur erreur (FR-07, moins de 50 ms).
- Sécurité :
  - classe d'interférence `input` : réservé au mode avant-plan et refusé en mode arrière-plan (décision 0013) ;
  - refusé quand `org.gnome.ScreenSaver.GetActive` vaut `true`, car l'entrée injectée atteint l'invite de déverrouillage (audit 4.1) ;
  - le kill switch par entrée physique (D4) doit exister avant que l'entrée réelle soit livrée.
- Preuves attendues :
  - les équivalents des checks `mouse`, `keyboard`, `release` et `kill-*` de `selftest` sur un gnome-shell sans écran, avec une fixture GTK 4 et une page Chrome qui enregistrent survol, glisser-déposer et frappes ;
  - une passe contrôlée sur une vraie session, lancée par Arthur.
- Non mesuré : les unités de la région absolue EI à une échelle fractionnaire.
