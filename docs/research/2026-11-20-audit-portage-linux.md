# Audit : porter neo-compute sous Linux (GNOME, KDE, wlroots, COSMIC, X11)

- Date : 2026-11-20
- Objet : établir ce que chaque partie de neo-compute devient sous Linux, assez précisément pour en tirer ensuite un PRD complet du portage : chaque outil dans chaque environnement (faisable ou non, par quel moyen, avec quelles limites), le mode arrière-plan, les invariants du produit, le build et les liaisons générées, les selftests, le bench, les evals et la distribution. C'est un constat et un relevé du travail à faire. Rien n'est implémenté, aucun PRD n'est rédigé, aucun fichier du dépôt n'a changé en dehors de ce document.
- Machine : Fedora 45, GNOME Shell et Mutter 51.1 sous Wayland, deux écrans 2560x1440 à l'échelle 1, 16 cœurs (la machine de référence Windows, en dual boot). Installés et utilisés par les sondes : KWin 6.8.3, sway 1.12, labwc 0.20.2, Weston 15.0.1, Xvfb, Xwayland, openbox, picom, PipeWire 1.6.11, WirePlumber 0.5.19, libei 1.6.0, at-spi2-core 2.62.1, GTK 4.24, KWrite (Qt 6), Google Chrome 157, Zig 0.17.1.
- Sources : le dépôt au commit `3091301` ; agent-desktop (`~/dev/agent-desktop`, commit `e8934a5e`) ; computer-use-linux (`agent-sh/computer-use-linux`, clone en lecture seule au commit `34bee24`) ; le JavaScript de gnome-shell 51.1 extrait de `libshell-51.so` ; Ghostty, Zed et GPUIX comme références de liaisons ; la documentation en ligne listée en section 17.
- Méthode : 14 sous-agents. Cinq sondes ont tourné dans des sessions graphiques privées : GNOME entrées, GNOME capture et fenêtres, accessibilité, X11 et Xwayland, KDE et wlroots. Six autres ont lu du code : le contrat du backend, deux volets d'agent-desktop, computer-use-linux, les selftests, bench et evals, le mode arrière-plan et les invariants. Une passe a porté sur le build et les liaisons, deux recherches sur le web. J'ai recoupé chaque rapport avant de le retenir (contrôles en section 13). Les sondes actives ont tourné dans des compositeurs sans écran : gnome-shell et Mutter `--headless`, KWin `--virtual`, sway, labwc et Weston headless, Xvfb. Sur la session réelle, elles n'ont fait que des lectures. Les sondes ont eu des effets de bord, réparés ou listés en section 12.

Statut de chaque constat :

| Statut | Sens |
|---|---|
| mesuré | observé sur cette machine par une commande ou une sonde |
| vérifié | lu dans le code ou un document, à l'endroit cité |
| documenté | source primaire en ligne (section 17), non revérifiée sur la machine |
| déduit | conclusion tirée de faits mesurés ou vérifiés, qu'aucune mesure ne montre directement |

Préfixes de chemins : `nc:` ce dépôt, `ad:` agent-desktop, `cul:` computer-use-linux, `gs:` le JavaScript de gnome-shell 51.1. Les scripts des sondes sont dans le dossier de travail de la session (`/tmp/claude-1000/-home-arthur-dev-neo-compute/67d9d2fd-2a7a-48cc-a4f1-bf8e149c31ba/scratchpad/`, sous-dossiers `gin`, `gcw`, `a11y`, `x11`, `kwl`, `build`) : ce dossier est temporaire, les commandes et les chiffres décisifs sont donc recopiés ici.

Vocabulaire. Un compositeur est le programme qui dessine les fenêtres et reçoit souris et clavier (Mutter pour GNOME, KWin pour KDE, sway, labwc, Hyprland, niri, cosmic-comp). Wayland est le protocole entre les applications et le compositeur ; un « global » est une interface que le compositeur annonce à ses clients. X11 est l'ancien système, encore présent par Xwayland (un serveur X qui fait tourner les vieilles applications sous Wayland). D-Bus est le bus de messages des services du bureau. AT-SPI est l'équivalent Linux de UI Automation : chaque application publie son arbre d'accessibilité sur un bus D-Bus dédié. PipeWire transporte les flux vidéo d'écran. libei (protocole EI, côté compositeur EIS) est la bibliothèque standard d'injection d'entrées sous Wayland. Un portail (`xdg-desktop-portal`) demande l'accord de l'utilisateur avant qu'une application touche l'écran ou l'entrée. evdev est l'interface du noyau qui expose les périphériques d'entrée (`/dev/input/event*`) ; uinput (`/dev/uinput`) permet d'en créer de faux.

## 0. Résumé

1. **Il n'y a pas « un » Linux mais quatre familles de backends, plus une couche commune.** GNOME (Mutter), KDE (KWin), wlroots et apparentés (sway, labwc, Hyprland, niri, COSMIC à part), et X11. Aucun protocole Wayland standard ne couvre tous les compositeurs : Mutter n'expose aucun global d'automatisation, KWin en expose par ses propres interfaces, wlroots par les protocoles `wlr`/`ext` (mesuré, section 1.2). La couche commune est AT-SPI pour l'arbre et les actions sémantiques, D-Bus et le protocole Wayland comme transports, et xkb pour les dispositions clavier.
2. **Le X11 natif n'est plus la cible principale.** GNOME 50 et Plasma 6.8 ont retiré leur session X11 (documenté ; aucune session X11 GNOME ou KDE installable ici, mesuré). Un backend X11 lancé sur un bureau Wayland ne voit et ne pilote que les clients Xwayland : la capture de la racine échoue en `BadMatch`, XTest n'atteint aucune fenêtre Wayland (mesuré, section 4.5). X11 reste utile pour Cinnamon, MATE, Xfce, et comme banc de test.
3. **Sous GNOME, tout ce qu'il faut existe sans dialogue, mais par des API privées ou une extension du Shell.** L'entrée passe par `org.gnome.Mutter.RemoteDesktop` et son canal EI, sans dialogue ni autorisation pour un processus de la session (mesuré). La capture d'un écran ou d'une fenêtre recouverte passe par `org.gnome.Mutter.ScreenCast` lu par PipeWire, là aussi sans dialogue (mesuré). La liste des fenêtres avec leurs rectangles, leur empilement et leur pid, l'activation, le déplacement sans activation et la position du pointeur demandent une extension GNOME Shell : `Introspect` est réservé à une liste d'appelants et ne donne ni position ni empilement ni pid (mesuré).
4. **Sous KDE, KWin donne tout sans autorisation.** Il fournit l'entrée par EIS (`org.kde.KWin.EIS.RemoteDesktop`, capacité texte comprise), la capture d'une fenêtre recouverte ou minimisée en 1,85 ms (`ScreenShot2`), et la gestion complète des fenêtres par un script KWin chargé depuis le bus (mesuré en headless). Les règles d'autorisation documentées ne s'appliquent pas dans KWin 6.8.3 headless (mesuré) : à confirmer dans une vraie session Plasma.
5. **Sous wlroots, les protocoles suffisent** (pointeur et clavier virtuels, `ext-image-copy-capture` d'une fenêtre recouverte en 2 ms, liste des fenêtres, presse-papiers sans focus). Le déplacement et le redimensionnement des fenêtres passent par l'IPC propre à chaque compositeur (mesuré pour sway et labwc).
6. **Le relâchement des entrées tenues dépend du transport.** Mutter (RemoteDesktop et EI) et KWin (EIS) relâchent en moins de 5 ms à la mort du client (mesuré). XTest, les claviers virtuels wlroots et `fake_input` de KWin gardent la touche enfoncée, avec répétition, 20 à 38 s et plus (mesuré). Il faut alors un processus gardien, mesuré sous X11 à 0,26 ms. Claude Code arrête un serveur Linux par SIGINT, puis SIGTERM à 100 ms, puis SIGKILL 400 ms plus tard (documenté et vérifié). `nc:src/` ne gère aucun signal (vérifié).
7. **Le kill switch n'a pas d'équivalent direct sous Wayland.** Aucune API de compositeur mesurée ne distingue une entrée physique d'une entrée injectée : l'IdleMonitor de Mutter compte l'injecté comme activité, et `KeyEvent` ne porte pas de périphérique (mesuré). X11 le permet par le `sourceid` des événements bruts XI2 (mesuré). Restent evdev, ce qui exige le groupe `input`, qui n'est pas un défaut Fedora (mesuré) ; une extension GNOME qui lirait le périphérique source de chaque événement Clutter (déduit, à sonder) ; et la soustraction de ce que neo-compute a lui-même injecté (déduit).
8. **AT-SPI remplace UI Automation sans changer le modèle du cœur.** Les actions sémantiques n'activent pas la fenêtre (mesuré sous GTK 4, Qt 6 et Chrome, Wayland et X11), sauf les popups qui prennent le clavier sous X11. Un instantané coûte 10 à 45 ms avec tous les appels en vol, sur un client natif (mesuré, section 5.2). Sous Wayland, aucun toolkit ne donne de coordonnées d'écran, seulement des coordonnées relatives à la fenêtre (mesuré). Il faut donc recomposer les coordonnées d'écran à partir du rectangle de la fenêtre, que donne le compositeur. Mutter 51 relie chaque fenêtre à son objet AT-SPI (`a11y-dbus-name`, `a11y-object-path`, vérifié). Trois écarts avec Windows :
   - une case à cocher GTK 4 n'a aucune action ;
   - les champs web de Chrome n'acceptent pas de texte sans entrée ;
   - Chrome n'expose son arbre web que lancé avec `--force-renderer-accessibility` (tout mesuré).
9. **Le cœur compile pour Linux, mais n'y tourne pas tel quel.** `zig build cross` ne fait que compiler (vérifié). Sous Linux, le serveur se construit silencieusement avec le backend factice (mesuré). La politique et l'audit lisent `APPDATA` et `LOCALAPPDATA`, donc aucun des deux ne se charge (vérifié). Les listes de politique sont des noms `.exe`, donc ni gestionnaire de mots de passe ni terminal n'est protégé (vérifié). Le bench passe « sans régression » avec 14 scénarios sur 16 ignorés (mesuré). Une copie fraîche ne construit même pas : le hash de libjpeg-turbo ne correspond qu'à une extraction qui garde le répertoire racine (mesuré).
10. **Un seul binaire Linux statique est possible.** Un client Zig sans aucune bibliothèque C parle déjà D-Bus et Wayland : 160 Ko, statique musl, mesuré sur la session réelle. PipeWire est la seule brique qui pousse vers une bibliothèque C (dlopen sous glibc). Elle n'est nécessaire que pour la capture par Mutter, et une extension GNOME pourrait capturer sans elle (déduit, à sonder).
11. **Ni agent-desktop ni computer-use-linux ne tient les invariants de neo-compute.** agent-desktop ne gère sous Linux que X11 et GNOME, sans pointeur sur les applications Wayland ni état persistant (vérifié). computer-use-linux couvre tous les compositeurs, mais ne relâche pas explicitement les entrées à l'arrêt et ne masque aucun mot de passe dans les images (vérifié). Il renvoie un mot de passe saisi en écho dans sa réponse (vérifié), et son mode « arrière-plan » déplace le focus tout en répondant `ok` (vérifié). Section 11.
12. **Treize décisions reviennent à Arthur** (section 14). Parmi elles : le périmètre des environnements, l'installation d'une extension GNOME, l'usage d'API privées sans consentement, le sort de `registry_read`, la façon de lire l'entrée physique, et l'activation de l'accessibilité, qui écrit un réglage durable.

## 1. Les environnements à couvrir

### 1.1 Sessions par distribution

| Distribution | Bureau par défaut | Session X11 | glibc | Statut |
|---|---|---|---|---|
| Fedora 45 Workstation | GNOME 51 | non : `/usr/share/xsessions/` ne contient que `openbox.desktop` | 2.44 | mesuré |
| Fedora KDE 45 | Plasma 6.8 | non : KWin 6.8.3 installé ici sans `kwin_x11` ni paquet `kwin-x11` | 2.44 | mesuré |
| Ubuntu 26.04 LTS | GNOME 50 | non, première LTS sans session Xorg | 2.43 | documenté |
| Ubuntu 24.04 LTS | GNOME 46 | non vérifié | 2.39 | documenté (glibc) |
| Ubuntu 22.04 LTS | GNOME 42 | non vérifié | 2.35 | documenté (glibc) |
| Debian 12 et 13 | GNOME (installateur) | non trouvé | 2.36 et 2.41 | documenté (glibc) |
| RHEL 10, CentOS Stream 10 | GNOME | non : Xorg retiré, Xwayland gardé | 2.39 | documenté |
| RHEL 9 | GNOME | non vérifié | 2.34 | documenté (glibc) |
| Pop!_OS 24.04 | COSMIC | sans objet | non trouvé | documenté |
| Linux Mint 22 | Cinnamon sous X11 ; Wayland annoncé pour Mint 23 | oui | non trouvé | annoncé |
| Xfce | xfwm4, X11 seulement ; xfwl4 (Wayland, Rust) en développement | oui | | annoncé |
| Plasma 6.7 et avant | Plasma | dernière version avec X11 | | documenté |

Parts de marché : aucune donnée crédible par bureau n'a été trouvée. L'enquête Steam d'octobre 2026 donne 3,95 % de Linux, dominé par des distributions de jeu (CachyOS, SteamOS, Bazzite), donc peu représentatif des postes de développeurs. La télémétrie KDE donne plus de 95 % de Wayland chez les utilisateurs de Plasma 6.6 (documenté).

### 1.2 Ce que chaque compositeur expose (mesuré)

Relevé par `wayland-info` dans chaque compositeur sans écran, et en lecture seule sur la session GNOME réelle. « SC caché » : le global disparaît pour un client en bac à sable (`wp_security_context_v1`), mesuré avec un client qui passe par ce protocole. Mutter sans écran expose exactement les mêmes globals que la session réelle (diff des deux listes, mesuré).

| Protocole | GNOME 51.1 réel et headless | KWin 6.8.3 | sway 1.12 | labwc 0.20.2 | Weston 15 |
|---|---|---|---|---|---|
| `zwlr_virtual_pointer_manager_v1` | non | non | v2, SC caché | v2, SC caché | non |
| `zwp_virtual_keyboard_manager_v1` | non | non | v1, SC caché | v1, SC caché | non |
| `org_kde_kwin_fake_input` | non | v6, SC caché | non | non | non |
| `zwlr_screencopy_manager_v1` | non | non | v3 | v3 | non |
| `ext_image_copy_capture_manager_v1` | non | non | v1 | v1 | non |
| `ext_foreign_toplevel_image_capture_source_manager_v1` | non | non | v1 | v1 | non |
| `ext_foreign_toplevel_list_v1` | non | non | v1 | v1 | non |
| `zwlr_foreign_toplevel_manager_v1` | non | non | v3 | v3 | non |
| `ext_data_control_manager_v1` | non | v1, SC caché | v1 | v1 | non |
| `zwlr_data_control_manager_v1` | non | non | v2 | v2 | non |
| `zwlr_layer_shell_v1` | non | v5 | v5 | v4 | non |
| `ext_idle_notifier_v1` | non | v2 | v2 | v2 | non |
| `ext_transient_seat_manager_v1` | non | non | oui | non | non |
| `org_kde_plasma_window_management`, `zkde_screencast_unstable_v1` | non | v21, v6, SC cachés | non | non | non |
| `wp_security_context_manager_v1` | non | v1 | v1 | v1 | non |
| `xdg_activation_v1` | v1 | v1 | v1 | v1 | non |
| `wl_seat` | oui | oui | oui | oui | aucun en headless |

Côté D-Bus (mesuré par `ListNames` et introspection) :
- Mutter, sur le bus de session : `org.gnome.Mutter.RemoteDesktop`, `ScreenCast` (version 4), `InputCapture`, `InputMapping`, `IdleMonitor`, `DisplayConfig`, `ServiceChannel`, `ColorManager`, et `org.freedesktop.a11y.Manager`.
- gnome-shell ajoute `org.gnome.Shell`, `org.gnome.Shell.Introspect`, `org.gnome.Shell.Screenshot` et `org.gnome.ScreenSaver`.
- KWin publie `org.kde.KWin` (`/KWin`, `/Scripting`, `/org/kde/KWin/EIS/RemoteDesktop`, `/org/kde/KWin/EIS/InputCapture`), `org.kde.KWin.ScreenShot2` (version 5) et `org.freedesktop.a11y.Manager`.
- Portails de la session réelle (propriétés lues seulement) : RemoteDesktop v2, ScreenCast v5, Screenshot v2, GlobalShortcuts v2, InputCapture v2 (mesuré).

Selon wayland.app (documenté, versions un peu antérieures aux locales) : Hyprland a les mêmes protocoles que sway, plus `layer-shell` v5. niri n'a pas `ext-image-copy-capture`. COSMIC a `ext-foreign-toplevel-list`, `ext-image-copy-capture`, `ext-data-control` et le clavier virtuel, mais ni pointeur virtuel `wlr` ni `wlr-foreign-toplevel-management` (computer-use-linux passe chez lui par ses protocoles `zcosmic_toplevel_*` et par le portail, vérifié dans `cul:src/bin/computer-use-linux-cosmic.rs`). KWin n'implémente volontairement ni `ext-image-copy-capture` ni `ext-foreign-toplevel-list` (bugs KDE 513785 et 483227 classés INTENTIONAL et NOT A BUG, documenté).

### 1.3 Conséquence

La détection doit identifier le compositeur, pas seulement Wayland contre X11. agent-desktop ne regarde que le socket qui répond (`ad:crates/linux/src/system/display/display_server.rs:60-90`, vérifié) et refuse donc tout ce qui n'est ni X11 ni Mutter. Les signaux disponibles sont `XDG_CURRENT_DESKTOP`, la présence des noms D-Bus (`org.gnome.Mutter.RemoteDesktop`, `org.kde.KWin`), les globals Wayland et les sockets IPC (`SWAYSOCK`, `HYPRLAND_INSTANCE_SIGNATURE`, `NIRI_SOCKET`) (déduit). La matrice ci-dessus montre que la bonne unité est la capacité, pas le nom du bureau : un backend Linux doit composer, à l'exécution, une table de capacités par famille (entrée, capture d'écran, capture de fenêtre, liste et gestion des fenêtres, presse-papiers, pointeur, détection de l'entrée physique) (déduit).

## 2. Structure cible

### 2.1 Ce que fait agent-desktop

| Fait | Preuve | Statut |
|---|---|---|
| Espace de travail Cargo : `crates/core`, `crates/linux`, `crates/windows`, `crates/macos`, `crates/ffi`, et le binaire dans `src/` | `ad:Cargo.toml:2-3` | vérifié |
| Le cœur définit l'interface de plateforme par traits : `ObservationOps`, `ActionOps`, `InputOps`, `SystemOps`, réunis dans `PlatformAdapter`, plus `AdapterSession` | `ad:crates/core/src/adapter/mod.rs:39`, `observation.rs:30`, `actions.rs:6`, `input.rs:9`, `system.rs:11`, `adapter_session.rs:9` | vérifié |
| Chaque crate de plateforme ne dépend que du cœur ; la sélection se fait par `cfg(target_os)` dans le binaire | `ad:crates/linux/Cargo.toml`, `ad:src/main.rs:37`, `:369` | vérifié |
| Le crate Linux : 1 027 fichiers Rust, 124 061 lignes, dossiers `actions`, `input` (`x11`, `wayland`), `system`, `tree`, `notifications` | `find crates/linux -name '*.rs' | xargs wc -l` | mesuré |
| Dépendances Linux directes : zbus 5.19 (D-Bus en Rust pur), x11rb 0.14 (X11 en Rust pur, extensions composite, damage, randr, shape, xkb, xtest), async-io, rustix, png. Ni libatspi, ni PipeWire, ni libwayland, ni libei | `ad:crates/linux/Cargo.toml:8-19` | vérifié |

### 2.2 Ce qu'a neo-compute aujourd'hui

`nc:src/main.zig:15-18` choisit à la compilation `backend/windows.zig` sous Windows et `backend/fake.zig` partout ailleurs. Le cœur appelle 58 méthodes sans condition : `fake.zig` les implémente toutes, c'est la spécification exécutable du contrat. Il sonde une vingtaine de capacités optionnelles par `@hasDecl` (vérifié, section 3). Le code Windows est déjà dans `src/backend/windows/`, à côté de `src/backend/windows.zig`.

### 2.3 Ce que la structure Linux doit prendre en compte (déduit)

- La même séparation qu'agent-desktop se traduit en Zig par un module par système dans `build.zig` : `core`, `backend/windows`, `backend/linux`, chacun avec son dossier. Le contrat reste celui que `fake.zig` implémente. Windows et Linux n'ont aucun fichier commun en dehors du cœur.
- Le choix de l'OS reste à la compilation, comme aujourd'hui. Sous Linux, le choix de l'environnement doit se faire **à l'exécution**, dans un seul binaire. Un même utilisateur passe d'une session GNOME à une session KDE, et une session GNOME fait tourner des clients Xwayland. agent-desktop fait aussi ce choix à l'exécution, mais seulement entre X11 et Mutter.
- Découpage naturel de `backend/linux/` selon les mesures :
  - des transports communs : fil D-Bus, fil Wayland, fil X11, xkb, evdev, EI ;
  - AT-SPI ;
  - un dossier par famille : `gnome`, `kde`, `wlroots`, `x11`, plus COSMIC ;
  - les composants à installer côté bureau : l'extension GNOME Shell en JavaScript, les scripts KWin en JavaScript.
- Les générateurs de liaisons suivent le même schéma que `tools/winmdgen` : une liste d'API dans un `.zon`, une source épinglée par hash, une sortie générée et des tests de disposition (section 8).
- À ne pas copier : un processus par commande (agent-desktop relance son binaire à chaque appel MCP, `ad:src/mcp/call.rs:26`, vérifié), ce qui interdit les entrées tenues et les connexions persistantes. Et l'absence d'identification du compositeur.

## 3. Le contrat du backend et ce que le cœur suppose de Windows

### 3.1 Les méthodes, par famille, et leur équivalent Linux

Le détail des 58 méthodes obligatoires (signatures, sémantique, appelants, implémentation Windows) est vérifié dans `nc:src/backend/fake.zig` et `nc:src/core/`. Coordonnées : pixels physiques du bureau virtuel, valeurs négatives possibles (`nc:src/core/display.zig:7-8`, vérifié). Le tableau donne l'équivalent par famille. Les détails et les preuves sont en section 4.

| Famille de méthodes | Rôle | GNOME | KDE | wlroots | X11 |
|---|---|---|---|---|---|
| `displays`, `displayInfo`, `foregroundDisplay` | écrans, échelle, zone de travail | `DisplayConfig.GetCurrentState` | script KWin, `wl_output`/`xdg_output` | `wl_output`/`xdg_output`, IPC | RandR |
| `capture`, `changes` | image d'un écran, zones modifiées | ScreenCast `RecordMonitor` (PipeWire) | `ScreenShot2.CaptureScreen` | `ext-image-copy-capture` | XShm, XDamage |
| `captureWindow` | fenêtre recouverte | ScreenCast `RecordWindow` | `ScreenShot2.CaptureWindow` | `ext-image-copy-capture`, source toplevel | Composite |
| `sendMouse`, `keyCombo`, `typeText`, `releaseAllInputs`, `cursorPosition` | entrée | RemoteDesktop et EI ; position par extension ou `a11y.Manager` | EIS ; `a11y.Manager` | pointeur et clavier virtuels | XTest, `XQueryPointer` |
| `windowAt`, `windowRef`, `windowRect`, `windowLayers`, `listWindows*`, `visibleWindows`, `topWindowStamp` | fenêtres, empilement, hit-test | extension Shell | script KWin | IPC du compositeur, `foreign-toplevel` (pas d'empilement) | EWMH |
| `focusWindow`, `placeWindow`, `showWindow`, `closeWindow`, `windowPlacement` | gestion | extension Shell | script KWin | IPC, `wlr-foreign-toplevel` | EWMH |
| `processName`, `appPid`, `processAncestors`, `processAlive`, `terminateProcess` | processus | `/proc`, pid par l'extension | `/proc`, pid par script | `/proc`, pid par IPC (sway) | `/proc`, `_NET_WM_PID` |
| `beginSecretScan`, `secretRects`, `secretScan` | champs mot de passe | AT-SPI et rectangle de fenêtre | idem | idem | AT-SPI (coordonnées écran) |
| `uiSnapshot`, `uiRoots`, `uiSubtree`, `uiElement`, `uiLive`, `uiOp`, `uiScrollHost`, `uiEntries`, `windowEvents`, `treeObserved` | arbre et actions | AT-SPI, commun à toutes les familles | | | |
| `guardArm`, `guardLinger`, `guardDisarm`, `restoreForeground`, `foregroundWindow` | garde du premier plan | extension Shell | script KWin | `foreign-toplevel` et IPC | EWMH |
| `appCatalog`, `launchApp`, `appExe`, `openPath`, `defaultApp`, `pathInfo`, `unsafeType`, `pathExtensions` | lancement | entrées `.desktop` (spécification freedesktop), types MIME | idem | idem | idem |
| `clipboardRead`, `clipboardWrite` | presse-papiers | presse-papiers de RemoteDesktop, ou extension | `ext-data-control` | `ext`/`wlr-data-control` | sélections X, XFixes |
| `registryValue`, `registryKey` | registre | aucun équivalent | | | |

Optionnels via `@hasDecl` : dans le cœur `uiNativeList`, `uiNativeSelect`, `type_pace_ns`, `uiAutoFocus`, `benchScenario` ; dans `main.zig` `initProcess`, `setCaptureMode`, les sondes, `init`, `deinit`, `startIndicator`, `stopIndicator`, `startKillSwitch`, `stopKillSwitch`, `acquireInstance`, `selftest`, `selftestBackground` (vérifié). Un backend Linux omettrait `uiNativeList` et `uiNativeSelect` (messages Win32) et `uiAutoFocus` (sans objet, section 5).

### 3.2 Ce qui, dans le cœur, est propre à Windows

« Nom » : renommage ou conversion. « Sens » : dépendance qu'un backend Linux ne peut pas satisfaire telle quelle. Tout est vérifié aux lignes citées.

| Concept | Où | Nature | Ce qu'il devient sous Linux (déduit) |
|---|---|---|---|
| Handle de fenêtre `u64` affiché et lu en hex (`0x1a2b`) | `nc:src/core/tools.zig:482-488`, `:536`, `:353` | nom sous X11 (XID) ; sens sous Wayland | un identifiant propre au backend : id Mutter (`Meta.Window.get_id()`, mesuré comme clé de `RecordWindow` et d'Introspect), UUID KWin, id `ext-foreign-toplevel`, XID. Garder au plus 53 bits pour les clients JSON (computer-use-linux le fait, `cul:src/windowing/types.rs:8`) |
| Noms `.exe` dans la politique, comparés sans casse | `nc:src/core/policy.zig:98-112`, `:136` ; `launch.zig:158,194,233` | sens : sous Linux, aucun processus ne s'appelle `KeePassXC.exe` ni `WindowsTerminal.exe`, donc les listes `deny` et `click` ne protègent plus rien | noms de processus Linux (`/proc/<pid>/comm`, `exe`) et identifiants d'application (`.desktop`, Flatpak) ; liste à refaire (`keepassxc`, `org.keepassxc.KeePassXC`, `1password`, `bitwarden`, `gnome-terminal-server`, `ptyxis`, `konsole`, `kitty`, `foot`, `alacritty`, `wezterm-gui`, `code`, `zed`) |
| `%APPDATA%` pour la politique, `%LOCALAPPDATA%` pour l'audit | `nc:src/main.zig:174-188` | sens : sous Linux, ni politique ni audit, seulement un message sur stderr | `$XDG_CONFIG_HOME/neo-compute/policy.json`, `$XDG_STATE_HOME/neo-compute/audit.jsonl` (décision d'Arthur, section 14) |
| elevated, UIPI, intégrité | `nc:src/core/display.zig:85,103,125`, `input.zig:18`, `actions.zig:14`, `screen.zig:259`, `uitree.zig:338` | nom, mais l'invariant de sécurité devient vide | processus d'un autre uid, dialogue polkit et écran de verrouillage (section 7) |
| `cloaked`, `other_desktop` | `nc:src/core/display.zig:105-108`, `tools.zig:364,557-560` | nom | fenêtre sur un autre espace de travail, fenêtre cachée |
| DPI 96, `scaled` | `nc:src/core/display.zig:90`, `tools.zig:576`, `screen.zig:246` | sens sous Wayland : échelles fractionnaires, coordonnées logiques | pixels physiques = logiques x échelle (mesuré, section 4.1) |
| Rôles issus des ControlType UIA ; noms de patterns dans les erreurs ; `Op.legacy` = MSAA | `nc:src/core/uitree.zig:11-54`, `:270` ; `a11y.zig:905-915`, `:1299`, `:1312-1317` | nom | correspondance avec les rôles et interfaces AT-SPI |
| Défilement en pourcentage par axe (`SetScrollPercent`) | `nc:src/core/uitree.zig:95-104`, `:283-285` | sens : AT-SPI n'a pas de pattern Scroll en pourcentage | `Value` de la barre de défilement quand elle existe, sinon `Component.ScrollTo` (section 5) |
| Clé d'élément = hash du RuntimeId ; texte en UTF-16 | `nc:src/core/uitree.zig:113`, `:250-261` ; `input.zig:20-22` | nom | nom de bus unique + chemin d'objet AT-SPI ; conversion UTF-8 |
| Heuristiques Chromium (`Chrome_WidgetWin_*`, `renders_covered` sur `Code.exe`, `frozen_*`, `lagging`, `Owner.web`) | `nc:src/core/display.zig:147-160`, `uitree.zig:147,180-185,712`, `a11y.zig:62-148,1086-1117` | sens : mesurées sous Windows ; sous Wayland, un client recouvert ne reçoit plus d'appels de trame (mesuré pour GTK, section 4.1) | à remesurer pour Chromium sur chaque compositeur |
| `firefox_no_tree`, « Electron arbre vide », bureau = barre des tâches | `nc:src/core/uitree.zig:178-185`, `a11y.zig:585-592` | sens | conditions d'activation de l'arbre propres à Linux (section 5) |
| Formats `CF_*` et marqueurs `ExcludeClipboardContentFromMonitorProcessing`, `CanIncludeInClipboardHistory`, `CanUploadToCloudClipboard` | `nc:src/core/clipboard.zig:24-90`, `tools.zig:451` | sens | types MIME et `x-kde-passwordManagerHint` (mesuré sous X11, section 4.5) |
| `registry_read` | `nc:src/core/tools.zig:466-479`, `regread.zig` | sens, et contrat produit | décision d'Arthur |
| `app_launch` : AUMID, menu Démarrer, `ms-settings:`, « refusé par Windows (0x hr) » | `nc:src/core/tools.zig:433`, `apps.zig:12-29,351`, `launch.zig:124,243` | sens | catalogue `.desktop`, identifiants d'application |
| Règles de chemins : `\\`, lettre de lecteur, flux NTFS, `{CLSID}`, PATHEXT, `explorer.exe` pour un dossier | `nc:src/core/launch.zig:23-95`, `:232` | sens | bit d'exécution, shebang, `.desktop` et AppImage refusés comme documents, chemins sensibles à la casse |
| Processus protégés (explorer, csrss, lsass) | `nc:src/core/windowctl.zig:21` | sens | gnome-shell, kwin_wayland, Xwayland, gdm, polkit, le serveur lui-même |
| Sélection native CBN/LBN | `nc:src/core/uitree.zig:306-358`, `a11y.zig:1533-1600` | optionnel | omis |
| Instructions MCP « this Windows desktop » ; descriptions d'outils (Start menu, AUMID, HKCU, cloaked) | `nc:src/core/mcp.zig:36,49,59` ; `tools.zig:353,364,433,451,468` | nom, mais contrat produit | texte par OS (décision d'Arthur) |
| `keys.zig` | `nc:src/core/keys.zig:2,127-128` | portable (noms de style X11) | rien |

### 3.3 Ce qui s'éteint sans prévenir

- **Instance unique** : sans `acquireInstance`, chaque instance se croit seule (`nc:src/main.zig:193`, vérifié). Équivalent : un verrou `flock` dans `$XDG_RUNTIME_DIR`, par affichage (déduit).
- **Kill switch** : sans `startKillSwitch`, il n'y a aucun arrêt physique, et rien ne le signale (vérifié).
- **Politique et audit** : section 3.2.
- **Garde du premier plan** : si `foregroundWindow` rend `null`, la garde ne s'arme jamais (`nc:src/core/mcp.zig:617-631`, vérifié). C'est ce que donnerait un backend Wayland qui ne lit pas le premier plan.
- **Bench** : `.unsupported => continue` (`nc:src/core/bench.zig:346`, vérifié) laisse passer le gate avec 2 scénarios sur 16 (mesuré).
- **Signaux** : aucun gestionnaire de SIGINT ou SIGTERM dans `nc:src/` (vérifié par recherche). Sous Linux, Claude Code commence par SIGINT, dont l'action par défaut tue le processus sans passer par `releaseAllInputs` (`nc:src/core/mcp.zig:371,583,587`, vérifié). Le relâchement dépend alors du transport (section 7).

## 4. Outil par outil, environnement par environnement

Chaque ligne donne le moyen, puis les limites, et le statut. Les chiffres sont des médianes et des p95 sur la machine, avec d'autres sondes en parallèle (charge moyenne entre 0,6 et 3,8, et jusqu'à 10 pendant quelques mesures de processeur de la capture GNOME) : ce sont des ordres de grandeur.

### 4.1 GNOME (Mutter et gnome-shell 51.1)

| Outil | Moyen | Limites | Statut |
|---|---|---|---|
| `screenshot` (écran) | `org.gnome.Mutter.ScreenCast` : `CreateSession`, `RecordMonitor(connecteur)`, `Start`, puis lecture du nœud PipeWire (cible = `object.serial` du nœud, pas son id) | Aucun dialogue. Une session vit tant que la connexion D-Bus qui l'a créée, donc dans le processus du serveur. Images seulement sur dommage (0 image en 15 s d'écran statique) : une image fraîche suppose de garder le flux ouvert, ou d'ouvrir une session (Start jusqu'à la première image : 20 à 37 ms). BGRx en memfd, ou DMA-BUF si le lecteur nomme un modificateur NVIDIA. Toute session allume l'indicateur « partage d'écran » de la barre du haut, cliquable pour tout arrêter, encore visible 1,8 s ou plus après l'arrêt | mesuré |
| | `org.gnome.Shell.Screenshot` | Refusé à un processus ordinaire (« Screenshot is not allowed »). Seuls les noms `org.gnome.SettingsDaemon.MediaKeys` et `org.freedesktop.impl.portal.desktop.gnome` y ont droit, et ils sont pris sur la session réelle | mesuré ; `gs:ui/screenshot.js:2848-2851` vérifié |
| | Portail Screenshot v2, non interactif | Autorisation rangée par identifiant d'application de l'hôte (tiré du cgroup : `paneflow` ici, `{'paneflow': ['yes']}` lu en direct). Sans accord enregistré : échec en 4 ms. Avec : 516 ms, fichier PNG déposé dans le dossier personnel | mesuré |
| | Extension GNOME Shell qui capture dans le Shell et rend l'image par un memfd | Éviterait PipeWire et l'indicateur | déduit, à sonder |
| `screenshot` avec `window`, `zoom` sur une fenêtre | ScreenCast `RecordWindow({'window-id': id})`, l'id étant `Meta.Window.get_id()` (le même que les clés d'Introspect) | Fenêtre entièrement recouverte : ses propres pixels (contrôle visuel : la fenêtre jaune, absente de la capture de l'écran, est entière dans le flux). Le flux **dégèle** le client recouvert : sans flux, un client GTK recouvert ne dessine plus (0 dessin pour 490 changements en 10 s) ; avec, 490 sur 490. Un changement apparaît dans le flux en 17,7/18,6 ms. Fenêtre sur un autre espace de travail : juste. Fenêtre minimisée : image fausse (un bloc de contenu sans barre de titre), inutilisable. Image = scène logique x ceil(échelle), fenêtre en haut à gauche | mesuré |
| clics, `mouse_move`, `left_click_drag`, `left_mouse_down`/`up` | `RemoteDesktop.NotifyPointerMotionAbsolute(stream, x, y)` (flux ScreenCast du moniteur, chemin passé en chaîne `s`), `NotifyPointerButton` (272, 273, 274 = gauche, droit, milieu) ; ou EI, dont le « shared virtual absolute pointer » couvre le moniteur sans aucun ScreenCast ni PipeWire | Position sous-pixel exacte. Appel D-Bus 0,16/0,23 ms ; injection jusqu'à l'événement GTK 0,33/0,40 ms (bouton). Double et triple clic : comptés par le toolkit (fenêtre GTK de 400 ms). Pièges : un clic sans mouvement préalable dans une session neuve est perdu (0/12) ; la première touche après `Start` est perdue (le clavier virtuel naît à la première touche). Une fenêtre inactive cliquée devient active | mesuré |
| `scroll` | `NotifyPointerAxis(dx, dy, flags)` (flag 2 = molette, 10 px = 1 cran) ; `NotifyPointerAxisDiscrete(axe, pas)` | Vertical et horizontal | mesuré |
| `cursor_position` | `org.freedesktop.a11y.Manager`, `PointerLocator.QueryPointer` : rend la position et le pid sous le pointeur | Refusé sauf si l'appelant possède le nom `org.gnome.Orca.KeyboardMonitor`, que tout processus peut prendre quand Orca ne tourne pas (`<allow own="*"/>` de `session.conf:35`) : 0,16 à 0,20 ms. Une fois sur deux, la première lecture après un mouvement a rendu `x=0` (cause non établie). Autre voie : `global.get_pointer()` dans une extension (0,21 ms, coordonnées logiques) | mesuré |
| `type` | `NotifyKeyboardKeysym` (Mutter ajoute lui-même Shift) | Un caractère absent de la disposition active (é, ü, emoji, CJK en `us`) est **abandonné en silence** : l'appel réussit, seul le journal de Mutter dit « No keycode found ». Contournements mesurés : lire la disposition par EI (le périphérique clavier EI publie la keymap XKB du compositeur) pour savoir à l'avance ce qui passe ; ou passer par le presse-papiers de la session RemoteDesktop (`EnableClipboard`, `SetSelection`, `SelectionWrite`, puis Ctrl+V : « é ü 😀 中文 » arrivé), qui remplace le presse-papiers de l'utilisateur. Ctrl+Maj+U ne marche pas sans IBus. Mutter 51 n'exporte aucun symbole EI de texte (`nm -D libmutter-51.so.0` : 92 imports `eis_*`, aucun `*text*`) | mesuré |
| | `RemoteDesktop.SetKeymap(a{sv})` (nouveau en 51) | **Fait planter Mutter** : 2 appels sur 2, SIGSEGV dans `meta_keymap_description_create_xkb_keymap` (core dumps 596321 et 602516). Sur la session réelle, ce serait la mort de GNOME Shell et de la session. Ne jamais l'appeler | mesuré |
| `key` | `NotifyKeyboardKeycode` (codes evdev ; xkb = evdev + 8) ou keysym | Latence 0,29/0,36 ms jusqu'à l'application | mesuré |
| `hold_key` et boutons tenus | appuis tenus sur la session | Relâchement par Mutter : `Stop` 1,2/1,5 ms ; fermeture de la connexion D-Bus 1,1/1,3 ms ; `kill -9` du processus 2,6/3,0 ms (max 3,15). Par EI : `kill -9` du client 0,65/0,86 ms. Un processus **figé** (SIGSTOP) garde ses touches : Mutter n'a pas de minuterie, et la répétition se fait dans l'application. Piège EI : si une copie du descripteur EIS reste ouverte ailleurs, rien n'est relâché avant le `Stop` (4 s, 125 répétitions) | mesuré |
| `wait` | rien | | |
| `ui_tree`, `ui_find`, `ui_act` | AT-SPI (section 5). Mutter 51 expose sur chaque fenêtre `a11y-dbus-name` et `a11y-object-path` : le lien direct fenêtre vers objet AT-SPI | Coordonnées : rectangle de la fenêtre par l'extension, combiné aux coordonnées AT-SPI relatives à la fenêtre | vérifié (typelib Meta-51) ; combinaison déduite |
| `window_list` | Extension GNOME Shell sur D-Bus : id, titre, wm_class, app id, pid, cadre et tampon, écran, rang dans `global.display.sort_windows_by_stacking`, minimisée, focus, espace de travail | 0,27/0,32 ms. `Introspect.GetWindows` ne suffit pas : réservé aux noms des portails (« GetWindows is not allowed »), et sans position, ni empilement, ni pid, ni espace de travail. Le mode « unsafe » l'ouvre mais affiche une notification | mesuré ; `gs:misc/introspect.js:7-10`, `:147-176` vérifié |
| `window_focus` | Extension : `Main.activateWindow`, ou `Meta.Window.focus` | Marche sans jeton d'activation, focus acquis au retour de l'appel (20/20) : 0,51/1,0 ms | mesuré |
| `window_set` | Extension : `move_resize_frame`, `minimize`/`unminimize`, `maximize`/`unmaximize`, `delete`, `raise` | Aucune ne change le focus. Cadre atteint après l'accusé du client en 16,3/18,1 ms (une trame) ; restauration sans focus (0/20 focus) ; fermeture en 6,6/7,0 ms ; `raise` sans focus 0,28 ms | mesuré |
| `app_launch` | Entrées `.desktop` ; lancement direct, par `gio launch`, ou par l'extension (`Shell.App.open_new_window`, qui fournit un jeton d'activation) | Avec la politique `smart` de Mutter, une nouvelle fenêtre GTK prend le focus et passe devant dans 21 cas sur 21, avec ou sans jeton, même pendant une frappe toutes les 50 ms. Seul un `present()` tardif sans jeton est refusé (`demands-attention`) | mesuré |
| `clipboard` | Presse-papiers de la session RemoteDesktop (`EnableClipboard`, `SelectionRead`, `SetSelection`, signal de changement de propriétaire), ou `St.Clipboard` dans l'extension | Mutter n'a pas de `data-control` : un client Wayland ordinaire ne lit le presse-papiers qu'avec le focus. L'écriture par RemoteDesktop est mesurée, la lecture et le signal ne le sont pas | écriture mesurée, lecture déduite |
| `registry_read` | aucun équivalent | dconf et gsettings sont la chose la plus proche (décision d'Arthur) | déduit |
| Indicateur | Extension : `St.Label` dans `uiGroup`, `reactive: false`, `can_focus: false` | Dessiné au-dessus des fenêtres ; un clic en son centre atteint la fenêtre dessous. Présent dans `RecordMonitor` et `RecordArea`, **absent de `RecordWindow`**. Aucune API n'exclut un acteur d'un flux d'écran | mesuré ; typelibs vérifiés |
| Écrans | `DisplayConfig.GetCurrentState` | Session réelle : DP-3 et DP-4, 2560x1440 à 144 Hz, échelle 1, mode de disposition logique ; échelles proposées 1 à 2,667, fractionnaires comprises (plus de drapeau expérimental dans le schéma). Flux d'écran en pixels physiques ; rectangles de fenêtres et pointeur en logique ; pixel = logique x échelle (mesuré à 2 et 1,5) | mesuré |

Verrouillage de l'écran (mesuré dans le gnome-shell privé, avec un faux GDM) :
- `org.gnome.ScreenSaver.Lock` rend la main en 264 ms.
- Sous le verrou, aucune entrée injectée n'atteint l'application, mais elle réveille l'invite de déverrouillage. Avec le vrai GDM, des touches injectées iraient dans le champ du mot de passe (déduit).
- `SetActive(false)` déverrouille **sans mot de passe** (2 sur 2). Le code le confirme : `gs:ui/shellDBus.js:545-550` appelle `screenShield.deactivate`, `gs:ui/screenShield.js:531-541`, que seul le contrôle parental du temps d'écran bloque (vérifié).

Ce que le backend doit en tirer :
- refuser d'agir quand `org.gnome.ScreenSaver.GetActive` vaut `true`, comme le bureau sécurisé sous Windows ;
- ne jamais appeler `SetActive`.

### 4.2 KDE (KWin 6.8.3, mesuré en headless)

| Outil | Moyen | Limites | Statut |
|---|---|---|---|
| `screenshot` | `org.kde.KWin.ScreenShot2.CaptureScreen`, `CaptureWorkspace`, `CaptureArea` (image écrite dans un pipe, sans PipeWire) | `CaptureScreen` 1280x800 3,8/7,0 ms. RGBX8888. Aucune autorisation demandée à un processus sans `.desktop` ; ni `screenshot.so` ni `libkwin.so.6` ne contiennent la chaîne `X-KDE-DBUS-Restricted-Interfaces`, alors que la documentation KDE de 2020 décrit cette règle et que les `.desktop` de Spectacle et du portail la déclarent | mesuré ; règle documentée ; à confirmer dans une vraie session Plasma |
| fenêtre seule | `ScreenShot2.CaptureWindow` | Fenêtre entièrement recouverte : ses propres pixels, décoration Breeze comprise (contrôle visuel). Minimisée : capturée aussi. Contenu frais sous couverture (un compteur avance entre deux captures). 1,85/2,57 ms. RGBA8888 prémultiplié, marge d'ombre incluse | mesuré |
| entrée | EIS : `org.kde.KWin.EIS.RemoteDesktop.connectToEIS(i)` rend un descripteur et un cookie, sans dialogue | Capacités : pointeur, absolu, clavier, tactile, défilement, boutons, **texte**. Touche 0,11/0,27 ms ; clic 0,18/0,29 ms. Touche tenue puis `kill -9` : relâchée 3,2 à 4,3 ms après. KWin coupe le contexte si l'appelant D-Bus quitte le bus | mesuré (envoi de texte UTF-8 par EI non mesuré) |
| | `org_kde_kwin_fake_input` | Utilisable sans `.desktop` (`X-KDE-Wayland-Interfaces` n'est pas appliqué), mais une touche tenue n'est **pas** relâchée à la mort du client (répétition encore 21 s après) : à éviter | mesuré |
| `cursor_position` | `a11y.Manager.QueryPointer` | Libre sous KWin, rend aussi le pid sous le pointeur | mesuré |
| `window_list`, `window_focus`, `window_set` | Script KWin chargé par `/Scripting.loadScript` depuis le bus de session, sans autorisation ; canal persistant : le script appelle une méthode du serveur en attente longue, et répond par une autre | Champs : UUID, titre, pid, `resourceClass`, `desktopFileName`, `frameGeometry` en coordonnées logiques fractionnaires, `stackingOrder`, actif, minimisé, écran. Lister 0,17/0,24 ms ; activer 0,24/0,34 ms ; déplacer, redimensionner, minimiser, restaurer, monter **sans changer la fenêtre active** (30/30, 40/40) ; le redimensionnement s'applique à la trame suivante (16,6 ms) ; fermer : fenêtre retirée en moins de 300 ms. Un script lancé puis déchargé à chaque requête coûte 1,04/1,44 ms | mesuré |
| `clipboard` | `ext-data-control` v1 | Sans focus ; `wl-paste` s'y lie | mesuré |
| `ui_*` | AT-SPI ; correspondance cadre AT-SPI et géométrie KWin | computer-use-linux apparie le rectangle du cadre AT-SPI aux géométries KWin et exige une correspondance unique | vérifié (`cul:src/windowing/backends/kwin.rs:1322-1367`) |
| Indicateur | `zwlr_layer_shell_v1` v5 (surface au-dessus de tout, région d'entrée vide) | Exclusion de la capture : option `hide-caller-windows` de ScreenShot2 | layer-shell mesuré ; exclusion déduite |
| Verrouillage | kscreenlocker | Verrouille KWin headless après 5 min sans saisie ; la fenêtre de verrouillage entre dans `stackingOrder` | mesuré |

### 4.3 wlroots et apparentés (sway 1.12, labwc 0.20.2 mesurés ; Hyprland, niri documentés)

| Outil | Moyen | Limites | Statut |
|---|---|---|---|
| `screenshot` | `ext-image-copy-capture` (source sortie) ou `wlr-screencopy` | `grim` complet (processus compris) 16 ms, soit une trame | mesuré |
| fenêtre seule | `ext-image-copy-capture` avec une source `ext-foreign-toplevel` | Fenêtre entièrement recouverte : contenu juste et frais (compteur qui avance). 2,1/2,3 ms. Sans décoration. niri n'a pas ce protocole (documenté) | mesuré |
| entrée | `zwlr_virtual_pointer_v1`, `zwp_virtual_keyboard_v1` (le client fournit sa keymap, donc tout caractère passe) | Touche 0,08/0,11 ms, clic 0,16/0,22 ms. La première touche envoyée avec la keymap est perdue ; il faut attendre environ 200 ms. Une touche tenue n'est **pas** relâchée à la mort du client : répétition encore 38 s après (sway). Seul « appui puis relâchement » depuis un nouveau client débloque. Chaque connexion d'un clavier virtuel donne `enter` puis `active` au client : garder un clavier persistant. COSMIC n'a pas le pointeur virtuel (documenté) | mesuré |
| siège séparé pour l'agent | `ext_transient_seat_manager_v1` (sway) | computer-use-linux s'en sert pour taper sans prendre le focus de l'utilisateur, mais GTK et Chromium ne voient pas un second siège (`cul:src/agent_seat.rs:1243-1257`) | protocole mesuré ; limite vérifiée chez computer-use-linux |
| `cursor_position` | aucun protocole | non mesuré par IPC | déduit |
| `window_list` | `ext-foreign-toplevel-list` (ni géométrie ni pid ; 0,14 ms) ; IPC sway `get_tree` (géométrie, pid, app_id, focus ; 0,09/0,12 ms) ; Hyprland `hyprctl clients -j`, niri IPC (vérifié chez computer-use-linux) | Pas d'empilement dans les protocoles. Dans sway, `visible` vaut true pour une fenêtre entièrement recouverte : c'est la visibilité de l'espace de travail, pas l'occultation. Pas de minimisation, remplacée par le scratchpad | mesuré |
| `window_focus`, `window_set` | `wlr-foreign-toplevel-management` (activer, minimiser, fermer, plein écran) ; IPC sway (`focus`, `move`, `resize`, `kill`) | sway : focus 0,13 ms, déplacement 0,05 ms sans changer le focus, `kill` jusqu'à disparition 1,2/2,0 ms. labwc n'a pas d'IPC de gestion : ni déplacement ni redimensionnement | mesuré |
| `clipboard` | `ext-data-control` ou `wlr-data-control` | Depuis un processus sans surface : 20/20 ; notification de changement 12 ms processus compris | mesuré |
| Indicateur | `layer-shell` | | déduit |
| Bac à sable | `wp_security_context_v1` cache 20 globals | Un serveur lancé depuis un client en bac à sable (Flatpak) ne verrait plus rien | mesuré |

### 4.4 COSMIC (non mesuré)

Le protocole d'entrée du pointeur manque (`wlr-virtual-pointer`). computer-use-linux passe donc par le portail RemoteDesktop et EIS, avec un binaire auxiliaire pour `ext-foreign-toplevel` et les protocoles `zcosmic_toplevel_*` (vérifié dans `cul:src/remote_desktop.rs:2130-2159` et `cul:src/bin/computer-use-linux-cosmic.rs`). Aucun cosmic-comp n'est installé ici : tout est documenté ou vérifié chez computer-use-linux, rien n'est mesuré.

### 4.5 X11 (mesuré sur Xvfb et openbox, puis sur le Xwayland d'un Mutter privé)

| Outil | Moyen | Limites | Statut |
|---|---|---|---|
| `screenshot` | `XShmGetImage` de la racine | 1920x1080 : 157/168 µs (contre 4,6 ms pour `XGetImage`). Sous un compositeur, agent-desktop refuse la racine, qui ne contiendrait que la scène du gestionnaire (`ad:crates/linux/src/system/capture/fullscreen_route.rs:18-25`) : non revérifié ici | mesuré ; réserve vérifiée chez agent-desktop |
| fenêtre seule | Composite : `XCompositeRedirectWindow` puis `NameWindowPixmap` | Fenêtre recouverte : contenu propre. Une fenêtre GTK 4 (profondeur 32) est déjà redirigée par le serveur. Fenêtre réduite (démappée sous openbox) : `BadMatch`. `XDamage` compte les changements d'une fenêtre (0 au repos ; le clignotement du curseur GTK compte) | mesuré |
| entrée | XTest | 12 à 16 µs jusqu'à l'événement. Caractère hors disposition : réaffectation d'un keycode libre, fiable à partir de 1 ms entre caractères (0/10 à 0 ms) | mesuré |
| entrées tenues | | Le serveur X les garde enfoncées quand l'injecteur meurt, quelle que soit la façon (répétition : 32 « X » en 1,6 s). Tout autre client peut les relâcher. Un processus fils qui garde sa propre connexion et lit un pipe relâche tout en 0,26/0,38 ms à la mort du parent. Piège : avec `PR_SET_PDEATHSIG(SIGKILL)`, le fils meurt avant de relâcher (30/30) | mesuré |
| entrée physique | événements bruts XI2.2 sur la racine, sans grab ni droits root | `sourceid` différent pour les esclaves « Virtual core XTEST » : l'équivalent exact de `LLMHF_INJECTED`. XRecord nomme même le client qui a injecté. Xvfb n'a pas de vrai périphérique : le cas physique n'est pas mesurable ici | mesuré (structure) ; physique déduit |
| `cursor_position` | `XQueryPointer` | | mesuré |
| fenêtres | EWMH : `_NET_CLIENT_LIST_STACKING`, `_NET_FRAME_EXTENTS`, `_NET_WM_PID`, `_NET_ACTIVE_WINDOW`, `_NET_MOVERESIZE_WINDOW`, `_NET_WM_STATE`, `_NET_CLOSE_WINDOW`, `_NET_RESTACK_WINDOW` | Activation 0,44 ms, déplacement 0,36 ms, réduction 0,36 ms, fermeture 0,33 ms ; monter sans focus 0,07 à 0,14 ms. L'occultation se calcule depuis l'empilement et les cadres (1 137 points de grille sur 1 137 conformes aux pixels). Restaurer une fenêtre réduite sans l'activer : aucune voie sous openbox. Les fenêtres override-redirect (menus) manquent à la liste | mesuré |
| `clipboard` | sélections X ; XFixes `SelectSelectionInput` | Lecture 0,24 ms ; chaque changement de propriétaire compté ; le contenu meurt avec son propriétaire (le serveur, persistant, peut en être un). La cible `x-kde-passwordManagerHint` apparaît et traverse le pont X11 vers Wayland | mesuré |
| Indicateur | fenêtre override-redirect, région d'entrée XShape vide | Laisse passer les clics. Présente dans `XGetImage` de la racine : X n'a pas d'équivalent de `WDA_EXCLUDEFROMCAPTURE`. La démapper le temps d'une capture coûte 0,34 ms sans compositeur, 1,1 ms avec picom | mesuré |
| Entrée « en arrière-plan » par `XSendEvent` | | GTK 4 ignore ces événements synthétiques | mesuré |

Xwayland sur GNOME : un « backend X11 » sur un bureau Wayland ne suffit pas.
- XTest n'atteint jamais une fenêtre GTK 4 Wayland : 0 événement sur 3 essais, le clic tombe sur la fenêtre de garde de Mutter. Il n'atteint que les clients X11 (mesuré).
- Chaque nouveau client XTest fait ouvrir par Xwayland (`-enable-ei-portal`) une session de portail RemoteDesktop. Sur la vraie session, on attend un dialogue de consentement par client (mesuré en privé sans gnome-shell ; dialogue déduit).
- `XGetImage` de la racine échoue en `BadMatch` (mesuré).
- `_NET_CLIENT_LIST` ne liste que les clients X11 (mesuré).
- Le presse-papiers est relié dans les deux sens (mesuré).

## 5. Accessibilité (AT-SPI)

### 5.1 Ce qui est établi par le code des deux références

| Fait | Preuve | Statut |
|---|---|---|
| Lecture en appels D-Bus bruts (zbus), un appel par propriété, parcours en largeur avec 32 nœuds en vol ; ni `Cache`, ni `Collection` | `ad:crates/linux/src/tree/properties/node_read.rs:148-285`, `tree/walk/walker_expand.rs:139` | vérifié |
| `Properties.GetAll` fait planter Qt 6.4 (SIGSEGV) ; `Cache.GetItems` répond `UnknownMethod` sur GTK3 et Chromium, une liste vide sur Qt, et marche sur GTK 4 (7 fois plus rapide selon la sonde) | `ad:probes/linux/FINDINGS.md` lignes L41-7, L2-6, L2-7 | vérifié (mesures d'agent-desktop sous Ubuntu 24.04) |
| Coût mesuré chez agent-desktop : 0,2 à 0,3 ms par appel, environ 3 ms par nœud ; Calculatrice 71 ms, Fichiers 177 ms, Firefox 890 ms | `ad:probes/linux/FINDINGS.md:67,439,452,994` | vérifié |
| Activation : un `RegisterEvent("window:activate")` à la connexion, sinon Chromium ne pose jamais `ACTIVE` | `ad:crates/linux/src/system/bus/mod.rs:94-110` | vérifié |
| Chromium : l'arbre s'active si un processus `orca` tourne, ou avec `ACCESSIBILITY_ENABLED=1`, `--force-renderer-accessibility`, ou la clé `toolkit-accessibility`. Qt 6 demande `IsEnabled` et `ScreenReaderEnabled`, ou `QT_LINUX_ACCESSIBILITY_ALWAYS_ON`. accesskit_unix (applications Rust comme Zed) suit `IsEnabled`. Sur cette machine, la combinaison réellement nécessaire est en 5.2 | sources Chromium et Qt, `accesskit_unix` 0.16 ; chaînes `ACCESSIBILITY_ENABLED` et `toolkit-accessibility` présentes dans le binaire de Chrome 157 | documenté ; chaînes mesurées |
| Actions sans effet sur le focus ni le pointeur : `DoAction`, `EditableText`, `Value`, `Selection` sur 68 actions ; `GrabFocus` active la fenêtre dans 2 cas sur 3 | `ad:probes/linux/FINDINGS.md:145`, `:139` | vérifié |
| Pièges : Gecko accepte `EditableText` sans rien changer ; Chromium n'a pas `EditableText` ; un objet détruit répond encore environ 16 s (GTK3, Chromium) ; `InsertText` compte en octets UTF-8 sous GTK et en unités UTF-16 sous Qt ; WebKit ne répond pas à `GetActions` (il faut `NActions` et l'index) ; WebKit donne un nom de bus bien connu qu'il faut résoudre en nom unique | `ad:probes/linux/FINDINGS.md:594,595,422,427` ; `ad:crates/linux/src/tree/properties/toolkit_trust.rs:151-156` ; `cul:src/atspi_tree.rs:286-301`, `:2314-2351` | vérifié |
| GTK 4 renvoie `[0,0,w,h]` pour les extents écran, même sous X11 ; sous Wayland aucune position globale | `ad:probes/linux/FINDINGS.md:177,318,329` | vérifié |
| Mots de passe : rôle 40 (`PASSWORD_TEXT`). agent-desktop ne lit jamais la valeur, mais ne masque rien dans ses captures ; computer-use-linux lit le texte de tout nœud et renvoie en écho, dans sa réponse, la valeur passée à `set_value` | `ad:crates/linux/src/tree/properties/value_read.rs:64-79` ; `cul:src/server.rs:2248` | vérifié |
| Attentes : agent-desktop réveille par signal un sondage de 100 ms, avec une nouvelle connexion par attente ; computer-use-linux dort 120 ms fixes | `ad:crates/linux/src/system/subscription.rs:199-250`, `wait_scheduler.rs:5-35` ; `cul:src/server.rs:6898` | vérifié |

### 5.2 Mesures sur cette machine

Banc : Mutter sans écran et Xvfb avec openbox, at-spi2-core 2.62.1 lancé à la main. Client de mesure natif en C sur sd-bus (`walk.c`), représentatif d'un client Zig ; les scripts Python sont 2 à 3 fois plus lents. Charge de la machine entre 1,7 et 4,8 sur 16 cœurs. Sur la session réelle, seulement des lectures.

Activation :

| Fait | Preuve | Statut |
|---|---|---|
| `org.a11y.Status` n'expose plus que `IsEnabled` (plus de `ScreenReaderEnabled`) | introspection et `Get` sur la session réelle | mesuré |
| Dans at-spi2-core 2.62, `IsEnabled` ne suit plus la clé `toolkit-accessibility`. Il passe à `true` dès qu'un client enregistre un écouteur (`Registry.RegisterEvent`), et le lanceur écrit alors la clé à `true` par dconf. Il repasse à `false` au départ du dernier écouteur, et la clé reste `true`. Une lecture d'arbre seule ne change rien | `dbus-monitor` privé : le lanceur (`:1.1`) envoie `ca.desrt.dconf.Writer.Change`, puis `PropertiesChanged IsEnabled` ; chaînes `EventListenerRegistered` et `toolkit-accessibility` dans `/usr/libexec/at-spi-bus-launcher` | mesuré en privé ; binaire vérifié |
| GTK 4 et GTK 3 s'enregistrent même avec `IsEnabled` à `false` | registre privé : Éditeur de texte, Calculatrice, Fichiers, fixture, portail GTK | mesuré |
| Qt 6 (KWrite) n'apparaît qu'au passage de `IsEnabled` à `true`, sans relance, et reste ensuite ; ou d'emblée avec `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1` | registre avant et après | mesuré |
| Chrome 157 est absent avec `IsEnabled` à `false`, même avec `--force-renderer-accessibility`. Avec `IsEnabled` à `true` (ou `ACCESSIBILITY_ENABLED=1`) mais sans le drapeau, il n'expose que 3 nœuds, et l'enfant du cadre est la référence nulle, même après 30 s. Avec les deux, 792 nœuds sont complets dès la première requête (217 à 0,25 s du lancement, 792 à 0,59 s) | parcours privés | mesuré |
| Zed 1.29.2 (GPUI, accesskit_unix 0.22.1), lancé sans réseau sous Wayland puis X11, avec un écouteur actif depuis 30 s : jamais connecté au bus. accesskit_unix ne se connecte que tant que `IsEnabled` vaut `true` et se désactive quand il repasse à `false` (`context.rs:142-166`, `:184-205`) | registre, pids du bus | mesuré ; cause de l'absence inconnue |
| Banc : `dbus-run-session` ne peut pas activer `org.a11y.Bus` (« Permission denied », SELinux probable). Il faut lancer `at-spi-bus-launcher --launch-immediately` et `at-spi2-registryd` à la main | journal du bus privé | mesuré |

Coût d'un instantané (rôle, nom, états, rectangle, valeur, enfants), p50/p95 en ms, n=20 :

| Application (nœuds) | Un appel à la fois | Tout un niveau en vol | `Cache.GetItems` seul | GetItems puis rectangles et valeurs en vol |
|---|---|---|---|---|
| fixture GTK 4 (135) | 47,0/50,3 | 21,5/28,2 | 1,05/1,24 | 9,4/10,3 |
| Calculatrice GTK 4 (105) | 40,9/50,3 | 13,3/16,3 | | |
| Éditeur de texte GTK 4 (83) | 30,4/31,8 | 10,7/11,8 | | |
| Fichiers GTK 4 (151) | 56,9/61,1 | 19,5/22,1 | 1,03/1,33 | |
| KWrite Qt 6 (272) | 81,8/88,8 | 11,3/12,5 | tableau vide | |
| Chrome, interface et page (792) | 197,9/208,6 | 43,6/46,5 | 5,30/5,56 | 21,8/24,5 |

- GTK 4 est limité par le fournisseur : la fixture consomme 28 ms de processeur par instantané, autant que le temps mur (mesuré).
- `Cache.GetItems` rend chemin, parent, nombre d'enfants, interfaces, nom, rôle, description et états ; ni rectangle, ni valeur, ni texte (mesuré).
- `Collection.GetMatches` est absent en GTK 4. Sous Qt et Chrome, il ne trouve rien avec le type de correspondance 0, seulement avec `ALL` (1) (mesuré).
- libatspi redemande rôle et états à chaque passe : 6 appels par nœud à chaud, 16 sans cache. Un client direct en vol est 2,7 fois plus rapide (mesuré).

Géométrie :

| Fait | Preuve | Statut |
|---|---|---|
| Sous Wayland, aucun toolkit ne donne de coordonnées d'écran. GTK 4 rend (0,0,l,h) en `SCREEN`, mais des coordonnées justes en `WINDOW`, barre de titre côté client comprise : (12,51) contre (12,12) sous openbox. Qt 6 et Chrome rendent en `SCREEN` les coordonnées relatives à la fenêtre | `geom.py` | mesuré |
| Sous X11, Qt et Chrome donnent les vraies coordonnées d'écran, égales à celles de `xdotool` ; GTK 4 rend toujours (0,0) | idem | mesuré |

Actions sans entrée injectée (sous Wayland, la fenêtre A est active et l'action vise B, inactive) :

| Fait | Statut |
|---|---|
| GTK 4 : bouton `Click` en 0,2 ms, effet à +251 ms (animation d'appui de GtkButton) ; `SetTextContents` et `InsertText` 0,3 à 0,4 ms ; `Value` 0,25 ms ; `SelectChild` 0,36 ms. Ni l'activation ni le focus ne bougent | mesuré |
| GTK 4 : une case à cocher n'a **aucune action**, et `GrabFocus` répond `NotSupported` : impossible de la cocher par AT-SPI. `ScrollTo` répond aussi `NotSupported` ; l'élément de liste expose une action `listitem.scroll-to`. Sur la liste d'une DropDown ouverte, `SelectChild` rend `True` sans rien sélectionner | mesuré |
| GTK 4 : ouvrir une DropDown par son bouton met le focus clavier GTK dans la popup (B devient `is-active`), sans que le compositeur change l'activation | mesuré |
| Qt 6 : texte et bouton (5 à 6 ms) agissent. `ShowMenu` rend `True` sans afficher de menu sous Wayland ; `GrabFocus` rend `False` | mesuré |
| Chrome, fenêtre inactive : agissent press, check, valeur, sélection de liste, `GrabFocus` d'un champ, `ScrollTo`, et l'action `select` d'une option, qui ne déplie pas la liste. Le focus se déplace dans la page, mais la fenêtre ne s'active pas. `GetActions` rend des noms vides : il faut `GetName(i)`. Les champs web n'ont pas d'`EditableText` : aucun texte ne s'écrit sans entrée | mesuré |
| X11 : les actions ne changent ni `_NET_ACTIVE_WINDOW` ni le focus X. Mais une popup GTK ou un menu Qt ouvert par une action prend le clavier jusqu'à sa fermeture | mesuré |

Événements :

| Fait | Statut |
|---|---|
| Sans `RegisterEvent`, aucun toolkit n'émet rien. Un seul type enregistré suffit pour que les trois émettent tout : il n'y a pas de filtrage par type | mesuré |
| Latence de l'action à l'événement : GTK 4 0,5/0,7 ms (émis avant la réponse) ; Qt 0,4/0,6 ; Chrome 16,2/16,5 (une trame à 60 Hz) | mesuré |
| La valeur d'un `Scale` GTK 4 change sans `StateChanged`. Un texte qui change sous Chrome remplace son nœud : `ChildrenChanged` remove puis add, avec un nouveau chemin | mesuré |
| Page animée (20 éléments à 20 Hz) : 1 386 ajouts et 1 386 retraits en 10 s. Le processeur de Chrome passe de 380 à 390 ms par 10 s sans accessibilité à 470 à 550 ms avec un écouteur | mesuré |

Mots de passe, identité, application figée, Chrome recouvert :

| Fait | Preuve | Statut |
|---|---|---|
| GTK 4 `PasswordEntry` : rôle 40. `GetText` rend une puce par caractère, ce qui révèle la longueur ; `SetTextContents` écrit un mot de passe sans entrée. L'action **`Peek`** met le secret en clair à l'écran et dans `GetText` | `pw.py` | mesuré |
| Chrome `type=password` : rôle 40, puces, pas d'`EditableText` | `chromestate.py` | mesuré |
| Le pid s'obtient par `GetConnectionUnixProcessID` sur le bus a11y. `ToolkitName` rend « GTK 4.24.1 », « Qt 6.11.2 » ou « Chromium 1.0 ». Le nom du cadre est le titre de la fenêtre, égal à `_NET_WM_NAME` sous X11 | `ident.py` | mesuré |
| Les chemins restent stables entre deux parcours sous GTK et Qt ; Chrome remplace les nœuds de texte qui changent | idem | mesuré |
| L'état `ACTIVE` du cadre suit le compositeur pour Qt et Chrome, pas pour GTK 4 (il dépend du clavier et des popups) : ce n'est pas un témoin du premier plan | Q4 | mesuré |
| Application arrêtée (SIGSTOP) : Gio respecte un délai par appel (200 ms donnent 200,3 ms). Par défaut, Gio attend 25 s, et libatspi 15 s en avalant l'erreur | `hung.py` | mesuré |
| Fil principal GTK bloqué : `Peer.Ping` répond en 0,3 ms (fil de service de GDBus) alors que `GetRole` expire. Seul un appel AT-SPI à délai court prouve qu'une application répond | `busy.py` | mesuré |
| Mutter passe une fenêtre entièrement recouverte à l'état `suspended` après environ 3,8 s. Sous Chrome recouvert, une page qui change chaque seconde garde un arbre à jour. Une page qui change toutes les 50 ms a un arbre figé pendant toute la couverture (environ 90 s, aucun événement) ; il saute à l'état courant une fois découvert, alors que le JavaScript n'a jamais cessé de tourner | `fixB.log` (état 109056) ; `tick.py` | mesuré ; cause inconnue |

### 5.3 Conséquences pour neo-compute (déduit)

- Le modèle du cœur (arbre en lignes, deltas, ids stables, actions par id, relecture d'une propriété pour le verdict, attente sur un compteur de changements) se transpose. La clé d'élément devient le nom de bus unique et le chemin d'objet, validés à chaque usage par le pid du propriétaire sur le bus.
- Un serveur persistant peut tenir une connexion unique et, par application, un miroir de l'arbre alimenté par les événements (`ChildrenChanged`, `StateChanged`, `PropertyChange`, `AddAccessible`/`RemoveAccessible` du cache). Les deux références relisent tout à chaque commande.
- `uiAutoFocus` n'a pas d'équivalent à couper : les actions AT-SPI ne focalisent pas la fenêtre. `GrabFocus` doit être classé intrusif, comme `SetFocus` sous Windows, et l'ouverture d'une popup aussi : sous X11, elle prend le clavier.
- Le client se lit le plus vite avec `Cache.GetItems`, là où il marche (GTK 4, Chromium), puis les rectangles et les valeurs, tous en vol. Qt se lit niveau par niveau, tous les appels en vol. Le coût se mesure alors entre 10 et 45 ms, contre 30 à 200 ms un appel à la fois.
- `responsive` a pour équivalent un appel AT-SPI à délai court, jamais `Ping`, et chaque appel porte son propre délai.
- L'action `Peek` d'un champ mot de passe GTK 4 doit être refusée (FR-09), et le nombre de puces ne doit pas sortir.
- `check` et `uncheck` n'ont pas de voie sémantique sur une case GTK 4 : le verdict doit le dire, au lieu d'une action qui ne fait rien.
- L'accessibilité de Chrome se décide à son lancement (`--force-renderer-accessibility`, plus `ACCESSIBILITY_ENABLED=1` ou `IsEnabled` à `true`). Un Chrome déjà ouvert sans ces réglages n'a pas d'arbre web : seul `app_launch` peut l'obtenir (décision 13).
- Un seul abonnement aux événements allume Qt et accesskit, et écrit `toolkit-accessibility=true` de façon durable dans dconf (décision 13).
- Les rectangles d'éléments sous Wayland se recomposent à partir du cadre de la fenêtre (extension, script KWin, IPC) et des coordonnées relatives à la fenêtre. Le lien fenêtre vers AT-SPI existe sous Mutter 51 (`a11y-object-path`) ; ailleurs, il passe par le pid et le titre (computer-use-linux).
- Le masquage des mots de passe dans les images suppose ces mêmes rectangles. Faute de rectangle sûr, l'image doit être refusée, comme le fait déjà `secretScan` (`nc:src/core/screen.zig:253-263`, vérifié).

## 6. Le mode arrière-plan

Chaque mécanisme vient de la décision 0013 et du PRD `tasks/prd-background-mode.md` (inventaire vérifié). Le fait Windows sur lequel il repose est rappelé, puis son équivalent par famille.

| Mécanisme (story) | Fait Windows | GNOME | KDE | wlroots | X11 | Statut |
|---|---|---|---|---|---|---|
| Actions sémantiques sans focus (US-040/041) | UIA focalise et passe devant sauf `AutoSetFocus` coupé sur `CUIAutomation8` | AT-SPI ne focalise pas, sauf `GrabFocus` | idem | idem | idem | vérifié chez agent-desktop |
| Cible de session, jamais le premier plan (US-042) | logique du cœur | portable | portable | portable | portable | vérifié |
| Lancer sans prendre le premier plan (US-043) | `SW_SHOWNOACTIVATE` | une nouvelle fenêtre prend le focus 21 fois sur 21 : il faut que l'extension rende le focus à la fenêtre de l'utilisateur dès l'apparition, ou empêche l'activation | script KWin (réactiver la précédente) ; focus-stealing de KWin non mesuré | `no_focus` de sway par IPC | `_NET_WM_USER_TIME=0` | GNOME mesuré, le reste déduit |
| Restaurer une fenêtre minimisée sans l'activer (US-043) | `restoreQuiet` | `unminimize` par l'extension : 0/20 focus | script KWin : 40/40 sans changer la fenêtre active | pas de minimisation chez sway | `XMapWindow` active : aucune voie sous openbox | mesuré |
| Leurre et témoin (US-044) | leurre d'un 2e processus qui presse F15 | fenêtre d'un autre processus, active, qui tape ; témoin : focus et premier plan par l'extension, pointeur par `QueryPointer` | script KWin, `QueryPointer` | IPC | EWMH, `XQueryPointer` | déduit |
| Pause par raccourci, souris et Échap ignorés (US-045) | hooks bas niveau | raccourci de l'extension (`Main.wm.addKeybinding`) ou portail GlobalShortcuts v2 | kglobalaccel | evdev | `XGrabKey` passif | déduit |
| Libellé seul (US-046) | fenêtre exclue de la capture | `St.Label` de l'extension, absent de `RecordWindow` | layer-shell | layer-shell | override-redirect, démappé pendant la capture | GNOME et X11 mesurés |
| Stabilisation sur événements (US-047/048) | WinEvents hors contexte, événements UIA | événements AT-SPI par application, signaux de fenêtre de l'extension | signaux de script KWin | événements `foreign-toplevel` | `PropertyNotify`, XDamage | section 5 ; X11 mesuré |
| Attente de `ui_find` (US-049) | compteur d'événements | idem | idem | idem | idem | déduit |
| Garde du premier plan (US-050) | événement `EVENT_SYSTEM_FOREGROUND`, réactivation par la file d'entrée | l'extension écoute `notify::focus-window` et réactive la fenêtre de l'utilisateur (`Main.activateWindow` marche sans jeton, mesuré) | script : `windowActivated`, puis `activeWindow = précédente` (activation mesurée) | état `activated` de `foreign-toplevel`, puis `activate` | `PropertyNotify` sur `_NET_ACTIVE_WINDOW`, puis activation (mesurée) | primitives mesurées ; garde déduite |
| Geste de l'utilisateur qui arrête la garde (US-050) | hooks : clic hors fenêtre, Alt ou Win | dépend de la lecture de l'entrée physique (section 7, FR-12) | idem | idem | XI2 | déduit |
| Actions complètes : check, uncheck, défilement, valeur, sélection par nom, attente d'activation (US-051 à 055) | patterns UIA, ~0,3 ms par aller-retour | `Action` (toggle), `Value`, `Selection`, `Component.ScrollTo` ; pas de défilement en pourcentage | idem | idem | idem | section 5 |
| Sous-arbre, relecture par id, occultation (US-056/057/059) | `windowLayers` | empilement et rectangles par l'extension | script KWin (`stackingOrder`) | **aucun empilement** dans les protocoles ni l'IPC de sway | EWMH (mesuré) | mesuré |
| Capture d'une fenêtre recouverte (US-060/061) | `PrintWindow` | `RecordWindow` (et l'indicateur de partage s'allume) | `CaptureWindow`, minimisée comprise | `ext-image-copy-capture` | Composite (pas les réduites) | mesuré |
| Chromium recouvert : arbre en retard, image figée (US-058, US-066) | mesuré sous Windows | un client recouvert ne reçoit plus d'appels de trame (GTK : 0 dessin) et passe `suspended` en 3,8 s ; `RecordWindow` le dégèle. Chrome recouvert : l'arbre suit une page lente, mais reste figé sur une page qui change toutes les 50 ms ; l'effet d'un flux `RecordWindow` sur cet arbre n'est pas mesuré | à mesurer | à mesurer | à mesurer | GTK et Chrome sous Mutter mesurés |
| Sélection native des listes (US-064) | messages Win32 | sans objet | | | | déduit |
| Prérequis caché : verrou de premier plan (0013:594) | `ForegroundLockTimeout` | la politique `smart` de Mutter laisse une nouvelle fenêtre prendre le focus | non mesuré | non mesuré | openbox n'empêche rien | mesuré (GNOME, openbox) |

Ce qui change de nature sous Linux :
- **L'indicateur de partage d'écran de GNOME.** Toute capture par ScreenCast l'allume, et un clic dessus arrête toutes les sessions. En mode arrière-plan, une capture de fenêtre fait donc apparaître un signal visible que l'utilisateur peut couper (mesuré, et `gs:ui/status/remoteAccess.js:12`, `:170-206` vérifié). C'est un argument pour la capture par l'extension (déduit).
- **Le dégel par le flux.** Sous Windows, Chrome recouvert gèle son image et son arbre. Sous GNOME, un flux `RecordWindow` maintient un client recouvert à jour (mesuré pour GTK). Cela pourrait rendre inutile la bande de 16 px de la décision 0013 (déduit, à mesurer avec Chrome).

## 7. Les invariants du produit

| Invariant | Mécanisme Windows | Linux | Statut |
|---|---|---|---|
| FR-07, relâche en moins de 50 ms (EOF, annulation, kill switch, erreur) | `SendInput` keyup | Mutter (RemoteDesktop, EI) et KWin (EIS) relâchent seuls en moins de 5 ms à la mort ou à la déconnexion. XTest, clavier virtuel wlroots et `fake_input` ne relâchent jamais : il faut un processus gardien avec sa propre connexion, qui relâche quand le pipe du parent se ferme (0,26 ms sous X11), sans `PR_SET_PDEATHSIG` | mesuré |
| | | Un serveur figé (SIGSTOP) garde ses touches même sous Mutter | mesuré |
| | | Gestionnaires de SIGINT, SIGTERM et SIGHUP qui relâchent avant de sortir, parce que Claude Code envoie SIGINT d'abord (agent-desktop le fait, `ad:crates/linux/src/input/x11/signal_release.rs:13-142`) | documenté, vérifié |
| FR-08, FR-28, politique par application | nom d'exe | nom de processus et identifiant d'application ; Flatpak : identifiant tiré du cgroup ou de `/.flatpak-info` (le portail le fait déjà par le cgroup, mesuré) | déduit |
| FR-09, aucun mot de passe exposé | UIA `IsPassword`, masque dans l'image | rôle `PASSWORD_TEXT` (40) ; masque fondé sur les rectangles recomposés (section 5) ; refus de l'action `Peek` de GTK 4, qui met le secret en clair dans `GetText` et à l'écran ; ne pas rendre le nombre de puces, qui donne la longueur ; presse-papiers : `x-kde-passwordManagerHint` | rôle, `Peek` et indice mesurés ; le reste déduit |
| FR-10, aucune connexion réseau | test des imports PE (`nc:tests/process_test.zig:286`) | les imports ELF ne disent rien d'un binaire statique ; D-Bus et Wayland ouvrent des sockets Unix. Un filtre seccomp posé au démarrage qui refuse `socket(AF_INET*)` ferait respecter l'invariant par le noyau | déduit |
| FR-11, aucun outil de commande | `app_launch` restreint | lancer un `.desktop` sans shell (analyse des codes `%f`, `%u` de `Exec`), refuser les entrées `Terminal=true` et les types exécutables comme documents | déduit |
| FR-12, seul un geste physique lève la pause | hooks bas niveau, `LLKHF_INJECTED` | X11 : `sourceid` XI2 (mesuré). GNOME et KDE : aucune API ne distingue l'injecté du physique (IdleMonitor compte l'injecté, `KeyEvent` n'a pas de périphérique, mesuré). evdev : `/dev/input/event*` exige le groupe `input`, déclaré sans membre par Fedora (`/usr/lib/sysusers.d/setup.conf:38`) et ajouté localement pour arthur (mesuré) ; l'entrée injectée ne crée aucun nœud evdev (36 avant et pendant une session, mesuré), donc lire evdev ne voit que le physique. Extension GNOME : lire le périphérique source des événements Clutter (déduit, à sonder) | mesuré et déduit |
| FR-13, audit JSONL | `%LOCALAPPDATA%` | `$XDG_STATE_HOME` | déduit |
| FR-14, une instance par bureau | mutex nommé | `flock` dans `$XDG_RUNTIME_DIR`, par affichage | déduit |
| FR-18, stdout JSON-RPC seul | dispatcher | portable | vérifié |
| FR-24, racines = fenêtres possédées et popups | propriétaire HWND | relation `transient_for` côté compositeur, racine d'application AT-SPI | déduit |
| FR-25, `app_launch` limité au catalogue et aux documents | menu Démarrer, `AssocIsDangerous` | entrées `.desktop` (spécification freedesktop) ; types dangereux à définir | déduit |
| FR-26, presse-papiers sans secret | formats `CanUpload`, `ExcludeMonitor` | `x-kde-passwordManagerHint` (KeePassXC, KDE) ; son absence ne prouve rien | mesuré (présence de l'indice) |
| FR-27, `registry_read` | registre | aucun équivalent | déduit |
| FR-30, indicateur sans blocage ni entrée consommée, exclu des captures | `WDA_EXCLUDEFROMCAPTURE` | GNOME : label de l'extension, absent de `RecordWindow` mais présent dans la capture d'écran ; X11 : démappé pendant la capture ; KDE : `hide-caller-windows` (déduit) | mesuré pour GNOME et X11 |
| FR-33, l'arrière-plan n'injecte jamais | classes d'interférence | portable | vérifié |
| FR-36, raccourci de pause en moins de 100 ms | hooks | raccourci de l'extension, kglobalaccel, `XGrabKey`, evdev | déduit |
| FR-42, image de fenêtre seulement si tous les mots de passe sont couverts | `secretScan` | même règle, avec les rectangles recomposés | déduit |
| Cibles élevées et bureau sécurisé (UIPI, `actions.zig:14-15`) | intégrité, bureau sécurisé | processus d'un autre uid ; écran verrouillé (`ScreenSaver.GetActive`, `LockedHint`) ; dialogue polkit dessiné par le Shell. L'entrée injectée atteint l'invite de déverrouillage (mesuré) : le backend doit refuser d'agir quand la session est verrouillée | mesuré et déduit |

Sécurité du modèle Linux (documenté et mesuré) :
- Tout processus non sandboxé de la session peut piloter le bureau par `org.gnome.Mutter.RemoteDesktop` sans dialogue. Les développeurs GNOME n'annoncent aucune restriction (discussion de mai 2026, documenté). La RFC gnome-shell #3943, qui réserverait ces API au portail, n'a pu être lue.
- KWin offre la même chose par EIS, ScreenShot2 et le scripting (mesuré).
- Le bus AT-SPI n'a aucun contrôle d'accès (documenté).
- Le portail Screenshot range son accord par application hôte : `paneflow` ici, pas l'agent (mesuré).
- Le nom `org.gnome.Orca.KeyboardMonitor` peut être pris par n'importe qui, et donne alors le clavier et le pointeur (mesuré).

## 8. Build, liaisons générées et gates

### 8.1 Les gates sur un hôte Linux (mesuré sur une copie, caches dans le dossier de travail)

| Commande | Résultat | Cause |
|---|---|---|
| copie fraîche, toute commande de build | échec au fetch : `hash mismatch: manifest declares N-V-__8AAGEjlwAuFcV7…_6 but the fetched package has N-V-__8AAGEjlwDyirWN…0J` | le hash du manifeste est celui de l'arbre qui garde son répertoire racine `libjpeg-turbo-3.1.4.1/` ; Zig 0.17.0 et 0.17.1 le retirent sous Linux ; `nc:build.zig:201` code ce chemin en dur. La détection de la racine ne dépend pas de l'OS dans `std` : un clone Windows frais pourrait échouer de même (déduit, non vérifiable ici) |
| `zig fmt --check .` | passe | |
| `zig build` | le serveur se construit **avec le backend factice**, sans le dire ; `probe` et `probe_c` échouent | `nc:src/main.zig:15-18` ; sondes installées sans condition, `nc:build.zig:141,282-308` ; `ole32` introuvable, `kernel32` exige du code indépendant de la position |
| `zig build test` | 353 tests sur 357 | `bindings_test` (bibliothèques Windows), `layout.c` (`windows.h`), 3 `process_test` (lecture PE d'un ELF de 131 Mo ; mutex Windows), `background_test.zig:638` (borne de 120 ms calée sur le quantum Windows de 15,6 ms, Linux donne 110 ms 3 fois sur 3) |
| `zig build cross` | passe, mais sous Linux sa cible est l'hôte : il ne prouve rien de plus | `nc:build.zig:111-112` |
| `zig build bench` | échec (dépend de l'installation des sondes) ; lancé à la main : « no regression » avec 14 scénarios sur 16 ignorés | `nc:src/core/bench.zig:346` |
| `selftest` | `platform FAILED: this build has no platform backend` | |
| `zig build -Dtarget=x86_64-windows-gnu` depuis Linux | passe, 19 étapes sur 19, en 20 s : `neo-compute.exe`, `probe.exe`, `probe_c.exe` | le mingw de Zig fournit les bibliothèques |
| `zig build test -Dtarget=x86_64-windows-gnu` | tout compile, rien ne s'exécute (ni wine ni qemu) | |

Pendant la première commande de la sonde, `zig build` 0.17 a refusé `--global-cache-dir` (« unrecognized argument ») et a écrit dans `~/.cache/zig`. Seules les variables `ZIG_GLOBAL_CACHE_DIR` et `ZIG_LOCAL_CACHE_DIR` redirigent le cache (mesuré).

### 8.2 Le pipeline de liaisons et son équivalent Linux

Aujourd'hui (vérifié) : `bindings/windows.zon` liste les API ; `tools/winmdgen` (1 530 lignes, dont un lecteur ECMA-335 de 394 lignes) lit le nupkg win32metadata épinglé par SHA-256, et émet la fermeture transitive des API listées. La sortie fait ici 8 794 lignes, 237 `extern` et 53 vtables. `tests/bindings_test.zig` force l'analyse et le lien ; `tests/layout_test.zig` compare 29 structures à `layout.c` ; un nom absent fait échouer le générateur avec le nom le plus proche. Sous Linux, le générateur et ce dernier test tournent ; seule la cible casse.

| Famille | Source lisible par une machine | Sur ce disque | Voie générée | Statut |
|---|---|---|---|---|
| Wayland, cœur | `wayland.xml` | `/usr/share/wayland/wayland.xml` (wayland-devel 1.26) | XML vers Zig : opcodes, signatures, énumérations, versions ; liste en `.zon` | mesuré |
| Protocoles Wayland (`ext`, `wlr`, `kde`, `virtual-keyboard`) | XML des dépôts amont | absents de `/usr/share` ; copies dans `~/.cargo/registry` (wayland-protocols 0.32.13, -wlr, -plasma, -misc) | même générateur, XML épinglés par tarball et hash | mesuré |
| D-Bus : portails, gnome-shell | XML d'introspection | `/usr/share/dbus-1/interfaces/` (portails, `org.gnome.Shell.Introspect`, `Screenshot`) | XML vers Zig : table des membres, signatures vers (dé)sérialisation, liste en `.zon` | mesuré |
| D-Bus : Mutter | `data/dbus-interfaces/*.xml` du tarball Mutter | absent ; l'introspection en direct donne RemoteDesktop (7 méthodes), ScreenCast (7), DisplayConfig (15), IdleMonitor (11) ; les interfaces `Session` et `Stream` n'apparaissent qu'après `CreateSession` | épingler les XML du tarball | mesuré |
| D-Bus : KWin | XML de KWin | absent | épingler | mesuré |
| AT-SPI | XML d'at-spi2-core | non installé par `at-spi2-core-devel` (seulement les en-têtes et `Atspi-2.0.gir`) | XML épinglé vers un client natif, ou GIR | mesuré |
| X11 | xcb-proto | absent de `/usr/share/xcb` ; copie complète dans `~/.cargo/registry/…/xcb-1.7.1/xml/` (xproto, xtest, composite, damage, xfixes, xinput, shm, shape, record, randr) | XML vers requêtes, réponses et événements, comme libxcb et x11rb | mesuré |
| libei | `proto/protocol.xml` de libei | absent ; `libei.so.1`, `libeis`, `liboeffis` 1.6.0 présents sans en-têtes | même générateur que Wayland | mesuré |
| PipeWire, SPA | aucune : le protocole n'est défini que par le C | ni en-têtes (`pipewire-devel` absent) ni description ; `libpipewire-0.3.so.0` 1.6.11 présent | translate-c d'en-têtes épinglés ; les macros `SPA_POD_*` ont la forme qui fait échouer translate-c ailleurs (déduit) | mesuré |
| xkbcommon | en-têtes | présents (1.13.1) | translate-c, qui marche | mesuré |

`std` 0.17 n'a pas de lecteur XML : un générateur Linux doit en écrire un (vérifié).

### 8.3 translate-c avec Zig 0.17.1 (mesuré)

| En-tête | Compile, lie, s'exécute | Points durs |
|---|---|---|
| `wayland-client.h` | oui | `wl_list_for_each*` et `WL_TYPEOF` refusés |
| `xcb.h` + xtest, composite, damage, xfixes, xinput, shm | oui | `XCB_PACKED` seulement |
| `dbus/dbus.h` | oui (libdbus 1.16.4) | aucun |
| `systemd/sd-bus.h` | oui | `SD_BUS_ERROR_NULL` (littéral composé), `__VA_ARGS__`, `__COUNTER__` |
| `atspi/atspi.h` + GLib | oui, en liant aussi `gobject-2.0` | toutes les macros de cast GObject inutilisables ; `GClosure` opaque |
| `xkbcommon.h` | oui | aucun |

Pour une cible croisée, translate-c prend les en-têtes de l'hôte et `linkSystemLibrary` échoue sans sysroot (mesuré).

### 8.4 Protocole natif ou bibliothèque C

Mesure décisive : la sonde `wire.zig` (environ 190 lignes, aucune bibliothèque C, binaire statique musl de 160 096 octets) s'authentifie sur le bus de session réel (SASL EXTERNAL, `Hello` rend un nom unique). Elle liste aussi les 46 globals Wayland de la session réelle par `get_registry` puis `sync`. Je l'ai relancée moi-même : `sasl: OK …`, `unique name :1.322`. `std` 0.17 fournit `sendmsg`/`recvmsg`, `SCM_RIGHTS` et `memfd_create` (vérifié).

| Famille | Natif en Zig | Bibliothèque C | Références locales | Risque |
|---|---|---|---|---|
| D-Bus | sérialisation, SASL, passage de descripteurs (`OpenPipeWireRemote`, `ConnectToEIS`), motif Request/Response des portails ; quelques milliers de lignes (déduit) | libdbus, sd-bus | zbus (D-Bus en Rust pur, base d'atspi, ashpd et accesskit_unix) ; Ghostty passe par GDBus | erreur d'alignement ou de signature, attrapée par un test d'octets |
| Wayland | en-tête de 8 octets, arguments alignés sur 4, descripteurs hors bande ; environ 2 000 lignes plus le générateur (déduit) | libwayland-client | Ghostty génère depuis le XML mais lie libwayland ; wayland-backend (Rust) contient un client pur | identifiants d'objets, `delete_id`, ordre de destruction |
| X11 | requêtes générées depuis xcb-proto, cookie MIT | libxcb | x11rb a une connexion pure (`RustConnection`) | numéros de séquence, opcodes d'extension |
| PipeWire | pods SPA, nœud client, zones partagées, eventfd ; de loin le plus gros (déduit) | libpipewire en dlopen | aucun projet local | boucle et verrou de `pw_thread_loop`, rappels sur son thread : l'équivalent de la condition 3 du Rust Switch Gate |

Aucune condition du Rust Switch Gate n'est touchée par cet audit (le gate porte sur la couche COM). Une version Linux du gate n'existe pas.

### 8.5 Ce que deviennent les gates (constats)

- `fmt` ne dépend pas de l'OS.
- `zig build` réussi sous Linux ne prouve aujourd'hui rien sur un backend.
- `test` contient 4 étapes à cible Windows et un test du cœur calé sur le quantum Windows.
- `cross` a besoin d'une réciproque (Windows depuis Linux, qui marche) et d'une cible Linux depuis Windows.
- Le bench a besoin d'une baseline par OS, et un scénario attendu ne doit pas pouvoir passer en `unsupported`.
- `selftest` et les evals sont Windows seulement.

## 9. Selftests, bench et evals

### 9.1 Inventaire (vérifié ; classement déduit à environ trois éléments près)

| Classe | Contenu |
|---|---|
| (a) cœur seul, portable tel quel | 2 scénarios de bench sur le backend factice (`transport`, `diff`), la calibration des tokens, environ 290 tests du cœur, `process_test` en partie, les 4 tests d'erreur de compilation |
| (b) concept portable, fixture ou mécanisme Linux à écrire | environ 115 checks de selftest (68 de `selftest`, 47 de `selftest --background`), 5 sondes, 24 scénarios de bench, 38 tâches d'eval sur 39 |
| (c) propre à Windows | 16 checks (registre, MSAA `bg-legacy`, messages Win32 `bg-select-*`, XAML, DXGI `capture-fallback`, `capture-exclusion`, `uipi`, `dpi-unaware`, `indicator-echo`), `probe_c`, `clipboard-probe`, `firefox-msaa`, la tâche `registry-read`, toute la plomberie PowerShell, les 3 tests de liaisons, environ 30 tests du cœur qui encodent un comportement Windows dans le faux backend (`lag_test`, `capture_test`, `system_test`, `windows_test`, `act_test`, `background_test`) |

Évals : 39 tâches dans `nc:evals/windows/tasks.json` (21 `existing`, 9 `parity`, 9 `background`, compté).
- Le harnais est en PowerShell avec du C# intégré (`Add-Type` sur user32, UIAutomationClient, WinForms, `csc`), et `pwsh` n'est pas installé ici (mesuré).
- Le témoin échantillonne toutes les 50 ms le premier plan, le focus, le curseur et le numéro de séquence du presse-papiers, et compte l'entrée injectée par `LLKHF_INJECTED` (`nc:evals/run.ps1:290-445`, vérifié). Tout est à réécrire, mais les concepts restent valables.
- `claude -p` est appelé avec `--strict-mcp-config --tools '' --allowedTools mcp__desk` (`nc:evals/run.ps1:491-496`, vérifié). Ce point est portable.

Bench : `bench/baseline.json` n'a aucune clé de machine ni d'OS (vérifié).

### 9.2 Les bancs de test sans écran (mesuré)

| Banc | Commande | Ce qu'il apporte | Pièges |
|---|---|---|---|
| GNOME complet | `gnome-shell --headless --wayland --no-x11 --virtual-monitor 1920x1080 --wayland-display=<nom>` | RemoteDesktop, ScreenCast, Introspect, ScreenSaver, extensions | voir l'isolation ci-dessous |
| Mutter seul | `mutter --headless --wayland --no-x11 --wayland-display=<nom> --virtual-monitor 1920x1080` | RemoteDesktop prêt en 0,21 s, sans `/dev/input` ni logind | disposition `us` sans `org.freedesktop.locale1` ; `gvfsd-fuse` monté dans le runtime privé sans `GIO_USE_VFS=local GVFS_DISABLE_FUSE=1` |
| KDE | `QT_QPA_PLATFORM=offscreen kwin_wayland --virtual --socket <nom> --width 1280 --height 800` | EIS, ScreenShot2, scripting, `fake_input` | verrouillage automatique au bout de 5 min |
| wlroots | `WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 sway -c <config>` ; labwc de même | tous les protocoles `wlr`/`ext` | aucun |
| X11 | `Xvfb :<n> -screen 0 1920x1080x24` + openbox (+ picom) | XTest, XI2, Composite, EWMH | aucun périphérique physique |
| Weston | `weston --backend=headless` | rien d'utile : aucun `wl_seat` | |

Isolation indispensable, apprise par les incidents de la section 12 (mesuré) :
- partir de `env -i` ;
- `HOME`, `XDG_RUNTIME_DIR` et tous les `XDG_*_HOME` privés, positionnés **avant** `dbus-run-session`, sinon son démon garde les vrais ;
- un chemin court : un socket de plus de 108 octets est refusé (« socket path … exceeds 108 bytes ») ;
- un faux bus système vide (`DBUS_SYSTEM_BUS_ADDRESS`), sinon gnome-shell s'enregistre auprès du vrai GDM et de logind ;
- un `XDG_SESSION_ID` factice, sinon logind attribue au compositeur privé la session de l'utilisateur par son PID ;
- un dconf privé avec verrouillage et mise en veille coupés, et pour KWin un `kscreenlockerrc` privé (`Autolock=false`, `LockOnResume=false`) ;
- un bus de session qui n'active que les services voulus ;
- un faux GDM pour que le Shell accepte de verrouiller ;
- `google-chrome --user-data-dir=<privé>`, sinon il passe la main au Chrome de l'utilisateur.

Ces bancs rendent possible une CI des backends Wayland sans écran : agent-desktop le fait déjà pour X11 et pour gnome-shell, à la main (`ad:.github/workflows/linux-e2e.yml:4,15`, vérifié). Ce que ces bancs ne peuvent pas prouver : l'entrée physique, les dialogues de consentement, la vraie session Plasma, et les GPU réels.

## 10. Distribution

| Fait | Preuve | Statut |
|---|---|---|
| Trois régimes de lien : (1) aucune bibliothèque C, binaire musl statique, cross-compilable partout ; (2) glibc 2.28 dynamique et `dlopen` des bibliothèques optionnelles (`std.DynLib` marche en gnu, échoue en musl statique) ; (3) lien direct, un build par distribution (viser glibc 2.28 échoue sur `stat64@GLIBC_2.33`) | sondes `hello.zig`, `xkblink.zig` | mesuré |
| Serveur actuel (backend factice, ReleaseFast) en musl statique : 10,4 Mo, 1,9 Mo après strip, répond à `initialize` ; aarch64 gnu et musl construits (non exécutés) | binaires de la sonde | mesuré |
| libjpeg-turbo se construit pour les quatre cibles Linux | log de build | mesuré |
| Claude Code sous Linux : Ubuntu 20.04+, Debian 10+, Alpine 3.19+, x64 et ARM64 ; `claude mcp add … -- <cmd>` ; arrêt par SIGINT, SIGTERM à 100 ms, SIGKILL 400 ms plus tard | code.claude.com/docs/en/mcp et /setup ; même séquence dans `~/dev/claude-code/services/mcp/client.ts:1426-1520` | documenté et vérifié |
| Flatpak ne convient pas : la sandbox filtre le bus AT-SPI et le ScreenCast de Mutter, et `wp_security_context` cache les globals d'automatisation | docs Flatpak, discussion GNOME de mai 2026 ; globals cachés mesurés | documenté et mesuré |
| `/dev/uinput` : pas de règle systemd par défaut ; ici l'ACL `user:arthur:rw-` vient de la règle de kdeconnectd (`/usr/lib/udev/rules.d/40-kdeconnect-uinput.rules`) | `getfacl`, `rpm -qf` | mesuré |
| Précédents : agent-desktop publie des binaires gnu x86_64 et aarch64 construits dans `ubuntu:22.04` (plancher glibc 2.35, 4,7 Mo + 0,6 Mo d'auxiliaire). uv publie du musl statique ; Ghostty passe par les distributions | `ad:.github/workflows/release.yml:64,75` ; documentation | vérifié et documenté |
| computer-use-linux construit x86_64 et aarch64, en gnu et en musl, avec cargo-zigbuild et **Zig 0.17.0**, le même que neo-compute. Le plancher glibc 2.28 (RHEL 8) est contrôlé par `objdump -T` en CI ; un échec musl ne bloque pas la release. Le serveur fait 14,9 Mo (x86_64 gnu). Un `.sha256` vient de la même origine que le binaire, sans signature. Distribution : npm, avec un postinstall qui télécharge le binaire ; crates.io ; un plugin Claude Code dont le lanceur télécharge, vérifie le sha256 et met en cache dans `~/.cache/computer-use-linux` | `cul:.github/workflows/ci.yml:248-331` (`GLIBC_FLOOR: "2.28"`), `cul:npm/install.js:139-212`, `cul:plugins/computer-use-linux/bin/computer-use-linux:35-79` | vérifié |
| Une extension GNOME Shell se livre en JavaScript, à installer dans `~/.local/share/gnome-shell/extensions/<uuid>`, à activer par `org.gnome.shell enabled-extensions`. computer-use-linux demande une reconnexion quand `extension.js` change, et ses `shell-version` doivent suivre chaque version de GNOME | `cul:src/gnome_extension.rs:24-32`, `:52-91`, `:131-145`, `:324-392` | vérifié |

## 11. agent-desktop et computer-use-linux : ce qu'ils font, ce qu'ils ne savent pas faire, ce qu'on peut faire mieux

| Sujet | agent-desktop (`e8934a5e`) | computer-use-linux (`34bee24`) | Ce que neo-compute peut faire mieux (déduit) |
|---|---|---|---|
| Environnements | X11 et GNOME Wayland seulement ; KDE, wlroots, COSMIC, Hyprland, niri jamais détectés (vérifié) | GNOME, KDE, Hyprland, niri, COSMIC, sway, i3, labwc, X11, par une chaîne de backends essayés dans l'ordre (`cul:src/windowing/registry.rs:58-73`) | table de capacités par famille, composée à l'exécution |
| Modèle de processus | une commande, un processus ; MCP relance le binaire à chaque appel ; ni touche ni bouton tenu (`ad:src/mcp/call.rs:26`, `ad:crates/linux/src/input/standalone.rs:3-16`) | serveur MCP persistant (rmcp), tokio mono-thread | serveur persistant, déjà le cas |
| Entrée GNOME | clavier par `NotifyKeyboardKeysym`, ASCII et disposition US seulement ; pointeur refusé pour les applications, faute de position des fenêtres (`ad:crates/linux/src/input/deliver.rs:39-79`) | uinput absolu (`/dev/uinput` requis), portail RemoteDesktop avec jeton de restauration, EI seulement pour le pointeur à l'échelle supérieure à 1 ; texte par keysyms après vérification de la disposition | RemoteDesktop et EI natifs, sans dialogue ni uinput ; positions par l'extension ; disposition lue par EI |
| Relâchement | journal des touches tenues dans `$XDG_RUNTIME_DIR` et relâche sur SIGTERM, SIGINT, SIGHUP (X11) (`ad:crates/linux/src/input/x11/signal_release.rs`) | les gardes `Drop` du portail lancent une tâche asynchrone de relâchement ; sur SIGINT ou SIGTERM, `process::exit(128+sig)` les coupe, et seul le nettoyage du compositeur relâche (`cul:src/server.rs:4479-4496`, `cul:src/remote_desktop.rs:957-985`, `:1049-1075`) | gardien par transport et gestionnaire de signaux, mesuré à moins de 1 ms |
| Dépendances | Rust pur : zbus, x11rb | Rust pur (zbus, atspi, x11rb, reis pour EI, kbvm pour xkb, wayland-client), mais environ 35 commandes externes lancées : gsettings, busctl, gdbus, grim, hyprctl, swaymsg, niri, kwriteconfig, xdotool, ydotool, wtype… (`cul:tests/cli_flags.rs:40-75`) | protocoles parlés nativement, aucune commande externe |
| Ce que l'installation change sur le système | rien | `setup` écrit `toolkit-accessibility=true` et peut forcer `IsEnabled`, sans jamais restaurer (`cul:src/diagnostics.rs:774-838`) ; il installe l'extension dans le dossier utilisateur et l'active, ce qui demande une reconnexion sous Wayland. `install.sh` passe par `sudo apt/dnf/pacman`, installe rustup par `curl \| sh` et un service utilisateur `ydotoold`, et conseille d'ajouter l'utilisateur au groupe `input` (`cul:install.sh:309-409`, `:470-531`) | chaque modification déclarée et réversible ; jamais le groupe `input` par défaut |
| Sécurité de l'extension GNOME | sans objet | l'extension ne vérifie **jamais** son appelant. Tout processus de la session peut lister les fenêtres (titres, pid), les activer, les déplacer, ou afficher un faux bandeau « X is using your computer » (`cul:gnome-shell-extension/…/extension.js:87-166` ; `get_sender` ne sert qu'à suivre le propriétaire de l'indicateur). Seul le client vérifie que le nom appartient au Shell | l'extension accepte seulement le pid du serveur, vérifié par `GetConnectionUnixProcessID` |
| Kill switch | aucun | aucun (vérifié par recherche) | XI2 sous X11 ; evdev ou extension ailleurs |
| Capture GNOME | portail Screenshot seul, écran entier, PNG relu ; Mutter ScreenCast mesuré puis écarté parce qu'il contourne le consentement, alors que l'entrée Mutter, qui le contourne aussi, est gardée (`ad:probes/linux/FINDINGS.md` L29-28) | `org.gnome.Shell.Screenshot` (refusé hors liste), portail, `gnome-screenshot` ; une fenêtre ciblée est **amenée au premier plan** puis découpée (`cul:src/server.rs:6629-6660`) | `RecordWindow` d'une fenêtre recouverte, sans la monter, ou capture par l'extension |
| Fenêtres | liste tirée des cadres AT-SPI : une application sans arbre est invisible ; focus, fermeture, déplacement refusés sous Wayland | extension GNOME (liste, activation, déplacement), scripts KWin (2 scripts et jusqu'à 2 s par activation), IPC des autres ; aucun champ d'empilement dans le modèle (`cul:src/windowing/types.rs:29-52`) | extension avec empilement ; canal KWin persistant (0,2 ms mesuré) ; empilement dans le modèle dès le départ |
| AT-SPI | zbus brut, BFS, 32 en vol, sans Cache ni Collection ; attente = sondage réveillé par signal | BFS, `GetChildAtIndex`, 16 en vol, nouvelle connexion par appel ; sommeil fixe de 120 ms après action | connexion persistante, miroir par événements, `Cache.GetItems` où il marche, compteur de changements |
| Mots de passe | valeur jamais lue, mais aucun masque dans les captures | aucun masque dans les images ; la valeur passée à `set_value` revient en écho dans la réponse (`cul:src/server.rs:2248`) | masque dans les images, refus de l'image sans scan sûr, jamais d'écho |
| Arrière-plan | actions sémantiques seulement ; entrée physique refusée sans `--headed` | stylet et écran tactile virtuels (uinput) sous GNOME et KWin : **déplacent le focus** et répondent `ok` (`cul:src/virtual_pen.rs:14-15`, `cul:src/server.rs:11503-11529`) ; écrivent des gsettings et `kcminputrc` persistants qu'un crash laisse (`cul:src/virtual_pen.rs:932-961`) ; X11 : second couple pointeur-clavier XInput2 (`AddMaster`, `cul:src/agent_seat.rs:694-719`) ; sway : siège transitoire ; consentement au repli mémorisé par un booléen global (`cul:src/server.rs:294-296`) | témoin bloquant avant et après chaque action ; aucun réglage persistant ; reprendre l'idée du second siège X11 pour un arrière-plan avec vraie entrée, en mesurant ses limites |
| Indicateur | aucun sous Wayland | overlay layer-shell ; sous GNOME, relais vers l'extension ; masqué pendant la capture par verrou partagé, ce qui fait clignoter l'overlay (`cul:src/indicator.rs:45-62`) | label de l'extension, absent de `RecordWindow` sans clignoter |
| Outil de commande | aucun | `run_shell` optionnel (`COMPUTER_USE_LINUX_ENABLE_SHELL=1`) | aucun (FR-11) |
| Tests | CI sous Xvfb ; e2e manuels : x11-openbox, x11-mutter, gnome-shell headless ; ni KDE ni wlroots | en CI, seul X11 sous Xvfb tourne vraiment. Le test sway headless est sauté (pas de sway sur le runner) ; Hyprland est simulé par un faux socket qui répond « ok ». Les stylets GNOME (vrai `gnome-shell --display-server` sur un VT avec vkms et sudo) et KWin (Docker privilégié) sont opt-in et ne tournent jamais en CI. GNOME, KDE, niri et COSMIC réels ne sont validés qu'à la main (`cul:.github/workflows/ci.yml:66`, `:206`, `cul:scripts/virtual_pen_test.py:1-30`, `cul:README.md:244`) | bancs sans écran des quatre familles (section 9.2) en CI, témoin qui relit le pointeur |
| Maturité | | v0.7.59 ; 0 issue ouverte, aucun TODO ; v0.7.42 à v0.7.59 du 5 au 20 novembre ; stylets GNOME et KWin publiés le jour de cet audit (`cul:CHANGELOG.md:10-27`) | |
| Taille | crate Linux de 124 061 lignes | environ 97 000 lignes, dont `src/server.rs` de 26 620 lignes qui déclare 21 outils, sans lancement d'application, presse-papiers, zoom ni touche tenue | |

Deux techniques sont à reprendre telles quelles :
- le journal des touches tenues avec relâche sur signal (agent-desktop) ;
- côté client, la vérification que le propriétaire D-Bus de l'extension est celui de `org.gnome.Shell`, contre l'usurpation (`cul:src/windowing/backends/gnome.rs:250-258`).

Les deux sont vérifiées dans le code. La vérification dans l'autre sens, l'extension qui contrôle son appelant, manque chez computer-use-linux et doit exister chez neo-compute (déduit).

## 12. Incidents pendant l'audit

Les sondes devaient ne rien laisser de modifié. Voici ce qu'elles ont touché sur la session réelle, et ce qui a été réparé.

| Incident | Cause | État | Statut |
|---|---|---|---|
| `LockedHint=yes` sur la session logind 3 de 14:27:33 à environ 14:33, écran GNOME non verrouillé (`ScreenSaver.GetActive` = false) | le KWin headless s'est verrouillé au bout de 5 min ; kscreenlocker a appelé `SetLockedHint` sur la session que logind associe à son PID (`XDG_SESSION_ID` absent) | réparé par moi : `busctl call org.freedesktop.login1 /org/freedesktop/login1/session/_33 org.freedesktop.login1.Session SetLockedHint b false`, relu `no` | mesuré |
| `/run/user/1000/doc` démonté (portail de documents de Flatpak), d'environ 14:40 à 14:48 | une session X11 privée lancée avec le vrai `XDG_RUNTIME_DIR` dans son `dbus-daemon` a activé ses propres portails ; à leur arrêt, le portail de documents a démonté le chemin réel | réparé par moi : `systemctl --user restart xdg-document-portal.service`, relu `fuse.portal` | mesuré |
| gnome-shell privé sur le vrai bus système pendant environ 2 min (14:26:24) | isolation incomplète au premier démarrage | il a appelé `RegisterSession` et `RegisterDisplay` de GDM, suivi les signaux Lock et Unlock de la session 3, tenté un agent polkit (refusé), pris puis libéré un inhibiteur de veille ; aucun inhibiteur ne reste (`systemd-inhibit --list` relu) ; aucune erreur GDM au journal | mesuré |
| `gvfsd-gphoto2` privé lancé vers 14:26 pour l'iPhone branché en USB, tué vers 14:27 | même démarrage | il a pu concurrencer l'accès à l'iPhone pendant environ une minute ; le montage gphoto2 réel de l'iPhone est présent | déduit |
| Sessions X11 privées avec le vrai `HOME` et le vrai `XDG_RUNTIME_DIR` dans leur `dbus-daemon` (14:21 à 14:41), journaliseurs GTK sur le vrai bus de session | variables posées dans les enfants seulement | aucune écriture gsettings, dconf ni `org.a11y.Status` (backend mémoire, `GTK_A11Y=none`) ; deux fichiers de cache NVIDIA modifiés (`~/.cache/nvidia/GLCache/e2fac26b…/edd3ede78a386ef2.{bin,toc}`, 14:37:48), laissés tels quels car ils appartiennent à un cache partagé | mesuré |
| `~/.cache/zig` : entrées écrites par des commandes Zig lancées avant la redirection du cache | `zig build` 0.17 n'accepte pas `--global-cache-dir` | une archive libjpeg déplacée dans le dossier de travail ; le reste est traité en fin d'audit (voir le message final) | mesuré |
| Core dumps dans le stockage système de systemd-coredump (14:23 à 14:50) : at-spi-bus-launcher, ibus-daemon (plusieurs), gnome-shell (2, démarrages sans bus système), mutter (3 : test de la longueur de socket, 2 `SetKeymap`), kdeconnectd | processus privés des sondes | non effaçables sans root ; ABRT a pu les signaler | mesuré |
| `toolkit-accessibility` vaut `true` dans le dconf réel, alors que `org.a11y.Status.IsEnabled` vaut `false` | La clé valait déjà `true` vers 14:21, lors de la première lecture de la sonde d'accessibilité, avant toute écriture possible des sondes. Entre 14:50 et la fin, le dconf réel n'a changé que par `night-light-last-coordinates`. Explication probable : at-spi2-core 2.62 écrit la clé à `true` dès qu'un client enregistre un écouteur (mesuré en privé, section 5.2). agent-desktop en enregistre un à chaque connexion (`ad:crates/linux/src/system/bus/mod.rs:94-110`), et le `setup` de computer-use-linux écrit la clé | état antérieur à l'audit, laissé tel quel | mesuré ; origine déduite |
| Effets de bord des sondes d'accessibilité | Un `gnome-shell --headless`, vers 14:22, a joint logind et GDM sur le vrai bus système pendant moins d'une minute. Dans l'environnement privé, KWrite et Fichiers ont démarré kdeconnectd, gvfsd-wsdd et gvfsd-dnssd, qui font de la découverte sur le réseau local, et goa-daemon et localsearch ont indexé le `HOME` privé. Sur l'environnement réel, deux commandes ont tourné : `import Gtk` en Python, qui a ouvert puis refermé une connexion à l'affichage Wayland réel sans fenêtre, et `at-spi-bus-launcher --help`, arrêté sur une erreur d'usage | services privés tués en une à deux minutes ; le lanceur AT-SPI réel garde son pid 3847 | mesuré |

Rien n'a été injecté dans la session réelle (aucune entrée, aucune capture, aucune session RemoteDesktop ou ScreenCast démarrée), d'après les rapports et les contrôles de processus. Une autre session Claude (projet paneflow) faisait tourner en même temps un sway et un Xwayland `:2` sur la machine : ils ne viennent pas de cet audit et n'ont pas été touchés.

## 13. Vérification des notes existantes et des rapports

### 13.1 La note du 2026-11-17 (`2026-11-17-backend-linux-gnome.md`)

| Ligne | Verdict | Preuve |
|---|---|---|
| §1.1 `CreateSession` sans dialogue | confirmé en privé ; précision : une session vit tant que la connexion D-Bus qui l'a créée (`gdbus call` la détruit aussitôt) | journal de Mutter « D-Bus client with active sessions vanished » |
| §1.2 ScreenCast v4 | confirmé en direct | `Properties.Get` → 4 |
| §1.3 à §1.5 (renvois vers agent-desktop) | confirmés au HEAD `e8934a5e` : `git diff 8ffecc1d HEAD` vide pour ces fichiers | lus aux lignes citées |
| §1.6 (pointeur impossible à viser) | toujours déduit ; nuancé : l'extension donne les rectangles, `QueryPointer` le pid sous le pointeur | |
| §1.7 (une fenêtre lancée s'ouvre derrière) | non reproduit avec GTK : 21 nouvelles fenêtres sur 21 actives et devant ; le cas GPUI demande une fenêtre sur la session réelle | mesuré en privé |
| §1.8 (sans jeton, aucun programme ne met une fenêtre devant) | **faux** : une nouvelle fenêtre sans jeton prend le focus, et l'extension active toute fenêtre ; seul un `present()` tardif sans jeton est refusé | mesuré en privé |
| §2.1 et §2.2 (autorisation par application hôte ; « non » enregistré → échec sans dialogue) | confirmés | `{'paneflow': ['yes']}` en direct ; échec en 1 ms en privé |
| §2.3 et §2.4 (dialogue, focus sur « Refuser ») | non re-mesurables (dialogue sur l'écran réel) | |
| §2.6 (ScreenCast sans dialogue, fenêtre seule) | confirmé, précisé : l'indicateur de partage s'allume ; la fenêtre recouverte n'est à jour que tant que son flux tourne | mesuré |
| §3.1 (« AT-SPI est éteint par défaut : `IsEnabled` vaut `false` ») | **à corriger** : `IsEnabled` vaut bien `false`, mais dans at-spi2-core 2.62 cela signifie seulement qu'aucun écouteur n'est enregistré en ce moment. GTK s'enregistre quoi qu'il arrive, et `toolkit-accessibility` vaut `true` | lu en direct ; règle mesurée en privé |
| §3.2 (aucune application GPUI sur le bus) | confirmé avec une autre application GPUI : Zed 1.29.2 ne s'est jamais connecté, même avec un écouteur actif. Crow Bot n'a pas été lancé, parce que son client démarre un démon qui lance des agents d'IA | mesuré |
| §3.3 (adaptateur accesskit créé, absence non expliquée) | adaptateur confirmé ; accesskit_unix ne se connecte que tant que `IsEnabled` vaut `true`. L'absence reste inexpliquée | code vérifié ; Zed mesuré |
| §3.4 (la capture seule pour GPUI) | tient, avec une nuance : un arbre GPUI n'existerait que pendant qu'un écouteur est actif | déduit |
| §3.5 (`IsEnabled` se remet à `false`) | confirmé ; il y repasse aussi seul au départ du dernier écouteur | mesuré |
| La citation « GPUI apps such as Paneflow expose no accessibility tree » attribuée au skill Linux d'agent-desktop | elle vient du skill installé d'Arthur (`~/.claude/skills/agent-desktop/SKILL.md:17`), pas du dépôt | recherche dans les deux |
| §4.3 Mutter sans écran | confirmé ; ajouter `GIO_USE_VFS=local GVFS_DISABLE_FUSE=1` | mesuré |
| §4.4 cookie Xwayland | confirmé et précisé : Xwayland démarre à la première connexion X, et `:2` vient de ce que `:0` et `:1` sont pris | mesuré |
| §4.5 limite des sockets | confirmé ; le message réel est « socket path … plus null terminator exceeds 108 bytes » | mesuré |
| §4.6 `kwin_wayland --virtual` | confirmé ; GTK 4.24 passe par `org_kde_kwin_server_decoration` et reçoit les décorations Breeze ; sans les précautions de la section 9.2, KWin touche la session logind de l'hôte | mesuré |
| §4.7 Xvfb et openbox | confirmé avec xdotool : (-195, +195) puis maximisée | mesuré |

### 13.2 Contrôles des rapports des sous-agents

Chaque rapport a été recoupé sur au moins une preuve décisive avant d'être retenu :
- **Contrat du backend** : `nc:src/main.zig:175,183,193`, `mcp.zig:615-634`, `policy.zig:98-112`.
- **Invariants** : `nc:src/core/registry.zig:264-266`, `tools.zig:163-166`, `mcp.zig:27`, `windows.zig:480-489`, `tests/process_test.zig:286`.
- **Tests** : 39 tâches comptées, corrigeant les 40 du rapport.
- **Build** : `nc:build.zig:198-201`, `background_test.zig:634-640`, et la sonde native relancée.
- **agent-desktop** :
  - `walker_expand.rs:139`, `standalone.rs:3-16`, `release.yml:64,75` ;
  - `FINDINGS.md`, lignes L2-6, L2-7, L4-16, L4-22, L29-28.
- **computer-use-linux** : `server.rs:4479-4496`, `remote_desktop.rs:2128-2136`, `windowing/backends/gnome.rs:104-114,250-258`, `agent_seat.rs:155-189,694-719`.
- **GNOME** :
  - core dumps de `SetKeymap` dans `coredumpctl` ;
  - absence de symboles EI de texte dans `libmutter-51.so.0` ;
  - `KeyboardMonitor` et `PointerLocator` introspectés en direct ;
  - `shellDBus.js:545-550` et `screenShield.js:531-541` extraits de `libshell-51.so` ;
  - ACL de `/dev/uinput` et groupe `input`.
- **Captures** : `RecordWindow` d'une fenêtre recouverte et indicateur de partage, `ScreenShot2.CaptureWindow` d'une fenêtre recouverte (images ouvertes).
- **KWin** : chaînes d'autorisation absentes.
- **Accessibilité** :
  - chaînes `EventListenerRegistered` et `toolkit-accessibility` dans le lanceur ;
  - trace `dbus-monitor` où le lanceur appelle `dconf.Writer.Change` ;
  - état 109056 (`suspended`) dans `fixB.log` ;
  - champs d'Introspect sans position ;
  - `ScreenReaderEnabled` absent de la session réelle.
- **computer-use-linux, compléments** : extension sans contrôle de l'appelant (`get_sender` ne sert qu'à l'indicateur), `shell-version` 45 à 51, `gsettings set` dans `diagnostics.rs`, `GLIBC_FLOOR: "2.28"` dans la CI.
- **Web** : la séquence d'arrêt de Claude Code (doc et `~/dev/claude-code/services/mcp/client.ts:1426-1520`), le dépôt computer-use-linux, les chaînes de Chrome.

## 14. Décisions pour Arthur

Arthur a tranché ces treize points le 2026-11-20 et ajouté le pilotage réel de la souris et du clavier sous GNOME : voir `docs/decisions/0014-portage-linux.md`.

1. **Périmètre des environnements de la première version.** GNOME seul, GNOME et KDE, ou les quatre familles. COSMIC n'a pas de pointeur virtuel. X11 natif ne sert plus que Cinnamon, MATE, Xfce et les bancs de test.
2. **Extension GNOME Shell obligatoire.** Sans elle, sous GNOME : ni rectangles ni empilement de fenêtres, ni activation fiable, ni garde du premier plan, ni label d'indicateur. Elle modifie le système de l'utilisateur (dossier d'extensions, `enabled-extensions`, reconnexion au premier ajout) et demande une maintenance à chaque version de GNOME.
3. **API privées sans consentement ou portails.**
   - Mutter RemoteDesktop et ScreenCast, KWin EIS, ScreenShot2 et scripting : sans dialogue, mais l'utilisateur ne donne aucun accord (le kill switch et la politique restent la seule protection).
   - Portails RemoteDesktop et ScreenCast : avec dialogue et jeton de restauration ; il n'y a pas de portail de liste de fenêtres.
   - Ce choix touche la politique de sécurité (contrat produit, Boundaries).
4. **Lecture de l'entrée physique (FR-12) sous Wayland.** evdev, qui exige le groupe `input` (une modification système et un accès à toutes les frappes) ; une extension GNOME qui lit le périphérique source (à sonder) ; ou une détection par soustraction, moins sûre.
5. **Prendre le nom `org.gnome.Orca.KeyboardMonitor`.** Il donne la position du pointeur et les touches sous GNOME, et la surveillance du clavier sous KWin. C'est se faire passer pour un lecteur d'écran, et ce n'est possible que si Orca ne tourne pas.
6. **`registry_read` sous Linux.** Le retirer de la liste des outils, le garder absent, ou le remplacer par une lecture dconf/gsettings. Les noms et paramètres d'outils sont le contrat produit.
7. **Textes du contrat.** Les instructions MCP et les descriptions d'outils qui nomment Windows (Start menu, AUMID, HKCU, cloaked, handles hexadécimaux) : texte par OS, ou texte neutre.
8. **Emplacements et clés de la politique.** `$XDG_CONFIG_HOME` et `$XDG_STATE_HOME`, et les listes de processus Linux (gestionnaires de mots de passe, terminaux, IDE).
9. **Saisie hors disposition sous GNOME.** Le presse-papiers de la session RemoteDesktop (qui remplace celui de l'utilisateur), `EditableText` d'AT-SPI, ou un refus explicite.
10. **Capture sous GNOME.**
    - PipeWire par dlopen de libpipewire : impose un binaire glibc dynamique.
    - Client PipeWire natif : le plus gros chantier.
    - Capture dans l'extension : à sonder, et elle éviterait aussi l'indicateur de partage.
11. **Indicateur de partage d'écran de GNOME en mode arrière-plan.** L'accepter comme signal, ou l'éviter par la capture dans l'extension.
12. **Un gate de bascule pour Linux.** La condition 3 du Rust Switch Gate porte sur COM. Faut-il l'étendre au client PipeWire (threading, durée de vie des tampons) ou à libei ?
13. **Activation de l'accessibilité.**
    - Un abonnement aux événements AT-SPI, indispensable aux attentes et à la stabilisation, allume Qt et accesskit. Il écrit aussi `toolkit-accessibility=true` dans dconf, de façon durable : c'est une modification du système de l'utilisateur, et Chrome en tient compte au lancement.
    - Chrome n'expose son arbre web que lancé avec `--force-renderer-accessibility`. `app_launch` peut-il ajouter ce drapeau et `ACCESSIBILITY_ENABLED=1` aux navigateurs qu'il lance ? Un Chrome déjà ouvert reste sans arbre web.

## 15. Travail à faire

Chantiers dans l'ordre de leurs dépendances. Chacun indique ce qu'il doit prouver. Ce ne sont pas des stories : le PRD les découpera.

| # | Chantier | Dépend de | Preuve attendue |
|---|---|---|---|
| L1 | Rendre le build Linux honnête : hash libjpeg indépendant de l'extraction ; sondes Windows conditionnelles ; erreur explicite si aucun backend ; `ZIG_GLOBAL_CACHE_DIR` documenté | | `zig build` et `zig build test` sur une copie fraîche, sous Linux et sous Windows |
| L2 | Structure : `backend/windows/` et `backend/linux/` en modules séparés dans `build.zig`, cœur inchangé ; `fake.zig` reste la spécification | L1 | `zig build cross` dans les deux sens (Windows depuis Linux mesuré, Linux depuis Windows) |
| L3 | Neutraliser le cœur : chemins de politique et d'audit par OS, listes de politique Linux, identifiants de fenêtre opaques, textes par OS, signaux SIGINT/SIGTERM/SIGHUP, verrou d'instance, `unsupported` qui fait échouer le bench, borne de `background_test.zig:638` | L2, décisions 6 à 8 | tests du cœur sur le faux backend, sous Linux et Windows |
| L4 | Transports natifs générés : fil D-Bus (SASL, descripteurs, signaux), fil Wayland, fil X11 (xcb-proto), EI ; générateurs depuis des XML épinglés, tests d'octets comme `layout_test` | L2 | tests d'octets contre `WAYLAND_DEBUG` et `dbus-monitor` ; binaire musl statique |
| L5 | Détection de l'environnement et table de capacités | L4 | selftest qui imprime la table sur chaque banc |
| L6 | AT-SPI : connexion persistante, lecture (Cache où il marche), actions, événements, mots de passe, délais bornés pour une application figée | L4 | équivalents des checks `ui-*` sur des fixtures GTK 4 et Qt 6 ; budgets de la section 5.2 |
| L7 | Backend GNOME : RemoteDesktop et EI, ScreenCast ou capture par l'extension, extension Shell (liste, empilement, activation, gestion, garde, label, pointeur), presse-papiers, écrans, verrou | L5, L6, décisions 2, 3, 10, 11 | selftest et selftest d'arrière-plan sur gnome-shell headless |
| L8 | Backend KDE : EIS, ScreenShot2, canal de script KWin persistant, `ext-data-control`, layer-shell | L5, L6 | idem sur KWin `--virtual`, puis contrôle dans une vraie session Plasma (autorisations) |
| L9 | Backend wlroots : pointeur et clavier virtuels avec gardien, `ext-image-copy-capture`, `foreign-toplevel`, IPC sway, Hyprland, niri, `data-control` | L5, L6 | idem sur sway et labwc headless |
| L10 | Backend X11 : XTest avec gardien, XI2 pour le kill switch, XShm, Composite, EWMH, sélections, indicateur override-redirect | L5, L6 | idem sur Xvfb |
| L11 | Relâche et kill switch par transport (gardien, signaux, lecture de l'entrée physique) | L7 à L10, décision 4 | équivalents de `release`, `kill-*` et `bg-kill-*` ; relâche en moins de 50 ms mesurée sous SIGINT, SIGTERM et SIGKILL |
| L12 | Mode arrière-plan : garde du premier plan, lancement sans focus, restauration sans focus, témoin bloquant, capture de fenêtre masquée | L7 à L11 | `selftest --background` Linux avec leurre et témoin |
| L13 | Chromium et Electron sous Linux : activation de l'arbre, comportement recouvert sur chaque compositeur, effet du flux `RecordWindow` | L6, L7 | sonde équivalente à `occlusion-probe` |
| L14 | Bench Linux : baselines par OS et par compositeur, scénarios de capture, d'arbre, d'action et de stabilisation | L7 à L10 | `zig build bench -- --check` par famille |
| L15 | Harnais d'evals Linux (sans PowerShell), tâches équivalentes (GNOME Text Editor, Calculatrice, Fichiers, Paramètres, Chrome, Firefox, VS Code), témoin Linux | L12 | `-DryRun` équivalent |
| L16 | Distribution : binaire x86_64 et aarch64, installation de l'extension et des scripts, documentation `claude mcp add` | L7, L8 | installation sur une machine propre (Fedora, Ubuntu 26.04) |
| L17 | Sécurité : refus quand la session est verrouillée ou qu'un dialogue polkit est ouvert, processus d'un autre uid, filtre seccomp anti-réseau, vérifications mutuelles du serveur et de l'extension (propriétaire du nom, pid de l'appelant), refus de `Peek` | L7 à L10 | checks `security` Linux |

## 16. Ce qui reste à mesurer

- Entrée physique : lecture evdev en vrai, IdleMonitor face à une entrée physique, et la piste de l'extension GNOME qui lit le périphérique source (aucun périphérique physique dans les bancs ; lecture interdite sur la session réelle).
- Capture dans une extension GNOME (`Meta.WindowActor`, `Shell.Screenshot` interne) : faisabilité, coût, fenêtre recouverte.
- Lecture du presse-papiers par la session RemoteDesktop (`SelectionRead`) et son signal de changement.
- Dialogues de consentement et autorisations dans de vraies sessions : portail GNOME, KWin ScreenShot2 et `fake_input` sous Plasma, XTest par Xwayland.
- Chrome recouvert sous KWin et wlroots ; la cause du gel de son arbre sous Mutter quand la page change vite ; l'effet d'un flux `RecordWindow` sur ce gel. Electron (aucune application installée).
- Pourquoi Zed 1.29.2 (GPUI) ne se connecte jamais au bus AT-SPI.
- `object:bounds-changed`, les événements des champs mot de passe de Chrome, `ScrollTo` et Toggle sous Qt, les coordonnées AT-SPI sous Xwayland.
- COSMIC, Hyprland et niri (non installés).
- Mise à l'échelle fractionnaire réelle (seulement une échelle temporaire en privé).
- `SetKeymap` de Mutter 51 : la bonne sémantique (le XML de l'interface n'est pas installé).
- Le sens des champs de `GstVideoCropMeta` d'un flux `RecordWindow`.

## 17. Sources en ligne

- GNOME 50 sans session X11 : <https://phoronix.com/news/gnome-50-alpha>, <https://blogs.gnome.org/alatiera/2025/06/08/the-x11-session-removal/>
- Plasma sans X11 à partir de 6.8 : <https://blogs.kde.org/2025/11/26/going-all-in-on-a-wayland-future/>
- Ubuntu 26.04 LTS : <https://www.omgubuntu.co.uk/2026/04/ubuntu-26-04-lts-released>
- RHEL 10 et Xorg : <https://www.redhat.com/en/blog/rhel-10-plans-wayland-and-xorg-server>
- Mint et Wayland : <https://www.omgubuntu.co.uk/2026/07/linux-mint-wayland-fully-supported> ; xfwl4 : <https://linuxiac.com/xfce-begins-work-on-xfwl4-a-rust-based-wayland-compositor/>
- Restrictions d'Introspect et de Screenshot : <https://gitlab.gnome.org/GNOME/gnome-shell/-/merge_requests/1970>
- Sécurité de Mutter ScreenCast et RemoteDesktop : <https://discourse.gnome.org/t/security-for-mutter-screencast/35009>, <https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/3943>
- GlobalShortcuts dans GNOME 48 : <https://release.gnome.org/48/developers/>
- Portail RemoteDesktop : <https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html>
- libei et ConnectToEIS : <https://gitlab.freedesktop.org/libinput/libei/-/issues/1>
- KWin : <https://bugs.kde.org/show_bug.cgi?id=513785>, <https://bugs.kde.org/show_bug.cgi?id=483227>, <https://bugs.kde.org/show_bug.cgi?id=480235>, <https://phabricator.kde.org/D29407>
- Tables de protocoles : <https://wayland.app/protocols/ext-image-copy-capture-v1>, <https://wayland.app/protocols/ext-foreign-toplevel-list-v1>, <https://wayland.app/protocols/wlr-virtual-pointer-unstable-v1>
- Chromium et l'accessibilité sous Linux : <https://chromium.googlesource.com/chromium/src/+/lkgr/content/browser/accessibility/browser_accessibility_state_impl_auralinux.cc> ; Chrome 140 en Wayland natif : <https://www.omgubuntu.co.uk/2025/08/chrome-140-wayland-auto-detection-linux> ; Electron 38 : <https://electronjs.org/blog/electron-38-0>
- Qt et l'accessibilité : <https://doc-snapshots.qt.io/qtforpython-6.5/PySide6/QtGui/QAccessible.html> ; accesskit_unix : <https://docs.rs/crate/accesskit_unix/0.16.0/source/src/context.rs>
- Claude Code : <https://code.claude.com/docs/en/mcp>, <https://code.claude.com/docs/en/setup>
- Flatpak : <https://docs.flatpak.org/en/latest/sandbox-permissions.html>
- glibc par distribution : <https://repology.org/project/glibc/versions>
- Enquête Steam d'octobre 2026 : <https://phoronix.com/news/Steam-Survey-October-2026>
- computer-use-linux : <https://github.com/agent-sh/computer-use-linux> ; kwin-mcp : <https://github.com/isac322/kwin-mcp> ; use-computer : <https://github.com/BogdanStamenovic/use-computer>
