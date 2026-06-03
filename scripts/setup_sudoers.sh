#!/usr/bin/env bash
# Install the CANTester scoped passwordless-sudo drop-in.
#
# Grants the invoking user NOPASSWD for exactly three commands the setup/run
# scripts need: apt-get (install deps), ip (bring up vcan0), modprobe (load
# kernel modules, if ever needed). Nothing else.
#
# This is the one piece of machine state that does NOT live in git and so does
# not transfer to a fresh box — run this once per machine:
#
#     sudo ./scripts/setup_sudoers.sh
#
# Safe by construction: the generated file is syntax-checked with `visudo -c`
# BEFORE it is installed, so a typo can never lock you out of sudo.
set -euo pipefail

DEST=/etc/sudoers.d/cantester

# The user to grant the rule to: the human who invoked `sudo`, not root.
TARGET_USER="${SUDO_USER:-$(id -un)}"
if [ "$TARGET_USER" = "root" ]; then
	echo "Refusing to grant the rule to root. Run as: sudo ./scripts/setup_sudoers.sh" >&2
	exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "This installs to ${DEST} and needs root. Re-run: sudo $0" >&2
	exit 1
fi

# Resolve absolute paths so the rule is exact (sudoers matches on full path).
APT="$(command -v apt-get || echo /usr/bin/apt-get)"
IP="$(command -v ip || echo /usr/sbin/ip)"
MODPROBE="$(command -v modprobe || echo /usr/sbin/modprobe)"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat >"$TMP" <<EOF
# CANTester scoped passwordless sudo — managed by scripts/setup_sudoers.sh.
# Lets the setup/run scripts install deps and bring up vcan0 without a prompt.
${TARGET_USER} ALL=(ALL) NOPASSWD: ${APT}, ${IP}, ${MODPROBE}
EOF

# Validate BEFORE touching the real file. visudo -c exits non-zero on any error.
if ! visudo -cf "$TMP" >/dev/null; then
	echo "Generated sudoers failed validation; NOT installing:" >&2
	cat "$TMP" >&2
	exit 1
fi

install -m 0440 -o root -g root "$TMP" "$DEST"

# Re-validate the whole sudoers set now that the drop-in is in place.
if ! visudo -c >/dev/null; then
	echo "WARNING: system sudoers failed validation after install — removing drop-in." >&2
	rm -f "$DEST"
	exit 1
fi

echo "Installed ${DEST}:"
sed 's/^/    /' "$DEST"
echo "Verify with:  sudo -n -l ${APT}"
