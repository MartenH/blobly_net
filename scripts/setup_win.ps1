# setup_win.ps1 — one-time native-Windows toolchain bootstrap for CANTester (W1).
#
# The PowerShell counterpart to scripts/setup_env.sh. It MUST be PowerShell, not
# bash: it *installs* MSYS2, so it runs before any MSYS2/bash shell exists. Once
# this finishes, the repeatable build is scripts\build_win.ps1 OR scripts\build_win.sh.
#
#   .\scripts\setup_win.ps1                 # install/clone/build everything missing
#   .\scripts\setup_win.ps1 -CapturePatches # (maintainer) regenerate win_patches\*.patch
#                                           #   from the CURRENT vmodules-ct (the verified
#                                           #   copy), overwriting the in-repo patches.
#
# Everything is isolated under C:\dev — nothing outside it is touched (no personal
# MSYS2, no user .vmodules, no global PATH). Idempotent: re-run safely; existing
# pieces are skipped. See docs/windows_build.md for the full recipe + gotchas.
param(
    [switch]$CapturePatches
)
$ErrorActionPreference = 'Stop'
$repo       = Split-Path -Parent $PSScriptRoot
$patchesDir = Join-Path $PSScriptRoot 'win_patches'

# Pinned layout (matches docs/windows_build.md + the Linux pins).
$dev        = 'C:\dev'
$msys       = 'C:\dev\msys64-ct'
$mingw      = "$msys\mingw64"
$bash       = "$msys\usr\bin\bash.exe"
$vdir       = 'C:\dev\v'
$vexe       = "$vdir\v.exe"
$vmodules   = 'C:\dev\vmodules-ct'
$vpin       = 'de365a1'   # V 0.5.1
$guipin     = '68b9302'   # vlang/gui
$vglyphpin  = '5685a6d'   # vlang/vglyph (validated for the W1 patch)

function Step($m) { Write-Host "`n==== $m ====" -ForegroundColor Cyan }

# The gui/vglyph patches: (module path under $vmodules, patch file). Order matters
# only in that all gui patches target the gui clone. 01-04 are the W1 Windows-build
# fixes; 06 exposes WindowCfg.sample_count (MSAA) which src/main.v sets, so it's
# required for the build to compile.
$patches = @(
    @{ Repo = 'gui';    File = '01-gui-readback-cobjmacros.patch' },
    @{ Repo = 'gui';    File = '02-gui-dialog-includes.patch'     },
    @{ Repo = 'gui';    File = '03-gui-titlebar-isvalid.patch'    },
    @{ Repo = 'vglyph'; File = '04-vglyph-empty-outline.patch'    },
    @{ Repo = 'gui';    File = '06-gui-sample-count.patch'        }
)

# -------- maintainer mode: capture verified patches from the live modules --------
if ($CapturePatches) {
    Step "Capturing patches from $vmodules (verified working copy)"
    foreach ($p in $patches) {
        $mod = Join-Path $vmodules $p.Repo
        # Each .patch is a single-file diff; recover its target path from the header.
        $target = (Get-Content (Join-Path $patchesDir $p.File) |
                   Where-Object { $_ -like '+++ b/*' } | Select-Object -First 1) -replace '^\+\+\+ b/',''
        $diff = & git -C $mod diff -- $target
        if (-not $diff) { Write-Warning "  $($p.File): no diff in $mod/$target (already committed upstream?)"; continue }
        $diff | Set-Content -NoNewline (Join-Path $patchesDir $p.File)
        Write-Host "  wrote $($p.File) from $mod/$target"
    }
    Write-Host "`nDone. Review + commit scripts\win_patches\*.patch."
    return
}

New-Item -ItemType Directory -Force $dev | Out-Null

# -------- 1. dedicated MSYS2 --------
Step '1/5 MSYS2 (dedicated root)'
if (Test-Path $bash) {
    Write-Host "  $msys exists — skipping install."
} else {
    $sfx = "$dev\msys2-base.sfx.exe"
    Write-Host '  downloading msys2-base...'
    Invoke-WebRequest 'https://github.com/msys2/msys2-installer/releases/download/nightly-x86_64/msys2-base-x86_64-latest.sfx.exe' -OutFile $sfx
    & $sfx -y "-o$dev"                       # extracts to $dev\msys64
    Rename-Item "$dev\msys64" $msys
    Remove-Item $sfx -ErrorAction SilentlyContinue
    # first-run system update (may need a second pass; -Syuu is re-run idempotently)
    & $bash -lc 'pacman -Syuu --noconfirm' ; & $bash -lc 'pacman -Syuu --noconfirm'
}

# -------- 2. mingw-w64 deps (+ python for the SUT) --------
Step '2/5 mingw-w64 packages'
$pkgs = 'mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf mingw-w64-x86_64-freetype ' +
        'mingw-w64-x86_64-harfbuzz mingw-w64-x86_64-fribidi mingw-w64-x86_64-fontconfig ' +
        'mingw-w64-x86_64-pango mingw-w64-x86_64-glib2 mingw-w64-x86_64-python ' +
        'mingw-w64-x86_64-gdb git'
& $bash -lc "pacman -S --needed --noconfirm $pkgs"

# -------- 3. V at the pin (tcc self-build, no MSVC) --------
Step '3/5 V compiler'
if (Test-Path $vexe) {
    Write-Host "  $vexe exists — skipping."
} else {
    if (-not (Test-Path $vdir)) { & git clone https://github.com/vlang/v.git $vdir }
    & git -C $vdir checkout $vpin
    cmd /c "$vdir\makev.bat"
    if (-not (Test-Path $vexe)) { throw "makev.bat did not produce $vexe" }
}

# -------- 4. gui + vglyph at pins, into the isolated modules dir --------
Step '4/5 gui + vglyph modules'
New-Item -ItemType Directory -Force $vmodules | Out-Null
function CloneModule($name, $url, $pin) {
    $dst = Join-Path $vmodules $name
    if (Test-Path $dst) { Write-Host "  $dst exists — skipping clone."; return }
    # core.autocrlf=false so the working tree stays LF and the LF patches apply.
    & git -c core.autocrlf=false clone $url $dst
    & git -C $dst -c advice.detachedHead=false checkout $pin
}
CloneModule 'gui'    'https://github.com/vlang/gui.git'    $guipin
CloneModule 'vglyph' 'https://github.com/vlang/vglyph.git' $vglyphpin

# -------- 5. apply the W1 patches (idempotent) --------
Step '5/5 W1 upstream patches'
foreach ($p in $patches) {
    $mod   = Join-Path $vmodules $p.Repo
    $patch = Join-Path $patchesDir $p.File
    # already applied? (reverse-applies cleanly) -> skip. else apply.
    & git -C $mod apply --reverse --check $patch 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host "  $($p.File): already applied — skip."; continue }
    & git -C $mod apply --check $patch 2>$null
    if ($LASTEXITCODE -ne 0) { throw "  $($p.File): does NOT apply to $mod (module drift? see docs/windows_build.md manifest)" }
    & git -C $mod apply $patch
    Write-Host "  $($p.File): applied."
}

Write-Host "`nAll done." -ForegroundColor Green
Write-Host @"
Next:
  .\scripts\build_win.ps1 -Run        # build + run (PowerShell), or
  bash scripts/build_win.sh -run      # build + run (from the MINGW64 shell)
  $mingw\bin\python.exe sut\can_sut.py udp   # driver-free virtual ECU (separate shell)
If a fresh build .exe is blocked by Smart App Control, turn SAC Off (irreversible) — see docs/windows_build.md gotcha #1.
"@
