# build_win.ps1 — native Windows build of Blobly Net via mingw-w64 gcc (W1).
#
# Uses a DEDICATED, isolated toolchain under C:\dev (see CLAUDE.md "Windows build
# (W1)" and docs/windows_build.md). Nothing outside C:\dev is touched.
#
#   .\scripts\build_win.ps1                 # build build\blobly_net.exe
#   .\scripts\build_win.ps1 -Run            # build then run
#   .\scripts\build_win.ps1 -Debug          # build with -g (asserts on) for gdb
#   $env:BLOBLY_PROJECT='projects\demo-udp.yml'; .\scripts\build_win.ps1 -Run
#
# Prereqs (one-time, see docs/windows_build.md):
#   - C:\dev\msys64-ct           dedicated MSYS2 + mingw-w64 gcc/pkgconf/pango/...
#   - C:\dev\v\v.exe             V 0.5.1 @ de365a1
#   - C:\dev\vmodules-ct\{gui,vglyph}  gui@68b9302 + vglyph (with the W1 patches)
param(
    [string]$Target = 'src\main.v',
    [string]$Out    = 'build\blobly_net.exe',
    [switch]$Run,
    [switch]$Debug,
    [switch]$SkipUnused   # add -skip-unused: prunes unused code -> much smaller generated
                          # C -> far faster gcc compile (try this if the build seems to hang)
)
$ErrorActionPreference = 'Stop'
$repo  = Split-Path -Parent $PSScriptRoot
$mingw = 'C:\dev\msys64-ct\mingw64'

# Isolated toolchain env.
$env:VMODULES        = 'C:\dev\vmodules-ct'
$env:PKG_CONFIG_PATH = "$mingw\lib\pkgconfig"          # V's v.pkgconfig reads this
$env:PATH            = "$mingw\bin;$env:PATH"          # gcc + pkg-config + runtime DLLs

# vglyph's native deps. V's built-in v.pkgconfig does NOT relocate a .pc `prefix=`,
# and our MSYS2 isn't at the default C:\msys64, so feed the *system* pkgconf's
# (correctly relocated) flags directly. The wrong /mingw64 paths V also derives are
# then harmlessly ignored.
$libs = 'freetype2 harfbuzz fribidi fontconfig pango pangoft2 gobject-2.0 glib-2.0'.Split(' ')
$cflags  = (& pkgconf --cflags $libs) -join ' '
# -ld3d11 -ldxgi: gui's nativebridge\readback_windows.c references D3D11 symbols
# unconditionally on Windows (used only for screenshots), so they must link even
# though we render on the GL backend.
$ldflags = ((& pkgconf --libs $libs) -join ' ') + ' -ld3d11 -ldxgi'

$v = 'C:\dev\v\v.exe'
$outPath = Join-Path $repo $Out
New-Item -ItemType Directory -Force (Split-Path -Parent $outPath) | Out-Null

$vargs = @('-cc','gcc','-enable-globals')  # main.v uses the in-proc bus (__global)
if ($SkipUnused) { $vargs += '-skip-unused' }
if ($Debug) { $vargs += '-g' }
$vargs += @('-path','@vlib|@vmodules|modules','-cflags',$cflags,'-ldflags',$ldflags,'-o',$outPath,(Join-Path $repo $Target))

Push-Location $repo
try { & $v @vargs; $code = $LASTEXITCODE } finally { Pop-Location }

if ($code -ne 0) { Write-Output "BUILD FAILED (exit $code)"; exit $code }
Write-Output "BUILD OK -> $outPath"
if ($Run) { Push-Location $repo; try { & $outPath } finally { Pop-Location } }
