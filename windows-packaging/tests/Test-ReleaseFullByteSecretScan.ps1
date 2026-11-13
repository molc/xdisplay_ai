param(
    [string]$PackagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

$policyPath = Join-Path $PackagingRoot 'manifests\security\release-fullbyte-scan-policy.s63i-hf2b.json'
$refPath = Join-Path $PackagingRoot 'manifests\security\ORIGINAL-FAIL-RECEIPT.REFERENCE.json'
$proposedPath = Join-Path $PackagingRoot 'manifests\security\PROPOSED-EXACT-EXCEPTIONS.NOT-ACTIVE.json'
$scanner = Join-Path $PackagingRoot 'ci\release_fullbyte_secret_scan.py'
$wrapper = Join-Path $PackagingRoot 'ci\Invoke-ReleaseFullByteSecretScan.ps1'

Assert-True -Condition (Test-Path -LiteralPath $policyPath) -Message 'Active full-byte scan policy missing.'
Assert-True -Condition (Test-Path -LiteralPath $refPath) -Message 'Original FAIL receipt reference missing.'
Assert-True -Condition (Test-Path -LiteralPath $proposedPath) -Message 'Proposed exceptions evidence copy missing.'
Assert-True -Condition (Test-Path -LiteralPath $scanner) -Message 'release_fullbyte_secret_scan.py missing.'
Assert-True -Condition (Test-Path -LiteralPath $wrapper) -Message 'Invoke-ReleaseFullByteSecretScan.ps1 missing.'

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
Assert-True -Condition ($policy.occurrenceCount -eq 18) -Message 'Active policy must bind exactly 18 reviewed occurrences.'
Assert-True -Condition (@($policy.exceptions).Count -eq 18) -Message 'Active policy exceptions length must be 18.'
Assert-True -Condition ($policy.limitations.ffmpegUnsignedDistributorProvenance -eq 'NOT_PROVEN') -Message 'Policy must honestly document FFmpeg provenance as NOT_PROVEN.'
Assert-True -Condition ($policy.explicitlyNotAllowed -contains 'backend_companion_snakeoil_complete_pem') -Message 'Policy must refuse snakeoil allowance.'
Assert-True -Condition ($policy.gitleaks.independent -eq $true) -Message 'Gitleaks must remain independent of full-byte scan.'
foreach ($ex in @($policy.exceptions)) {
    Assert-True -Condition ($ex.active -eq $true) -Message 'Every active-policy exception must have active=true.'
    Assert-True -Condition (@($ex.publicSourceProof).Count -gt 0) -Message 'Exception missing publicSourceProof.'
    Assert-True -Condition ([string]$ex.classification -notmatch 'SNAKEOIL') -Message 'Snakeoil must not be activated as an exception.'
}

$ref = Get-Content -LiteralPath $refPath -Raw | ConvertFrom-Json
Assert-True -Condition ($ref.doNotRewrite -eq $true) -Message 'Original FAIL receipt reference must set doNotRewrite.'
Assert-True -Condition ($ref.windowsReceiptSha256 -eq 'CBFED2C99D0BBB17E071108B07D1C9895B21D4461365B9795FCD10FED2801401') -Message 'Preserved FAIL receipt SHA mismatch.'

$pythonTests = Join-Path $PSScriptRoot 'test_release_fullbyte_secret_scan.py'
Write-Host 'RUN python3 -m unittest test_release_fullbyte_secret_scan'
Push-Location $PSScriptRoot
try {
    & python3 -m unittest test_release_fullbyte_secret_scan.py
    if ($LASTEXITCODE -ne 0) {
        throw "test_release_fullbyte_secret_scan.py failed (exit $LASTEXITCODE)"
    }
}
finally {
    Pop-Location
}

. (Join-Path $PackagingRoot 'ci\CachedRelease.ps1')
Assert-True -Condition ((Get-PinnedClientScanStatus) -eq 'PENDING_AUDITED_RESCAN') -Message 'Packaging gate scan pin must stay PENDING_AUDITED_RESCAN.'

$wrapperText = Get-Content -LiteralPath $wrapper -Raw
Assert-True -Condition ($wrapperText -match 'release_fullbyte_secret_scan\.py') -Message 'Wrapper must invoke the Python full-byte scanner.'
Assert-True -Condition ($wrapperText -match 'NEW audited') -Message 'Wrapper must document NEW audited report emission.'

Write-Host 'PASS: release full-byte secret scan policy + unit tests'
exit 0
