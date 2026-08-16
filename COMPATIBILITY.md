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

## New finding: unpinned `mt5linux` breaks on the script's own target Python version

2026-08-16, reported by a user of this toolkit (`Wine 11.15 Staging`, native
`winehq-staging` apt package — not one of the two configurations above).
Steps [1/5]-[4/5] completed cleanly (consistent with the "none of the three
original bugs occur on Wine 11.x" finding above), but step [5/5]'s
verification failed:

```
File "C:\Python310\lib\site-packages\mt5linux\metatrader5.py", line 1755
    code = f'mt5.copy_rates_from("{symbol}", {timeframe}, {
           ^
SyntaxError: unterminated string literal (detected at line 1755)
```

Root cause, confirmed by reading the actual failing source line: current
PyPI `mt5linux` (1.1.1, as of this report) uses a multi-line expression
inside an f-string's `{...}` — valid only on **Python 3.12+** (PEP 701's
relaxed f-string grammar). This script installs **Python 3.10.11** — what
it was actually tested against, paired with `mt5linux 1.0.3` per its own
header comment. Since `pip install mt5linux` (no version pin) always grabs
whatever's newest on PyPI, the install step "succeeds" and the failure only
surfaces one step later, on an unrelated-looking error deep in a dependency.

**Fix applied**: pin `mt5linux==1.0.3` in the script's step [4/5] install
command, matching the version already named in the script's own header.
Re-verified end-to-end after the fix: exit code 0, `mt5linux OK,
MetaTrader5 OK`, and a real bridge connection (`mt5.initialize()` →
`True`, real `account_info()` returned) confirmed working through it.

This doesn't fix itself if `mt5linux` publishes another release — the pin
just freezes to the version this toolkit is actually verified against.
Revisit if intentionally testing/supporting a newer Python + mt5linux pair.

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
