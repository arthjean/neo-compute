#!/bin/sh
# US-075: a KDE test session kept past KWin's automatic lock (5 min,
# audit 4.2) starts no kscreenlocker_greet. Run inside the session:
#   zig-out/bin/linux-session kde exec -- sh tests/linux/session/kde_no_lock.sh [SECONDS]
# The launcher's witness checks the user's real LockedHint before and after.
seconds=${1:-370}
[ -n "$NC_SESSION_ID" ] || { echo "kde_no_lock.sh: à lancer dans une session de tools/linux-session" >&2; exit 2; }
elapsed=0
while [ "$elapsed" -lt "$seconds" ]; do
    for p in $(pgrep -f kscreenlocker_greet); do
        if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "NC_SESSION_ID=$NC_SESSION_ID"; then
            echo "kscreenlocker_greet démarré après $elapsed s (pid $p)" >&2
            exit 1
        fi
    done
    sleep 10
    elapsed=$((elapsed + 10))
done
echo "aucun kscreenlocker_greet en $seconds s"
