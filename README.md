# MT5-on-Linux Python Bridge Setup

Gets a working Python + [`mt5linux`](https://pypi.org/project/mt5linux/) bridge
running against a MetaTrader 5 terminal installed under Wine on Linux —
automated, with the specific undocumented failure modes below already fixed.

If you've tried this yourself, you've probably already hit at least one of
these. Each was root-caused against real Wine debug output, not guessed at.

## The problem this solves

The official `MetaTrader5` Python package only ships Windows wheels — there's
no Linux build. The standard workaround is
[`mt5linux`](https://pypi.org/project/mt5linux/), which runs a small RPyC
server *inside* Wine (talking to the real MT5 terminal) and lets your native
Linux Python connect to it over a local socket. Getting that server running
is where it gets painful:

### 1. Python's installer silently fails with no useful output

Python 3.10's installer checks the reported Windows version and requires
8.1+. Most Wine setups (and MT5 itself often runs better) report Windows 7 by
default. Running the installer normally just exits with code 1 and prints
nothing to the console — you only find the real reason
(`Windows 8.1 or later is required to continue installation`) by re-running
with `/log` and reading the bootstrapper's own log file.

### 2. A missing CRT symbol hangs the whole bridge via a stuck debugger

Once Python is installed, the `MetaTrader5` package (via `numpy`) calls
`ucrtbase.dll.crealf` — a C99 complex-number function that Wine's builtin
`ucrtbase.dll` doesn't implement. Wine's response to a missing symbol isn't
to raise a clean error: it launches its internal debugger (`winedbg`) and
sits there. From the calling side, this looks like a hang, not a crash — the
RPyC connection succeeds, then the server-side call never returns, silently
eating CPU and your time until you notice and manually kill the stuck
`winedbg` process.

**Fix:** `winetricks ucrtbase2019` replaces Wine's builtin `ucrtbase.dll`
with Microsoft's real one, via a `native,builtin` DLL override.

### 3. Wine's `python.exe` crashes outside a real terminal

```
Fatal Python error: init_sys_streams: can't initialize sys standard streams
OSError: [WinError 6] Invalid handle
```

This happens whenever Wine's `python.exe` doesn't have a real tty attached —
which is exactly the situation in scripts, CI, most terminal-automation
setups, and (notably) piped/captured shell output. It is **not** related to
the Wine prefix's reported Windows version (a plausible-looking but wrong
first guess) — reverting that had zero effect. The actual fix: wrap the
invocation in `script -qec '...' /dev/null` to allocate a pseudo-terminal.

## Usage

```bash
WINEPREFIX=/path/to/your/mt5/prefix ./setup_mt5_python_bridge.sh
```

Requires: `wine`, `winetricks`, `curl`, `cabextract` (a `winetricks`
dependency) already installed on the host, and MetaTrader 5 already set up
in the target prefix — this script installs the Python side only, not MT5
itself.

The script is idempotent — safe to re-run; it detects and skips steps
that are already done.

**After it finishes**, start the bridge server and connect from native
Python:

```bash
# Wine side (run once, leave running):
script -qec 'WINEPREFIX=/path/to/prefix wine "C:\Python310\python.exe" -m mt5linux --host localhost -p 18812' /dev/null &

# Native Linux side (pip install mt5linux there too):
python3 -c "
from mt5linux import MetaTrader5
mt5 = MetaTrader5(host='localhost', port=18812)
print('initialize():', mt5.initialize())
print(mt5.terminal_info())
"
```

## What this does NOT do

- Does not install or configure MetaTrader 5 itself — bring your own
  working Wine + MT5 setup.
- Does not touch anything trading-related — this is purely environment
  setup for the read/write data bridge.
- Bridge latency itself is negligible (sub-2ms for local calls, measured) —
  it's local IPC between two processes on the same machine, not a network
  hop. The real MT5-to-broker network round-trip for live order execution
  is a separate cost, unaffected by any of this.

## Tested against

Verified end-to-end on two configurations:
- Debian GNU/Linux 12, Wine 8.0 (Debian package) — all three fixes below
  are needed and confirmed working here.
- Wine 11.0 (official WineHQ flatpak) — **none of the three bugs occur** on
  this version; Wine 11 defaults to reporting Windows 10, and both the
  `crealf` and tty-stdio issues are simply absent. Also surfaced a
  separate, real limitation: **flatpak-packaged Wine doesn't work with this
  script's approach at all** (sandboxed filesystem + hardcoded internal
  `WINEPREFIX` that ignores the env var) — if your MT5 runs under a
  flatpak Wine, this script isn't going to work as shipped. Full detail in
  [COMPATIBILITY.md](COMPATIBILITY.md).

**Not tested**: any other distro, or any Wine version between 8.0 and 11.0.
If it breaks against a different Wine or Python version, the debugging
approach that found these fixes still applies: read the actual error
output (`/log` for MSI installers, Wine's own stderr for DLL/symbol
errors), don't guess.

## License

MIT. Use at your own risk — this touches a Wine prefix's registry and
installs software into it; review the script before running it against
anything you can't afford to rebuild.
