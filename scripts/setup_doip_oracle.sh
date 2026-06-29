#!/bin/sh
# setup_doip_oracle.sh — build the .venv-doip virtualenv with scapy, the
# independent DoIP/UDS oracle for modules/doip (see sut/doip_server.py).
# Dev-only; the venv is git-ignored. Re-run on a fresh box.
set -e
cd "$(dirname "$0")/.."

python3 -m venv .venv-doip
.venv-doip/bin/pip install --quiet --disable-pip-version-check --upgrade pip
.venv-doip/bin/pip install --quiet --disable-pip-version-check scapy

echo "scapy installed in .venv-doip:"
.venv-doip/bin/python -c "import scapy; from scapy.contrib.automotive.doip import UDS_DoIPSocket; print('  scapy', scapy.VERSION, '+ DoIP OK')"

cat <<'EOF'

DoIP oracle ready. To cross-validate the V DoIP entity against scapy:
  1) start the V entity:
       v -enable-globals -path "@vlib|@vmodules|modules" run cmd/doip_smoke/smoke.v serve
  2) run the oracle:
       .venv-doip/bin/python sut/doip_server.py 127.0.0.1 13400
EOF
