# build_win_msvc.ps1 — native Windows build of CANTester via MSVC + vcpkg.
#
# The MSVC/vcpkg counterpart to build_win.ps1 (which uses mingw-w64 gcc + MSYS2).
# This mirrors vlang/gui's own Windows CI recipe (`-cc msvc`, libs from vcpkg).
#
#   .\scripts\build_win_msvc.ps1            # build build\cantester-msvc.exe
#   .\scripts\build_win_msvc.ps1 -Run       # build then run
#   .\scripts\build_win_msvc.ps1 -Deps      # `vcpkg install pango freetype` first
#   .\scripts\build_win_msvc.ps1 -Debug     # -g (asserts on) for cdb/WinDbg
#
# PREREQS:
#   - Visual Studio 2022 Build Tools, "Desktop development with C++" workload
#     (provides cl.exe AND bundles vcpkg).
#   - RUN FROM a "x64 Native Tools Command Prompt for VS 2022" / "Developer
#     PowerShell for VS" so cl.exe + its INCLUDE/LIB env are set.
#   - Reuses the existing isolated V + modules from setup_win.ps1:
#       C:\dev\v\v.exe (V is compiler-agnostic), C:\dev\vmodules-ct\{gui,vglyph}.
#   - Only the #03 titlebar patch is needed on MSVC (#01/#02 are gcc-only; #04 is
#     debug-only). setup_win.ps1 already applies it.
#
# ✅ VALIDATED 2026-06-08 on a fresh box (VS 2022 BuildTools + vcpkg @ C:\dev\vcpkg):
# builds AND renders. V's built-in v.pkgconfig resolves the vcpkg .pc files via
# PKG_CONFIG_PATH (vcpkg's prefix is `${pcfiledir}/../..` — relocatable, so it Just
# Works; no prefix-rewrite needed), and V's msvc backend correctly turns the .pc
# `-lfreetype`-style flags into proper .lib linking. The explicit /I + /LIBPATH below
# are a belt-and-suspenders fallback. Notes:
#   - `vcpkg install pango freetype` builds the whole tree FROM SOURCE on a cold box
#     (~30-60 min). GitHub CI is fast only because the runner restores from a warm
#     vcpkg binary cache; first run there is from-source too. Our build is cached in
#     %LOCALAPPDATA%\vcpkg\archives, so re-runs here are instant.
#   - If you `set VCPKG_ROOT` then enter a VS dev shell, note VsDevCmd OVERWRITES
#     VCPKG_ROOT to the VS-bundled vcpkg — set VCPKG_ROOT *after* VsDevCmd.
param(
    [string]$Target = 'src\main.v',
    [string]$Out    = 'build\cantester-msvc.exe',
    [string]$Triplet = 'x64-windows',
    # Captured here (before any VS dev-shell setup) because VsDevCmd/Launch-VsDevShell
    # OVERWRITES VCPKG_ROOT to the VS-bundled vcpkg. Default to our C:\dev\vcpkg, else
    # VCPKG_ROOT, else the CI runner's pre-installed vcpkg.
    [string]$VcpkgRoot = $(if (Test-Path 'C:\dev\vcpkg\vcpkg.exe') { 'C:\dev\vcpkg' }
                          elseif ($env:VCPKG_ROOT) { $env:VCPKG_ROOT }
                          else { $env:VCPKG_INSTALLATION_ROOT }),
    [switch]$Deps,
    [switch]$Run,
    [switch]$Debug
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Die($m) { Write-Host $m -ForegroundColor Red; exit 1 }

# --- 1. ensure cl.exe — auto-enter the VS dev env if we're not already in one ---
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { Die "cl.exe not found and no VS installer present. Install VS 2022 Build Tools ('Desktop development with C++')." }
    $vsInstall = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    if (-not $vsInstall) { Die "No VS C++ tools found. Install VS 2022 Build Tools ('Desktop development with C++')." }
    Write-Host "==== entering VS dev shell: $vsInstall ====" -ForegroundColor Cyan
    & (Join-Path $vsInstall 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { Die "Failed to put cl.exe on PATH via the VS dev shell." }
}

# --- 2. vcpkg installed tree (VcpkgRoot captured in param defaults, before the dev
#       shell could overwrite VCPKG_ROOT to the VS-bundled vcpkg) ---
$vcpkgRoot = $VcpkgRoot
if (-not $vcpkgRoot) { Die "vcpkg not found. Pass -VcpkgRoot, set VCPKG_ROOT, or install the VS C++ workload (bundles vcpkg)." }
$vcpkgExe = Join-Path $vcpkgRoot 'vcpkg.exe'
if (-not (Test-Path $vcpkgExe)) { $vcpkgExe = 'vcpkg' }   # fall back to PATH (CI runner)

if ($Deps) {
    Write-Host "==== vcpkg install pango freetype ($Triplet) ====" -ForegroundColor Cyan
    & $vcpkgExe install pango freetype --triplet $Triplet
    if ($LASTEXITCODE -ne 0) { Die "vcpkg install failed." }
}

$installed = Join-Path $vcpkgRoot "installed\$Triplet"
if (-not (Test-Path "$installed\include")) {
    Die "No vcpkg libs at $installed. Run with -Deps (or: vcpkg install pango freetype --triplet $Triplet)."
}

# --- 3. toolchain env: isolated modules + vcpkg lib discovery ---
$env:VMODULES        = 'C:\dev\vmodules-ct'
$env:PKG_CONFIG_PATH = "$installed\lib\pkgconfig"        # (a) V's v.pkgconfig reads this

$v = 'C:\dev\v\v.exe'
if (-not (Test-Path $v)) { Die "V not found at $v (run scripts\setup_win.ps1 first)." }

# (b) explicit MSVC include/lib fallback — harmless if pkgconfig already covers it.
$cflags  = "/I`"$installed\include`""
$ldflags = "/LIBPATH:`"$installed\lib`""

$outPath = Join-Path $repo $Out
New-Item -ItemType Directory -Force (Split-Path -Parent $outPath) | Out-Null

$vargs = @('-cc','msvc','-no-parallel','-enable-globals')  # main.v uses the in-proc bus (__global)
if ($Debug) { $vargs += '-g' }
$vargs += @('-path','@vlib|@vmodules|modules','-cflags',$cflags,'-ldflags',$ldflags,'-o',$outPath,(Join-Path $repo $Target))

Write-Host "==== v -cc msvc  ->  $Out ====" -ForegroundColor Cyan
Push-Location $repo
try { & $v @vargs; $code = $LASTEXITCODE } finally { Pop-Location }
if ($code -ne 0) { Die "BUILD FAILED (exit $code). If it's a missing pango/freetype header or unresolved symbol, paste it back." }

# --- 4. bundle the dynamic vcpkg DLLs next to the exe so it runs outside the shell ---
$binOut = Split-Path -Parent $outPath
Copy-Item "$installed\bin\*.dll" $binOut -Force -ErrorAction SilentlyContinue
Write-Host "BUILD OK -> $outPath  (vcpkg DLLs copied alongside)" -ForegroundColor Green

if ($Run) { Push-Location $repo; try { & $outPath } finally { Pop-Location } }
