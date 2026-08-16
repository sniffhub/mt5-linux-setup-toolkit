# Compatibility: tested vs. assumed

Honesty check before anyone pays for this: here's exactly what's been
verified on real hardware, versus what's reasoned from how each fix works
but not independently tested.

## Configuration 1 — Debian 12, Wine 8.0 (native apt package)

Verified end-to-end, twice, via the actual `setup_mt5_python_bridge.sh`
script: Python 3.10.11, mt5linux 1.0.3, MetaTrader5 5.0.5735, pywin32 312.
All three documented bugs (installer version check, `crealf` hang, tty
stdio crash) reproduce here and are fixed by the script.

## Configuration 2 — Wine 11.0 (official WineHQ flatpak, `org.winehq.Wine`)

Tested directly against real Wine 11.0 (not reasoned about) after a
disk-space constraint that initially blocked this was resolved. Results,
per-bug:

| Bug | On Wine 8.0 (Debian) | On Wine 11.0 (flatpak) |
|---|---|---|
| 1. Python installer requires Win8.1+, prefix defaults to reporting Win7 | Occurs — needs `winecfg /v win10` workaround | **Does not occur** — Wine 11.0 defaults to reporting Windows 10 (`10.0.19045`) out of the box |
| 2. `ucrtbase.dll.crealf` missing symbol hangs via winedbg | Occurs — needs `winetricks ucrtbase2019` | **Does not occur** — `MetaTrader5` imports cleanly with zero fix applied |
| 3. `python.exe` crashes without a real tty (`init_sys_streams`) | Occurs — needs `script -qec ... /dev/null` wrapper | **Does not occur** — plain unwrapped `pip install` ran fine |

**All three fixes this toolkit exists for appear to be specific to older
Wine (confirmed on 8.0), not universal Wine behavior.** This is a real
result, not a guess — but it's one additional data point (one Wine version,
one packaging method), not exhaustive coverage of every version in between
8.0 and 11.0, or every distro.

### New finding, unrelated to the original 3 bugs: flatpak-packaged Wine doesn't work with this script's approach at all

The official WineHQ flatpak (a genuinely common way people get Wine today,
also how Bottles/Lutris-style tools often work) has two properties that
break this script's core mechanism, independent of Wine version:

- Its sandbox only permits filesystem access to XDG user directories
  (`~/Downloads`, `~/Documents`, etc.) — arbitrary paths like `/tmp` or a
  custom directory under `$HOME` are invisible to it. The script's use of
  `mktemp -d` for the downloaded installer fails here (`wine: failed to
  open "..."`) until the file is moved somewhere flatpak-permitted.
- It **hardcodes `WINEPREFIX=/var/data/wine` in its own manifest**, and
  ignores any `WINEPREFIX` environment variable passed in. The script's
  entire approach (`WINEPREFIX=<path> ./setup_mt5_python_bridge.sh`)
  fundamentally does not target a flatpak Wine install's actual prefix —
  it would silently operate on the wrong prefix rather than erroring
  clearly, if not for the filesystem sandboxing catching it first.

**This means: if MT5 itself is running under a flatpak-packaged Wine, this
script will not work as-is.** Not a version-compatibility gap — a packaging
architecture mismatch. Flagging clearly rather than letting a flatpak-Wine
user hit confusing failures and assume the ucrtbase/tty fixes are broken
when the real issue is upstream of them.

## Upgrading `mt5linux` after initial setup — restart the bridge server too

Real-world gotcha hit running an actual live bot on top of this toolkit's
setup (2026-08-16): if you bump `mt5linux`'s version on a system that
already has the Wine-side bridge server (`python -m mt5linux --host ...`)
running, the already-running process keeps its old `rpyc` (mt5linux's RPC
layer) loaded in memory. A native-Python client built against the newer
mt5linux/rpyc then talks a mismatched wire protocol and fails with a
confusing, unrelated-looking error:

```
invalid message type: 18
```

**Fix**: restart the Wine-side bridge server process after upgrading
`mt5linux` on either side — `pip install --upgrade mt5linux` alone is not
enough, the already-running server has to actually reload the new code.

If the bridge runs under a supervisor with a crash-loop guard (e.g. systemd
`Restart=on-failure` + `StartLimitBurst`), treat the upgrade + restart as
one deliberate action, not several rapid manual restarts while debugging —
repeated restarts inside the burst window will trip the limit and the
service will refuse to start again until `StartLimitIntervalSec` elapses
(working as intended, but easy to mistake for a new bug mid-debug).

This is part of why this toolkit pins to `mt5linux==1.0.3` rather than
tracking latest (see the finding above) — if you do intentionally move to a
newer pinned version, this restart step is the other half of doing it
safely.

## What's still genuinely untested

- Any distro other than Debian 12 (Ubuntu, Fedora, Arch — package names
  documented below, not verified)
- Any Wine version between 8.0 and 11.0 (9.x, 10.x) — untested, no data
  either way
- Wine installed via a distro's own non-Debian packaging (e.g. Ubuntu's
  wine package, WineHQ's own apt repo rather than flatpak)

## Distro package names (documented, not tested on these distros)

The script requires `wine`, `winetricks`, `curl`, `cabextract` on PATH.
Package names, from general package-manager knowledge, not verified here:

| Distro | Install command |
|---|---|
| Debian/Ubuntu | `sudo apt install wine winetricks curl cabextract` |
| Fedora | `sudo dnf install wine winetricks curl cabextract` |
| Arch | `sudo pacman -S wine winetricks curl cabextract` |

If any of these package names are stale or split differently on a given
release, that's exactly the kind of gap this document exists to admit
rather than paper over.

## What would actually close the remaining gap

Real distro-level verification (Ubuntu, Fedora, Arch with their native Wine
packages) still needs either separate machines/VMs or CI (GitHub Actions
Ubuntu runners could install Wine fresh and run this end-to-end) — not
attempted here, flagged as the honest next step rather than done.
