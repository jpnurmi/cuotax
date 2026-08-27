# SPDX-License-Identifier: MIT

param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projects = @(
    (Join-Path $windowsRoot "CuotaX\CuotaX.csproj"),
    (Join-Path $windowsRoot "CuotaX.Tests\CuotaX.Tests.csproj")
)

foreach ($project in $projects) {
    $formatArguments = @("format", $project)
    if ($Check) {
        $formatArguments += "--verify-no-changes"
    }

    & dotnet $formatArguments
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
