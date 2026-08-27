# SPDX-License-Identifier: MIT

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectRoot = (Resolve-Path (Join-Path $windowsRoot "..")).Path
$source = Join-Path $projectRoot "dist\windows\CuotaX.exe"
$destination = Join-Path $env:LOCALAPPDATA "Programs\CuotaX"
$executable = Join-Path $destination "CuotaX.exe"

& (Join-Path $PSScriptRoot "build.ps1")
Get-Process -Name "CuotaX" -ErrorAction SilentlyContinue | Stop-Process
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $executable -Force
Start-Process -FilePath $executable -WindowStyle Hidden
