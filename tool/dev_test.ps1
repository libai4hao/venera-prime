#requires -Version 5.1
[CmdletBinding()]
param(
    [int]$Concurrency = 2,
    [switch]$SkipPubGet,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$TestPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    # This repository has several GitHub Git dependencies. On machines where
    # github.com HTTPS is unreliable, rewrite them to SSH for this process
    # only. The user's global Git configuration is intentionally left alone.
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'url.git@github.com:.insteadOf'
    $env:GIT_CONFIG_VALUE_0 = 'https://github.com/'

    if (-not $SkipPubGet) {
        Write-Host '==> flutter pub get'
        flutter pub get
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }

    $flutterArgs = @('test', '--no-pub', "--concurrency=$Concurrency")
    if ($TestPath -and $TestPath.Count -gt 0) {
        $flutterArgs += $TestPath
    }

    Write-Host "==> flutter $($flutterArgs -join ' ')"
    & flutter @flutterArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
