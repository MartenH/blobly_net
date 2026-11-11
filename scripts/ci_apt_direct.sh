#!/bin/sh
# Point apt on a GitHub-hosted Ubuntu runner straight at the Ubuntu archive. The runner image
# routes apt through mirror+file:/etc/apt/apt-mirrors.txt, whose first entry
# (azure.archive.ubuntu.com) has been unresolvable for hours at a time; every job that installs
# a package then fails before compiling anything. Retries cover a slow archive.
set -eu
src=/etc/apt/sources.list.d/ubuntu.sources
if [ -f "$src" ]; then
	sudo sed -i -E 's#^URIs: mirror\+file:[^ ]*#URIs: http://archive.ubuntu.com/ubuntu/#' "$src"
fi
echo 'Acquire::Retries "5";' | sudo tee /etc/apt/apt.conf.d/80-retries >/dev/null
sudo apt-get update -q
