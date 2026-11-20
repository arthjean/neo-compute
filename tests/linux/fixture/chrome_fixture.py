"""Opens tests/linux/pages/fixture.html in Chrome and writes its events to
NC_FIXTURE_LOG (US-076).

Run with `python3 -I` inside a test session (tools/linux-session). The page
logs each event to the console as "NCFIX <json>"; Chrome writes console
messages to its stderr with --enable-logging=stderr, and this wrapper
copies each such line to the log. Chrome gets a profile of its own under
the session's HOME (without it, Chrome hands the page to the user's own
Chrome), the accessibility tree from the start, and its background
network services off.

  chrome_fixture.py [--kiosk] [--page FILE] [-- extra Chrome flags]

Exits with Chrome's code; 77 when Chrome is not installed.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

CONSOLE = re.compile(r'"NCFIX (.*)", source: ')
HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(os.path.dirname(HERE), "pages", "fixture.html")


def enable_accessibility():
    """Chrome builds its AT-SPI tree only when org.a11y.Status says
    accessibility is on when it starts (audit 5.2); in a test session
    nothing has turned it on yet. The AT-SPI bus launcher keeps the value
    in the session's private dconf, never the real one."""
    try:
        import gi

        gi.require_version("Gio", "2.0")
        from gi.repository import Gio, GLib

        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        bus.call_sync(
            "org.a11y.Bus", "/org/a11y/bus", "org.freedesktop.DBus.Properties", "Set",
            GLib.Variant("(ssv)", ("org.a11y.Status", "IsEnabled", GLib.Variant("b", True))),
            None, Gio.DBusCallFlags.NONE, 2000, None,
        )
    except Exception as err:  # noqa: BLE001 - the page still runs, without its tree
        print(f"chrome_fixture.py : accessibilité non activée ({err})", file=sys.stderr)


def main():
    argv = sys.argv[1:]
    kiosk = "--kiosk" in argv
    page = PAGE
    extra = []
    if "--page" in argv:
        page = os.path.abspath(argv[argv.index("--page") + 1])
    if "--" in argv:
        extra = argv[argv.index("--") + 1 :]
    if "NC_SESSION" not in os.environ:
        print("chrome_fixture.py : à lancer dans une session de tools/linux-session.", file=sys.stderr)
        return 2
    chrome = shutil.which("google-chrome") or shutil.which("chromium") or shutil.which("chromium-browser")
    if chrome is None:
        print("Chrome introuvable : installe google-chrome ou chromium.", file=sys.stderr)
        return 77
    profile = tempfile.mkdtemp(prefix="chrome-fixture-", dir=os.environ.get("XDG_CACHE_HOME"))
    log_path = os.environ.get("NC_FIXTURE_LOG")
    out = open(log_path, "a", buffering=1, encoding="utf-8") if log_path else sys.stdout
    flags = [
        f"--user-data-dir={profile}",
        "--ozone-platform=wayland",
        "--force-renderer-accessibility",
        "--enable-logging=stderr",
        "--no-first-run",
        "--no-default-browser-check",
        "--password-store=basic",
        "--disable-background-networking",
        "--disable-component-update",
        "--disable-default-apps",
        "--disable-sync",
        "--disable-domain-reliability",
        "--metrics-recording-only",
        "--no-pings",
        "--disable-features=Translate,OptimizationHints,MediaRouter",
    ]
    if kiosk:
        flags.append("--kiosk")
    enable_accessibility()
    proc = subprocess.Popen([chrome, *flags, *extra, "file://" + page], stderr=subprocess.PIPE, text=True, errors="replace")

    def stop(*_):
        proc.terminate()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    for line in proc.stderr:
        m = CONSOLE.search(line)
        if not m:
            continue
        try:
            event = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        event["mono_ns"] = time.monotonic_ns()
        out.write(json.dumps(event, ensure_ascii=False) + "\n")
        out.flush()
    code = proc.wait()
    shutil.rmtree(profile, ignore_errors=True)
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
