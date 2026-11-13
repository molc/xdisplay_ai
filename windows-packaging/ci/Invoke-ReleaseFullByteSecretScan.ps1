<#
.SYNOPSIS
  Audited occurrence-aware full-byte release secret scan (standalone).

.DESCRIPTION
  Full-file binary scan of a Windows final release candidate tree.
  Exact public-constant exceptions come from the active policy JSON.
  Emits a NEW audited report; does not rewrite the preserved original FAIL receipt.
  Independent of text-only Invoke-SecretsScan and of gitleaks (empty gitleaks [] is not PASS).

.EXAMPLE
  pwsh -NoProfile -File windows-packaging/ci/Invoke-ReleaseFullByteSecretScan.ps1 `
    -ReleaseRoot 'T:\c186-client-inputs-1898d30c-20261112\final' `
    -OutputPath 'T:\c186-client-inputs-1898d30c-20261112\audited-fullbyte-scan-report.json'
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseRoot,
    [string]$PolicyPath = '',
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [string]$PythonExe = 'python',
    [switch]$AllowEmptyTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $packagingRoot 'manifests\security\release-fullbyte-scan-policy.s63i-hf2b.json'
}

$scanner = Join-Path $PSScriptRoot 'release_fullbyte_secret_scan.py'
if (-not (Test-Path -LiteralPath $scanner -PathType Leaf)) {
    throw "Full-byte scanner missing: $scanner"
}
if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    throw "Full-byte scan policy missing: $PolicyPath"
}
if (-not (Test-Path -LiteralPath $ReleaseRoot -PathType Container)) {
    throw "Release root does not exist: $ReleaseRoot"
}

$python = $PythonExe
if (-not (Get-Command -Name $python -ErrorAction SilentlyContinue)) {
    foreach ($candidate in @('python3', 'py')) {
        if (Get-Command -Name $candidate -ErrorAction SilentlyContinue) {
            $python = $candidate
            break
        }
    }
}
if (-not (Get-Command -Name $python -ErrorAction SilentlyContinue)) {
    throw 'Python is required for Invoke-ReleaseFullByteSecretScan (python/python3/py).'
}

$argList = @(
    $scanner,
    '--root', $ReleaseRoot,
    '--policy', $PolicyPath,
    '--output', $OutputPath
)
if ($AllowEmptyTree) {
    $argList += '--allow-empty-tree'
}

& $python @argList
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    throw "Audited full-byte secret scan FAIL (exit $exit). Report: $OutputPath. Original FAIL receipt must remain preserved; this is a NEW report only."
}

return [pscustomobject]@{
    ok = $true
    outputPath = $OutputPath
    policyPath = $PolicyPath
    releaseRoot = $ReleaseRoot
}
