# SPDX-License-Identifier: MIT

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$source = Join-Path $projectRoot "dist\windows\CuotaX.exe"
$destination = Join-Path $env:LOCALAPPDATA "Programs\CuotaX"
$executable = Join-Path $destination "CuotaX.exe"

& (Join-Path $PSScriptRoot "build-windows.ps1")
Get-Process -Name "CuotaX" -ErrorAction SilentlyContinue | Stop-Process
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -LiteralPath $source -Destination $executable -Force
Start-Process -FilePath $executable -WindowStyle Hidden
