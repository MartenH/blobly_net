#!/bin/sh
# Screenshot the running Blobly Net window under WSLg.
# Usage: scripts/shot.sh [out.png]   (default /tmp/ct.png)
out="${1:-/tmp/ct.png}"
export XCURSOR_THEME=Adwaita XCURSOR_SIZE=24
wid="$(xdotool search --name Blobly Net | tail -1)"
if [ -z "$wid" ]; then echo "no Blobly Net window" >&2; exit 1; fi
import -window "$wid" "$out" && echo "$out"
