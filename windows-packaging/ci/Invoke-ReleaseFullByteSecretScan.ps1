<#
.SYNOPSIS
  Audited occurrence-aware full-byte release secret scan (standalone).

.DESCRIPTION
  Full-file binary scan of a Windows final release candidate tree.
  Exact public-constant exceptions come from the active policy JSON.
  Emits a NEW create-new/exclusive audited report; refuses protected evidence /
  policy / scanner paths and refuses outputs inside the release root.
  Independent of text-only Invoke-SecretsScan and of gitleaks (empty gitleaks [] is not PASS).

.EXAMPLE
  pwsh -NoProfile -File windows-packaging/ci/Invoke-ReleaseFullByteSecretScan.ps1 `
    -ReleaseRoot 'T:\c186-client-inputs-1898d30c-20261112\final' `
    -TreeManifestPath 'T:\c186-client-inputs-1898d30c-20261112\final-tree-manifest.json' `
    -ExpectedFileCount 2389 `
    -OutputPath 'T:\c186-client-inputs-1898d30c-20261112\audited-fullbyte-scan-report-NEW.json'
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseRoot,
    [string]$PolicyPath = '',
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedFileCount,
    [Parameter(Mandatory = $true)]
    [string]$TreeManifestPath,
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
if (-not (Test-Path -LiteralPath $TreeManifestPath -PathType Leaf)) {
    throw "Tree manifest does not exist: $TreeManifestPath"
}
if ($ExpectedFileCount -le 0) {
    throw 'ExpectedFileCount must be a positive complete tree file count'
}
if (Test-Path -LiteralPath $OutputPath) {
    throw "OutputPath already exists (create-new/exclusive only; refusing overwrite): $OutputPath"
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
    '--output', $OutputPath,
    '--expected-file-count', "$ExpectedFileCount",
    '--tree-manifest', $TreeManifestPath
)
if ($AllowEmptyTree) {
    $argList += '--allow-empty-tree'
}

& $python @argList
$exit = $LASTEXITCODE
if ($exit -ne 0) {
    throw "Audited full-byte secret scan FAIL (exit $exit). Report path was create-new only: $OutputPath. Original FAIL receipt must remain preserved."
}

return [pscustomobject]@{
    ok = $true
    outputPath = $OutputPath
    policyPath = $PolicyPath
    releaseRoot = $ReleaseRoot
    expectedFileCount = $ExpectedFileCount
    treeManifestPath = $TreeManifestPath
}
