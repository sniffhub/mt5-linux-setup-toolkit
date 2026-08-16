#!/usr/bin/env bash
#
# setup_mt5_python_bridge.sh
#
# Automates getting a working Python + mt5linux bridge running inside a
# Wine prefix that already has MetaTrader 5 installed. Fixes the specific,
# poorly-documented failure modes hit when doing this by hand:
#
#   1. Python's installer requires the prefix to report Windows 8.1+, but
#      Wine's default (and the version needed for MT5 itself to run well)
#      is often Windows 7 -> installer silently exits 1 with no output.
#   2. Once installed, Wine's builtin ucrtbase.dll is missing symbols
#      (e.g. crealf) that MetaTrader5/numpy need -> Wine launches winedbg
#      and HANGS instead of erroring, silently eating your time.
#   3. Wine's python.exe crashes on startup ("Fatal Python error:
#      init_sys_streams ... Invalid handle") when its stdio isn't a real
#      tty -- i.e. whenever you run it from a script, CI, or most
#      terminal-multiplexer/automation setups.
#
# Each of these was root-caused by actually reading Wine's own debug
# output rather than guessing. See README.md for the full story.
#
# Usage:
#   WINEPREFIX=/path/to/your/mt5/prefix ./setup_mt5_python_bridge.sh
#
# Requires: wine, winetricks, curl, cabextract (winetricks dependency)
# Tested against: Wine 8.0, Python 3.10.11, mt5linux 1.0.3

set -euo pipefail

if [ -z "${WINEPREFIX:-}" ]; then
    echo "ERROR: WINEPREFIX is not set." >&2
    echo "Usage: WINEPREFIX=/path/to/your/mt5/prefix $0" >&2
    exit 1
fi

if [ ! -d "$WINEPREFIX" ]; then
    echo "ERROR: WINEPREFIX directory does not exist: $WINEPREFIX" >&2
    echo "Set up MetaTrader 5 in this prefix first (this script does not install MT5 itself)." >&2
    exit 1
fi

for cmd in wine winetricks curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: required command '$cmd' not found on PATH." >&2
        exit 1
    fi
done

PY_VERSION="3.10.11"
PY_INSTALLER="python-${PY_VERSION}-amd64.exe"
PY_URL="https://www.python.org/ftp/python/${PY_VERSION}/${PY_INSTALLER}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# A plain `wine python.exe ...` crashes with "Fatal Python error:
# init_sys_streams" whenever stdout/stderr aren't a real tty (piped output,
# most CI/automation contexts). Wrapping every Wine-Python invocation in
# `script` allocates a pseudo-terminal, which fixes it reliably.
#
# Arguments are safely re-quoted with printf %q before being handed to
# `script -qec` -- building this via a naive "$*" join loses inner quoting
# on anything with spaces/semicolons/quotes (e.g. `-c "import x; print(y)"`),
# which is exactly the kind of bug this toolkit exists to catch, not repeat.
wine_python() {
    local quoted_args=""
    for arg in "$@"; do
        quoted_args="$quoted_args $(printf '%q' "$arg")"
    done
    script -qec "WINEPREFIX=$WINEPREFIX wine \"C:\\\\Python310\\\\python.exe\"$quoted_args" /dev/null
}

echo "==> [1/5] Checking for existing Python install in prefix..."
if [ -f "$WINEPREFIX/drive_c/Python310/python.exe" ]; then
    echo "    Found existing C:\\Python310\\python.exe -- skipping install."
else
    echo "==> [2/5] Downloading Python ${PY_VERSION} (64-bit) installer..."
    curl -fL -o "$WORKDIR/$PY_INSTALLER" "$PY_URL"

    echo "==> Setting prefix Windows version to Win10 (Python installer requires 8.1+)..."
    WINEPREFIX="$WINEPREFIX" winecfg /v win10

    echo "==> Installing Python ${PY_VERSION} silently..."
    WINEPREFIX="$WINEPREFIX" wine "$WORKDIR/$PY_INSTALLER" \
        /quiet InstallAllUsers=1 PrependPath=1 Include_test=0 TargetDir="C:\Python310"

    echo "==> Reverting prefix Windows version to Win7 (Win10 mode breaks Python's console/stdio handling under Wine)..."
    WINEPREFIX="$WINEPREFIX" winecfg /v win7

    if [ ! -f "$WINEPREFIX/drive_c/Python310/python.exe" ]; then
        echo "ERROR: Python install did not produce C:\\Python310\\python.exe -- see Wine's own error output above." >&2
        exit 1
    fi
    echo "    Installed: $(wine_python --version)"
fi

echo "==> [3/5] Applying ucrtbase2019 fix (missing CRT symbols cause a Wine-debugger hang otherwise)..."
if WINEPREFIX="$WINEPREFIX" winetricks list-installed 2>/dev/null | grep -q ucrtbase2019; then
    echo "    Already applied -- skipping."
else
    script -qec "WINEPREFIX=$WINEPREFIX winetricks -q ucrtbase2019" /dev/null
fi

echo "==> [4/5] Installing mt5linux + MetaTrader5 + pywin32 into the Wine Python..."
# mt5linux pinned to 1.0.3 (the version this script/header claims to be
# tested against, matching Python 3.10.11). Verified for real: current PyPI
# mt5linux (1.1.1) uses a multi-line f-string expression -- valid only on
# Python 3.12+ (PEP 701) -- which is a SyntaxError under the 3.10.11 this
# script installs. Unpinned `pip install mt5linux` silently grabs whatever
# is newest on PyPI, so without this pin the install "succeeds" and step
# [5/5]'s verification then fails on an unrelated, confusing error.
wine_python -m pip install --upgrade pip "mt5linux==1.0.3" MetaTrader5 pywin32

echo "==> [5/5] Verifying the install..."
wine_python -c "import mt5linux, MetaTrader5; print('mt5linux OK, MetaTrader5 OK')"

cat <<'EOF'

==> Setup complete.

Next steps:
  1. Start the bridge server (adjust the path to your terminal64.exe if needed):
       script -qec 'WINEPREFIX='"$WINEPREFIX"' wine "C:\Python310\python.exe" -m mt5linux --host localhost -p 18812' /dev/null &

  2. From native Linux Python (pip install mt5linux there too), connect:
       from mt5linux import MetaTrader5
       mt5 = MetaTrader5(host='localhost', port=18812)
       mt5.initialize()
       print(mt5.terminal_info())

See README.md for troubleshooting and what each fix above is actually for.
EOF
