# SPDX-License-Identifier: MIT

param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$projects = @(
    (Join-Path $projectRoot "windows\CuotaX\CuotaX.csproj"),
    (Join-Path $projectRoot "tests\CuotaX.Windows.Tests\CuotaX.Windows.Tests.csproj")
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
