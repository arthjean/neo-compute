[PRD]
# PRD: neo-compute, portage Linux

## Changelog

| Version | Date | Author | Summary |
|---------|------|--------|---------|
| 1.0 | 2026-11-20 | Arthur Jean | Version initiale : portage Linux (GNOME de référence, KDE, wlroots) d'après l'audit `docs/research/2026-11-20-audit-portage-linux.md` et la décision `docs/decisions/0014-portage-linux.md` (D1 à D14), EP-019 à EP-032 |

## Problem Statement

1. **neo-compute ne tourne pas sous Linux.** `src/main.zig:15-18` choisit le backend Windows sous Windows et le backend factice partout ailleurs. Sous Linux, `zig build` construit donc en silence un serveur sans bureau, et `selftest` répond « this build has no platform backend » (audit 8.1, mesuré).
2. **Les gates mentent sous Linux.**
   - Une copie fraîche ne construit pas : le hash de libjpeg-turbo ne correspond qu'à une extraction qui garde le répertoire racine (`build.zig:201`).
   - `zig build test` passe 353 tests sur 357.
   - `zig build cross` y compile pour l'hôte et ne prouve rien.
   - Le bench conclut « no regression » avec 14 scénarios sur 16 ignorés (`src/core/bench.zig:346`).
   (Audit 8.1, mesuré.)
3. **Le cœur suppose Windows sans le dire** (audit 3.2 et 3.3, vérifié).
   - La politique et l'audit lisent `APPDATA` et `LOCALAPPDATA` (`src/main.zig:174-188`). Sous Linux, aucun des deux ne se charge.
   - Les listes de politique sont des noms `.exe` (`src/core/policy.zig:98-112`). Sous Linux, ni gestionnaire de mots de passe ni terminal n'est protégé.
   - Aucun signal n'est géré dans `src/`, alors que Claude Code arrête un serveur Linux par SIGINT, puis SIGTERM à 100 ms, puis SIGKILL 400 ms plus tard. SIGINT tue donc le processus sans relâcher les touches tenues.
   - Les textes MCP nomment Windows, et `registry_read` n'a pas d'équivalent.
4. **Les outils Linux existants ne tiennent pas les invariants de neo-compute** (audit 11, vérifié).
   - agent-desktop refuse toute commande de pointeur sur une application Wayland (`crates/linux/src/input/deliver.rs:39-79`) et ne garde aucun état entre deux commandes.
   - computer-use-linux ne relâche pas les entrées tenues sur SIGINT ou SIGTERM et ne masque aucun mot de passe dans ses images.
   - computer-use-linux renvoie en écho la valeur passée à `set_value`, et son mode arrière-plan déplace le focus en répondant `ok`.
   - Aucun des deux n'a de kill switch.
5. **Arthur travaille sous Fedora 45 GNOME Wayland** (machine de référence en dual boot) et veut que l'agent y pilote la vraie souris et le vrai clavier (décision 0014, D14). Une passe visuelle a besoin de survol, de glisser-déposer, de canevas, de raccourcis globaux ou d'applications sans arbre d'accessibilité.

**Why now:**
- **Le PRD initial annonçait ce portage pour plus tard.** Il prévoyait un PRD séparé, construit sur Fedora une fois neo-compute validé sous Windows (`tasks/prd-neo-compute.md:27`). Les PRD Windows sont livrés jusqu'à EP-018 (commit `3091301`).
- **Linux est désormais Wayland.** GNOME 50 et Plasma 6.8 ont retiré leur session X11, et Ubuntu 26.04 LTS et RHEL 10 n'en ont plus : la cible est stable (audit 1.1, documenté).
- **Tout est vérifié et décidé.** L'audit du 2026-11-20 a mesuré chaque voie sur cette machine, et Arthur a tranché les quatorze choix structurants le même jour (décision 0014).

## Overview

Le portage garde le cœur (`src/core/`) comme module commun et ajoute un backend Linux, séparé du backend Windows, sur le modèle d'agent-desktop (un crate par système). Les trois modules sont `core`, `backend_windows` et `backend_linux`. Le système se choisit à la compilation, comme aujourd'hui. Sous Linux, le binaire unique choisit la famille de compositeur à l'exécution (GNOME, KDE, wlroots) et compose une table de capacités. Une capacité absente donne un message qui nomme la cause et l'action suivante (FR-06).

Disposition visée :

```
src/core/                 cœur commun, sans API d'OS ; les données propres à un OS viennent du backend
src/backend/fake.zig      spécification exécutable du contrat (58 méthodes obligatoires)
src/backend/windows.zig + windows/   inchangés de comportement
src/backend/linux.zig     façade : choix de la famille à l'exécution, table de capacités
src/backend/linux/
  wire/       D-Bus, Wayland, EI parlés en Zig natif ; xkb.zig (libxkbcommon par dlopen)
  atspi/      arbre, actions, événements, mots de passe, rôles
  common/     lancement (.desktop, MIME, processus lanceur, scopes systemd), /proc, signaux, verrou,
              chemins XDG, seccomp, presse-papiers data-control, libellé layer-shell, evdev
  gnome/      RemoteDesktop et EI, écrans, client de l'extension, capture, ScreenCast, extension/ (JS)
  kde/        EIS, ScreenShot2, canal du script KWin, script/ (JS)
  wlroots/    pointeur et clavier virtuels, gardien (guardian.zig), ext-image-copy-capture, foreign-toplevel, IPC sway
tools/protogen/        XML (Wayland, EI, introspection D-Bus) vers Zig, comme tools/winmdgen
tools/linux-session/   sessions sans écran isolées pour selftests, bench et évals
tools/evals-linux/     harnais d'évals Linux
bindings/linux.zon     interfaces et membres utilisés ; sources XML épinglées dans build.zig.zon
tests/linux/           fixtures GTK 4 (Python), pages Chrome, traces de référence (octets D-Bus et Wayland)
```

Décisions qui portent la conception, chacune tirée de l'audit et de la décision 0014 :

1. **GNOME est la référence.** L'entrée réelle passe par le canal EI de la session `org.gnome.Mutter.RemoteDesktop` : sans dialogue, au sous-pixel près, 0,3 à 0,4 ms de l'injection à l'application, relâche en 0,65 à 3 ms à la mort du client (audit 4.1, mesuré). L'extension GNOME Shell donne la liste des fenêtres avec empilement, l'activation, la gestion sans changer le focus, le pointeur, le libellé et la détection de l'entrée physique (audit 4.1, mesuré ; D2, D4). La capture passe d'abord par l'extension (D10), avec ScreenCast et libpipewire chargée à l'exécution en repli.
2. **AT-SPI remplace UI Automation sans changer le modèle du cœur.** Un instantané se lit en 10 à 46 ms avec tous les appels d'un niveau en vol. Les actions n'activent pas la fenêtre. Sous Wayland, les coordonnées d'écran se recomposent à partir du cadre de la fenêtre (audit 5.2, mesuré).
3. **KDE et wlroots suivent.** KWin donne l'entrée par EIS, la capture d'une fenêtre recouverte ou minimisée et la gestion des fenêtres par un script persistant (audit 4.2, mesuré en headless). wlroots passe par les protocoles `wlr`/`ext`, avec un processus gardien parce que ses claviers virtuels ne relâchent rien à la mort du client (audit 4.3, mesuré).
4. **Les transports sont générés et natifs.** D-Bus, Wayland et EI sont générés depuis des XML épinglés et parlés en Zig natif. La sonde `wire.zig`, 160 Ko statique, sans bibliothèque C, s'est authentifiée sur le vrai bus et a lu les 46 globals de la vraie session (audit 8.4, mesuré). Seules libpipewire et libxkbcommon sont chargées par `dlopen`.
5. **Les tests ne touchent jamais la session réelle.** Chaque selftest, bench et éval tourne dans une session sans écran isolée (`tools/linux-session`). Un témoin vérifie après chaque session que rien de réel n'a changé : c'est la leçon des incidents de l'audit (section 12).

### Décisions de contrat proposées (US-067)

Ces points ne sont pas tranchés par la décision 0014. Ils touchent la sécurité, la politique ou le contrat, donc ils reviennent à Arthur (AGENTS.md, « Boundaries »). US-067 les consigne dans un amendement de 0014. Une story qui en dépend ne démarre pas avant sa réponse.

| # | Point proposé | Preuve ou raison | Stories qui en dépendent |
|---|---|---|---|
| P1 | Sous GNOME, l'entrée réelle exige l'extension, seule source du kill switch par entrée physique. Sans elle, les outils d'entrée sont refusés | D14 exige le kill switch avant l'entrée réelle ; aucune API de Mutter ne distingue l'entrée physique (audit 7, mesuré) | US-090 à US-094 |
| P2 | Sous KDE, le kill switch se déclenche sur un mouvement physique du pointeur, détecté en retirant de la position du curseur celle que le serveur a injectée, et sur le raccourci de pause. Le serveur refuse d'injecter la combinaison de ce raccourci. Un Échap physique ne déclenche rien | D4 (soustraction) ; KWin ne donne les touches qu'au nom d'Orca, que D5 interdit (audit 4.2) ; A41, validée par US-105 | US-107 |
| P3 | Sous wlroots, l'entrée réelle n'est possible qu'avec `--physical-input evdev`. Le mode arrière-plan y est refusé | D4 (evdev sur activation explicite) ; D1 (pas d'empilement, audit 4.3) | US-110, US-112, US-121 |
| P4 | Les sous-commandes `neo-compute setup` et `neo-compute setup --uninstall`, et ce qu'elles modifient : dossier de l'extension, `enabled-extensions`, rien d'autre | D2 (installation par commande explicite) ; FR-54 | US-082 |
| P5 | Sous Linux, `selftest` refuse la session réelle sans `--real-session` | Huit des neuf incidents de l'audit viennent de sondes qui ont touché la session réelle (audit 12) | US-081 |
| P6 | Versions prises en charge : GNOME 50 et 51, Plasma 6.8, sway 1.12, labwc 0.20. Une session X11 est refusée | Versions installées et mesurées (audit 1.2) ; GNOME 50 est celui d'Ubuntu 26.04 LTS (audit 1.1) ; D1 | US-081, US-082 |
| P7 | Distribution : glibc 2.28 dynamique, x86_64 et aarch64, libpipewire et libxkbcommon chargées à l'exécution | T12 (audit 10, mesuré) | US-069, US-080, US-097, US-120 |
| P8 | Listes de politique Linux par défaut : gestionnaires de mots de passe en `deny`, terminaux et éditeurs de code en `click`, comme les listes Windows | D8 ; `src/core/policy.zig:98-118` (niveaux `deny` et `click` des listes Windows) | US-070 |
| P9 | Filtre seccomp contre le réseau. Refus d'agir sur une fenêtre d'un autre uid, pendant un dialogue système modal ou sur un écran verrouillé, sur chaque famille | FR-10 ; l'entrée injectée atteint l'invite de déverrouillage (audit 4.1, mesuré) ; équivalents Linux d'UIPI (audit 7) | US-094, US-107, US-112, US-119 |
| P10 | En mode serveur, neo-compute n'exécute aucun programme lui-même. Seul `app_launch` fait exécuter une application, sans shell, par un processus lanceur créé au démarrage, qui ne porte pas le filtre seccomp | FR-11 et AGENTS.md (aucun outil de commande) ; un filtre seccomp est hérité par les enfants et conservé à travers `execve` (`seccomp(2)`) : une application lancée par le serveur filtré n'aurait pas de réseau | US-099, US-119 |
| P11 | Les évals Linux tournent dans une session GNOME isolée, et non sur le bureau réel, avec un harnais en Zig | T10 ; P5 | US-116 |
| P12 | Les gestes physiques simulés (méthode `SimulatePhysical` de l'extension, option `--physical-input simulated`) ne sont acceptés que dans un banc : `NC_SESSION` posé et `XDG_RUNTIME_DIR` sous `/run/user/<uid>/nc-`. Ils remplacent alors la source physique du kill switch | Sans eux, aucun contrôle du kill switch ne tourne sur un banc sans écran, qui n'a aucun périphérique physique (audit 9.2). Un processus local capable de poser ces variables peut déjà injecter des entrées lui-même : la garde vise l'usage accidentel hors banc | US-083, US-110 |

### Livraisons

| Livraison | Contenu | Points |
|---|---|---|
| 1 : GNOME au premier plan | EP-019 à EP-025 sauf US-097, plus US-119 | 101 |
| 2 : arrière-plan et mesures GNOME | EP-026, EP-029, EP-030, EP-031, US-097, US-120 | 42 |
| 3 : KDE et wlroots | EP-027, EP-028 | 31 |

Périmètre : 14 epics, 58 stories, 174 points. Si la sonde US-095 infirme A25, US-097 devient P0 et passe en livraison 1.

## Non-Goals

- **Backend X11 natif (chantier L10 de l'audit) et COSMIC.** Ils sont hors de cette version (D1). Sous GNOME, les applications Xwayland passent par le compositeur comme les autres. COSMIC n'a pas de pointeur virtuel. Une session X11 est refusée avec un message (US-081).
- **IPC propres à Hyprland et à niri.** Ces compositeurs passent par les protocoles génériques s'ils les exposent : foreign-toplevel, screencopy, pointeur et clavier virtuels. Seul l'IPC de sway est implémenté, faute de banc pour les autres (non installés, audit 4.3).
- **Mode arrière-plan sous wlroots.** Aucun protocole ne donne l'empilement des fenêtres (D1, P3).
- **Portails comme voie principale.** Le portail RemoteDesktop reste un repli d'EI pour un compositeur inconnu (D3).
- **uinput, second siège (MPX, `ext_transient_seat`), stylet ou tactile virtuels.** computer-use-linux montre qu'ils déplacent le focus ou exigent `/dev/uinput` (audit 11).
- **Client PipeWire natif et compilateur de dispositions xkb natif** (D10, Technical Decisions).
- **Paquets de distribution (rpm, deb, Flatpak, Snap), npm, plugin Claude Code, publication de l'extension sur extensions.gnome.org.** La distribution v1 est une archive par architecture (US-120). Flatpak est inadapté, car la sandbox filtre AT-SPI et ScreenCast (audit 10).
- **GNOME avant 50, Plasma avant 6.8.** Non mesurés (P6).
- **Lecteur dconf à la place de `registry_read`** (D6).
- **Firefox et VS Code dans les évals Linux.** Ils ne sont pas installés sur la machine de référence. Leurs tâches deviennent des tâches Chrome et KWrite, ou sont retirées (US-117, US-123).
- **Relâche des touches d'un serveur figé (SIGSTOP).** Ni Mutter ni le serveur ne peuvent agir. La limite est documentée (US-093).
- **Changement des PRD Windows.** Le comportement Windows reste identique, gates compris.

## Success Metrics

| Metric | Baseline (current) | Target | Timeframe | How Measured |
|--------|-------------------|--------|-----------|-------------|
| Gates passés sous Linux sur une copie fraîche (fmt, build, test, cross, bench) | 1 sur 5 (fmt seul, audit 8.1) | 5 sur 5 | Livraison 1 | Copie fraîche, cache Zig vide (US-068) |
| Différences de la session réelle relevées par le témoin des bancs | 9 incidents pendant l'audit (section 12) | 0 sur 20 cycles par famille | Livraison 1 | Témoin de `tools/linux-session` (US-074, US-075) |
| Relâche d'une touche tenue après EOF, SIGINT, SIGTERM, SIGKILL sous GNOME | Aucun gestionnaire de signal | < 50 ms (FR-07) dans les 4 cas | Livraison 1 | Contrôle `release` (US-093) |
| Budgets absolus de `src/core/bench.zig` tenus sous GNOME | Non mesuré | Tous les scénarios de `bench/baseline-linux.json` | Livraison 2 | `zig build bench -- --check bench/baseline-linux.json` (US-115) |
| Violations de non-interférence sur 1 000 actions d'arrière-plan sous GNOME | N/A | 0 | Livraison 2 | Contrôle `bg-loop` (US-100) |
| Réussite sur la suite Linux `existing` | N/A | ≥ 95 % (cible Windows, PRD background) | Livraison 2 | Campagne US-118 |
| Réussite sur la suite Linux `background` | N/A | ≥ 85 % (cible Windows, PRD background) | Livraison 2 | Campagne US-118 |
| Fuites de mot de passe sur les tâches canari Linux | N/A | 0 | Livraison 2 | Campagne US-118 |

## Target Users

- **Arthur (développeur, utilisateur principal).** Il travaille sous Fedora 45 GNOME Wayland, deux écrans 2560x1440 à l'échelle 1, en dual boot avec la machine de référence Windows (audit, en-tête). Aujourd'hui, il n'a sous Linux que agent-desktop, sans pointeur sur les applications Wayland, ou computer-use-linux, sans les invariants de neo-compute.
- **Claude Code (agent consommateur).** Il arrête un serveur Linux par signaux et non par fermeture de stdin (`~/dev/claude-code/services/mcp/client.ts:1426-1520`, vérifié). Il est pris en charge sous Ubuntu 20.04+, Debian 10+ et Alpine 3.19+, en x64 et ARM64 (audit 10, documenté).
- **Développeurs Claude Code sous Linux (secondaire).** Ils utilisent surtout GNOME (bureau par défaut de Fedora, Ubuntu, RHEL, Debian) ou KDE ; aucune donnée crédible de parts de marché par bureau (audit 1.1).

## Research Findings

Les sources primaires sont l'audit `docs/research/2026-11-20-audit-portage-linux.md` (par section) et la décision 0014. Les constats décisifs :

| Constat | Source | Statut |
|---|---|---|
| Mutter : RemoteDesktop et ScreenCast sans dialogue pour un processus de la session. La session meurt avec la connexion D-Bus. Un premier clic sans mouvement préalable et la première touche après `Start` sont perdus. Un keysym hors disposition est abandonné en silence. `SetKeymap` fait planter Mutter 51.1 | audit 4.1 | mesuré |
| EI sous Mutter : pointeur absolu sur la région de chaque écran, sans ScreenCast. La keymap du compositeur est publiée. Aucun symbole de texte EI dans `libmutter-51.so.0`. Relâche en 0,65/0,86 ms au `kill -9` du client | audit 4.1 | mesuré |
| Extension GNOME : liste en 0,27/0,32 ms avec empilement, pid et cadre. Activation sans jeton 20 fois sur 20. Gestion sans changer le focus. `unminimize` sans focus 0 fois sur 20. Libellé `St.Label` traversé par les clics, absent de `RecordWindow` | audit 4.1 | mesuré |
| `Introspect.GetWindows` est réservé aux portails et ne donne ni position, ni empilement, ni pid. `Shell.Screenshot` est réservé à deux noms déjà pris | audit 4.1 ; `gs:ui/screenshot.js:2848-2851` | mesuré, vérifié |
| ScreenCast `RecordWindow` d'une fenêtre recouverte rend ses propres pixels et fait redessiner le client. Toute session allume l'indicateur de partage d'écran. Images seulement sur dommage | audit 4.1 | mesuré |
| Une nouvelle fenêtre prend le focus 21 fois sur 21, avec ou sans jeton, sous la politique `smart` de Mutter | audit 4.1 | mesuré |
| Écran verrouillé : l'entrée injectée réveille l'invite. `SetActive(false)` déverrouille sans mot de passe | audit 4.1 ; `gs:ui/shellDBus.js:545-550` | mesuré, vérifié |
| AT-SPI 2.62 : `IsEnabled` suit les écouteurs, et l'abonnement écrit `toolkit-accessibility=true`. GTK 4 s'enregistre toujours. Qt attend `IsEnabled`. Chrome exige `--force-renderer-accessibility` | audit 5.2 | mesuré |
| Instantané pipeliné : GTK 4 (135 nœuds) 21,5/28,2 ms, Chrome (792) 43,6/46,5 ms. `Cache.GetItems` marche sous GTK 4 et Chromium, mais rend vide sous Qt | audit 5.2 | mesuré |
| Sous Wayland, aucun toolkit ne donne de coordonnées d'écran. Une case GTK 4 n'a aucune action. Les champs web de Chrome n'ont pas d'`EditableText`. `Peek` met un mot de passe GTK 4 en clair. `Ping` répond quand le fil principal est bloqué | audit 5.2 | mesuré |
| KWin 6.8.3 headless : EIS (avec texte), ScreenShot2 (fenêtre recouverte ou minimisée en 1,85 ms) et Scripting (canal long-poll en 0,17 ms) sans autorisation. `X-KDE-DBUS-Restricted-Interfaces` n'est pas appliqué | audit 4.2 | mesuré |
| wlroots (sway, labwc) : pointeur et clavier virtuels, `ext-image-copy-capture` d'une fenêtre recouverte en 2,1 ms, data-control sans focus. Une touche tenue n'est pas relâchée à la mort du client (38 s de répétition) | audit 4.3 | mesuré |
| Aucune API de compositeur ne distingue l'entrée physique de l'injectée. L'IdleMonitor compte l'injecté. RemoteDesktop et EI ne créent aucun nœud evdev | audit 7 | mesuré |
| Sonde native Zig : SASL EXTERNAL et `Hello` sur le bus réel, `get_registry` sur la session réelle, binaire musl statique de 160 096 octets | audit 8.4 | mesuré |
| Liens : glibc 2.28 dynamique et `dlopen` marchent ; musl statique ne peut pas faire de `dlopen` ; lier directement des bibliothèques système en ciblant 2.28 échoue sur `stat64@GLIBC_2.33` | audit 10 | mesuré |
| Gates sous Linux : hash libjpeg, sondes Windows installées sans condition, 4 étapes de test Windows, borne de 120 ms calée sur Windows (110 ms mesurés sous Linux), bench à vide | audit 8.1 | mesuré |
| Bancs sans écran : gnome-shell, Mutter, KWin, sway, labwc et Xvfb, avec la liste des isolations nécessaires. Neuf incidents faute de les respecter | audit 9.2 et 12 | mesuré |
| computer-use-linux construit gnu et musl avec cargo-zigbuild et Zig 0.17.0, plancher glibc 2.28 vérifié en CI. Son extension ne contrôle pas l'appelant | audit 10 et 11 | vérifié |
| Chrome (`/opt/google/chrome`), Helium (`/opt/helium`) et les applications Electron Cursor, Proton Pass et ChatGPT installées portent `chrome_100_percent.pak` à côté de leur exécutable | `find /opt /usr/lib /usr/share -name chrome_100_percent.pak` sur la machine, 2026-11-20 | mesuré |
| Un filtre seccomp est hérité par les enfants (`fork`, `clone`) et conservé à travers `execve` | `seccomp(2)`, page de manuel Linux | documenté |
| Sur la machine : sessions Wayland `gnome`, `plasma` et `sway` installées ; `swaylock` 1.8.6 installé ; ni `qemu-user-static`, ni Firefox, ni VS Code, ni pwsh | `/usr/share/wayland-sessions`, `rpm -q`, `which`, 2026-11-20 | mesuré |

## Assumptions & Constraints

### Assumptions (to validate)

- **A24 :** l'extension GNOME distingue une entrée physique d'une entrée injectée par le périphérique d'origine de l'événement Clutter. Un nœud de périphérique (`/dev/input/event*`) non nul signifie une entrée physique, car RemoteDesktop et EI n'en créent aucun (audit 7, mesuré). Haut risque : le kill switch de GNOME (P1, D14) et le mode arrière-plan en dépendent. Validé par US-083 sur la session réelle, avant US-094.
- **A25 :** l'extension capture l'écran et une fenêtre dans le Shell, et transmet les pixels par memfd dans les budgets `capture` (8 ms) et `screenshot` (30 ms p95). Une fenêtre recouverte y garde ses propres pixels, et l'extension signale les changements de chaque fenêtre (dommage de son acteur). Haut risque : la voie de capture (D10, D11) en dépend. Validé par US-095.
- **A26 :** la saisie Unicode d'IBus (Ctrl+Maj+U, code, espace) tape un caractère hors disposition dans GTK 4, Qt 6 et Chrome sous GNOME. Validé par US-092.
- **A27 :** dans une vraie session Plasma 6.8, EIS, ScreenShot2 et Scripting restent accessibles sans dialogue à un processus sans fichier `.desktop`, comme sous KWin headless. Haut risque pour EP-027. Validé par US-105.
- **A28 :** un script KWin lit la position du curseur et est prévenu de ses changements (`workspace.cursorPos`, `cursorPosChanged`). Validé par US-105.
- **A29 :** à une échelle fractionnaire, la région absolue EI est en coordonnées logiques de l'écran. Validé par US-090 à 1, 1,5 et 2.
- **A30 :** gnome-shell sans écran porte tout ce que les selftests GNOME exigent. L'extension, RemoteDesktop et EI, et ScreenCast y sont mesurés (audit 4.1 et 9.2). Restent à mesurer l'échelle temporaire de `DisplayConfig` (validée par US-085) et le verrouillage avec le faux GDM (validé par US-094).
- **A31 :** sous chaque compositeur, l'arbre d'un Chrome recouvert suit les actions sur une page lente et se fige sur une page qui change toutes les 50 ms. C'est mesuré sous Mutter, sans flux de capture (audit 5.2). L'effet d'une capture de fenêtre et le comportement sous KWin et sway sont à mesurer. Validé par US-114 (GNOME), US-109 (KDE) et US-122 (sway).
- **A32 :** cadre de la fenêtre (extension) plus coordonnées AT-SPI relatives à la fenêtre donnent les coordonnées d'écran d'un élément à 1 px près, décorations côté client comprises. Validé par US-089.
- **A33 :** les propriétés `a11y-dbus-name` et `a11y-object-path` de Mutter 51 sont remplies quand l'accessibilité est active (elles étaient nulles avec `GTK_A11Y=none`, audit 4.1). Sinon, le lien entre fenêtre et racine AT-SPI passe par le pid et le titre. Validé par US-086.
- **A34 :** l'interface de texte EI de KWin tape une chaîne UTF-8 hors disposition. La capacité est annoncée, l'envoi n'est pas mesuré (audit 4.2). Validé par US-107.
- **A35 :** chaque compositeur sans écran démarre en moins de 30 s. Mutter est prêt en 0,21 s (audit 4.1) ; le temps de gnome-shell n'est pas mesuré précisément. Validé par US-074 et US-075.
- **A36 :** GNOME 50 (Ubuntu 26.04 LTS) expose les mêmes API que GNOME 51 pour ce que le serveur et l'extension utilisent. Validé par US-120.
- **A37 :** sous wlroots, un processus gardien relâche les touches tenues en moins de 50 ms après le SIGKILL du serveur. Le gardien X11 est mesuré à 0,26 ms ; sous wlroots, un nouveau client qui appuie puis relâche débloque la touche (audit 4.3 et 4.5). Validé par US-121.
- **A38 :** Paramètres de GNOME (`gnome-control-center`) fonctionne dans gnome-shell sans écran, pour les tâches d'évals. Validé par US-117.
- **A39 :** le binaire Linux ReleaseFast strippé reste sous 3 MB, cible Windows du PRD background. Le serveur actuel (backend factice) fait 1,9 Mo en musl strippé (audit 10). Validé par US-120.
- **A40 :** sous GNOME, le presse-papiers de la session RemoteDesktop se lit (`SelectionRead`) et signale les changements de propriétaire. Seule l'écriture est mesurée (audit 4.1). À défaut, l'extension lit le presse-papiers par `St.Clipboard` et suit les changements par le signal `owner-changed` de `Meta.Selection`. Le presse-papiers (US-098), la restauration de US-092 et le témoin de US-100 en dépendent. Validé par US-098.
- **A41 :** sous KDE, un mouvement physique du pointeur se distingue de l'entrée injectée par l'écart entre la position du curseur et la dernière position absolue injectée par le serveur, sans faux déclenchement. L'audit juge cette détection « moins sûre » (audit 14, point 4), sans l'avoir mesurée. Haut risque : le kill switch de KDE (P2) en dépend. Validé par US-105 sur une vraie session Plasma.
- **A42 :** sous wlroots, les pointeurs et claviers virtuels ne créent aucun nœud dans `/dev/input`, donc tout événement evdev est physique. C'est mesuré pour RemoteDesktop et EI seulement (audit 7) ; le kill switch evdev n'est pas mesuré (audit 16). Validé par US-121.
- **A43 :** l'option `hide-caller-windows` de ScreenShot2 retire des captures la surface layer-shell du libellé. C'est déduit (audit 4.2). Validé par US-108.
- **A44 :** un script KWin persistant se décharge de lui-même dans les 5 s qui suivent la mort du serveur, quand son attente longue échoue. Le délai de 5 s est une tolérance fixée par ce PRD, non mesurée. Validé par US-106.
- **A45 :** le binaire aarch64 fonctionne. Il a été construit, jamais exécuté (audit 10). Validé par US-120 sous émulation.
- **A46 :** une application Electron porte `chrome_100_percent.pak` ou `resources.pak` à côté de son exécutable, comme les trois installées ici (Research Findings), et accepte `--force-renderer-accessibility`. Validé par US-113 avec Cursor.
- **A47 :** sous wlroots, un écran verrouillé par `ext-session-lock` se reconnaît : aucune fenêtre de `ext-foreign-toplevel` n'est active, ou `LockedHint` de logind vaut vrai. Sans ce signal, une entrée injectée pourrait taper dans l'invite de déverrouillage, et des échecs répétés bloquer le compte. Validé par US-112 avec swaylock sur le banc sway.

### Hard Constraints

- Zig 0.17.0, version épinglée et contrat produit. La machine Linux a 0.17.1 (audit 8.1) ; les gates tournent avec 0.17.0 (US-068), sauf décision d'Arthur (Q20).
- Les invariants FR-07 à FR-18 et ceux du mode arrière-plan (FR-31 à FR-47) restent vrais sur les deux systèmes.
- Les 17 outils du toolset restent conformes à `tests/fixtures/toolset_20260801.json`. Une extension est un paramètre optionnel.
- `src/core/` n'appelle aucune API d'OS et ne contient aucun nom de variable d'environnement ni de chemin propres à un OS : le backend les fournit.
- Les tables de protocoles sont générées depuis des XML épinglés par hash. Aucune table de protocole n'est écrite à la main, comme pour les liaisons Win32.
- Aucun selftest, bench ni éval ne tourne sur la session réelle sans `--real-session`, réservé à Arthur.
- Aucune campagne `claude -p` sans Arthur, aucune clé `ANTHROPIC_API_KEY` (AGENTS.md).
- Chaque défaut de la couche des bibliothèques C sous Linux compte pour la condition 3 du Rust Switch Gate (D12) : libpipewire, libxkbcommon, durée de vie des descripteurs. Le compteur est dans `docs/decisions/0001-zig-vs-rust.md`.
- Le comportement Windows ne change pas : une story qui touche `src/core/`, `build.zig`, `build.zig.zon` ou `src/backend/windows/` passe aussi les gates Windows (Quality Gates).

## Technical Decisions

| # | Décision | Options considérées | Choix et preuve |
|---|---|---|---|
| T1 | Choix de la famille de compositeur | Un binaire par famille, choisi à la compilation ; un binaire qui choisit à l'exécution | À l'exécution. Un même utilisateur passe de GNOME à KDE, et la bonne unité est la capacité, pas le nom du bureau (audit 1.3 et 2.3). |
| T2 | Transports D-Bus, Wayland, EI | libdbus, sd-bus et libwayland par translate-c (mesurés utilisables) ; Zig natif | Zig natif généré (D12). La sonde `wire.zig` marche sur la session réelle, et un binaire sans C est portable (audit 8.4). |
| T3 | Dispositions clavier | Analyseur xkb natif ; libxkbcommon par `dlopen` | `dlopen`. Chaque compositeur Wayland dépend de libxkbcommon, et ses en-têtes passent translate-c (audit 8.3). Le clavier virtuel wlroots exige de compiler une keymap. Un analyseur natif reste possible plus tard. |
| T4 | Capture sous GNOME | Client PipeWire natif ; libpipewire par `dlopen` ; extension | Extension d'abord, si US-095 valide A25, puis ScreenCast par `dlopen` en repli (D10, D11). |
| T5 | Bancs de test | Lanceur intégré au serveur ; outil séparé | Outil séparé `tools/linux-session` : le binaire livré ne lance aucun compositeur, et le témoin vit hors du produit (audit 12). |
| T6 | Fixtures | Fenêtre GTK 4 en Zig (exige `gtk4-devel`, absent) ; Python et PyGObject (présents) | Python GTK 4, `python3 -I` : PyGObject et GTK 4 sont installés et les sondes s'en sont servies (audit 5.2). `gtk4-devel` est absent (mesuré). |
| T7 | Confiance entre serveur et extension | Aucune (computer-use-linux) ; pid ; chemin de l'exécutable | L'extension n'accepte qu'un appelant dont `/proc/<pid>/exe` est le binaire enregistré par `setup`. Le serveur vérifie que le nom appartient au propriétaire de `org.gnome.Shell` (audit 11 ; D2). |
| T8 | Canal KWin | Script chargé et déchargé à chaque requête (1,04 ms) ; script persistant en long-poll (0,17 ms) | Persistant (audit 4.2, mesuré). |
| T9 | Lancement d'applications | Lancement par le Shell ; `fork` puis `exec` depuis le serveur ; service systemd transitoire ; processus lanceur créé au démarrage | Processus lanceur, créé avant le filtre seccomp et avant tout fil, qui exécute par `posix_spawn` sans shell. Un enfant du serveur filtré hériterait du filtre et n'aurait pas de réseau (`seccomp(2)`). Un service systemd n'existe pas sur le bus privé des bancs. Quand le gestionnaire systemd de l'utilisateur répond, le processus passe ensuite dans un scope `app-neocompute-<id>-<n>.scope` par `StartTransientUnit` : son identifiant d'application devient lisible dans le cgroup comme sous GNOME (`app-gnome-paneflow-6352.scope`, audit 4.1), ce qu'exige D8. Les drapeaux de Chromium s'ajoutent (D13). |
| T10 | Harnais d'évals Linux | `run.ps1` sous pwsh ; Python ; Zig | Zig dans une session isolée : pwsh est absent (mesuré), le témoin C# de `run.ps1` ne se porte pas (audit 9.1), et les transports du serveur servent au témoin. |
| T11 | Baseline du bench | Clé `os` dans `bench/baseline.json` ; fichier par OS | `bench/baseline-linux.json` : `bench/baseline.json` reste intact, sans clé `os` (vérifié). |
| T12 | Format binaire | musl statique ; glibc 2.28 dynamique et `dlopen` ; lien direct par distribution | glibc 2.28 (P7) : musl statique interdit le `dlopen` (mesuré), le lien direct à 2.28 échoue (mesuré). Plancher identique à computer-use-linux (audit 10). |
| T13 | Relâche sous wlroots | Aucune (le compositeur garde la touche) ; gardien | Processus gardien créé au démarrage par `fork`, sans `exec`, avec sa propre connexion Wayland et un journal des touches tenues reçu du serveur (audit 4.3, A37). |
| T14 | Identifiants de fenêtre | Changer le contrat ; table de session dans le backend | Table du backend (D7) : le cœur et le contrat ne bougent pas. |
| T15 | Signaux | Gestionnaire qui relâche directement ; tube vers le répartiteur | Le gestionnaire écrit dans un tube que la boucle du répartiteur surveille, puis la relâche suit le chemin de l'EOF : un seul chemin de relâche. Preuve : un gestionnaire de signal ne peut appeler que des fonctions async-signal-safe (`signal-safety(7)`), alors que la relâche EI écrit sur des sockets et passe par l'état du serveur ; le chemin de l'EOF relâche déjà en moins de 50 ms (contrôle `release` du selftest Windows) ; Claude Code envoie SIGINT puis SIGTERM 100 ms plus tard (`client.ts:1426-1520`). |

## Quality Gates

These commands must pass for every user story, on the host OS where the story is developed:
- `zig fmt --check .` - formatage
- `zig build` - serveur du système hôte (Linux : backend Linux ; Windows : backend Windows, sondes et bindings générés)
- `zig build test` - tests du cœur sur le backend factice, budgets vérifiés à la compilation, générateurs, et sous Windows bindings et dispositions de structures
- `zig build cross` - le serveur de l'autre système compile (depuis Linux : Windows ; depuis Windows : Linux x86_64 et aarch64)
- `zig build bench -- --check bench/baseline-linux.json` - sous Linux (à partir de US-115, cette commande lance elle-même les scénarios de bureau dans une session `gnome` isolée) ; sous Windows, `zig build bench -- --check bench/baseline.json`

US-068, US-069 et US-073 créent la forme Linux de ces gates. Une story antérieure à leur livraison n'est tenue qu'aux gates déjà établis sur son hôte.

Additional gates:
- `zig build session -- gnome selftest` - stories qui touchent `src/backend/linux/`, `bindings/linux.zon`, `tools/protogen/` ou `tools/linux-session/`, sortie jointe au rapport
- `zig build session -- kde selftest` et `zig build session -- sway selftest` - à partir de US-079 pour les contrôles de transport, puis pour chaque story de EP-027 (`kde`) et de EP-028 (`sway`, plus `labwc` pour US-111 et US-122)
- `zig build session -- gnome selftest --background` - à partir de US-100, pour les stories qui touchent le mode arrière-plan ou un chemin qu'il partage
- `zig build evals -- --dry-run` - stories qui touchent `evals/linux/` ou `tools/evals-linux/`
- Stories qui touchent `src/core/`, `build.zig`, `build.zig.zon` ou `src/backend/windows/` : les gates Windows d'AGENTS.md sur la machine de référence démarrée sous Windows (`zig build run -- selftest`, et `selftest --background` quand un chemin du mode arrière-plan change), avant que `/review-epic` certifie la story

## Epics & User Stories

### EP-019: Fondations : build honnête, modules par OS, cœur neutre

Rendre le dépôt constructible et vérifiable sous Linux sans changer Windows : build sur copie fraîche, modules séparés, squelette du backend Linux, cœur sans hypothèse Windows (chantiers L1 à L3 de l'audit). Livraison 1.

**Definition of Done:** Sur une copie fraîche sous Linux, les cinq gates passent et le serveur Linux répond à `initialize` et `tools/list`. Sous Windows, les cinq gates et `selftest` rendent les mêmes contrôles `ok` qu'au commit `3091301`. L'amendement de la décision 0014 porte les réponses d'Arthur aux points P1 à P12.

#### US-067: Amendement de la décision 0014 pour les points de contrat du PRD
**Description:** En tant qu'Arthur, je veux les points de contrat que ce PRD ajoute consignés et confirmés afin qu'aucun code qui change la sécurité, la politique ou le contrat ne parte sans mon accord.

**Priority:** P0
**Size:** XS (1 pt)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] `docs/decisions/0014-portage-linux.md` reçoit une section « Amendement du PRD Linux » qui tranche P1 à P12 (Overview), chacun avec la réponse d'Arthur citée et datée.
- [ ] Les décisions D1 à D14 restent inchangées dans le fichier.
- [ ] Étant donné un point sans réponse d'Arthur, quand la story est exécutée, alors elle passe `BLOCKED`, le rapport liste les points en attente, et aucune story listée en face de ce point dans la table de l'Overview ne démarre.

#### US-068: Build honnête sur une copie fraîche
**Description:** En tant que développeur, je veux que `zig build` réussisse ou échoue franchement sur chaque système afin qu'un gate vert prouve quelque chose.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** None

**Acceptance Criteria:**
- [ ] Étant donné une copie fraîche du dépôt, Zig 0.17.0, et `ZIG_GLOBAL_CACHE_DIR` et `ZIG_LOCAL_CACHE_DIR` vers des dossiers vides, quand `zig build` tourne sous Linux, alors le fetch de libjpeg-turbo réussit sans « hash mismatch ».
- [ ] Le même `build.zig.zon` construit sous Windows sur une copie fraîche avec un cache vide.
- [ ] `build.zig` ne code plus le répertoire racine de l'archive libjpeg-turbo (`build.zig:201` aujourd'hui).
- [ ] `probe` et `probe_c` ne sont construits et installés que pour une cible Windows.
- [ ] `bindings_test`, `layout_test` et les tests de lecture PE de `tests/process_test.zig` ne sont ajoutés au step `test` que pour une cible Windows.
- [ ] Le test de `src/core/background_test.zig:638` passe sous Linux (110 ms mesurés) et sous Windows : sa borne basse vient de la granularité du minuteur de l'hôte au lieu du quantum Windows de 15,6 ms.
- [ ] Étant donné une cible sans backend (`-Dtarget=aarch64-macos`), quand `zig build` tourne, alors il échoue avec « Aucun backend pour macos : neo-compute se construit pour windows et linux, ou avec -Dfake-backend=true pour les tests. »
- [ ] `AGENTS.md` dit comment installer Zig 0.17.0 sous Linux. Il précise aussi que `ZIG_GLOBAL_CACHE_DIR` redirige le cache et que `zig build` 0.17 refuse `--global-cache-dir`.

#### US-069: Modules par OS et squelette du backend Linux
**Description:** En tant que développeur, je veux le backend Linux dans un module séparé, sélectionné sous Linux, afin de construire le portage sans toucher au code Windows.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-068, US-067 (P7)

**Acceptance Criteria:**
- [ ] `build.zig` déclare trois modules : `core` (`src/core/`), `backend_windows` (`src/backend/windows.zig` et `src/backend/windows/`) et `backend_linux` (`src/backend/linux.zig` et `src/backend/linux/`). `src/main.zig` choisit `backend_linux` pour `os.tag == .linux` sans `-Dfake-backend`.
- [ ] Un test du build échoue en nommant le fichier si un fichier de `src/core/` importe un fichier de `src/backend/`, ou si un fichier de `src/backend/linux/` importe un fichier de `src/backend/windows/`, ou l'inverse.
- [ ] `src/backend/linux.zig` implémente les 58 méthodes appelées sans condition par le cœur. Chaque méthode pas encore implémentée rend une erreur que l'outil traduit en « Linux : <outil> n'est pas encore disponible dans ce build. Aucune action exécutée. »
- [ ] Sous Linux, le serveur répond à `initialize` et à `tools/list`, et la liste contient les 17 outils de la fixture.
- [ ] `zig build cross` lancé sous Linux construit `neo-compute.exe`, `probe.exe` et `probe_c.exe` pour `x86_64-windows-gnu`. Lancé sous Windows, il construit le serveur Linux pour `x86_64-linux-gnu.2.28` et `aarch64-linux-gnu.2.28`.
- [ ] Étant donné un appel `screenshot` au serveur Linux de cette story, quand il est traité, alors la réponse est `isError: true` avec le message ci-dessus, et le processus répond à l'appel suivant.
- [ ] Sous Windows, `zig build run -- selftest` rend les mêmes contrôles `ok` qu'avant la story.

#### US-070: Politique et audit aux emplacements XDG, identité d'application
**Description:** En tant qu'Arthur, je veux que la politique et l'audit se chargent sous Linux et reconnaissent les applications Linux afin que les règles `deny` protègent vraiment mes gestionnaires de mots de passe et mes terminaux.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-069, US-067 (P8)

**Acceptance Criteria:**
- [ ] Sous Linux, la politique se lit dans `$XDG_CONFIG_HOME/neo-compute/policy.json`, ou dans `~/.config/neo-compute/policy.json` quand la variable est absente ou vide.
- [ ] Sous Linux, l'audit s'écrit dans `$XDG_STATE_HOME/neo-compute/audit.jsonl`, ou par défaut dans `~/.local/state/neo-compute/audit.jsonl`. Le dossier est créé en mode 0700.
- [ ] Le cœur reçoit ces chemins du backend. Un test échoue si `src/core/` contient `APPDATA`, `LOCALAPPDATA`, `XDG_` ou `HOME`.
- [ ] Le backend Linux rend l'identité d'une application à partir de trois sources :
  - l'identifiant d'application lu dans le cgroup du processus, sous la forme `app-<lanceur>-<id>-<n>.scope` ou `app-flatpak-<id>-<n>.scope` ;
  - l'identifiant Flatpak lu dans `/proc/<pid>/root/.flatpak-info` ;
  - le nom de base de `/proc/<pid>/exe`.
  Il ne lit jamais `/proc/<pid>/comm`.
- [ ] Une entrée de politique Linux correspond à une application par son identifiant d'application ou par le nom de son exécutable, sans tenir compte de la casse.
- [ ] La liste Linux de niveau `deny` par défaut contient, par identifiant d'application et par nom d'exécutable, les gestionnaires de mots de passe KeePassXC, Bitwarden, 1Password et Proton Pass (P8).
- [ ] La liste Linux de niveau `click` par défaut contient de même les terminaux GNOME Terminal, Ptyxis, Konsole, kitty, Alacritty, foot, WezTerm, Ghostty, xterm et Paneflow (P8).
- [ ] La liste `click` contient aussi les éditeurs de code VS Code (`code`), Cursor, Windsurf et Zed (`zed`, `zeditor`, `dev.zed.Zed`), comme la liste `shells` de Windows (P8).
- [ ] Étant donné KeePassXC lancé depuis un terminal (cgroup `vte-spawn-*.scope`, sans identifiant d'application), quand une action vise sa fenêtre, alors la règle `deny` s'applique par le nom d'exécutable `keepassxc`.
- [ ] Étant donné un `policy.json` invalide sous Linux, alors le serveur se comporte comme sous Windows pour un fichier invalide, et l'audit l'enregistre.
- [ ] Les listes et les chemins Windows ne changent pas : un test du cœur compare les listes Windows à celles d'avant la story.

#### US-071: Contrat par OS : textes, outils optionnels, identifiants de fenêtre
**Description:** En tant que Claude Code, je veux des descriptions et des instructions qui décrivent le système où je travaille, avec les mêmes noms et paramètres d'outils, afin de ne pas suivre des consignes Windows sous Linux.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-069

**Acceptance Criteria:**
- [ ] Les descriptions des outils ajoutés au toolset et les trois textes d'`instructions` (modes `a11y`, `vision`, `background`) viennent de constantes du backend. Sous Windows, `tools/list` et `initialize` rendent des octets identiques à ceux d'avant la story (test de comparaison).
- [ ] Sous Linux, aucun texte de `tools/list` ni d'`instructions` ne contient « Windows », « Start menu », « AUMID », « HKCU » ou « registry ».
- [ ] `registry_read` n'est enregistré que si le backend déclare `registryValue` (`@hasDecl`). Le backend Linux ne le déclare pas, et `tools/list` sous Linux ne contient pas `registry_read`.
- [ ] Étant donné un appel `registry_read` au serveur Linux, alors la réponse est l'erreur d'outil inconnu existante (-32602).
- [ ] Les budgets de définitions (`alwaysLoad` ≤ 1 500 tokens estimés, total ≤ 4 500, chaque `instructions` ≤ 1 500 caractères) sont vérifiés à la compilation pour les textes Linux comme pour les textes Windows.
- [ ] Le backend Linux rend des handles `u64` affichés en hexadécimal, associés à l'identifiant du compositeur dans une table de session. Un handle n'est jamais réattribué pendant la vie du processus : un test de la table le vérifie sur 10 000 fenêtres simulées.
- [ ] Étant donné un handle inconnu ou celui d'une fenêtre fermée, alors l'outil répond avec le message existant de fenêtre introuvable.

#### US-072: Arrêt par signal et instance unique sous Linux
**Description:** En tant qu'Arthur, je veux que le serveur relâche toute touche tenue quand Claude Code l'arrête par signal afin qu'aucune touche ne reste enfoncée sur mon bureau.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-069

**Acceptance Criteria:**
- [ ] Sous Linux, SIGINT, SIGTERM et SIGHUP écrivent dans un tube que la boucle du répartiteur surveille. Le serveur suit alors le chemin de l'EOF : `releaseAllInputs`, ligne d'audit en cours, sortie avec le code 0.
- [ ] Un test de `tests/process_test.zig` lance sous Linux le serveur avec le backend factice, tient une touche par `hold_key` puis envoie SIGINT. Il lit sur stderr la relâche moins de 50 ms après le signal. Le même test passe avec SIGTERM et SIGHUP.
- [ ] Sous Linux, l'instance unique (FR-14) est un verrou `flock` exclusif sur `$XDG_RUNTIME_DIR/neo-compute/<affichage>.lock`. L'affichage est `WAYLAND_DISPLAY`, sinon `DISPLAY`.
- [ ] Étant donné un second serveur sur le même affichage, quand il reçoit une action, alors il répond avec le message existant d'instance (FR-14). Un serveur sur un autre affichage n'est pas bloqué.
- [ ] Étant donné un serveur tué par SIGKILL, alors un nouveau serveur prend le verrou au démarrage suivant (test).
- [ ] Étant donné `XDG_RUNTIME_DIR` absent, alors les outils d'action répondent « XDG_RUNTIME_DIR absent : impossible de garantir une seule instance. Lance neo-compute depuis une session graphique. » et aucun n'agit.

#### US-073: Bench par système d'exploitation
**Description:** En tant que développeur, je veux une baseline par OS et un gate qui échoue sur un scénario non pris en charge afin que le bench ne passe plus à vide.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-068

**Acceptance Criteria:**
- [ ] `bench/baseline-linux.json` existe, avec `"os": "linux"` et les scénarios `transport` et `diff` mesurés sous Linux par passes complètes (règle d'AGENTS.md).
- [ ] Une baseline sans clé `os` est une baseline Windows, et `bench/baseline.json` n'est pas modifié.
- [ ] Étant donné une baseline d'un autre OS que l'hôte, quand `zig build bench -- --check <fichier>` tourne, alors il échoue avec « Baseline <os> sur un hôte <os> : utilise bench/baseline-linux.json sous Linux, bench/baseline.json sous Windows. »
- [ ] Étant donné un scénario présent dans la baseline qui rend `unsupported`, alors le gate échoue en nommant le scénario.
- [ ] `zig build bench` ne dépend plus de l'installation de `probe` et `probe_c` sous Linux.
- [ ] Sous Windows, `zig build bench -- --check bench/baseline.json` rend le même verdict qu'avant la story.

---

### EP-020: Bancs de test Linux isolés

Donner aux selftests, au bench et aux évals des sessions graphiques sans écran, isolées de la session réelle, avec un témoin qui le prouve, et des fixtures qui rapportent ce qu'elles reçoivent. Livraison 1.

**Definition of Done:** Pour `gnome`, `kde`, `sway` et `labwc`, 20 cycles de `zig build session -- <famille> exec -- true` sortent avec le code 0, et le témoin ne rapporte aucune différence. Dans la session `gnome`, la fixture GTK 4 et la page Chrome écrivent leurs événements.

#### US-074: Lanceur de session isolée et témoin de la session réelle (GNOME)
**Description:** En tant que développeur, je veux lancer une commande dans un GNOME sans écran qui ne touche rien de ma session afin de tester l'entrée réelle et la capture sans risque.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-068

**Acceptance Criteria:**
- [ ] `zig build session -- gnome <arguments de neo-compute>` lance `neo-compute <arguments>` dans une session GNOME sans écran : `gnome-shell --headless --wayland --no-x11 --virtual-monitor 1920x1080`. `zig build session -- gnome exec -- <commande>` y lance une commande quelconque. Les deux arrêtent ensuite la session et rendent le code de sortie de la commande.
- [ ] `tools/linux-session` offre aussi `start <famille>`, qui affiche un identifiant et garde la session, puis `exec <id> -- <commande>` et `stop <id>`.
- [ ] La session part de `env -i`. `HOME`, `XDG_RUNTIME_DIR`, `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` et `XDG_CACHE_HOME` sont privés et posés avant le démarrage de son bus. `XDG_RUNTIME_DIR` est `/run/user/<uid>/nc-<6 caractères>`.
- [ ] Le bus de session de la session est privé et n'active que dconf, le magasin de permissions, les portails, PipeWire et WirePlumber.
- [ ] `DBUS_SYSTEM_BUS_ADDRESS` désigne un bus système factice qui ne porte qu'un faux service GDM.
- [ ] Le dconf de la session est privé, avec le verrouillage et la mise en veille coupés.
- [ ] Les processus de la session portent `XDG_SESSION_ID=nc-none`, `GIO_USE_VFS=local`, `GVFS_DISABLE_FUSE=1` et `NC_SESSION=gnome`.
- [ ] Le bus AT-SPI de la session est lancé par `at-spi-bus-launcher --launch-immediately`, puis `at-spi2-registryd`.
- [ ] Le lanceur se déclare sous-récupérateur (`PR_SET_CHILD_SUBREAPER`). À l'arrêt, il tue tous ses descendants et supprime son `XDG_RUNTIME_DIR`.
- [ ] Avant et après chaque session, le témoin compare `LockedHint` et `State` des sessions logind de l'utilisateur, et ses inhibiteurs logind.
- [ ] Avant et après chaque session, le témoin compare les entrées et les montages de `/run/user/<uid>`.
- [ ] Avant et après chaque session, le témoin compare les fichiers `/tmp/dbus-*`, `/tmp/.X*-lock` et `/tmp/.X11-unix/X*`.
- [ ] Après la session, le témoin vérifie qu'aucun processus ne porte `NC_SESSION` dans son environnement.
- [ ] Pendant la session, le témoin vérifie chaque seconde qu'aucun processus descendant n'a le `HOME` ou le `XDG_RUNTIME_DIR` réels dans `/proc/<pid>/environ`.
- [ ] Étant donné une différence relevée par le témoin, alors le lanceur sort avec le code 3 et la liste des différences. Un test du lanceur le prouve en créant `/tmp/dbus-nc-witness-test` pendant une session, puis en le supprimant.
- [ ] Étant donné 20 cycles `zig build session -- gnome exec -- true`, alors chacun sort avec le code 0 sans différence relevée.
- [ ] Étant donné un gnome-shell qui ne démarre pas en 30 s (A35), alors le lanceur sort avec le code 2 et le chemin du journal du compositeur, le témoin ne relève aucune différence, et le `XDG_RUNTIME_DIR` privé est supprimé.
- [ ] Étant donné un chemin de socket de session de plus de 107 octets, alors le lanceur refuse avant tout démarrage avec un message qui nomme le chemin.
- [ ] `AGENTS.md` documente les commandes du lanceur et la règle « jamais de selftest sur la session réelle sans `--real-session` ».

#### US-075: KDE, sway et labwc dans le lanceur
**Description:** En tant que développeur, je veux les mêmes sessions isolées pour KWin et wlroots afin de tester ces familles sans toucher ma session.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-074

**Acceptance Criteria:**
- [ ] `zig build session -- kde …` lance `kwin_wayland --virtual --socket <nom> --width 1280 --height 800` avec `QT_QPA_PLATFORM=offscreen` et un `kscreenlockerrc` privé (`Autolock=false`, `LockOnResume=false`).
- [ ] `zig build session -- sway …` lance sway avec `WLR_BACKENDS=headless`, `WLR_RENDERER=pixman`, `WLR_LIBINPUT_NO_DEVICES=1` et une configuration privée. `zig build session -- labwc …` lance labwc avec les mêmes variables.
- [ ] Les 20 cycles et le témoin de US-074 passent pour `kde`, `sway` et `labwc`.
- [ ] Pour `sway` et `labwc`, le bus système factice porte aussi un faux `org.freedesktop.login1` dont le selftest change `LockedHint` (pour US-112).
- [ ] Étant donné une session KDE gardée 6 min sans entrée, soit au-delà du verrouillage automatique mesuré à 5 min (audit 4.2), alors aucun `kscreenlocker_greet` ne démarre et `LockedHint` de l'utilisateur ne change pas.
- [ ] Étant donné un compositeur absent du système, alors le lanceur sort avec le code 77 et « <compositeur> introuvable : installe-le ou saute cette famille. »

#### US-076: Fixtures Linux
**Description:** En tant que développeur, je veux une fenêtre GTK 4 et une page Chrome qui rapportent chaque événement reçu afin que les selftests prouvent l'effet réel d'une action.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-074

**Acceptance Criteria:**
- [ ] `tests/linux/fixture/gtk_fixture.py`, lancé par `python3 -I`, ouvre « Fixture neo-compute ». Elle contient un bouton, une case à cocher, un champ de texte, un champ mot de passe, un curseur 0..100, une liste de 30 entrées, une liste déroulante, une zone de texte multiligne, deux zones de glisser-déposer, une zone de survol et un canevas.
- [ ] La fixture écrit chaque événement reçu en une ligne JSON horodatée dans le fichier que nomme `NC_FIXTURE_LOG` : clic et nombre de clics, entrée et sortie de survol, glisser-déposer terminé, touche avec keysym et modificateurs, texte inséré, défilement, position du pointeur sur le canevas, changement de valeur, état actif de la fenêtre.
- [ ] Au démarrage, la fixture écrit le rectangle de chaque contrôle en coordonnées de sa surface.
- [ ] `tests/linux/pages/fixture.html` reproduit ces contrôles dans Chrome et expose ses compteurs dans une région ARIA live lisible par AT-SPI.
- [ ] `gtk_fixture.py --role decoy` ouvre une fenêtre leurre, plein écran avec `--fullscreen`, qui écrit chaque touche reçue dans `NC_FIXTURE_LOG`. Ses touches lui viennent d'une seconde session d'entrée du banc, distincte de celle du serveur (US-100).
- [ ] `gtk_fixture.py --app-id <id>` donne à la fixture l'identifiant d'application `<id>` (contrôles de politique de US-070 et de dialogue système de US-112).
- [ ] Étant donné PyGObject ou GTK 4 absents, alors la fixture sort avec le code 77 et « PyGObject et GTK 4 requis : installe python3-gobject et gtk4. ». Un contrôle de selftest qui en dépend est alors noté `skipped` avec cette raison.

---

### EP-021: Transports natifs générés

Parler D-Bus, Wayland et EI en Zig natif depuis des descriptions XML épinglées et générées, comme les liaisons Win32 (D12, chantier L4). Livraison 1.

**Definition of Done:** Les tests d'octets D-Bus, Wayland et EI passent dans `zig build test`. Dans la session `gnome`, les contrôles `dbus`, `wayland` et `ei` du selftest sont `ok`. Le binaire Linux ne déclare dans ses dépendances `NEEDED` que des bibliothèques de la glibc.

#### US-077: Générateur protogen et descriptions épinglées
**Description:** En tant que développeur, je veux que chaque table de protocole soit générée depuis un XML épinglé afin qu'aucune erreur de transcription manuelle n'entre dans les transports, comme la vtable décalée de US-001.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-069

**Acceptance Criteria:**
- [ ] `tools/protogen` lit le XML de protocole Wayland, le XML de protocole EI et le XML d'introspection D-Bus, sans dépendance C. Il émet du Zig : opcodes, signatures, énumérations et versions minimales pour Wayland et EI, membres et signatures de types pour D-Bus.
- [ ] `bindings/linux.zon` liste les interfaces et membres utilisés, et seule la fermeture de cette liste est émise.
- [ ] `RemoteDesktop.SetKeymap` (plante Mutter 51.1), `org.gnome.ScreenSaver.SetActive` (déverrouille sans mot de passe) et `org_kde_kwin_fake_input` (garde une touche tenue à la mort du client) figurent dans une liste de refus (audit 4.1 et 4.2). Le générateur échoue si `bindings/linux.zon` en demande un (FR-61).
- [ ] Les sources sont épinglées par hash dans `build.zig.zon` :
  - wayland (`wayland.xml`), wayland-protocols, wlr-protocols, plasma-wayland-protocols ;
  - libei 1.6 (`proto/protocol.xml`) ;
  - Mutter 51.1 et gnome-shell 51.1 (`data/dbus-interfaces/`) ;
  - xdg-desktop-portal ;
  - at-spi2-core 2.62 (`xml/`) ;
  - les XML D-Bus de KWin 6.8.
- [ ] Étant donné un nom absent des sources dans `bindings/linux.zon`, alors le générateur échoue en nommant le nom le plus proche, comme `tools/winmdgen`.
- [ ] Étant donné une archive dont le hash ne correspond pas, alors le build échoue avant toute génération.
- [ ] Deux générations successives produisent des fichiers identiques octet pour octet.
- [ ] `zig build test` contient des tests du générateur : XML minimal accepté, entité ou DTD refusées, signature D-Bus invalide refusée.

#### US-078: Fil D-Bus natif
**Description:** En tant que backend Linux, je veux un client D-Bus sans bibliothèque C, avec un délai par appel, afin de parler à Mutter, KWin, AT-SPI et logind sans bloquer sur un pair figé.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-077, US-074

**Acceptance Criteria:**
- [ ] Le fil se connecte à une adresse `unix:path=` ou `unix:abstract=`, s'authentifie par SASL EXTERNAL, appelle `Hello` et rend son nom unique.
- [ ] Il sérialise et désérialise tous les types qu'utilise `bindings/linux.zon`, y compris variants, dictionnaires, tableaux de structures et descripteurs de fichiers passés par `SCM_RIGHTS`.
- [ ] Il reçoit les signaux selon des règles de correspondance, peut posséder un nom (`RequestName`) et lit le pid d'un appelant (`GetConnectionUnixProcessID`).
- [ ] Étant donné un pair arrêté par SIGSTOP, quand un appel lui est fait avec un délai de 200 ms, alors l'appel échoue entre 200 et 220 ms : 10 % de tolérance fixée par ce PRD, Gio mesuré à 200,3 ms (audit 5.2).
- [ ] Des tests d'octets comparent chaque message émis aux captures `dbus-monitor --binary` rangées dans `tests/linux/golden/dbus/`.
- [ ] Étant donné un message mal formé reçu d'un pair, alors la connexion se ferme avec une erreur typée, et le serveur ne plante pas (test sur 20 messages corrompus).
- [ ] Dans `zig build session -- gnome selftest`, le contrôle `dbus` crée puis arrête une session `org.gnome.Mutter.RemoteDesktop` et rapporte la latence p50/p95 de l'appel (référence 0,16/0,23 ms, audit 4.1).

#### US-079: Fil Wayland natif
**Description:** En tant que backend Linux, je veux un client Wayland sans bibliothèque C afin de lier les protocoles de KWin et de wlroots et de dessiner le libellé.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-077, US-074, US-075

**Acceptance Criteria:**
- [ ] Le fil se connecte à `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` et lit le registre. Il lie un global à la plus petite des versions annoncée et générée. Il échange des messages avec descripteurs et gère `delete_id` et `wl_display.sync`.
- [ ] Il fournit des tampons `wl_shm` sur `memfd_create` pour les surfaces que le serveur dessine.
- [ ] Un événement `wl_display.error` devient une erreur typée qui nomme l'objet, le code et le message.
- [ ] Des tests d'octets comparent les requêtes émises aux traces `WAYLAND_DEBUG=client` rangées dans `tests/linux/golden/wayland/`.
- [ ] Dans les sessions `gnome`, `kde` et `sway`, le contrôle `wayland` liste les globals, et leurs noms et versions correspondent au tableau 1.2 de l'audit pour les protocoles qui y figurent.
- [ ] Étant donné le socket fermé par le compositeur, alors chaque requête en attente échoue, et l'outil répond « Compositeur Wayland déconnecté : relance la session graphique. » sans planter.

#### US-080: Fil EI natif et dispositions xkb
**Description:** En tant que backend Linux, je veux parler EI et lire la disposition clavier du compositeur afin d'injecter pointeur et clavier par le même canal sous Mutter, KWin et le portail.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-074, US-076, US-078, US-067 (P7)

**Acceptance Criteria:**
- [ ] Le fil EI ouvre un contexte client sur le descripteur que rend `ConnectToEIS`, que ce soit par Mutter (`RemoteDesktop.Session`), KWin (`org.kde.KWin.EIS.RemoteDesktop`) ou le portail RemoteDesktop. Il négocie les interfaces et liste sièges, périphériques et capacités, sans bibliothèque C.
- [ ] Il envoie, par trames, des mouvements absolus dans une région, des mouvements relatifs, des boutons, du défilement continu et par crans, et des touches.
- [ ] Il lit la keymap XKB du clavier EI. `src/backend/linux/wire/xkb.zig` charge `libxkbcommon.so.0` par `dlopen` et rend, pour un keysym, le keycode et les modificateurs qui le produisent dans la disposition active.
- [ ] Dans `zig build session -- gnome selftest`, le contrôle `ei` déplace le pointeur absolu en 20 points du canevas de la fixture. Chaque point reçu est exact au pixel logique près, à l'échelle 1.
- [ ] Étant donné un périphérique EI suspendu par le compositeur, alors l'action répond « Entrée suspendue par le compositeur : réessaie dans un instant. » et n'envoie rien.
- [ ] Étant donné une copie du descripteur EIS restée ouverte ailleurs (piège mesuré, audit 4.1), alors le serveur ferme toutes les copies qu'il détient avant `Stop` (test sur le banc : la relâche arrive en moins de 50 ms).
- [ ] Étant donné `libxkbcommon.so.0` absent, alors la capacité clavier est absente de la table de capacités, et `type` et `key` répondent « libxkbcommon introuvable : installe-la pour taper du texte. »

---

### EP-022: Détection et GNOME Shell : extension, fenêtres, écrans

Identifier la famille de compositeur, installer l'extension GNOME par une commande explicite, et donner au serveur les fenêtres, l'empilement, le pointeur et les écrans de GNOME (chantiers L5 et L7). Livraison 1.

**Definition of Done:** Dans la session `gnome`, avec l'extension installée par `neo-compute setup` dans le `HOME` privé :
- la table de capacités GNOME montre l'extension et sa version, la liste et l'empilement des fenêtres, leur gestion et la position du pointeur ;
- les contrôles `windows-list`, `windows-manage`, `windows-focus` et `displays` sont `ok`, dans les budgets `window_list` (5 ms) et `window_set` (20 ms) ;
- la sonde A24 est conclue dans la décision 0014.

#### US-081: Détection de la famille et table de capacités
**Description:** En tant que Claude Code, je veux savoir ce que la session permet et pourquoi un outil manque afin de choisir une autre voie au lieu d'échouer sans explication.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-074, US-078, US-079, US-067 (P5, P6)

**Acceptance Criteria:**
- [ ] Au démarrage, le backend classe la session :
  - `gnome` si `org.gnome.Mutter.RemoteDesktop` existe sur le bus de session ;
  - `kde` si `org.kde.KWin` existe ;
  - `wlroots` si `SWAYSOCK` est posé, ou si `zwlr_virtual_pointer_manager_v1` ou `ext_image_copy_capture_manager_v1` est annoncé ;
  - `inconnue` sinon.
- [ ] Il compose une table de capacités et l'écrit sur stderr au démarrage : pointeur, clavier, texte hors disposition, capture d'écran, capture de fenêtre, liste et empilement des fenêtres, gestion des fenêtres, presse-papiers, position du pointeur, entrée physique, extension ou script et sa version.
- [ ] `neo-compute selftest` imprime la table en première ligne de sa sortie.
- [ ] Étant donné un outil qui exige une capacité absente, alors il répond sans agir « Linux (<famille>) : <capacité> indisponible, <raison>. <action suivante>. ». Exemple : « Linux (gnome) : liste des fenêtres indisponible, extension GNOME absente. Lance neo-compute setup puis reconnecte-toi. »
- [ ] Étant donné une session sans `WAYLAND_DISPLAY` mais avec `DISPLAY`, alors les outils d'action et de capture répondent « Session X11 : non prise en charge dans cette version. Ouvre une session Wayland (GNOME, KDE ou sway). »
- [ ] Étant donné une version de GNOME, Plasma, sway ou labwc hors de celles de P6, alors la table l'indique, et le serveur fonctionne avec les capacités qu'il détecte.
- [ ] Étant donné `neo-compute selftest` lancé sans `NC_SESSION` et sans `--real-session`, alors il sort avec le code 2 et « selftest injecte des entrées : lance-le par zig build session, ou ajoute --real-session sur ta propre session. »

#### US-082: Extension GNOME Shell embarquée et `neo-compute setup`
**Description:** En tant qu'Arthur, je veux installer l'extension par une commande explicite, réversible, et que personne d'autre que le serveur ne puisse l'appeler, afin de donner au serveur ce que GNOME réserve au Shell sans ouvrir une porte à d'autres processus.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-081, US-067 (P4, P6)

**Acceptance Criteria:**
- [ ] L'extension (ESM, `shell-version` `["50", "51"]`, UUID `neo-compute@local`) est embarquée dans le binaire par `@embedFile` depuis `src/backend/linux/gnome/extension/`. Elle publie `org.neocompute.Shell1` sur le bus de session.
- [ ] `neo-compute setup` écrit l'extension dans `$XDG_DATA_HOME/gnome-shell/extensions/neo-compute@local/`, avec le chemin canonique du binaire dans le fichier `trusted-exe` de ce dossier.
- [ ] `setup` ajoute l'UUID à `org.gnome.shell enabled-extensions` par `ca.desrt.dconf.Writer`, sans aucune commande externe.
- [ ] Étant donné un Shell en cours qui n'a pas chargé l'extension à la version du binaire (`org.gnome.Shell.Extensions.GetExtensionInfo`), alors `setup` imprime « Reconnecte-toi pour charger l'extension : GNOME sous Wayland ne recharge pas le Shell. »
- [ ] `neo-compute setup --uninstall` retire l'UUID de `enabled-extensions` et supprime le dossier. Deux exécutions successives de `setup` ou de `--uninstall` laissent le même état.
- [ ] `setup` ne modifie jamais `disable-user-extensions`. Quand ce réglage vaut `true`, il le signale avec « Les extensions utilisateur sont désactivées dans GNOME : active-les dans Extensions, puis relance neo-compute setup. ». `setup` signale aussi l'écriture de `toolkit-accessibility` par at-spi2-core (D13).
- [ ] L'extension n'accepte que les appels d'un processus dont `/proc/<pid>/exe` est le chemin de `trusted-exe`, pid lu par `GetConnectionUnixProcessID`. Tout autre appelant reçoit `org.freedesktop.DBus.Error.AccessDenied`.
- [ ] Le serveur n'utilise `org.neocompute.Shell1` que si son propriétaire est aussi le propriétaire de `org.gnome.Shell`.
- [ ] L'extension expose sa version. Étant donné une version différente de celle du serveur, alors les outils qui en dépendent répondent « Extension GNOME de version <x>, serveur <y> : relance neo-compute setup puis reconnecte-toi. »
- [ ] L'extension n'a aucune méthode qui évalue du code (pas d'`Eval`).
- [ ] Dans la session `gnome`, `setup` puis le redémarrage du Shell privé chargent l'extension, et la table de capacités la montre.

#### US-083: Sonde A24 : distinguer l'entrée physique de l'entrée injectée
**Description:** En tant qu'Arthur, je veux vérifier sur ma vraie session que l'extension reconnaît mes gestes physiques parmi les entrées injectées afin que le kill switch de GNOME repose sur une mesure.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-082, US-080, US-076, US-067 (P12)

**Acceptance Criteria:**
- [ ] L'extension classe chaque événement de pointeur et de clavier par son périphérique d'origine : un nœud de périphérique non nul signifie une entrée physique. Le classement est exposé au serveur par un signal.
- [ ] `neo-compute input-probe --real-session`, lancé par Arthur, injecte pendant 60 s, sur une fenêtre de fixture, 200 mouvements et 100 touches par EI. Arthur fait pendant ce temps au moins 50 gestes physiques (mouvements et touches). La sonde écrit le nombre d'événements classés dans chaque catégorie.
- [ ] Le verdict de A24 est consigné dans `docs/decisions/0014-portage-linux.md` avec les comptes : il est validé si 100 % des événements injectés sont classés injectés et 100 % des gestes physiques classés physiques.
- [ ] Dans un banc (P12 : `NC_SESSION` posé et `XDG_RUNTIME_DIR` sous `/run/user/<uid>/nc-`), l'extension accepte une méthode `SimulatePhysical` qui produit un événement classé physique, pour que les selftests du kill switch tournent sur le banc.
- [ ] Étant donné un appel à `SimulatePhysical` hors d'un banc, alors l'extension répond `org.freedesktop.DBus.Error.AccessDenied` et ne produit aucun événement (test).
- [ ] Étant donné A24 infirmée, alors la story s'arrête et rend compte à Arthur. Le rapport propose la détection par soustraction de D4, et US-094 passe `BLOCKED`.

#### US-084: Fenêtres GNOME : liste, empilement, gestion, pointeur
**Description:** En tant que Claude Code, je veux lister, viser, activer et ranger les fenêtres de GNOME et connaître la position du pointeur afin d'utiliser `window_list`, `window_focus`, `window_set` et `cursor_position` comme sous Windows.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-082

**Acceptance Criteria:**
- [ ] L'extension rend pour chaque fenêtre : id Mutter, titre, `wm_class`, identifiant d'application, pid, cadre et tampon, écran, rang d'empilement (`sort_windows_by_stacking`), minimisée, active, espace de travail, maximisée, `transient_for`, `a11y-dbus-name` et `a11y-object-path`.
- [ ] Le backend implémente `listWindows`, `visibleWindows`, `windowRect`, `windowLayers`, `windowAt`, `windowRef`, `topWindowStamp`, `foregroundWindow`, `appPid`, `processName`, `cursorPosition`, `focusWindow`, `placeWindow`, `showWindow`, `closeWindow` et `windowPlacement` par l'extension.
- [ ] Le contrôle `windows-list` vérifie que `window_list` rend la fixture et le leurre de la session `gnome` en moins de 5 ms au p95 sur 20 appels (budget `window_list` ; 0,32 ms mesurés côté extension, audit 4.1).
- [ ] Le contrôle `windows-manage` vérifie que `window_set` (déplacement, taille, minimisation, restauration, maximisation) ne change pas la fenêtre active, 20 fois sur 20, et répond en moins de 20 ms au p95 (budget `window_set`).
- [ ] Le contrôle `windows-focus` vérifie que `window_focus` rend la fenêtre active au retour de l'appel, 20 fois sur 20, sans jeton d'activation.
- [ ] `cursor_position` rend la position logique de `global.get_pointer()` convertie dans l'espace des captures, sans prendre le nom d'Orca (D5). Un test du backend vérifie la conversion à l'échelle 1, 1,5 et 2 ; le contrôle `cursor` de US-090 la vérifie après des mouvements réels.
- [ ] Étant donné une fenêtre fermée entre `window_list` et une action, alors l'outil répond avec le message existant de fenêtre introuvable.
- [ ] Étant donné `close` sur une fenêtre d'un processus protégé (gnome-shell, Xwayland, gdm, un agent polkit, un portail, ou le serveur lui-même), alors l'outil refuse avec le message existant de processus protégé.
- [ ] Étant donné une fenêtre sur un autre espace de travail, alors `window_list` la marque `{other_desktop}`, comme sous Windows.

#### US-085: Écrans et échelles
**Description:** En tant que Claude Code, je veux les écrans, leurs échelles et la correspondance entre pixels de capture et coordonnées logiques afin que mes clics tombent où je vise à toute échelle.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-081

**Acceptance Criteria:**
- [ ] `displays`, `displayInfo` et `foregroundDisplay` viennent de `org.gnome.Mutter.DisplayConfig.GetCurrentState` : connecteur, mode, position logique, échelle, principal.
- [ ] Le modèle de `src/core/display.zig` reçoit des pixels physiques ; un pixel physique vaut une coordonnée logique multipliée par l'échelle de l'écran (mesuré à 1,5 et 2, audit 4.1).
- [ ] Dans la session `gnome`, le contrôle `displays` passe l'écran virtuel 1920x1080 à l'échelle 2 puis 1,5 par `ApplyMonitorsConfig` en méthode temporaire. `displays` rend alors cette échelle et une taille logique de 960x540, puis de 1280x720. Le contrôle remet ensuite l'échelle 1.
- [ ] Le verdict de A30 pour l'échelle temporaire sur gnome-shell sans écran est consigné dans 0014.
- [ ] Étant donné une configuration d'écrans qui change pendant la session (signal `MonitorsChanged`), alors l'appel suivant utilise la nouvelle configuration.
- [ ] Étant donné `DisplayConfig` qui ne répond pas en 200 ms, alors l'outil répond « Écrans illisibles : Mutter ne répond pas. Réessaie. » sans agir.

---

### EP-023: Accessibilité AT-SPI

Lire les arbres, agir sans entrée, suivre les changements et masquer les mots de passe par AT-SPI, avec les budgets et les verdicts du cœur (chantier L6). Livraison 1.

**Definition of Done:** Dans la session `gnome`, les contrôles `ui`, `ui-act`, `ui-find`, `ui-find-wait`, `password-mask` et `ui-coords` sont `ok` sur la fixture GTK 4 et la page Chrome, et les verdicts de A32 et A33 sont consignés dans 0014. `ui_tree` tient les budgets `ui_tree` (50 ms p95) sur la fixture et `chrome` (120 ms p95) sur la page.

#### US-086: Lecture de l'arbre AT-SPI
**Description:** En tant que Claude Code, je veux `ui_tree` et `ui_find` sur les applications GTK, Qt et Chromium afin de lire l'interface au lieu de deviner sur une capture.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-084, US-076

**Acceptance Criteria:**
- [ ] Le backend lit l'adresse du bus d'accessibilité par `org.a11y.Bus.GetAddress` et la liste des applications du registre.
- [ ] Une fenêtre se relie à sa racine AT-SPI par `a11y-dbus-name` et `a11y-object-path` quand l'extension les rend. Sinon, elle s'y relie par le pid et le titre du cadre. Le verdict de A33 est consigné dans 0014.
- [ ] Étant donné deux cadres candidats pour une fenêtre, alors `ui_tree` répond « Deux arbres possibles pour <titre> (pid <n>) : <a>, <b>. Passe window avec le handle exact. » sans lire.
- [ ] Un instantané lit par `Cache.GetItems` quand la réponse n'est pas vide, sinon niveau par niveau avec tous les appels d'un niveau en vol. Les rectangles et les valeurs se lisent en vol après. Chaque appel porte un délai de 200 ms.
- [ ] Les rôles AT-SPI se traduisent par une table de `src/backend/linux/atspi/roles.zig` vers les rôles du cœur. Un rôle inconnu garde son nom AT-SPI.
- [ ] Le contrôle `ui-find` trouve par `ui_find` chaque contrôle de la fixture GTK 4 et de la page Chrome, par son nom et par son rôle.
- [ ] La clé d'un élément est le nom de bus unique plus le chemin d'objet, revalidée à chaque usage par le pid du propriétaire.
- [ ] Le contrôle `ui` vérifie que `ui_tree` de la fixture GTK 4 tient moins de 50 ms au p95 sur 20 appels, et celui de la page Chrome moins de 120 ms (budgets `ui_tree` et `chrome` ; mesurés à 28,2 et 46,5 ms en vol, audit 5.2), et que chaque contrôle de la fixture y figure avec son rôle.
- [ ] Étant donné une application arrêtée par SIGSTOP, alors son arbre porte `{partial: timeout}` en moins de 250 ms (délai de 200 ms par appel, plus 50 ms de marge fixée par ce PRD), et `ui_tree` de la fixture GTK 4 lu pendant ce temps tient 50 ms au p95.

#### US-087: Actions AT-SPI et verdicts
**Description:** En tant que Claude Code, je veux `ui_act` sur les éléments AT-SPI avec un verdict honnête afin d'agir sans entrée physique et de savoir si l'action a pris.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-086

**Acceptance Criteria:**
- [ ] `invoke` appelle `DoAction` sur l'index dont `GetName(i)` vaut `click`, `press`, `activate` ou `doDefault`, et jamais sur les noms de `GetActions`, que Chrome rend vides (audit 5.2).
- [ ] `set_value` sur un texte appelle `EditableText.SetTextContents`. Sur un élément à plage, il écrit `Value.CurrentValue`. `select` appelle `Selection.SelectChild` par index ou par nom.
- [ ] `scroll` appelle `Component.ScrollTo`, ou l'action `listitem.scroll-to` d'un élément de liste GTK 4.
- [ ] `focus` appelle `GrabFocus` et reste de classe intrusive en mode arrière-plan.
- [ ] Chaque action relit une propriété (état, valeur ou texte) et rend le verdict du cœur : vérifié, non vérifiable ou contredit.
- [ ] Le contrôle `ui-act` exécute `invoke` sur le bouton, `set_value` sur le champ de texte et le curseur, `select` sur la liste et `scroll` sur sa 30e entrée de la fixture. Il lit chaque effet dans `NC_FIXTURE_LOG` et le verdict « vérifié ».
- [ ] Étant donné `check` ou `uncheck` sur une case GTK 4 sans action, alors rien n'est envoyé, et l'outil répond « <élément> n'expose aucune action AT-SPI (GTK 4) : impossible de le cocher sans entrée. En mode a11y, clique-le avec left_click. »
- [ ] Étant donné `set_value` sur un champ web de Chrome sans `EditableText`, alors rien n'est envoyé, et l'outil répond « <élément> n'accepte pas d'écriture AT-SPI (Chromium) : tape le texte avec type après l'avoir cliqué. »
- [ ] Étant donné `SelectChild` qui rend `True` sans changer la sélection (liste d'une DropDown GTK 4, audit 5.2), alors le verdict est « contredit ».

#### US-088: Événements, compteur de changements et réactivité
**Description:** En tant que Claude Code, je veux que la stabilisation et `ui_find` `wait_ms` se réveillent sur les changements de l'application cible afin de ne pas attendre un délai fixe ni lire l'écran.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-086

**Acceptance Criteria:**
- [ ] À la connexion, le backend enregistre une fois `object:` et `window:` par `Registry.RegisterEvent`. Il n'écrit lui-même aucun réglage ; l'écriture de `toolkit-accessibility` par at-spi2-core est la seule admise (D13).
- [ ] `windowEvents` rend un compteur par application, incrémenté par `ChildrenChanged`, `StateChanged`, `TextChanged`, `PropertyChange` et les événements `window:`.
- [ ] Une relecture de l'arbre toutes les 250 ms au plus (`reread_floor_ms`) couvre les changements sans événement, comme la valeur d'un `Scale` GTK 4 (audit 5.2).
- [ ] `responsive` teste une application par un appel AT-SPI (`GetRole`) avec un délai de 200 ms, jamais par `Peer.Ping` : `Ping` répond même quand le fil principal GTK est bloqué (audit 5.2).
- [ ] Le contrôle `ui-find-wait` vérifie que `ui_find` avec `wait_ms` répond moins de 100 ms après l'apparition de l'élément attendu dans la fixture (NFR du PRD background).
- [ ] Étant donné une page qui émet 1 386 ajouts et 1 386 retraits en 10 s (audit 5.2), alors le serveur reste sous 5 % d'un cœur pendant une attente de `ui_find` (NFR du PRD background).

#### US-089: Mots de passe et coordonnées des éléments
**Description:** En tant qu'Arthur, je veux qu'aucun mot de passe ne sorte d'AT-SPI et que les rectangles des éléments soient en coordonnées d'écran exactes afin de masquer les secrets dans les images et de viser juste.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-086, US-085

**Acceptance Criteria:**
- [ ] Les éléments de rôle 40 (`PASSWORD_TEXT`) de GTK, Qt et Chromium alimentent `secretRects` et `secretScan`. Leur texte n'est jamais lu dans une sortie : ni les puces, ni leur nombre.
- [ ] Le contrôle `password-mask` remplit le champ mot de passe de la fixture GTK 4 et celui de la page Chrome avec `s3cret`. Il vérifie que ni `ui_tree`, ni `ui_find`, ni l'audit ne contiennent `s3cret`, une puce ou la longueur 6.
- [ ] L'action `Peek` d'un champ mot de passe n'est jamais appelée. Étant donné `ui_act` qui la demande, alors l'outil répond « Action Peek refusée : elle affiche le mot de passe en clair. » (FR-09).
- [ ] Le rectangle d'écran d'un élément est l'origine de la surface de sa fenêtre (cadre et tampon rendus par l'extension) plus ses coordonnées AT-SPI `WINDOW`. Les décorations côté client sont donc comprises.
- [ ] Dans la session `gnome`, le contrôle `ui-coords` vérifie A32 à l'échelle 1, puis 1,5, puis 2. Il compare les rectangles de 20 contrôles de la fixture à ceux qu'elle a écrits : chaque centre calculé tombe dans le contrôle, et l'écart reste ≤ 1 px. Le verdict est consigné dans 0014.
- [ ] Étant donné un champ mot de passe dont le rectangle d'écran ne peut pas être calculé, alors `secretScan` échoue, et toute image de cette fenêtre est refusée (FR-42).

---

### EP-024: GNOME : souris et clavier réels (D14)

Sous GNOME, piloter la vraie souris et le vrai clavier par le canal EI de RemoteDesktop, sans perte d'événement et avec relâche garantie, kill switch par entrée physique et libellé (décision 0014, D14). Livraison 1.

**Definition of Done:** Dans la session `gnome`, les contrôles suivants sont `ok` : `mouse`, `mouse-buttons`, `mouse-bounds`, `drag`, `hover`, `scroll`, `keyboard`, `type`, `type-unicode`, `release-eof`, `release-sigint`, `release-sigterm`, `release-sigkill`, `kill-escape`, `kill-mouse`, `kill-pause`, `cursor`, `indicator` et `locked`. Une passe `selftest --real-session` d'Arthur sur sa session est consignée dans 0014.

#### US-090: Pointeur réel par EI
**Description:** En tant que Claude Code, je veux cliquer, double-cliquer, glisser, survoler et faire défiler avec la vraie souris sous GNOME afin de mener une passe visuelle qui exige un vrai comportement de pointeur.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-080, US-082, US-084, US-085, US-076, US-067 (P1)

**Acceptance Criteria:**
- [ ] Le backend ouvre une session `RemoteDesktop` à la première action d'entrée, prend son canal par `ConnectToEIS`, et envoie un mouvement avant tout premier clic d'une session neuve (sinon le clic est perdu, audit 4.1).
- [ ] Le contrôle `mouse` fait 20 `left_click` à des coordonnées de capture du canevas, et la fixture reçoit 20 clics gauches simples à ≤ 1 px des points visés.
- [ ] Le contrôle `mouse-buttons` envoie `right_click`, `middle_click`, `double_click`, `triple_click`, puis `left_mouse_down` et `left_mouse_up`. La fixture rapporte pour chacun le bouton et le nombre de clics attendus.
- [ ] Le contrôle `cursor` vérifie qu'après chaque `mouse_move`, `cursor_position` rend le point visé à ≤ 1 px, à l'échelle 1, 1,5 et 2.
- [ ] Le contrôle `drag` fait un glisser-déposer GTK entre les deux zones de la fixture, avec des mouvements intermédiaires, et la fixture rapporte un dépôt terminé.
- [ ] Le contrôle `hover` déplace le pointeur sur la zone de survol puis hors d'elle, et la fixture rapporte une entrée et une sortie.
- [ ] Le contrôle `scroll` fait défiler de 3 crans vers le bas puis 2 vers la droite, et la fixture rapporte 3 et 2 crans.
- [ ] À l'échelle 1, puis 1,5, puis 2, un clic à la coordonnée de capture d'un point du canevas arrive à ≤ 1 px de ce point. Le verdict de A29 est consigné dans 0014.
- [ ] Étant donné une coordonnée hors de tous les écrans, alors l'outil refuse avec le message existant (`mouse-bounds`), et rien n'est envoyé.
- [ ] Étant donné une session RemoteDesktop fermée par Mutter, alors l'action en cours répond « Session d'entrée fermée par GNOME : relance l'action. », et l'action suivante ouvre une nouvelle session.
- [ ] Étant donné l'extension absente (P1), alors les outils d'entrée répondent « Entrée réelle indisponible : sans l'extension GNOME, aucun kill switch ne peut détecter tes gestes. Lance neo-compute setup puis reconnecte-toi. » et rien n'est envoyé.

#### US-091: Clavier réel : touches, combinaisons et texte de la disposition
**Description:** En tant que Claude Code, je veux taper des touches, des raccourcis et du texte avec le vrai clavier sous GNOME afin de piloter n'importe quelle application comme un utilisateur.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-090

**Acceptance Criteria:**
- [ ] `key`, `hold_key` et `type` traduisent chaque nom de touche de `src/core/keys.zig` et chaque caractère en keycode et modificateurs par la disposition que publie le clavier EI.
- [ ] La session est amorcée avant la première touche, qui sinon est perdue (audit 4.1). La fixture reçoit les 20 premières touches de 20 sessions neuves.
- [ ] Le contrôle `keyboard` tape `a`, `;`, `ctrl+a` et `shift+Tab`, et la fixture rapporte les keysyms et les modificateurs attendus.
- [ ] Le contrôle `type` tape un texte ASCII de 200 caractères, et la zone de texte de la fixture contient exactement ce texte.
- [ ] Avant tout envoi, chaque caractère du texte est vérifié contre la disposition. Étant donné un caractère absent et aucune voie de US-092, alors rien n'est envoyé, et l'outil répond « Caractères absents de la disposition <nom> : <liste>. Aucune touche envoyée. »
- [ ] Étant donné un changement de disposition par l'utilisateur pendant la session, alors le texte tapé ensuite suit la nouvelle disposition (contrôle avec `us` puis `fr`).
- [ ] Un test du générateur prouve qu'aucun appel à `RemoteDesktop.SetKeymap` n'est compilé.

#### US-092: Sonde A26 et saisie hors disposition
**Description:** En tant que Claude Code, je veux taper « é », « ü », un emoji ou du chinois sous GNOME quelle que soit la disposition afin que `type` ne perde jamais un caractère.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-091, US-098

**Acceptance Criteria:**
- [ ] Une sonde, dans la session `gnome` avec un `ibus-daemon` privé, tape « é ü 😀 中文 » par Ctrl+Maj+U dans la fixture GTK 4, dans KWrite (Qt 6) et dans la page Chrome. Le verdict de A26 par toolkit est consigné dans 0014.
- [ ] Si A26 est validée pour les trois toolkits, alors `type` tape ces caractères par Ctrl+Maj+U, et le contrôle `type-unicode` vérifie le texte reçu par la fixture.
- [ ] Si A26 est infirmée pour un toolkit, alors `type` passe par le presse-papiers de la session RemoteDesktop. Il sauvegarde tous les types MIME de la sélection courante, écrit le texte, envoie Ctrl+V, restaure la sélection, puis vérifie la restauration en la relisant. Le contrôle `type-unicode` vérifie alors le texte reçu par la fixture par cette voie.
- [ ] Étant donné une restauration du presse-papiers qui échoue, alors le résultat porte la ligne « Presse-papiers non restauré : son propriétaire a disparu. ».
- [ ] Étant donné la politique `clipboard` refusée pour la cible, alors la voie du presse-papiers n'est pas prise, et l'outil répond avec le message de US-091.

#### US-093: Relâchement des entrées tenues sous GNOME
**Description:** En tant qu'Arthur, je veux qu'aucune touche ni aucun bouton ne reste enfoncé quand le serveur s'arrête, quelle que soit la façon, afin que mon clavier reste utilisable.

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-090, US-072

**Acceptance Criteria:**
- [ ] `releaseAllInputs` relâche par EI chaque touche et chaque bouton tenus, puis arrête la session RemoteDesktop.
- [ ] Dans la session `gnome`, un contrôle tient Maj par `hold_key` puis ferme stdin. La fixture voit le relâchement de Maj moins de 50 ms après (`release-eof`).
- [ ] Le même contrôle passe avec SIGINT (`release-sigint`) et SIGTERM (`release-sigterm`).
- [ ] Avec SIGKILL (`release-sigkill`), c'est Mutter qui relâche en moins de 50 ms (mesuré à 2,6/3,0 ms, audit 4.1).
- [ ] Étant donné une annulation (`notifications/cancelled`) ou une erreur pendant `hold_key`, alors les entrées sont relâchées en moins de 50 ms.
- [ ] `AGENTS.md` documente la limite : un serveur figé par SIGSTOP garde ses touches, car Mutter n'a pas de minuterie (audit 4.1).

#### US-094: Kill switch, pause, indicateur et verrouillage sous GNOME
**Description:** En tant qu'Arthur, je veux reprendre la main par un geste physique et voir quand l'agent agit afin que l'entrée réelle reste sous mon contrôle.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-083, US-093, US-067 (P1, P9)

**Acceptance Criteria:**
- [ ] Le contrôle `kill-mouse` produit, par `SimulatePhysical`, un mouvement physique de 9 px pendant un `left_click_drag` en cours. L'action est annulée et le serveur passe en pause en moins de 100 ms. Le seuil est celui de Windows : plus de 8 px (`move_threshold_px`, `src/backend/windows/hooks.zig:17`).
- [ ] Le contrôle `kill-escape` produit de même un Échap physique pendant un `type` de 200 caractères : l'action est annulée et le serveur passe en pause en moins de 100 ms.
- [ ] Étant donné un mouvement physique de 8 px pendant une action, alors l'action continue et le serveur ne passe pas en pause.
- [ ] Le raccourci de réarmement est déclaré par l'extension (`Main.wm.addKeybinding`). Seul un appui physique lève la pause (FR-12), et un appui injecté est ignoré (contrôle `kill-pause`, avec `SimulatePhysical` de US-083).
- [ ] Le libellé est un `St.Label` posé dans `uiGroup`, avec `reactive: false` et `can_focus: false`. Il montre les états « en action » et « en pause », et un clic sur lui atteint la fenêtre dessous (contrôle `indicator`).
- [ ] Le libellé est absent de toute image rendue par `screenshot` et `zoom`.
- [ ] Étant donné `org.gnome.ScreenSaver.GetActive` à `true`, alors les outils d'entrée et de capture répondent avec le message existant de session inactive. Aucune entrée n'est envoyée, car l'entrée injectée atteindrait l'invite de déverrouillage (audit 4.1, contrôle `locked`).
- [ ] Étant donné un verrouillage pendant `hold_key`, alors les entrées sont relâchées en moins de 50 ms.
- [ ] Le serveur n'appelle jamais `org.gnome.ScreenSaver.SetActive` : la liste de refus de US-077 le prouve, car l'appel déverrouille sans mot de passe (audit 4.1).
- [ ] Le contrôle `locked` verrouille la session par `org.gnome.ScreenSaver.Lock` avec le faux GDM du banc, et le verdict de A30 pour le verrou est consigné dans 0014.
- [ ] Arthur lance `neo-compute selftest --real-session` sur sa session Fedora 45. Les résultats des contrôles `mouse`, `keyboard`, `release-*` et `kill-*` sont consignés dans 0014 (preuve demandée par D14).

---

### EP-025: GNOME : capture, presse-papiers et lancement

Donner à GNOME `screenshot`, `zoom`, `ui_tree marks`, `clipboard` et `app_launch` avec masquage des mots de passe, presse-papiers sans fuite et lancement sans shell (chantier L7). Livraison 1, sauf US-097 en livraison 2.

**Definition of Done:** Dans la session `gnome`, les contrôles `capture-window`, `capture-scale`, `capture-covered`, `capture-no-indicator`, `password-mask-image`, `ui-marks`, `clipboard`, `apps-catalog`, `app-launch` et `open-path` sont `ok`. `screenshot` tient le budget de 30 ms p95, et les verdicts de A25 et A40 sont consignés dans 0014.

#### US-095: Sonde A25 : capture par l'extension
**Description:** En tant qu'Arthur, je veux mesurer si l'extension capture l'écran et une fenêtre recouverte dans les budgets afin de choisir la voie de capture sur une mesure (D10).

**Priority:** P0
**Size:** S (2 pts)
**Dependencies:** Blocked by US-082

**Acceptance Criteria:**
- [ ] Dans la session `gnome`, une sonde demande à l'extension 20 captures de l'écran 1920x1080 et 20 captures d'une fenêtre de fixture de 800x600, en pixels bruts passés par memfd. Elle écrit p50 et p95 côté serveur.
- [ ] La sonde capture la fenêtre de fixture entièrement recouverte par le leurre et vérifie que l'image montre la fixture et non le leurre.
- [ ] La sonde mesure si l'image d'une fixture recouverte suit un changement fait pendant la couverture, avant et après l'état `suspended` de Mutter (3,8 s, audit 5.2).
- [ ] La sonde vérifie que l'extension signale les changements d'une fenêtre (dommage de son acteur) et compte ces signaux pendant 5 s de fixture au repos puis animée.
- [ ] Le verdict de A25 est consigné dans 0014 : validé si la capture d'écran tient 30 ms au p95, si la fenêtre recouverte rend ses propres pixels, et si le signal de dommage existe.
- [ ] Étant donné A25 infirmée, alors US-096 passe `BLOCKED` avec la raison, US-097 devient P0 et passe en livraison 1, et le rapport le signale en tête.

#### US-096: Capture d'écran et de fenêtre par l'extension
**Description:** En tant que Claude Code, je veux `screenshot`, `zoom` et `ui_tree marks` sous GNOME, sur l'écran ou sur une fenêtre recouverte, sans allumer l'indicateur de partage d'écran.

**Priority:** P0
**Size:** L (5 pts)
**Dependencies:** Blocked by US-095, US-089, US-085

**Acceptance Criteria:**
- [ ] `capture` rend l'image d'un écran par l'extension, et `captureWindow` celle d'une fenêtre, recouverte comprise. Les pixels BGRA passent par un memfd, puis par le réducteur et l'encodeur existants.
- [ ] Le contrôle `capture-window` vérifie que, dans l'image d'une fixture en vue, chaque contrôle se trouve à ≤ 1 px du rectangle que la fixture a écrit.
- [ ] Le contrôle `capture-scale` passe l'écran à l'échelle 2 puis 1,5 (US-085). La largeur de l'image brute vaut alors la largeur logique multipliée par l'échelle, et chaque contrôle de la fixture reste à ≤ 1 px de son rectangle converti en coordonnées de capture.
- [ ] Le contrôle `ui-marks` vérifie que `ui_tree marks` dessine les identifiants sur l'image de la fixture et coûte moins de 8 ms au-delà de `screenshot` au p95 (budget `marks`).
- [ ] `screenshot` d'un écran 1920x1080 tient 30 ms au p95, et `capture` 8 ms au p95 (budgets de `src/core/bench.zig`).
- [ ] `changes` rend vrai quand l'extension a signalé un dommage depuis l'appel précédent. La stabilisation des modes `a11y` et `vision` s'en sert.
- [ ] `screenshot` avec `window` d'une fenêtre entièrement recouverte montre la fenêtre et non ce qui la couvre (contrôle `capture-covered`).
- [ ] Les champs mot de passe de la fenêtre capturée sont noirs dans `screenshot` et dans un `zoom` sur eux (contrôle `password-mask-image`).
- [ ] L'extension rend la visibilité de l'indicateur de partage d'écran du panneau. Le contrôle `capture-no-indicator` la lit fausse pendant et après 20 captures par l'extension.
- [ ] Étant donné une fenêtre minimisée, alors `screenshot` avec `window` répond « Fenêtre minimisée : restaure-la avec window_set (state normal). » sans image.
- [ ] Étant donné un balayage des mots de passe qui échoue, alors l'image de la fenêtre est refusée (FR-42).

#### US-097: Repli ScreenCast par libpipewire chargée à l'exécution
**Description:** En tant que Claude Code, je veux une capture qui marche sans extension, et qui fait redessiner une fenêtre recouverte, afin de garder `screenshot` en mode réduit.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-095, US-078, US-067 (P7)

**Acceptance Criteria:**
- [ ] `libpipewire-0.3.so.0` est chargée par `dlopen`. Le backend ouvre `RecordMonitor` ou `RecordWindow` et lit le nœud par son `object.serial`, en memfd BGRx (audit 4.1).
- [ ] Le flux reste ouvert tant que le serveur agit : une capture rend la dernière image reçue sans rouvrir de session, car le premier écran met 19 à 37 ms à arriver (audit 4.1).
- [ ] Sans extension, `screenshot` passe par ce repli, et la table de capacités l'indique.
- [ ] Étant donné l'utilisateur qui arrête le partage depuis l'indicateur de GNOME, alors le serveur se met en pause comme sur le kill switch (D11), et l'outil répond « Partage d'écran arrêté par l'utilisateur : en pause. Attends qu'Arthur réarme. »
- [ ] Étant donné `libpipewire-0.3.so.0` absente, alors la capacité est absente, et l'outil répond « libpipewire introuvable : installe pipewire-libs, ou lance neo-compute setup pour la capture par l'extension. »
- [ ] Chaque défaut de cette couche C compte pour la condition 3 dans `docs/decisions/0001-zig-vs-rust.md` (D12).

#### US-098: Presse-papiers sous GNOME
**Description:** En tant que Claude Code, je veux lire et écrire le presse-papiers sous GNOME sans jamais rendre un secret afin de transférer du texte entre applications.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-090

**Acceptance Criteria:**
- [ ] `clipboard` `set` écrit `text/plain;charset=utf-8` par le presse-papiers de la session RemoteDesktop (`EnableClipboard`, `SetSelection`, `SelectionWrite` ; écriture mesurée, audit 4.1). La fixture colle ce texte.
- [ ] `clipboard` `get` lit la sélection par `SelectionRead`. Le contrôle `clipboard` relit un texte copié dans la fixture et attend le signal de changement de propriétaire. Le verdict de A40 est consigné dans 0014.
- [ ] Étant donné A40 infirmée, alors `get` et le suivi des changements passent par l'extension (`St.Clipboard`, signal `owner-changed` de `Meta.Selection`), et le contrôle `clipboard` passe par cette voie.
- [ ] Étant donné une sélection qui porte `x-kde-passwordManagerHint`, alors `get` répond par le message existant de contenu secret (FR-26) sans en rendre le texte.
- [ ] Étant donné un contenu de plus de 8 000 caractères, alors la sortie est tronquée selon FR-16.
- [ ] Étant donné une lecture dont le propriétaire ne répond pas en 200 ms, alors l'outil répond « Presse-papiers illisible : l'application propriétaire ne répond pas. » sans bloquer.

#### US-099: Catalogue et lancement d'applications
**Description:** En tant que Claude Code, je veux lancer une application du catalogue Linux sans shell, sans qu'elle hérite des restrictions du serveur, afin d'utiliser `app_launch` comme sous Windows.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-081, US-070, US-067 (P10)

**Acceptance Criteria:**
- [ ] `appCatalog` lit les entrées `.desktop` de `$XDG_DATA_HOME/applications` et des `$XDG_DATA_DIRS`, en respectant `NoDisplay`, `Hidden`, `OnlyShowIn`, `NotShowIn` et `TryExec`.
- [ ] `launchApp` découpe `Exec` selon la Desktop Entry Specification (guillemets, codes `%f %F %u %U %i %c %k`) en un vecteur d'arguments, sans shell.
- [ ] Au démarrage, avant le filtre seccomp et avant tout fil, le serveur crée un processus lanceur (`common/launch.zig`), qui meurt avec lui (`PR_SET_PDEATHSIG`). `launchApp` lui passe le vecteur et l'environnement par un tube, et le lanceur exécute par `posix_spawn` (T9, P10).
- [ ] Le contrôle `app-launch` lance la fixture par `app_launch`, et sa fenêtre apparaît dans `window_list` ; le processus lancé a pour parent le processus lanceur.
- [ ] Quand le gestionnaire systemd de l'utilisateur répond, le processus lancé passe dans un scope transitoire `app-neocompute-<id>-<n>.scope` par `StartTransientUnit`. Son identifiant d'application est ensuite lisible par US-070.
- [ ] Étant donné aucun gestionnaire systemd joignable, comme sur le bus privé des bancs, alors le processus est lancé sans scope, et son identité vient de `/proc/<pid>/exe`.
- [ ] Étant donné une entrée `Terminal=true`, alors `app_launch` la refuse avec « <application> s'ouvre dans un terminal : refusé, aucun outil de commande (FR-11). »
- [ ] Étant donné un code de champ inconnu dans `Exec`, alors le lancement est refusé avec « Entrée <fichier> invalide : code <code> inconnu. »
- [ ] Un test du build échoue si `fork`, `execve`, `posix_spawn` ou `std.process.Child` apparaît dans `src/core/`, ou dans `src/backend/linux/` hors de `common/launch.zig`, `wlroots/guardian.zig` et des fichiers de selftest et de sonde (`selftest*.zig`, `*_probe.zig`) (P10).
- [ ] Le contrôle `apps-catalog` vérifie que le catalogue complet tient le budget `apps-catalog` (300 ms), et une recherche dans le catalogue en cache le budget `apps` (1 ms).

#### US-124: Ouverture de documents par leur application par défaut
**Description:** En tant que Claude Code, je veux ouvrir un document avec l'application que l'utilisateur a choisie pour son type, et jamais un exécutable, afin d'utiliser `app_launch` avec un chemin comme sous Windows.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-099

**Acceptance Criteria:**
- [ ] `openPath` trouve le type MIME d'un fichier par les `globs2` de shared-mime-info des `$XDG_DATA_DIRS`, puis par ses premiers octets (`magic`) quand aucun motif ne correspond.
- [ ] `openPath` trouve l'application par défaut par la chaîne des `mimeapps.list` de la spécification XDG (`$XDG_CONFIG_HOME`, `$XDG_CONFIG_DIRS`, puis `applications/` des `$XDG_DATA_DIRS`, variantes `<bureau>-mimeapps.list` d'abord), puis la lance par US-099 avec le chemin en argument.
- [ ] Le contrôle `open-path` ouvre un fichier `.txt` du `HOME` privé dans la session `gnome` : GNOME Text Editor s'ouvre avec ce fichier (titre de la fenêtre).
- [ ] Étant donné un document exécutable (bit `x`, `application/x-executable`, `application/x-shellscript`, `application/x-desktop`, `.AppImage`, `.run`), alors `openPath` le refuse avec le message existant de type dangereux (FR-25).
- [ ] Étant donné un type sans application par défaut, alors `app_launch` répond « Aucune application pour <type> : ouvre le fichier avec une application nommée. »

---

### EP-026: GNOME : mode arrière-plan

Porter le mode `--mode background` sous GNOME : rien ne prend la souris, le clavier ni le premier plan de l'utilisateur, et un témoin le prouve (chantier L12). Livraison 2.

**Definition of Done:** `zig build session -- gnome selftest --background` passe : `bg-loop` (1 000 actions, 0 violation), garde du premier plan, lancement et restauration sans focus, capture d'une fenêtre recouverte, stabilisation sur événements, pause par raccourci, et témoin d'action intrusive `bg-must-catch` détecté.

#### US-100: Leurre, témoin et selftest d'arrière-plan Linux
**Description:** En tant que développeur, je veux un leurre au premier plan et un témoin qui échantillonne le focus, le pointeur et le presse-papiers afin de prouver la non-interférence sous GNOME.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-094, US-076, US-084, US-098

**Acceptance Criteria:**
- [ ] `selftest --background` ouvre un leurre (`gtk_fixture.py --role decoy`) d'un autre processus au premier plan. Le selftest lui envoie F15 toutes les 250 ms par une seconde session d'entrée qui joue l'utilisateur : une session RemoteDesktop sous GNOME, un second contexte EIS sous KDE (US-109).
- [ ] Sous GNOME, le témoin lit toutes les 50 ms, par l'extension, la fenêtre active, la position du pointeur et le compte des changements de propriétaire du presse-papiers (A40).
- [ ] Le témoin compte comme violation toute touche autre que F15 reçue par le leurre, et, sous GNOME, tout événement injecté autre que les F15 du leurre selon le classement de US-083.
- [ ] Le contrôle `bg-loop` exécute 1 000 actions d'arrière-plan sur une fixture recouverte et exige 0 changement de fenêtre active, de pointeur ou de presse-papiers, et 0 événement injecté par le serveur.
- [ ] Le contrôle `bg-must-catch` envoie une action intrusive témoin, un clic injecté, et exige que le témoin la détecte.
- [ ] Étant donné une violation, alors le contrôle échoue en écrivant l'échantillon avant et après.

#### US-101: Garde du premier plan, lancement et restauration sans focus
**Description:** En tant qu'Arthur, je veux que l'agent lance et restaure ses fenêtres sans me prendre le premier plan, et que GNOME me le rende si une fenêtre de l'agent le prend, afin de continuer à travailler.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-100, US-099

**Acceptance Criteria:**
- [ ] L'extension surveille `notify::focus-window`. Quand le processus cible prend le premier plan sans geste de l'utilisateur, pendant l'action ou dans les 2 s qui suivent (`linger_ms`), elle réactive la fenêtre de l'utilisateur par `Main.activateWindow` en moins de 200 ms (NFR du PRD background).
- [ ] `app_launch` en mode arrière-plan laisse la fenêtre de l'utilisateur active, ou la lui rend en moins de 200 ms. La mesure de l'audit montre qu'une nouvelle fenêtre prend le focus 21 fois sur 21 (contrôle `bg-launch`).
- [ ] `window_set` `state: normal` restaure une fenêtre minimisée par `unminimize`, sans focus, 20 fois sur 20 (contrôle `bg-restore`).
- [ ] Étant donné un clic physique hors de la fenêtre de l'utilisateur, ou une touche avec Alt ou Super, pendant l'action, alors aucune restauration n'a lieu, et l'audit l'enregistre (règle du geste, décision 0013).
- [ ] Le résultat et l'audit portent `guard_late` quand la restauration a eu lieu après le retour de l'action.

#### US-102: Cible de session, recouvrement et stabilisation sur événements
**Description:** En tant que Claude Code, je veux viser ma fenêtre cible, savoir si elle est recouverte, et stabiliser sur ses événements afin de travailler derrière l'utilisateur sans lire son écran.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-100, US-088

**Acceptance Criteria:**
- [ ] En mode arrière-plan, un outil sans `window` vise la fenêtre cible de session et ne lit jamais la fenêtre active (FR-35).
- [ ] `windowLayers` vient de l'empilement et des cadres de l'extension, et le drapeau `{occluded}` suit la règle de `a11y.zig` (contrôle `bg-occluded`).
- [ ] La stabilisation et l'attente de `ui_find` lisent le compteur AT-SPI de la cible (US-088) et jamais une capture (FR-37). Une action sans effet, sous un leurre qui se redessine, se stabilise en moins de 150 ms au p95 (budget `bg-settle`).
- [ ] Étant donné une cible fermée pendant l'action, alors l'outil répond « Fenêtre cible fermée : rappelle window_list », et la cible est effacée.

#### US-103: Capture d'une fenêtre recouverte en arrière-plan
**Description:** En tant que Claude Code, je veux voir ma fenêtre cible recouverte, mots de passe masqués, avec un drapeau quand l'image peut être figée, afin de contrôler visuellement mon travail en arrière-plan.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-096, US-102

**Acceptance Criteria:**
- [ ] En mode arrière-plan, `screenshot`, `zoom` et `ui_tree marks` rendent la fenêtre cible par `captureWindow`, et `observe: screenshot` rend la même image.
- [ ] La capture d'une fenêtre de 2560x1440 recouverte tient 60 ms au p95 (budget `bg-capture`).
- [ ] Le résultat porte `frozen_image` quand la fenêtre est à l'état `suspended` de Mutter (audit 5.2), car son client ne redessine plus.
- [ ] Étant donné un balayage des mots de passe incomplet, alors l'image est refusée (FR-42).

#### US-104: Pause par raccourci et libellé seul en arrière-plan
**Description:** En tant qu'Arthur, je veux que ma souris et Échap ne mettent pas l'agent en pause en arrière-plan, et que le raccourci serve de bascule, afin de cohabiter comme sous Windows.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-094, US-100

**Acceptance Criteria:**
- [ ] En mode arrière-plan, un mouvement physique du pointeur ou un Échap physique ne mettent pas en pause et ne sont pas consommés (FR-36, avec `SimulatePhysical`).
- [ ] Le raccourci de réarmement bascule la pause en moins de 100 ms. Les répétitions automatiques d'une touche tenue ne basculent qu'une fois (règle `swallow` de `hooks.zig`).
- [ ] Le libellé seul est affiché en mode arrière-plan.
- [ ] Étant donné le raccourci injecté par le serveur, alors la pause ne bascule pas.

---

### EP-027: KDE Plasma

Porter le serveur sous KWin : entrée par EIS, capture par ScreenShot2, fenêtres et garde par un script KWin persistant, presse-papiers par data-control, libellé par layer-shell (chantier L8). Livraison 3.

**Definition of Done:** `zig build session -- kde selftest` et `zig build session -- kde selftest --background` passent. Les verdicts de A27, A28, A41, A43, A44 et A31 sous KDE sont consignés dans 0014.

#### US-105: Sonde A27, A28 et A41 sur une vraie session Plasma
**Description:** En tant qu'Arthur, je veux vérifier dans ma vraie session Plasma que KWin donne EIS, ScreenShot2 et le scripting sans dialogue, et que la détection de mes gestes par soustraction tient, afin que le backend KDE repose sur la session réelle et pas seulement sur KWin sans écran.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-080

**Acceptance Criteria:**
- [ ] Arthur lance `neo-compute kde-probe --real-session` dans sa session Plasma 6.8. Pour chaque étape ci-dessous, la sonde écrit sa réussite et si un dialogue est apparu.
- [ ] Étape EIS : un contexte ouvert par `connectToEIS`, puis fermé sans aucun événement.
- [ ] Étape capture : `CaptureWindow` d'une fenêtre ouverte par la sonde.
- [ ] Étape script : un script KWin qui ne fait que lister les fenêtres, chargé puis déchargé.
- [ ] Étape pointeur : `workspace.cursorPos` lu, un signal de changement reçu pendant qu'Arthur bouge la souris, et `a11y.Manager.QueryPointer` appelé.
- [ ] Étape raccourci : un raccourci de pause déclaré, puis retiré.
- [ ] Étape soustraction (A41) : pendant 60 s, la sonde injecte par EIS 200 positions absolues dans une fenêtre qu'elle a ouverte, pendant qu'Arthur fait au moins 30 mouvements physiques de plus de 8 px. Elle compte les mouvements physiques détectés, leur délai de détection, et les injections détectées à tort comme physiques.
- [ ] Les verdicts de A27, A28 et A41 sont consignés dans 0014. A41 est validée si chaque mouvement physique est détecté en moins de 100 ms et si aucune injection n'est détectée comme physique.
- [ ] Étant donné A41 infirmée, alors US-107 passe `BLOCKED`, et le rapport propose à Arthur une autre source d'entrée physique sous KDE : evdev sur activation explicite, comme sous wlroots (D4).
- [ ] Étant donné une étape refusée ou un dialogue, alors la capacité correspondante passe par le portail (D3). Le rapport le signale en tête, et les stories de EP-027 qui en dépendent sont réécrites avant de démarrer.

#### US-106: Script KWin persistant : fenêtres, empilement, garde, pointeur
**Description:** En tant que Claude Code, je veux lister, activer et ranger les fenêtres de KDE sans changer la fenêtre active afin d'avoir sous KDE ce que l'extension donne sous GNOME.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-105, US-075, US-081

**Acceptance Criteria:**
- [ ] Le serveur écrit son script dans `$XDG_RUNTIME_DIR/neo-compute/kwin-<pid>.js` (mode 0600), le charge par `/Scripting.loadScript` et le lance.
- [ ] Le script appelle en attente longue une méthode du serveur pour recevoir ses commandes. Le serveur n'accepte ces appels que du nom unique propriétaire de `org.kde.KWin`.
- [ ] Le script rend pour chaque fenêtre : UUID, titre, pid, `resourceClass`, `desktopFileName`, `frameGeometry`, rang dans `stackingOrder`, active, minimisée, écran.
- [ ] Il active, déplace, redimensionne, minimise, restaure, monte et ferme une fenêtre. Hors activation, aucune de ces opérations ne change la fenêtre active (30 fois sur 30, audit 4.2).
- [ ] La liste tient le budget `window_list` (5 ms au p95), et `window_set` le budget de 20 ms au p95.
- [ ] `cursor_position` vient du script (A28), sinon de `a11y.Manager.QueryPointer`, libre sous KWin (audit 4.2).
- [ ] Étant donné le serveur tué par SIGKILL, alors le script se décharge en moins de 5 s : `isScriptLoaded` rend `false`. Le verdict de A44 est consigné dans 0014.
- [ ] Étant donné le scripting indisponible, alors la capacité « gestion des fenêtres » est absente avec sa raison.

#### US-107: Entrée par EIS, relâchement et kill switch sous KDE
**Description:** En tant que Claude Code, je veux la vraie souris et le vrai clavier sous KDE, avec un kill switch, afin de mener une passe visuelle sous Plasma.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-106, US-072, US-076, US-067 (P2, P9)

**Acceptance Criteria:**
- [ ] Le backend ouvre EIS par `org.kde.KWin.EIS.RemoteDesktop.connectToEIS` et envoie pointeur absolu, boutons, défilement et touches par le fil EI.
- [ ] Les caractères hors disposition passent par l'interface de texte EI. Le contrôle `type-unicode` vérifie « é ü 😀 中文 » dans la fixture, et le verdict de A34 est consigné dans 0014.
- [ ] Les contrôles `release-eof`, `release-sigint`, `release-sigterm` et `release-sigkill` passent sous KWin en moins de 50 ms (KWin mesuré à 3,2 à 4,3 ms au `kill -9`, audit 4.2).
- [ ] Le kill switch (P2) se déclenche quand le curseur s'écarte de plus de 8 px de la dernière position injectée par le serveur. Le contrôle `kill-mouse` le vérifie : un second contexte EIS du banc déplace le pointeur de 9 px pendant un `left_click_drag`, et le serveur passe en pause en moins de 100 ms.
- [ ] Le raccourci de pause, déclaré par le script, met le serveur en pause en moins de 100 ms (contrôle `kill-pause`, appui envoyé par le second contexte EIS du banc).
- [ ] Étant donné `key` ou `hold_key` avec la combinaison du raccourci de pause, alors l'outil refuse avec « Combinaison réservée au raccourci de pause de neo-compute : refusée. » et rien n'est envoyé. Toute activation du raccourci vient donc d'un autre que le serveur (FR-12).
- [ ] Étant donné une fenêtre active d'identifiant d'application `org.kde.polkit-kde-authentication-agent-1`, rendue par le script, alors les outils d'entrée sont refusés avec le message de dialogue système de US-119 (contrôle `system-dialog`, fixture lancée avec cet `--app-id`).
- [ ] Étant donné un écran verrouillé (`org.freedesktop.ScreenSaver.GetActive` à `true`), alors les outils d'entrée et de capture répondent avec le message existant de session inactive.
- [ ] Le serveur n'utilise jamais `org_kde_kwin_fake_input`, qui garde une touche tenue enfoncée à la mort du client (audit 4.2). Un test du générateur le prouve.

#### US-108: Capture ScreenShot2, presse-papiers et libellé sous KDE
**Description:** En tant que Claude Code, je veux capturer l'écran et une fenêtre recouverte, lire et écrire le presse-papiers, et voir le libellé sous KDE.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-106, US-079

**Acceptance Criteria:**
- [ ] `capture` passe par `ScreenShot2.CaptureScreen`, et `captureWindow` par `CaptureWindow`, recouverte ou minimisée. Les pixels arrivent par un tube, puis sont convertis de RGBA prémultiplié.
- [ ] L'image de `CaptureWindow`, qui inclut la marge d'ombre (audit 4.2), est rognée au `frameGeometry` rendu par le script. Le contrôle `capture-window` sous KDE trouve chaque contrôle de la fixture à ≤ 1 px de son rectangle.
- [ ] `screenshot` tient 30 ms au p95, et la capture d'une fenêtre recouverte 60 ms au p95 (budgets `screenshot` et `bg-capture` ; `CaptureWindow` mesuré à 1,85 ms, audit 4.2).
- [ ] `clipboard` passe par `ext-data-control` sans focus. `x-kde-passwordManagerHint` est traité comme un secret (FR-26).
- [ ] Le libellé est une surface `zwlr_layer_shell_v1` dessinée par le fil Wayland (`wl_shm`) avec une région d'entrée vide : un clic sur lui atteint la fenêtre dessous.
- [ ] Le libellé est absent des captures d'écran, par l'option `hide-caller-windows` de ScreenShot2. Le verdict de A43 est consigné dans 0014.
- [ ] Étant donné A43 infirmée, alors le serveur retire la surface du libellé pendant la capture puis la remet, et le contrôle `indicator` ne trouve aucun pixel du libellé dans l'image.
- [ ] Étant donné `CaptureWindow` d'une fenêtre fermée, alors l'outil répond avec le message existant de fenêtre introuvable.

#### US-109: Mode arrière-plan sous KDE
**Description:** En tant qu'Arthur, je veux le mode arrière-plan sous KDE avec les mêmes garanties que sous GNOME.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-107, US-108, US-100, US-114

**Acceptance Criteria:**
- [ ] La garde du premier plan passe par le signal `windowActivated` du script. Elle rend la fenêtre de l'utilisateur en moins de 200 ms et suit la règle du geste de US-101.
- [ ] `app_launch` et la restauration d'une fenêtre minimisée laissent la fenêtre de l'utilisateur active (40 fois sur 40 pour la restauration, audit 4.2).
- [ ] Sous KDE, le témoin de US-100 lit la fenêtre active et le curseur par un script KWin du banc, distinct de celui du serveur, et les changements de propriétaire du presse-papiers par `ext-data-control`. Tout mouvement du curseur non demandé par le banc est une violation.
- [ ] `zig build session -- kde selftest --background` passe `bg-loop` (1 000 actions, 0 violation) et détecte `bg-must-catch`.
- [ ] `neo-compute occlusion-probe linux` (US-114) tourne dans la session `kde`. Le verdict de A31 sous KDE est consigné dans 0014, et les règles de `a11y.zig` reçoivent les situations KDE mesurées.
- [ ] Étant donné un geste capable de changer la fenêtre active (clic physique hors de la fenêtre de l'utilisateur), alors aucune restauration n'a lieu.

---

### EP-028: wlroots (sway, labwc)

Porter les modes `a11y` et `vision` sous les compositeurs wlroots par leurs protocoles, l'IPC de sway et un gardien de relâche (chantier L9, P3). Livraison 3.

**Definition of Done:** `zig build session -- sway selftest` passe, entrée comprise par `--physical-input simulated`. Les contrôles de liste, de capture, d'entrée et de presse-papiers passent dans `zig build session -- labwc selftest`. Les verdicts de A37, A42, A47 et A31 sous sway sont consignés dans 0014.

#### US-110: Pointeur et clavier virtuels sous wlroots
**Description:** En tant que Claude Code, je veux la vraie souris et le vrai clavier sous wlroots, texte hors disposition compris, afin de piloter sway comme GNOME.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-080, US-075, US-076, US-081, US-067 (P3, P12)

**Acceptance Criteria:**
- [ ] Le pointeur passe par `zwlr_virtual_pointer_v1`, en mouvement absolu sur l'étendue de l'écran. Le contrôle `mouse` sous sway fait 20 `left_click` sur le canevas de la fixture, reçus à ≤ 1 px des points visés.
- [ ] Le clavier passe par `zwp_virtual_keyboard_v1`, avec une keymap compilée par libxkbcommon. Le contrôle `keyboard` sous sway tape `a`, `;`, `ctrl+a` et `shift+Tab`, et la fixture rapporte les keysyms et les modificateurs attendus.
- [ ] Les keysyms d'un texte hors disposition sont ajoutés à la keymap sur des keycodes libres, avec une attente de 200 ms après chaque nouvelle keymap, car la première touche est perdue (audit 4.3). Le contrôle `type-unicode` sous sway vérifie « é ü 😀 中文 » dans la fixture.
- [ ] `--physical-input simulated` n'est accepté que dans un banc (P12) : le selftest y envoie des gestes physiques simulés par un descripteur, pour que les contrôles d'entrée tournent sur le banc sans `/dev/input` (US-121).
- [ ] Étant donné ni `--physical-input evdev` ni `--physical-input simulated`, alors les outils d'entrée répondent « Entrée réelle indisponible sous <compositeur> : aucun kill switch sans --physical-input evdev (lecture de /dev/input). Relance neo-compute avec cette option si tu l'acceptes. » et rien n'est envoyé.
- [ ] Étant donné `--physical-input simulated` hors d'un banc (`NC_SESSION` absent, ou `XDG_RUNTIME_DIR` hors de `/run/user/<uid>/nc-`), alors le serveur refuse de démarrer avec « --physical-input simulated est réservé aux bancs de test. »

#### US-121: Gardien de relâche et entrée physique sous wlroots
**Description:** En tant qu'Arthur, je veux qu'aucune touche ne reste enfoncée sous sway même si le serveur est tué, et que mes gestes physiques mettent l'agent en pause, afin que l'entrée réelle reste sous mon contrôle.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-110, US-072

**Acceptance Criteria:**
- [ ] Au démarrage, avant le filtre seccomp et avant tout fil, le serveur crée par `fork`, sans `exec`, un processus gardien (`wlroots/guardian.zig`) qui ouvre sa propre connexion Wayland et reçoit par un tube le journal des touches et des boutons tenus.
- [ ] Quand le tube se ferme, le gardien appuie puis relâche chaque touche et chaque bouton du journal, puis sort.
- [ ] Le contrôle `release-sigkill` sous sway voit Maj relâchée moins de 50 ms après le SIGKILL du serveur. Le verdict de A37 est consigné dans 0014.
- [ ] Les contrôles `release-eof`, `release-sigint` et `release-sigterm` passent sous sway en moins de 50 ms.
- [ ] Le contrôle `virtual-no-evdev` liste `/dev/input` avant et après la création du pointeur et du clavier virtuels sous sway sans écran, et n'y trouve aucun nœud nouveau. Le verdict de A42 est consigné dans 0014.
- [ ] Avec `--physical-input evdev`, le serveur lit les `input_event` de `/dev/input/event*` ; tout événement lu est physique (A42). Un test lit des événements enregistrés dans `tests/linux/golden/evdev/` et rend les mouvements et les touches attendus.
- [ ] Les contrôles `kill-mouse` (9 px) et `kill-escape` passent sous sway par `--physical-input simulated` : l'action est annulée et le serveur passe en pause en moins de 100 ms.
- [ ] Arthur lance `neo-compute selftest --real-session --physical-input evdev` dans une vraie session sway, avec une lecture de `/dev/input/event*` qu'il s'accorde lui-même pour cette passe. `kill-mouse` et `kill-escape` y passent sur ses gestes physiques, et le verdict de A42 sur la session réelle est consigné dans 0014.
- [ ] Étant donné `--physical-input evdev` sans droit de lecture sur `/dev/input/event*`, alors le serveur l'écrit au démarrage et refuse les outils d'entrée avec « Lecture de /dev/input refusée : ajoute une règle d'accès ou le groupe input, en sachant qu'il donne la lecture de tous les claviers. »

#### US-111: Fenêtres sous wlroots
**Description:** En tant que Claude Code, je veux lister, activer et ranger les fenêtres sous sway et labwc afin d'utiliser `window_list`, `window_focus` et `window_set` sous wlroots.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-079, US-075, US-076, US-081

**Acceptance Criteria:**
- [ ] La liste des fenêtres vient de `ext-foreign-toplevel-list`. Sous sway, l'IPC `get_tree`, parlé en natif sur `$SWAYSOCK`, la complète : géométrie, pid, `app_id`, focus. Le contrôle `windows-list` y trouve la fixture et le leurre en moins de 5 ms au p95.
- [ ] Sous sway, `window_focus`, le déplacement, la taille et la fermeture passent par l'IPC (contrôle `windows-manage`, budget de 20 ms au p95).
- [ ] Ailleurs que sous sway, activer, minimiser et fermer passent par `wlr-foreign-toplevel-management`. Le contrôle `windows-manage` sous labwc les vérifie.
- [ ] La liste ne porte aucun rang d'empilement, et `{occluded}` n'est jamais posé sous wlroots, faute d'empilement (D1).
- [ ] Étant donné labwc, alors `window_set` avec position ou taille répond « labwc n'offre pas de déplacement ni de redimensionnement aux clients : seules l'activation, la minimisation et la fermeture sont possibles. »

#### US-122: Capture sous wlroots
**Description:** En tant que Claude Code, je veux capturer l'écran et une fenêtre recouverte sous sway et labwc, mots de passe masqués, afin de faire une passe visuelle sous wlroots.

**Priority:** P2
**Size:** M (3 pts)
**Dependencies:** Blocked by US-111, US-089, US-114

**Acceptance Criteria:**
- [ ] `capture` passe par `ext-image-copy-capture` (source sortie), sinon par `zwlr_screencopy_manager_v1`. `screenshot` tient 30 ms au p95 sous sway.
- [ ] `captureWindow` passe par `ext-image-copy-capture` avec une source `ext-foreign-toplevel`, recouverte comprise (2,1 ms mesurés, audit 4.3). Le contrôle `capture-covered` sous sway et labwc montre la fixture et non ce qui la couvre.
- [ ] Dans `screenshot` avec `window`, les champs mot de passe sont noirs, placés par les coordonnées AT-SPI relatives à la fenêtre (contrôle `password-mask-image` sous sway et labwc).
- [ ] Étant donné une capture de l'écran entier sous labwc, où aucune géométrie de fenêtre n'est connue, et une fenêtre active qui contient un champ mot de passe, alors la capture est refusée avec « Capture de l'écran refusée sous labwc : la fenêtre active contient un champ mot de passe dont la position est inconnue. Capture la fenêtre avec window. »
- [ ] Étant donné un compositeur sans `ext-image-copy-capture` ni screencopy, alors la capacité de capture est absente avec sa raison.
- [ ] `neo-compute occlusion-probe linux` (US-114) tourne dans la session `sway`. Le verdict de A31 sous sway est consigné dans 0014.

#### US-112: Presse-papiers, libellé, pointeur et limites sous wlroots
**Description:** En tant que Claude Code, je veux le presse-papiers et le libellé sous wlroots, et des refus clairs pour ce que wlroots ne permet pas.

**Priority:** P2
**Size:** S (2 pts)
**Dependencies:** Blocked by US-111, US-121, US-067 (P3, P9)

**Acceptance Criteria:**
- [ ] `clipboard` passe par `ext-data-control`, sinon par `zwlr_data_control`, sans focus (20 fois sur 20, audit 4.3).
- [ ] Le libellé est une surface layer-shell avec une région d'entrée vide.
- [ ] Étant donné `cursor_position` sous wlroots, alors l'outil répond « Position du pointeur inconnue sous <compositeur> : aucun protocole ne la donne. » (audit 4.3).
- [ ] Étant donné `--mode background` sous wlroots, alors le serveur refuse de démarrer le mode avec « Mode arrière-plan indisponible sous <compositeur> : aucun protocole ne donne l'empilement des fenêtres. Relance en mode a11y. »
- [ ] Le contrôle `locked` lance swaylock sur le banc sway : aucune fenêtre de `ext-foreign-toplevel` n'est alors active, et les outils d'entrée et de capture répondent avec le message existant de session inactive. Le verdict de A47 est consigné dans 0014.
- [ ] Étant donné `LockedHint` à vrai sur la session logind du serveur (faux logind du banc, US-075), alors les outils d'entrée et de capture répondent avec le message existant de session inactive.
- [ ] Étant donné une fenêtre active dont l'identifiant d'application figure dans la liste des agents polkit connus (`src/backend/linux/common/system_dialogs.zig`), alors les outils d'entrée sont refusés avec le message de dialogue système de US-119 (contrôle `system-dialog`, fixture lancée avec un `--app-id` de la liste).

---

### EP-029: Chromium et Electron sous Linux

Rendre lisible l'arbre web de Chromium sous Linux, et régler les heuristiques de recouvrement sur des mesures Linux (chantier L13, D13). Livraison 2.

**Definition of Done:** Dans la session `gnome`, un Chrome lancé par `app_launch` expose l'arbre de la page de fixture, un Chrome lancé sans accessibilité donne le message de cause, et le verdict de A31 sous GNOME est consigné dans 0014. Les verdicts sous KDE et sway appartiennent à US-109 et US-122.

#### US-113: Accessibilité de Chromium et Electron au lancement
**Description:** En tant que Claude Code, je veux que les navigateurs Chromium et les applications Electron que je lance exposent leur arbre web, et une explication quand ils ne le font pas.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-099, US-086

**Acceptance Criteria:**
- [ ] `app_launch` ajoute `--force-renderer-accessibility` à la ligne de commande et `ACCESSIBILITY_ENABLED=1` à l'environnement d'une application Chromium ou Electron. Une application est reconnue comme telle quand `resources.pak` ou `chrome_100_percent.pak` se trouve à côté de son exécutable (mesuré pour Chrome, Helium, Cursor, Proton Pass et ChatGPT, Research Findings).
- [ ] Le contrôle `electron-a11y` lance Cursor par `app_launch` dans la session `gnome` et trouve son éditeur dans `ui_tree`. Le verdict de A46 est consigné dans 0014. Étant donné Cursor absent, alors le contrôle est noté `skipped` avec sa raison.
- [ ] Un Chrome lancé ainsi expose le document de la page de fixture et ses contrôles dans `ui_tree`.
- [ ] Étant donné une fenêtre Chromium dont le cadre n'a qu'un enfant nul (`/org/a11y/atspi/null`, audit 5.2), alors `ui_tree` répond « Chrome lancé sans accessibilité : ferme-le et relance-le par app_launch. »
- [ ] Étant donné Chrome déjà ouvert sans le drapeau, alors `app_launch` de Chrome répond « Chrome tourne déjà sans accessibilité : la nouvelle fenêtre rejoint ce processus. Ferme Chrome puis relance-le par app_launch. ». La raison : un second lancement rejoint le processus existant et ignore ses drapeaux.

#### US-114: Sonde A31 : Chromium recouvert sous GNOME
**Description:** En tant qu'Arthur, je veux mesurer comment l'arbre d'un Chrome recouvert suit les actions sous GNOME, avec une sonde que KDE et sway reprendront, afin que les verdicts de `ui_act` restent vrais sous Linux.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-113, US-096

**Acceptance Criteria:**
- [ ] `neo-compute occlusion-probe linux`, dans la session `gnome`, mesure pour une page lente (1 changement par seconde) et une page animée (toutes les 50 ms) :
  - si l'arbre suit une action quand Chrome est en vue ;
  - quand il est recouvert ;
  - quand il est recouvert avec une capture de fenêtre en cours.
- [ ] La sonde prend la famille de la session courante, pour que US-109 et US-122 la relancent sous KDE et sway sans la modifier.
- [ ] Le verdict de A31 sous GNOME est consigné dans 0014. Les règles `lagging`, `renders_covered` et `frozen_*` de `src/core/a11y.zig` reçoivent les applications et les situations Linux mesurées, sans changer les règles Windows (test du cœur).
- [ ] Étant donné une situation où l'arbre est figé, alors `ui_act` sur un élément du document web de cette fenêtre répond « délivré, effet non vérifiable », avec la ligne de l'arbre figé, comme sous Windows (US-066).

---

### EP-030: Bench Linux

Mesurer les chemins Linux contre les budgets absolus du produit et une baseline Linux (chantier L14). Livraison 2.

**Definition of Done:** `zig build bench -- --check bench/baseline-linux.json` passe sous Linux avec tous les scénarios de la baseline, et aucun scénario ne rend `unsupported`.

#### US-115: Scénarios Linux et baseline
**Description:** En tant que développeur, je veux les scénarios du bench sous GNOME avec les mêmes budgets absolus que sous Windows afin qu'une régression Linux fasse échouer le gate.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-073, US-096, US-099, US-102, US-103, US-113

**Acceptance Criteria:**
- [ ] Les scénarios `capture`, `screenshot`, `window_list`, `window_set`, `ui_tree` (fixture GTK 4), `chrome`, `apps-catalog`, `apps`, `marks`, `bg-act`, `bg-settle` et `bg-capture` tournent dans la session `gnome`, avec les budgets absolus de `src/core/bench.zig` sous les mêmes noms.
- [ ] Un scénario Linux `click` mesure le temps d'un `left_click` jusqu'à la réception par la fixture. Il n'a qu'une référence, pas de budget absolu, faute d'exigence.
- [ ] `bench/baseline-linux.json` reçoit ces scénarios, mesurés par passes complètes `all` (règle d'AGENTS.md).
- [ ] Sous Linux, `zig build bench` lance le bench ReleaseFast dans une session `gnome` par `tools/linux-session` : la commande du gate ne change pas.
- [ ] Étant donné `neo-compute bench` lancé directement hors de `NC_SESSION` avec un scénario de bureau, alors il sort avec le code 2 et « bench Linux : les scénarios de bureau tournent dans une session isolée, lance zig build bench. »

---

### EP-031: Évals Linux

Rejouer les suites d'évals sous Linux dans une session GNOME isolée, avec un témoin de non-interférence, puis une campagne lancée par Arthur (chantier L15, P11). Livraison 2.

Équivalences des applications des tâches Windows (`evals/windows/tasks.json`, 21 tâches `existing`, 9 `parity`, 9 `background`) :

| Windows | Linux |
|---|---|
| Bloc-notes | GNOME Text Editor |
| Explorateur | Fichiers (Nautilus) |
| Paramètres | Paramètres de GNOME (`gnome-control-center`, A38) |
| Calculatrice | GNOME Calculator |
| VS Code | KWrite (VS Code absent de la machine) |
| Réglages (Win32), Export (WinForms) | fixtures GTK 4 de `tests/linux/fixture/` |
| Chrome | Chrome, mêmes pages |
| Registre, Firefox | retirés : D6, et Firefox absent de la machine |

**Definition of Done:** `zig build evals -- --dry-run --solve` passe toutes les tâches Linux dans la session `gnome`, avec un témoin silencieux sur la suite `background`. La campagne de US-118 est consignée dans `evals/reports/`.

#### US-116: Harnais d'évals Linux
**Description:** En tant qu'Arthur, je veux un harnais Linux qui prépare, vérifie et nettoie chaque tâche sans `claude -p` en essai, et qui ne touche jamais mon bureau, afin de préparer une campagne Linux.

**Priority:** P1
**Size:** L (5 pts)
**Dependencies:** Blocked by US-074, US-090, US-067 (P11)

**Acceptance Criteria:**
- [ ] `zig build evals -- --dry-run [--suite existing|parity|background] [--solve]` lit `evals/linux/tasks.json`. Il démarre une session `gnome` par `tools/linux-session start`, puis exécute pour chaque tâche la préparation, la vérification de l'état final et le nettoyage.
- [ ] Le harnais vérifie qu'aucun prompt `parity` ou `background` ne nomme un outil, comme `run.ps1`.
- [ ] `--solve` joue la solution scriptée de chaque tâche par `neo-compute` en stdio, et la vérification de la tâche l'accepte.
- [ ] Sans `--dry-run`, le harnais appelle `claude -p --strict-mcp-config --tools '' --allowedTools mcp__desk`, comme `evals/run.ps1:491-496`. Le serveur MCP est `tools/linux-session exec <id> -- neo-compute`, et Claude Code garde l'environnement réel d'Arthur. Cette voie est réservée à Arthur.
- [ ] Le harnais écrit `evals/reports/<date>-linux.md` au format des rapports Windows.
- [ ] Étant donné des changements non commités sous `evals/linux/` sans `--dry-run`, alors le harnais refuse de démarrer, comme `run.ps1`.
- [ ] Étant donné une tâche dont la préparation échoue, alors elle est notée en échec de harnais, la suite continue, et le code de sortie vaut 1.

#### US-117: Tâches Linux de la suite existing
**Description:** En tant qu'Arthur, je veux les équivalents Linux des 21 tâches `existing` afin de comparer les deux systèmes sur le même travail.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-116, US-096, US-098, US-099, US-113, US-124

**Acceptance Criteria:**
- [ ] Chacune des 21 tâches `existing` de `evals/windows/tasks.json` a son équivalent, de même `id`, dans `evals/linux/tasks.json`, avec l'application de la table d'équivalences de l'epic.
- [ ] Le prompt de chaque tâche nomme l'application Linux.
- [ ] La vérification de chaque tâche lit l'état final par AT-SPI, le système de fichiers ou le presse-papiers.
- [ ] La tâche canari `chrome-password` vérifie qu'aucun mot de passe n'apparaît dans la sortie de Claude ni dans l'audit (décision 0007).
- [ ] `zig build evals -- --dry-run --solve --suite existing` passe les 21 tâches dans la session `gnome`. Les trois tâches de Paramètres donnent le verdict de A38, consigné dans 0014.
- [ ] Étant donné une application absente du système, alors la tâche est notée `skipped` avec sa raison et comptée à part du taux de réussite.

#### US-123: Tâches Linux des suites parity et background
**Description:** En tant qu'Arthur, je veux les tâches `parity` et `background` sous Linux, avec un témoin de non-interférence, afin de mesurer le mode arrière-plan GNOME sur le même travail que sous Windows.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-117, US-100, US-101, US-103

**Acceptance Criteria:**
- [ ] `evals/linux/tasks.json` porte les 7 tâches `parity` transposables, de même `id`. `registry-read` et `firefox-form` y figurent comme retirées, avec leur raison (table de l'epic).
- [ ] Il porte les 9 tâches `background`, de même `id`, sous le leurre de US-100.
- [ ] Pendant chaque tâche `background`, le témoin de US-100 échantillonne toutes les 50 ms et doit rester silencieux.
- [ ] `zig build evals -- --dry-run --solve --suite parity` puis `--suite background` passent toutes les tâches dans la session `gnome`.
- [ ] Étant donné une solution scriptée témoin qui déplace le pointeur de 6 px, puis une autre qui prend le premier plan, alors le harnais signale chacune comme une violation et la tâche échoue, comme `run.ps1 -Solve`.

#### US-118: Campagne Linux
**Description:** En tant qu'Arthur, je veux lancer une campagne Linux et la comparer à la campagne Windows afin de décider si neo-compute est prêt sous Linux.

**Priority:** P1
**Size:** S (2 pts)
**Dependencies:** Blocked by US-117, US-123, US-115, US-104, US-114

**Acceptance Criteria:**
- [ ] Arthur lance `zig build evals -- --suite existing`, puis `parity` et `background`, sur son abonnement, une fois les gates passés.
- [ ] `evals/reports/<date>-linux.md` donne par suite : taux de réussite, tokens médians par delta, violations du témoin et fuites canari. Il les compare à la dernière campagne Windows.
- [ ] Les cibles de Success Metrics sont évaluées dans le rapport : ≥ 95 % sur `existing`, ≥ 85 % sur `background`, 0 violation, 0 fuite.
- [ ] Étant donné une cible manquée, alors le rapport liste les tâches en échec avec leur cause, et une question est ajoutée à Open Questions.

---

### EP-032: Sécurité et distribution

Faire respecter par le noyau les invariants de sécurité sous Linux, et livrer un binaire installable sur les distributions visées (chantiers L16 et L17). US-119 en livraison 1, US-120 en livraison 2.

**Definition of Done:**
- Le test de sécurité prouve qu'un `connect` réseau du serveur échoue, et le contrôle `app-launch` qu'une application lancée n'hérite pas du filtre.
- Les archives x86_64 et aarch64 se construisent, et le verdict de A45 est consigné.
- Le serveur répond à `initialize` dans des conteneurs Fedora 45, Ubuntu 22.04 et Ubuntu 26.04.
- L'installation d'Arthur sur sa session Fedora est consignée.

#### US-119: Invariants de sécurité Linux
**Description:** En tant qu'Arthur, je veux que le noyau interdise le réseau au serveur, et que le serveur refuse d'agir sur ce qui n'est pas à moi ou sur un écran verrouillé, afin que les invariants tiennent même face à un défaut du code.

**Priority:** P0
**Size:** M (3 pts)
**Dependencies:** Blocked by US-082, US-072, US-084, US-099, US-067 (P9, P10)

**Acceptance Criteria:**
- [ ] Le contrôle `app-launch` lit `Seccomp:` à 2 (filtre) dans `/proc/<pid>/status` du serveur, et à 0 pour la fixture lancée par `app_launch`.
- [ ] Au démarrage, après la création du processus lanceur (US-099) et, sous wlroots, du gardien (US-121), et avant tout fil, le serveur pose un filtre seccomp qui fait échouer `socket` avec `EPERM` pour les familles `AF_INET`, `AF_INET6` et `AF_PACKET`. Les sockets `AF_UNIX` restent permis (FR-10).
- [ ] Un test de `tests/process_test.zig` lance le serveur avec une sous-commande de test qui tente un `connect` TCP vers 127.0.0.1. Le test lit `EPERM` sur stderr.
- [ ] Étant donné la pose du filtre qui échoue, simulée par un point d'injection des tests de `tests/process_test.zig`, alors le serveur refuse de démarrer avec « Filtre réseau impossible (seccomp indisponible) : neo-compute ne démarre pas sans lui. »
- [ ] Un test du backend Linux, avec un lecteur de `/proc` simulé qui rend un autre uid pour le pid d'une fenêtre, prouve que toute action et toute capture de cette fenêtre sont refusées avec « <application> appartient à un autre utilisateur : refusé. »
- [ ] Étant donné un dialogue modal du Shell ouvert, comme l'agent polkit (`Main.modalCount` > 0), alors les outils d'entrée sont refusés avec « Un dialogue système est ouvert (<nom>) : réponds-y toi-même. Aucune action exécutée. » Le contrôle `system-dialog` ouvre ce dialogue par une méthode de test de l'extension, acceptée en `NC_SESSION` seulement.
- [ ] Un selftest `security` vérifie les deux sens de la confiance : l'extension refuse un appelant étranger, et le serveur refuse une extension dont le propriétaire n'est pas le Shell.

#### US-120: Archives de distribution et installation
**Description:** En tant que développeur sous Linux, je veux une archive par architecture, un `setup` et une ligne `claude mcp add` afin d'installer neo-compute sans le construire.

**Priority:** P1
**Size:** M (3 pts)
**Dependencies:** Blocked by US-082, US-091, US-097, US-067 (P7)

**Acceptance Criteria:**
- [ ] `zig build release` produit `neo-compute-<version>-x86_64-linux.tar.gz` et `neo-compute-<version>-aarch64-linux.tar.gz`. Chacune contient le binaire ReleaseFast strippé pour `*-linux-gnu.2.28`, son `.sha256` et un `README`.
- [ ] Le binaire ne déclare dans `NEEDED` que des bibliothèques de la glibc. libpipewire et libxkbcommon sont chargées par `dlopen`.
- [ ] Le binaire x86_64 répond à `initialize` dans des conteneurs (podman) Fedora 45, Ubuntu 22.04 et Ubuntu 26.04.
- [ ] Le binaire aarch64 répond à `initialize` dans un conteneur Ubuntu 26.04 `--arch arm64` sous `qemu-aarch64-static` (paquet `qemu-user-static`, absent de la machine, à installer par Arthur). Le verdict de A45 est consigné dans 0014.
- [ ] Étant donné aucun émulateur aarch64 installé, alors `zig build release` construit l'archive aarch64 avec `-UNVERIFIED` dans son nom, et le rapport le signale en tête.
- [ ] Le binaire strippé fait moins de 3 MB (A39). Sinon, le rapport donne sa taille par module et le signale en tête.
- [ ] Le `README` donne `neo-compute setup`, la reconnexion, puis `claude mcp add -s user neo-compute -- <chemin>`, avec la vérification par `claude mcp list` d'AGENTS.md.
- [ ] Arthur installe l'archive sur sa session Fedora 45 et sur une machine virtuelle Ubuntu 26.04 (GNOME 50, A36), puis lance `selftest --real-session`. Les résultats sont consignés dans 0014.
- [ ] Étant donné une glibc antérieure à 2.28, alors le chargeur refuse le binaire. Le `README` nomme ce plancher et les distributions qui le respectent.

---

## Functional Requirements

- FR-48: Sous Linux, un binaire unique identifie à l'exécution la famille de compositeur (GNOME, KDE, wlroots). Un outil qui exige une capacité absente répond par un message qui nomme la capacité, la cause et l'action suivante (FR-06).
- FR-49: Sous Linux, les outils gardent leurs noms et paramètres. `registry_read` n'est listé que par un backend qui fournit `registryValue`.
- FR-50: Sous GNOME, les outils d'entrée envoient de vrais événements de pointeur et de clavier par le canal EI de la session `org.gnome.Mutter.RemoteDesktop` (D14).
- FR-51: Aucun caractère passé à `type` n'est perdu sans erreur : un caractère qui ne peut pas être tapé fait échouer l'appel avant tout envoi.
- FR-52: Sur SIGINT, SIGTERM et SIGHUP, le serveur relâche toute entrée tenue et sort en moins de 50 ms. À sa mort, le compositeur ou un gardien relâche en moins de 50 ms (étend FR-07).
- FR-53: Une entrée réelle n'est envoyée que si un kill switch par entrée physique est actif sur la famille courante. Seule exception, dans un banc (P12) : des gestes physiques simulés remplacent la source physique.
- FR-54: Le serveur ne modifie aucun réglage du système de l'utilisateur, sauf par `neo-compute setup`. Seule exception : l'écriture de `toolkit-accessibility` que fait at-spi2-core quand le serveur s'abonne aux événements (D13).
- FR-55: L'extension GNOME et le script KWin n'acceptent que les appels du serveur. Le serveur vérifie que leur nom appartient au Shell ou à KWin.
- FR-56: En mode serveur, neo-compute n'exécute aucun programme lui-même. Seul `app_launch` fait exécuter une application, sans shell, par le processus lanceur créé au démarrage ; le gardien wlroots est une copie du serveur, sans `exec`. Les sous-commandes de test (`selftest`, sondes) lancent leurs fixtures.
- FR-57: Un filtre seccomp posé au démarrage, après la création du lanceur et du gardien, interdit au serveur toute socket réseau (fait respecter FR-10). Les applications lancées n'en héritent pas.
- FR-58: Les selftests, le bench et les évals Linux tournent dans une session isolée. Un témoin vérifie que la session réelle n'a pas changé.
- FR-59: Sur chaque famille, le serveur refuse d'agir sur un écran verrouillé, pendant un dialogue système modal, et sur une fenêtre d'un autre uid. Signaux : `ScreenSaver.GetActive` et `Main.modalCount` sous GNOME ; `org.freedesktop.ScreenSaver.GetActive` et la fenêtre active de l'agent polkit sous KDE ; aucune fenêtre active, `LockedHint` et la liste des agents polkit sous wlroots (A47).
- FR-60: L'action `Peek` n'est jamais appelée, et ni le texte ni la longueur d'un mot de passe ne sortent (étend FR-09).
- FR-61: Le serveur n'appelle jamais `RemoteDesktop.SetKeymap`, `ScreenSaver.SetActive` ni `org_kde_kwin_fake_input`.

## Non-Functional Requirements

- **Performance** (budgets de `src/core/bench.zig`, mêmes noms de scénarios) :
  - `capture` < 8 ms p95 ; `screenshot` < 30 ms p95 ; `marks` < 8 ms au-delà de `screenshot` ;
  - `ui_tree` < 50 ms p95 sur la fixture ; `chrome` < 120 ms p95 ;
  - `window_list` < 5 ms p95 ; `window_set` < 20 ms p95 ;
  - `apps-catalog` < 300 ms ; `apps` < 1 ms ;
  - `bg-act` < 20 ms p95 ; `bg-settle` < 150 ms p95 (étape `settle`) ; `bg-capture` < 60 ms p95 ;
  - relâche < 50 ms (FR-07) ; pause < 100 ms (FR-36) ; restauration du premier plan < 200 ms ; réaction de `ui_find` `wait_ms` < 100 ms (PRD background).
- **Footprint :** binaire ReleaseFast strippé ≤ 3 MB (A39) ; 0 allocation du GPA par requête en régime établi (AGENTS.md) ; attente de `ui_find` < 5 % d'un cœur.
- **Security :** 0 socket réseau (test seccomp) ; 0 appel des membres interdits de FR-61 (test du générateur) ; 0 création de processus hors des sites admis par FR-56 (`launch.zig`, `guardian.zig`, fichiers de selftest et de sonde ; test du build) ; 0 fuite sur les tâches canari.
- **Reliability :** 0 différence du témoin des bancs sur 20 cycles par famille ; 0 violation sur 1 000 actions `bg-loop` sous GNOME et KDE.
- **Compatibility :** glibc ≥ 2.28, x86_64 et aarch64 ; GNOME 50 et 51, Plasma 6.8, sway 1.12, labwc 0.20 (P6).

## Edge Cases & Error States

| # | Scenario | Trigger | Expected Behavior | User Message |
|---|----------|---------|-------------------|--------------|
| 1 | Capacité absente | Outil qui exige une capacité que la famille n'a pas | Aucune action | « Linux (<famille>) : <capacité> indisponible, <raison>. <action suivante>. » |
| 2 | Session X11 | `DISPLAY` sans `WAYLAND_DISPLAY` | Action et capture refusées | « Session X11 : non prise en charge dans cette version. Ouvre une session Wayland (GNOME, KDE ou sway). » |
| 3 | Extension absente sous GNOME | Pas de `setup`, ou pas de reconnexion | Mode réduit : AT-SPI et ScreenCast ; entrée refusée (P1) | « Entrée réelle indisponible : sans l'extension GNOME, aucun kill switch ne peut détecter tes gestes. Lance neo-compute setup puis reconnecte-toi. » |
| 4 | Extension d'une autre version | Binaire mis à jour sans `setup` | Outils qui en dépendent refusés | « Extension GNOME de version <x>, serveur <y> : relance neo-compute setup puis reconnecte-toi. » |
| 5 | Appelant étranger de l'extension | Un autre processus appelle `org.neocompute.Shell1` | `AccessDenied` | (aucun : erreur D-Bus) |
| 6 | Extensions utilisateur désactivées | `disable-user-extensions` vaut `true` | `setup` ne change rien | « Les extensions utilisateur sont désactivées dans GNOME : active-les dans Extensions, puis relance neo-compute setup. » |
| 7 | Caractère hors disposition | `type` avec « é » en disposition `us`, sans voie de US-092 | Rien n'est envoyé | « Caractères absents de la disposition <nom> : <liste>. Aucune touche envoyée. » |
| 8 | Session RemoteDesktop fermée | Mutter ferme la session (verrou, redémarrage) | Action en cours en échec, session rouverte à l'action suivante | « Session d'entrée fermée par GNOME : relance l'action. » |
| 9 | Écran verrouillé | `ScreenSaver.GetActive` à `true` | Entrée et capture refusées, entrées tenues relâchées | Message existant de session inactive |
| 10 | Dialogue système modal | Agent polkit ouvert (Shell, KDE ou wlroots) | Entrée refusée | « Un dialogue système est ouvert (<nom>) : réponds-y toi-même. Aucune action exécutée. » |
| 11 | Fenêtre d'un autre uid | Application lancée par un autre utilisateur | Action et capture refusées | « <application> appartient à un autre utilisateur : refusé. » |
| 12 | Application figée | Fil principal bloqué ou SIGSTOP | `{partial: timeout}` en < 250 ms, autres applications lues | Message existant de fenêtre figée |
| 13 | Case GTK 4 sans action | `check` sur une case GTK 4 | Rien n'est envoyé | « <élément> n'expose aucune action AT-SPI (GTK 4) : impossible de le cocher sans entrée. En mode a11y, clique-le avec left_click. » |
| 14 | Champ web sans écriture | `set_value` sur un champ de Chrome | Rien n'est envoyé | « <élément> n'accepte pas d'écriture AT-SPI (Chromium) : tape le texte avec type après l'avoir cliqué. » |
| 15 | `Peek` demandé | `ui_act` qui vise l'action Peek d'un mot de passe | Refus | « Action Peek refusée : elle affiche le mot de passe en clair. » |
| 16 | Chrome sans accessibilité | Chrome ouvert hors `app_launch` | Arbre non lu | « Chrome lancé sans accessibilité : ferme-le et relance-le par app_launch. » |
| 17 | Chrome déjà ouvert | `app_launch` de Chrome alors qu'il tourne sans le drapeau | Pas de nouveau processus | « Chrome tourne déjà sans accessibilité : la nouvelle fenêtre rejoint ce processus. Ferme Chrome puis relance-le par app_launch. » |
| 18 | Entrée de terminal | `.desktop` avec `Terminal=true` | Refus | « <application> s'ouvre dans un terminal : refusé, aucun outil de commande (FR-11). » |
| 19 | Partage arrêté par l'utilisateur | Clic sur l'indicateur de partage de GNOME (repli ScreenCast) | Pause | « Partage d'écran arrêté par l'utilisateur : en pause. Attends qu'Arthur réarme. » |
| 20 | libpipewire ou libxkbcommon absente | Système minimal | Capacité absente | « libpipewire introuvable : … » / « libxkbcommon introuvable : installe-la pour taper du texte. » |
| 21 | Entrée sous wlroots sans evdev | Pas de `--physical-input evdev` | Entrée refusée | « Entrée réelle indisponible sous <compositeur> : aucun kill switch sans --physical-input evdev (lecture de /dev/input). Relance neo-compute avec cette option si tu l'acceptes. » |
| 22 | Arrière-plan sous wlroots | `--mode background` sous sway | Mode refusé | « Mode arrière-plan indisponible sous <compositeur> : aucun protocole ne donne l'empilement des fenêtres. Relance en mode a11y. » |
| 23 | Serveur figé | SIGSTOP pendant `hold_key` | Les touches restent tenues (limite documentée) | (aucun) |
| 24 | Selftest sur la session réelle | `neo-compute selftest` hors banc | Refus | « selftest injecte des entrées : lance-le par zig build session, ou ajoute --real-session sur ta propre session. » |
| 25 | Seconde instance | Deux serveurs sur le même affichage | Actions refusées (FR-14) | Message existant d'instance |
| 26 | `XDG_RUNTIME_DIR` absent | Serveur lancé hors session graphique | Actions refusées | « XDG_RUNTIME_DIR absent : impossible de garantir une seule instance. Lance neo-compute depuis une session graphique. » |
| 27 | Compositeur déconnecté | Fin de session Wayland | Requêtes en échec, pas de plantage | « Compositeur Wayland déconnecté : relance la session graphique. » |
| 28 | Fenêtre minimisée capturée | `screenshot` avec `window` sur une fenêtre minimisée (GNOME) | Pas d'image | « Fenêtre minimisée : restaure-la avec window_set (state normal). » |
| 29 | Raccourci de pause injecté | `key` avec la combinaison du raccourci de pause (KDE) | Refus, rien n'est envoyé | « Combinaison réservée au raccourci de pause de neo-compute : refusée. » |
| 30 | Capture d'écran sous labwc avec mot de passe | Fenêtre active avec un champ mot de passe, géométrie inconnue | Capture refusée | « Capture de l'écran refusée sous labwc : la fenêtre active contient un champ mot de passe dont la position est inconnue. Capture la fenêtre avec window. » |
| 31 | Option de test hors banc | `--physical-input simulated` hors d'un banc (P12) | Démarrage refusé | « --physical-input simulated est réservé aux bancs de test. » |
| 32 | Document sans application | `app_launch` d'un fichier dont le type n'a pas d'application par défaut | Rien n'est lancé | « Aucune application pour <type> : ouvre le fichier avec une application nommée. » |

## Risks & Mitigations

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | L'extension ne distingue pas l'entrée physique (A24 infirmée) : pas de kill switch fiable sous GNOME | Med | High | Sonde US-083 sur la session réelle avant US-094 ; repli par soustraction (D4) ; entrée refusée tant que P1 n'est pas tenu |
| 2 | La capture par l'extension est trop lente ou fausse (A25 infirmée) | Med | Med | Sonde US-095 ; repli ScreenCast (US-097) devenu P0 ; indicateur de partage accepté (D11) |
| 3 | GNOME réserve RemoteDesktop au portail (gnome-shell #3943) | Low | High | Entrée bâtie sur EI : seul l'accès au descripteur change (D3) ; portail RemoteDesktop déjà prévu en repli |
| 4 | L'API des extensions change à chaque version majeure de GNOME | High | Med | `shell-version` limité aux versions mesurées (P6) ; refus explicite d'une version inconnue ; banc gnome-shell sans écran pour chaque version |
| 5 | Une vraie session Plasma demande une autorisation que KWin sans écran ne demande pas (A27) | Med | Med | Sonde US-105 avant EP-027 ; portail en repli (D3) |
| 6 | Les bancs touchent encore la session réelle | Low | High | Témoin à chaque cycle (US-074) ; code de sortie 3 ; isolations de l'audit 9.2 imposées par le lanceur |
| 7 | Un défaut des transports natifs (alignement D-Bus, identifiants Wayland) | Med | Med | Générateur depuis XML épinglés ; tests d'octets contre des traces réelles ; messages corrompus testés |
| 8 | La couche C (libpipewire, libxkbcommon) fait apparaître des défauts Zig | Med | Med | Surface limitée à `dlopen` ; défauts comptés pour la condition 3 (D12) |
| 9 | `SetKeymap` ou `SetActive` appelés par erreur (plantage de Mutter, déverrouillage) | Low | High | Liste de refus du générateur et tests (US-091, US-094, FR-61) |
| 10 | Un mot de passe sort par AT-SPI (puces, `Peek`) ou par une capture | Low | High | FR-60 ; image refusée sans balayage complet (FR-42) ; tâche canari Linux |
| 11 | Chrome recouvert rend un arbre figé sous Linux (A31) | High | Med | Sonde US-114 ; verdict « non vérifiable » comme sous Windows |
| 12 | Une évolution du cœur casse Windows | Med | High | Gates Windows obligatoires pour toute story qui touche le cœur ou le build ; tests de comparaison d'octets (US-071) |
| 13 | 58 stories dépassent une livraison | High | Low | Trois livraisons ; la livraison 1 rend GNOME utilisable seule |
| 14 | Les selftests reposent sur Python (fixture) | Low | Low | `python3 -I` ; contrôles notés `skipped` avec leur raison si PyGObject manque |
| 15 | Le serveur figé par SIGSTOP garde ses touches | Low | Med | Limite documentée (US-093) ; hors du chemin d'arrêt de Claude Code, qui envoie SIGINT, SIGTERM puis SIGKILL |
| 16 | Les applications lancées héritent du filtre seccomp et perdent le réseau | High | High | Processus lanceur créé avant le filtre (T9, US-099) ; contrôle `app-launch` de US-119 qui lit `Seccomp:` à 0 pour l'application lancée |
| 17 | La détection par soustraction ne suffit pas comme kill switch sous KDE (A41 infirmée) | Med | High | Sonde US-105 sur une vraie session Plasma avant US-107 ; repli evdev sur activation explicite (D4) |
| 18 | Une entrée injectée tape dans l'invite de déverrouillage sous wlroots, et des échecs répétés bloquent le compte | Low | High | Signaux de verrou de A47 vérifiés avec swaylock (US-112) ; entrée réelle wlroots seulement sur activation explicite (P3) |

## Open Questions

- **Q20 :** Zig 0.17.1, installé sur la machine Linux, remplace-t-il 0.17.0, épinglé ? La version de Zig est un choix de contrat d'Arthur. Sans réponse, les gates tournent avec 0.17.0 (US-068).
- **Q21 :** COSMIC et un backend X11 natif font-ils l'objet d'un PRD séparé ? À décider après la campagne US-118 (D1).
- **Q22 :** faut-il un canal de distribution au-delà de l'archive (plugin Claude Code, COPR, publication de l'extension) ? À décider après US-120.
- **Q23 :** IPC de Hyprland et de niri : faut-il les ajouter quand un banc existe ? Aujourd'hui, ces compositeurs ne sont pas installés.
- **Q24 :** remplacer libxkbcommon par un analyseur de keymap natif, pour viser un binaire musl statique quand la capture par l'extension suffit ? À décider après US-095 et US-120 (T3, T12).

## Files NOT to Modify

- `tests/fixtures/toolset_20260801.json` : contrat externe d'Anthropic.
- `bench/baseline.json` : baseline Windows. La baseline Linux est `bench/baseline-linux.json`.
- Les sources de `src/backend/windows/` et `src/backend/windows.zig`, sauf les imports et conditions de build qu'exige la séparation des modules (US-069), sans changement de comportement.
- `bindings/windows.zon` et le fichier `win32.zig` généré.
- `evals/windows/`, `evals/run.ps1`, `evals/night.ps1`, `evals/report.ps1`.
- L'écriture sur stdout et l'ordre du répartiteur dans `src/core/mcp.zig`.
- `docs/decisions/0001` à `0013`, sauf le compteur de la condition 3 dans `0001-zig-vs-rust.md`. Les amendements vont dans `0014`.
- `docs/research/2026-11-20-audit-portage-linux.md` et `docs/research/2026-11-17-backend-linux-gnome.md` : constats datés.
- La configuration de la session réelle d'Arthur (dconf, dossier d'extensions, `/run/user/<uid>`) : seuls `neo-compute setup` et une passe `--real-session` lancée par Arthur y touchent.
- `~/dev/agent-desktop`, `~/dev/claude-code` et le clone de computer-use-linux : références en lecture seule.
[/PRD]
