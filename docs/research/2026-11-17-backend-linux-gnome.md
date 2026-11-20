# Recherche : ce qu'un backend Linux trouvera sur GNOME Wayland (entrées, captures, accessibilité)

- Date : 2026-11-17
- Objet : consigner ce qui a été mesuré pendant la passe visuelle de l'epic EP-001 de Crow Bot (PRD `tasks/prd-crow-bot-linux-port.md` du dépôt `~/dev/crowbot`) et qui concerne un futur backend Linux de neo-compute : envoyer souris et clavier, capturer l'écran, lire l'interface. C'est un constat, pas une conception : rien n'est implémenté ici.
- Sources : l'ordinateur de référence (Fedora 45, session GNOME sur Wayland, Mutter 51.1, deux écrans de 2560 par 1440 à l'échelle 1) ; le clone local d'agent-desktop (`~/dev/agent-desktop`, commit `8ffecc1d`) ; le code de GPUI au rev `0cfc4a4` de Zed (`~/.cargo/git/checkouts/zed-*/0cfc4a4/`). Aucune source web.
- Méthode : chaque ligne porte « mesuré » (observé sur la machine par une commande citée), « vérifié » (le code ou le document cité a été lu à la ligne indiquée) ou « déduit » (conclusion tirée de ce qui a été lu ou mesuré, qu'aucune mesure ne montre directement).

Vocabulaire. Mutter est le compositeur de GNOME : le programme qui dessine les fenêtres et reçoit la souris et le clavier. Un portail (`xdg-desktop-portal`) est un service qui demande l'accord de l'utilisateur avant qu'une application touche à l'écran ou aux fichiers. PipeWire est le service qui transporte les flux audio et vidéo sous Linux. AT-SPI est l'équivalent Linux de UI Automation : le bus par lequel les applications publient leur arbre d'accessibilité. GPUI est le cadre d'interface de Zed, utilisé par Crow Bot et Paneflow.

## 1. Souris et clavier sans autorisation

Réponse courte : Mutter expose une télécommande que tout programme du compte peut ouvrir sans dialogue. C'est l'équivalent le plus proche de `SendInput` sous Windows.

| Fait | Source | Statut |
|---|---|---|
| `org.gnome.Mutter.RemoteDesktop.CreateSession` rend une session (`/org/gnome/Mutter/RemoteDesktop/Session/u2676`) sans aucune fenêtre de confirmation | `gdbus call --session --dest org.gnome.Mutter.RemoteDesktop --object-path /org/gnome/Mutter/RemoteDesktop --method org.gnome.Mutter.RemoteDesktop.CreateSession` | mesuré |
| `org.gnome.Mutter.ScreenCast` répond en version 4 | `gdbus call ... org.freedesktop.DBus.Properties.Get org.gnome.Mutter.ScreenCast Version` | mesuré |
| Une position absolue du pointeur se donne relativement à un flux ScreenCast attaché à l'écran visé : agent-desktop ouvre une session RemoteDesktop, attache un flux par connecteur d'écran (`DP-3`), puis envoie `NotifyPointerMotionAbsolute` et `NotifyPointerButton` (boutons 272, 273, 274) | `crates/linux/src/input/wayland/pointer_send.rs:14-60` | vérifié |
| agent-desktop envoie les touches et le texte par cette même télécommande sous Wayland | `crates/linux/src/input/deliver.rs:28-36`, `skills/.../references/display-servers-and-input.md` (tableau « X11 versus Wayland ») | vérifié |
| agent-desktop refuse pourtant toute commande de pointeur sur une application sous Wayland (`mouse_event`, `drag`, clic physique), alors que son transport existe : il ne sert qu'aux clics dans la barre de GNOME | `crates/linux/src/input/deliver.rs:39-79`, `crates/linux/src/input/physical/target_pointer.rs:52-54`, `:226-260` | vérifié |
| La raison du refus : sous Wayland, une application ne connaît pas la position des fenêtres à l'écran, donc une cible désignée par l'arbre d'accessibilité ne peut pas être visée. Viser des coordonnées lues sur une capture reste possible | les mêmes fichiers ; `display-servers-and-input.md` (« On Wayland the pointer cannot be aimed ») | déduit |
| Une fenêtre qu'un programme lance s'ouvre derrière la fenêtre active : GNOME lui retire l'activation (`xdg_toplevel.configure` passe de l'état activé à aucun état) et la laisse sous Paneflow ; il a fallu l'amener devant à la main | journal `WAYLAND_DEBUG=client` du client Crow Bot | mesuré |
| Sans jeton d'activation (`xdg_activation_v1`), qu'une application n'obtient qu'avec une entrée récente de l'utilisateur, aucun programme ne peut mettre une fenêtre au premier plan sous Wayland ; la télécommande de Mutter (un clic simulé sur la fenêtre, ou `super` puis une recherche) est le moyen restant | | déduit |

## 2. Captures d'écran

Réponse courte : le portail mémorise une réponse par application hôte ; ScreenCast de Mutter capture sans jamais demander.

| Fait | Source | Statut |
|---|---|---|
| La permission de capture du portail est rangée dans la table `screenshot`, clé `screenshot`, par identifiant d'application : celle de l'hôte qui lance l'agent (`paneflow` ici), pas celle de l'agent | `gdbus call ... org.freedesktop.impl.portal.PermissionStore.Lookup screenshot screenshot` rend `{'paneflow': ['no']}` puis `['yes']` | mesuré |
| Une réponse « non » enregistrée fait échouer chaque capture à l'instant, sans dialogue (réponse 2 du portail) | `agent-desktop screenshot --screen 0` : `PERM_DENIED`, « response 2 » | mesuré |
| `PermissionStore.DeletePermission screenshot screenshot paneflow` efface la réponse : le dialogue revient à la capture suivante | même commande `gdbus` | mesuré |
| Le dialogue met le focus sur « Refuser » : un Entrée accidentel enregistre un refus | `skills/.../references/capture-and-clipboard.md` (« Deny focused ») ; deux refus involontaires pendant la session | mesuré |
| Le portail ne capture pas une fenêtre seule sous Wayland, seulement un écran ; un écran se choisit par recadrage de l'image du bureau | `capture-and-clipboard.md` (« A window target is PLATFORM_NOT_SUPPORTED on Wayland ») | vérifié |
| `org.gnome.Mutter.ScreenCast` (`RecordMonitor`, `RecordWindow`) ouvert depuis un programme du compte, puis lu par PipeWire, donnerait des images sans portail ni dialogue, et une fenêtre seule ; aucune image n'a été lue ainsi pendant la session | la création de session RemoteDesktop sans dialogue (section 1) ; l'interface `ScreenCast` version 4 | déduit |

## 3. Lire l'interface

| Fait | Source | Statut |
|---|---|---|
| AT-SPI est éteint par défaut sur ce poste : `org.a11y.Status.IsEnabled` vaut `false` | `gdbus call ... org.a11y.Bus ... Get org.a11y.Status IsEnabled` | mesuré |
| Même avec `IsEnabled` à `true` et le client relancé, une application GPUI (Crow Bot) n'apparaît pas sur le bus d'accessibilité ; Paneflow n'y est pas non plus | `busctl --address=<bus a11y> list` filtré sur le pid ; `agent-desktop list-apps` (10 applications, aucune GPUI) | mesuré |
| GPUI crée pourtant un adaptateur `accesskit_unix` pour chaque fenêtre ; pourquoi il ne s'enregistre pas n'a pas été établi | GPUI `crates/gpui_linux/src/linux/wayland/window.rs:2282-2295`, `crates/gpui/src/window.rs:1776` | vérifié (adaptateur), non expliqué (absence) |
| Pour une application GPUI, la capture d'écran est donc la seule lecture possible ; l'arbre AT-SPI ne sert qu'aux applications GTK, Qt et aux navigateurs lancés avec leur drapeau d'accessibilité | les deux lignes précédentes ; `agent-desktop` skill Linux (« GPUI apps such as Paneflow expose no accessibility tree ») | déduit |
| `IsEnabled` se remet à `false` par la même propriété ; il a été rallumé quelques minutes puis éteint | `gdbus ... Set org.a11y.Status IsEnabled "<false>"` | mesuré |

## 4. Sessions et bancs d'essai

| Fait | Source | Statut |
|---|---|---|
| Fedora 45 n'a plus de session GNOME sur X11 : `/usr/share/xsessions/` ne contient que `openbox.desktop` ; `/usr/share/wayland-sessions/` contient `gnome`, `gnome-classic`, `plasma`, `sway` | `ls` des deux dossiers | mesuré |
| Une session Plasma est installée : KDE peut servir de second bureau de test | même mesure | mesuré |
| Un GNOME sans écran tourne sans toucher la session de l'utilisateur : `dbus-run-session -- mutter --headless --wayland --no-x11 --wayland-display=<nom> --virtual-monitor 1920x1080`, avec `XDG_RUNTIME_DIR` dans un dossier court et privé | sondes de la revue EP-001 | mesuré |
| Sans `--no-x11`, ce Mutter démarre Xwayland (`:2`, avec `:3` pour ses services) et écrit son cookie X dans `$XDG_RUNTIME_DIR/.mutter-Xwaylandauth.*` : il faut le passer en `XAUTHORITY` | `mutter` : « Using public X11 display :2 » ; refus « Invalid MIT-MAGIC-COOKIE-1 key » sans cookie | mesuré |
| Un chemin de socket Unix de plus de 107 octets est refusé (`SUN_LEN`) : un `XDG_RUNTIME_DIR` sous un dossier profond fait échouer le compositeur | échec « path must be shorter than SUN_LEN » | mesuré |
| `kwin_wayland --virtual --socket <nom>` sous `QT_QPA_PLATFORM=offscreen` donne un KDE sans écran ; il accepte les décorations côté client (`zxdg_toplevel_decoration_v1.configure(1)`) | journal `WAYLAND_DEBUG` | mesuré |
| Xvfb avec openbox donne un X11 privé où agent-desktop pilote vraiment le pointeur (`--headed drag`, `mouse-click --count 2`) : la fenêtre s'est déplacée de (-195, +195) puis s'est maximisée | `xdotool getwindowgeometry`, `xprop _NET_WM_STATE` | mesuré |
| Aucune de ces sessions sans écran ne se capture par le portail de l'utilisateur ; une capture y passe par le serveur X (Xvfb) ou devrait passer par le ScreenCast du Mutter privé | | déduit |

## 5. Ce qui reste ouvert pour neo-compute

- Lire une image d'un flux ScreenCast de Mutter par PipeWire depuis Zig : coût, latence, et capture d'une fenêtre recouverte (`RecordWindow`).
- La politique de neo-compute face à une télécommande sans consentement : sous Windows, `SendInput` n'en demande pas non plus ; le garde (kill switch, relâchement des touches en 50 ms) doit couvrir la session RemoteDesktop de la même façon.
- Une session GNOME verrouillée ou en économie d'écran : non mesuré.
- KDE : Plasma a son propre accès (KWin, portail RemoteDesktop avec jeton de restauration) ; rien n'a été mesuré au-delà du point de la section 4.
