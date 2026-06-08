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
# ⚠ BEST-EFFORT / UNTESTED: the one uncertain piece is how V's cl.exe invocation
# discovers the vcpkg headers/libs on a non-CI box (the GitHub runner has vcpkg
# pre-integrated; a fresh box does not). This script tries, in order:
#   (a) PKG_CONFIG_PATH -> vcpkg's lib\pkgconfig  (V's built-in v.pkgconfig reads it)
#   (b) explicit  /I<include>  and  /LIBPATH:<lib>  as -cflags/-ldflags fallback
# If V still can't find pango/freetype, paste the first error — the exact missing
# header/symbol tells us which flag to fix.
param(
    [string]$Target = 'src\main.v',
    [string]$Out    = 'build\cantester-msvc.exe',
    [string]$Triplet = 'x64-windows',
    [switch]$Deps,
    [switch]$Run,
    [switch]$Debug
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Die($m) { Write-Host $m -ForegroundColor Red; exit 1 }

# --- 1. must be in a VS dev shell (cl.exe on PATH) ---
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    Die "cl.exe not found. Open 'x64 Native Tools Command Prompt for VS 2022' (or Developer PowerShell) and re-run."
}

# --- 2. locate vcpkg + its installed tree ---
$vcpkgCmd = Get-Command vcpkg -ErrorAction SilentlyContinue
$vcpkgExe = if ($vcpkgCmd) { $vcpkgCmd.Source } else { $null }
$vcpkgRoot = if ($env:VCPKG_ROOT) { $env:VCPKG_ROOT }
             elseif ($env:VCPKG_INSTALLATION_ROOT) { $env:VCPKG_INSTALLATION_ROOT }
             elseif ($vcpkgExe) { Split-Path -Parent $vcpkgExe }
             else { $null }
if (-not $vcpkgRoot) { Die "vcpkg not found. Install VS 2022 C++ workload (bundles vcpkg) or set VCPKG_ROOT." }

if ($Deps) {
    Write-Host "==== vcpkg install pango freetype ($Triplet) ====" -ForegroundColor Cyan
    & vcpkg install pango freetype --triplet $Triplet
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

$vargs = @('-cc','msvc','-no-parallel')
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
