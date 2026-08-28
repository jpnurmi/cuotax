# SPDX-License-Identifier: MIT

param(
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projectRoot = (Resolve-Path (Join-Path $windowsRoot "..")).Path
$output = Join-Path $projectRoot "dist\windows"
$buildCommit = (& git -C $projectRoot rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $buildCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Could not determine the build commit"
}

dotnet publish (Join-Path $windowsRoot "CuotaX\CuotaX.csproj") `
    --configuration $Configuration `
    --runtime win-x64 `
    --self-contained false `
    --output $output `
    -p:PublishSingleFile=true `
    -p:DebugType=None `
    -p:DebugSymbols=false `
    -p:SourceRevisionId=$buildCommit

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}
