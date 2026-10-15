# SPDX-License-Identifier: MIT

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectRoot = (Resolve-Path (Join-Path $windowsRoot "..")).Path
$source = Join-Path $projectRoot "dist\windows\CuotaX.exe"
$destination = Join-Path $env:LOCALAPPDATA "Programs\CuotaX"
$executable = Join-Path $destination "CuotaX.exe"

& (Join-Path $PSScriptRoot "build.ps1")
Get-Process -Name "CuotaX" -ErrorAction SilentlyContinue | Stop-Process -PassThru | Wait-Process -Timeout 10
New-Item -ItemType Directory -Path $destination -Force | Out-Null
for ($attempt = 0; ; $attempt++) {
    try {
        Copy-Item -LiteralPath $source -Destination $executable -Force
        break
    } catch [System.IO.IOException] {
        if ($attempt -ge 20) {
            throw
        }
        Start-Sleep -Milliseconds 250
    }
}
Copy-Item -LiteralPath (Join-Path $projectRoot "dist\windows\claude-statusline.mjs") -Destination $destination -Force
Start-Process -FilePath $executable -WindowStyle Hidden
