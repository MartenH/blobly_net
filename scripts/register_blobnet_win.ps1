# register_blobnet_win.ps1 — associate .blobnet project files with blobly_net.exe on
# Windows, so double-clicking one opens it in the app.
#
#   .\scripts\register_blobnet_win.ps1                 # register (auto-detect the exe)
#   .\scripts\register_blobnet_win.ps1 -Exe C:\path\blobly_net.exe
#   .\scripts\register_blobnet_win.ps1 -Unregister     # remove the association
#
# Per-user (HKCU\Software\Classes) — NO admin required, and it doesn't touch other
# users. blobly_net already accepts a project path as its first CLI argument
# (cli_project_arg), so the shell just launches `blobly_net.exe "<file.blobnet>"`.
param(
    [string]$Exe,
    [switch]$Unregister
)
$ErrorActionPreference = 'Stop'

$ext    = '.blobnet'
$progId = 'blobly_net.Project'
$classes = 'HKCU:\Software\Classes'

if ($Unregister) {
    Remove-Item "$classes\$ext"    -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$classes\$progId" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Unregistered $ext."
    return
}

# Locate the exe: -Exe wins; else next to this script's bundle; else on PATH.
if (-not $Exe) {
    $repo = Split-Path -Parent $PSScriptRoot
    foreach ($c in @("$repo\blobly_net.exe", "$repo\build\blobly_net.exe",
                     "$PSScriptRoot\blobly_net.exe")) {
        if (Test-Path $c) { $Exe = (Resolve-Path $c).Path; break }
    }
    if (-not $Exe) { $Exe = (Get-Command blobly_net.exe -ErrorAction SilentlyContinue).Source }
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    throw "blobly_net.exe not found — pass it with -Exe C:\path\blobly_net.exe"
}
$Exe = (Resolve-Path $Exe).Path

# .blobnet -> ProgID
New-Item -Path "$classes\$ext" -Force | Out-Null
Set-ItemProperty -Path "$classes\$ext" -Name '(default)' -Value $progId

# ProgID: friendly name, icon (the exe's), and the open command.
New-Item -Path "$classes\$progId" -Force | Out-Null
Set-ItemProperty -Path "$classes\$progId" -Name '(default)' -Value 'Blobly Net project'
New-Item -Path "$classes\$progId\DefaultIcon" -Force | Out-Null
Set-ItemProperty -Path "$classes\$progId\DefaultIcon" -Name '(default)' -Value "`"$Exe`",0"
New-Item -Path "$classes\$progId\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path "$classes\$progId\shell\open\command" -Name '(default)' -Value "`"$Exe`" `"%1`""

Write-Host "Registered $ext -> $Exe (per-user)."
Write-Host "Double-click a .blobnet file to open it in Blobly Net."
Write-Host "(If Explorer still shows the old handler, log off/on or run: -Unregister then re-run.)"
