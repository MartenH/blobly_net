#!/usr/bin/env bash
# mint_windows_v.sh — build the Windows V toolchain asset that windows.yml downloads from the
# `v-toolchain` release, cross-compiled from Linux. V will not build itself on the Windows runner
# (docs/known_issues.md), so this asset is the Windows job's compiler.
#
#   scripts/mint_windows_v.sh [vdir] [outdir]   vdir: a V built at the pins (default $V_DIR, ~/v)
#
# Writes <outdir>/v-<sha7>-windows.zip: the V checkout's tracked files with v.exe at the root,
# laid out the way windows.yml unpacks it into C:\v-ct. Upload it to the `v-toolchain` release
# and set V_ASSET in windows.yml.
#
# V3 bakes the root it was BUILT in into the compiler (`@VMODROOT`) and prefers it over where
# the executable sits, so a cross-built v.exe would look for vlib under this machine's path. The
# C is therefore generated, the baked root rewritten to C:/v-ct, and compiled here with mingw:
# the asset only works unpacked at C:\v-ct, which is where windows.yml puts it.
set -eu
set -o pipefail # a failed `git archive` must not zip a v.exe with no vlib
here=$(cd "$(dirname "$0")/.." && pwd -P)
. "$here/scripts/v_toolchain.sh"
vdir=$(cd "${1:-${V_DIR:-$HOME/v}}" && pwd -P)
outdir=$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd -P)
install_root='C:/v-ct' # windows.yml: Expand-Archive ... -DestinationPath C:\v-ct
cc=x86_64-w64-mingw32-gcc

v_pin=$(tr -d '[:space:]' <"$here/.v-version")
vc_pin=$(tr -d '[:space:]' <"$here/.vc-version")
reason=$(v_toolchain_build_reason "$vdir" "$v_pin" "$vc_pin")
if [ -n "$reason" ]; then
	echo "mint_windows_v: $vdir is not a V built at the pins ($reason); build it with v_toolchain_install first" >&2
	exit 1
fi
command -v "$cc" >/dev/null || { echo "mint_windows_v: needs $cc (apt-get install gcc-mingw-w64-x86-64)" >&2; exit 1; }
command -v zip >/dev/null || { echo "mint_windows_v: needs zip" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# -prod embeds the compiler's $embed_file headers; without it they are read from vdir at run time.
# -no-prealloc: a compiler build defaults to V's bump arena, whose realloc copies the NEW size out
# of the old block (vlib/builtin/allocation.c.v); on Windows that read runs off the end of the
# arena and v.exe dies with an access violation compiling blobly/isotp/isotp_test.v. The C
# allocator has no such read.
(cd "$vdir" && V_MACOS_V3_NO_FALLBACK=1 ./v -prod -no-prealloc -os windows -o "$tmp/v.c" cmd/v)

# the two run-time copies of the build root: the baked vroot, and the VEXE default set in main
python3 - "$tmp/v.c" "$vdir" "$install_root" <<'EOF'
import re, sys
path, vdir, root = sys.argv[1:4]
s = open(path, encoding='latin-1').read()
# the C holds the path's UTF-8 BYTES and their count; read as latin-1, one char per byte
nbytes = len(vdir.encode('utf-8'))
vdir = vdir.encode('utf-8').decode('latin-1')
lit = re.escape('{"%s", %d, 1};' % (vdir, nbytes))
s, n1 = re.subn(r'(static const string _str_\d+ = )' + lit, lambda m: m.group(1) + '{"%s", %d, 1};' % (root, len(root)), s)
if n1 == 0:
    # since vlang/v#30453 a literal is declared through a macro: `_SL(_str_N, "...", len);`
    macro = re.escape('"%s", %d);' % (vdir, nbytes))
    s, n1 = re.subn(r'(_SL\(_str_\d+, )' + macro, lambda m: m.group(1) + '"%s", %d);' % (root, len(root)), s)
s, n2 = re.subn(re.escape('const char* v3_vexe = "%s/v";' % vdir), 'const char* v3_vexe = "%s/v.exe";' % root, s)
if (n1, n2) != (1, 1):
    sys.exit('mint_windows_v: expected one baked root and one VEXE default in the C, found %d and %d; V changed shape' % (n1, n2))
# an #include is read here at compile time; a vlib/ path is an $embed_file's label, its content
# compiled in under -prod
left = [l for l in s.splitlines()
        if vdir in l and not l.startswith('#include') and '"%s/vlib/' % vdir not in l]
if left:
    sys.exit('mint_windows_v: the build root is still in the C outside #include lines:\n' + '\n'.join(left[:5]))
open(path, 'w', encoding='latin-1').write(s)
EOF

# the native C files V links through `#flag ....o`, which `-o v.c` leaves out: the list V's own
# Windows bootstrap compiles beside its generated C (makev.bat's V_STAGE_NATIVE)
helpers=()
natives=$(grep -m1 '^set V_STAGE_NATIVE=' "$vdir/makev.bat" || true)
for f in $(printf '%s' "$natives" | grep -o '%~dp0[^"]*' | sed -e 's/^%~dp0//' -e 's|\\|/|g'); do
	[ -f "$vdir/$f" ] || { echo "mint_windows_v: makev.bat names $f, which $vdir does not have" >&2; exit 1; }
	helpers+=("$vdir/$f")
done

# the command `v -prod -showcc -os windows -cc $cc` runs, with the C above in place of its own
"$cc" -std=gnu11 -O2 -flto -municode -Wl,--stack=33554432 -w -Wno-incompatible-pointer-types \
	-fwrapv -Wno-int-conversion -o "$tmp/v.exe" "$tmp/v.c" "${helpers[@]}" -l dbghelp -lws2_32 \
	-L"$vdir/vlib/crypto/rand/internal/libraries/bcrypt" -lbcrypt \
	-I "$vdir/thirdparty/stdatomic/win" -l advapi32

mkdir "$tmp/stage"
git -C "$vdir" archive --format=tar HEAD | tar -x -C "$tmp/stage"
cp "$tmp/v.exe" "$tmp/stage/v.exe"
sha=$(git -C "$vdir" rev-parse --short=7 HEAD)
zipf="$outdir/v-$sha-windows.zip"
rm -f "$zipf"
(cd "$tmp/stage" && zip -q -r -X "$zipf" .)
echo "mint_windows_v: $zipf ($(du -h "$zipf" | cut -f1)), sha256 $(sha256sum "$zipf" | cut -d' ' -f1)"
