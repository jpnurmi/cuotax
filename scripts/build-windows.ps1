# SPDX-License-Identifier: MIT

param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$output = Join-Path $projectRoot "dist\windows"

dotnet publish (Join-Path $projectRoot "windows\CuotaX\CuotaX.csproj") `
    --configuration $Configuration `
    --runtime win-x64 `
    --self-contained false `
    --output $output `
    -p:PublishSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}
