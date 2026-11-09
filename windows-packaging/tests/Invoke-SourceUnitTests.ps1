param(
    [string]$PackagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host 'RUN Test-NativePowerShellEncoding.ps1'
& (Join-Path $PSScriptRoot 'Test-NativePowerShellEncoding.ps1') -PackagingRoot $PackagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Test-NativePowerShellEncoding.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'RUN Test-S63fPackagingContract.ps1'
& (Join-Path $PSScriptRoot 'Test-S63fPackagingContract.ps1') -PackagingRoot $PackagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Test-S63fPackagingContract.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'RUN Test-CachedReleasePackaging.ps1'
& (Join-Path $PSScriptRoot 'Test-CachedReleasePackaging.ps1') -PackagingRoot $PackagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Test-CachedReleasePackaging.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'RUN Test-InstallerCorrectness.ps1'
& (Join-Path $PSScriptRoot 'Test-InstallerCorrectness.ps1') -PackagingRoot $PackagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Test-InstallerCorrectness.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'RUN Test-PromptPinMigration.ps1'
& (Join-Path $PSScriptRoot 'Test-PromptPinMigration.ps1')
if ($LASTEXITCODE -ne 0) {
    throw "Test-PromptPinMigration.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'RUN Test-PublishedPortFallback.ps1'
& (Join-Path $PSScriptRoot 'Test-PublishedPortFallback.ps1') -PackagingRoot $PackagingRoot
if ($LASTEXITCODE -ne 0) {
    throw "Test-PublishedPortFallback.ps1 failed (exit $LASTEXITCODE)"
}

Write-Host 'PASS: source/unit tests (not Windows acceptance)'
exit 0
