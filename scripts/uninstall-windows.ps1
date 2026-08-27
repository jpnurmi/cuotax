# SPDX-License-Identifier: MIT

$ErrorActionPreference = "Stop"
$programs = Join-Path $env:LOCALAPPDATA "Programs"
$destination = Join-Path $programs "CuotaX"
$executable = Join-Path $destination "CuotaX.exe"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

if (Test-Path -LiteralPath $runKey) {
    Remove-ItemProperty -LiteralPath $runKey -Name "CuotaX" -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
    return
}
if (-not (Test-Path -LiteralPath $programs -PathType Container)) {
    return
}

$resolvedPrograms = (Resolve-Path -LiteralPath $programs).Path
$resolvedDestination = (Resolve-Path -LiteralPath $destination).Path
$resolvedParent = Split-Path $resolvedDestination -Parent
if ($resolvedParent -ne $resolvedPrograms) {
    throw "Refusing to remove unexpected path: $destination"
}

if (Test-Path -LiteralPath $executable) {
    & $executable --unregister
}
Get-Process -Name "CuotaX" -ErrorAction SilentlyContinue | Stop-Process

Remove-Item -LiteralPath $destination -Recurse -Force
