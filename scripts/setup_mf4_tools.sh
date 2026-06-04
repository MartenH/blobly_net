#!/usr/bin/env bash
# Set up the MF4 bridge tooling: a Python venv with asammdf (to read real ASAM
# MDF4 recordings) + download real J1939 sample logs and a DBC into samples/.
#
# MF4 is a heavy binary format, so we DON'T parse it in V — `sut/mf4_bridge.py`
# uses asammdf to convert .mf4 -> candump .log (which our V tools replay/decode)
# and to semantically diff two recordings. This is dev/oracle tooling only; the
# venv and samples/ are git-ignored.
#
# Run once:  ./scripts/setup_mf4_tools.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=.venv-tools
if [ ! -x "$VENV/bin/python" ]; then
	echo "==> creating $VENV (needs python3-venv/pip; sudo apt installs them)"
	if ! python3 -m venv "$VENV" 2>/dev/null; then
		sudo apt-get install -y -q python3-venv python3-pip
		python3 -m venv "$VENV"
	fi
fi
# asammdf reads MF4; python-can writes it (MF4Writer) + reads candump .log
# (CanutilsLogReader) — used by `mf4_bridge.py tomf4` to mint an MF4 from any
# capture we own. python-can is also our `transport` oracle (see CLAUDE.md).
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet asammdf python-can
"$VENV/bin/python" -c "import asammdf, can; print('asammdf', asammdf.__version__, '| python-can', can.__version__)"

# Real CSS Electronics / CANedge J1939 samples (a parked log + a driving log) and
# the matching demo DBC. Hosted in their public api-examples repo.
mkdir -p samples
RAW="https://raw.githubusercontent.com/CSS-Electronics/api-examples/master/examples"
declare -A FILES=(
	["samples/j1939.dbc"]="$RAW/other/asammdf-basics/input/CSS-Electronics-SAE-J1939-DEMO.dbc"
	["samples/parked.mf4"]="$RAW/other/asammdf-basics/input/00000001.MF4"
	["samples/driving.mf4"]="$RAW/data-processing/LOG/958D2219/00002501/00002081.MF4"
)
for dest in "${!FILES[@]}"; do
	if [ ! -f "$dest" ]; then
		echo "==> fetching $dest"
		curl -fsSL "${FILES[$dest]}" -o "$dest"
	fi
done

echo
echo "Ready. Try:"
echo "  $VENV/bin/python sut/mf4_bridge.py convert samples/driving.mf4 /tmp/drive.log"
echo "  $VENV/bin/python sut/mf4_bridge.py tomf4   samples/demo.log    samples/demo.mf4"
echo "  $VENV/bin/python sut/mf4_bridge.py diff    samples/parked.mf4 samples/parked.mf4"
echo "  v -path \"@vlib|@vmodules|modules\" run cmd/dbc_decode/decode.v samples/j1939.dbc 0CF004FE <data_hex>"
