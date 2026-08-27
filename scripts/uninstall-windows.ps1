# SPDX-License-Identifier: MIT

$ErrorActionPreference = "Stop"
$programs = (Resolve-Path (Join-Path $env:LOCALAPPDATA "Programs")).Path
$destination = Join-Path $programs "CuotaX"
$executable = Join-Path $destination "CuotaX.exe"

if (Test-Path -LiteralPath $executable) {
    & $executable --unregister
}
Get-Process -Name "CuotaX" -ErrorAction SilentlyContinue | Stop-Process

$resolvedParent = (Resolve-Path -LiteralPath (Split-Path $destination -Parent)).Path
if ($resolvedParent -ne $programs) {
    throw "Refusing to remove unexpected path: $destination"
}
if (Test-Path -LiteralPath $destination) {
    Remove-Item -LiteralPath $destination -Recurse -Force
}
