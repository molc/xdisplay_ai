<#
.SYNOPSIS
  Start one packaging run on the Windows builder (win11-wsl2-builder) and record its state as JSON.
.DESCRIPTION
  Replaces the hand-copied Run-Native014Build-rN.ps1 wrappers. Guards: no existing work root, no other build
  process, scratch volume identity + 12 GiB floor, pinned client identity, optional proof hashes for overlaid files,
  and the unit-test log written by Sync-SourceOverlay.ps1 must end with "EXIT 0". TEMP is pointed at a directory
  that belongs to this run (a missing TEMP makes WiX smartcab spin forever, see ops/README.md).
  Run it detached (Start-Process ... -WindowStyle Hidden) because a full build takes 30-70 minutes.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File T:\logs\Invoke-NativeBuild.ps1 -Run r12 -SourceCommit <40 hex> -Reason 'client c-186'
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^r\d+$')][string]$Run,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{7,40}$')][string]$SourceCommit,
    [string]$SourceRoot = 'T:\source-e2e27dd8\windows-packaging',
    [string]$WorkRoot = '',
    [string]$Logs = 'T:\logs',
    [string]$Reason = '',
    [string]$ExpectedClientSha256 = '',
    [string]$ExpectedConverterSha256 = '',
    [string]$ClientReleaseDir = '',
    [string]$ConverterReleaseDir = 'P:\converter-fix-10b7\bin',
    [string]$BackendCommit = 'dd6ab3d505827a94cbc9d59d7067fcce14db6fbe',
    [string]$PinsPath = '',
    [hashtable]$RequiredFileHashes = @{},
    [int]$LimitSeconds = 10800,
    [switch]$SkipUnitTestWait
)
$ErrorActionPreference = 'Stop'
$commit8 = $SourceCommit.Substring(0, 8).ToLower()
if (-not $WorkRoot) { $WorkRoot = "T:\work\014-s63f-$commit8-$Run" }
if (-not $ClientReleaseDir) { $ClientReleaseDir = Join-Path $SourceRoot 'inputs\client\xdisplay-win64' }
if (-not $PinsPath) { $PinsPath = Join-Path $SourceRoot 'manifests\pins\offline-inputs.s63f.json' }
$cached = Get-Content (Join-Path $SourceRoot 'ci\CachedRelease.ps1') -Raw
if (-not $ExpectedClientSha256) { $ExpectedClientSha256 = [regex]::Match($cached, "Get-PinnedCatalogwriteClientSha256\s*\{\s*return\s*'([0-9A-Fa-f]{64})'").Groups[1].Value }
if (-not $ExpectedConverterSha256) { $ExpectedConverterSha256 = [regex]::Match($cached, "Get-PinnedConverterSha256\s*\{\s*return\s*'([0-9A-Fa-f]{64})'").Groups[1].Value }
if (-not $ExpectedClientSha256 -or -not $ExpectedConverterSha256) { throw 'Could not read the pinned client/converter SHA256 from ci/CachedRelease.ps1' }

$statePath = Join-Path $Logs "$Run-state.json"
$report = Join-Path $Logs "$Run-product-report.json"
$stdout = Join-Path $Logs "$Run.stdout.log"
$stderr = Join-Path $Logs "$Run.stderr.log"
$unitLog = Join-Path $Logs "$Run-unit-tests.log"
$state = [ordered]@{ run = $Run; sourceCommit = $SourceCommit; backendCommit = $BackendCommit; workRoot = $WorkRoot; productReport = $report; stdout = $stdout; stderr = $stderr; limitSeconds = $LimitSeconds; reason = $Reason }
function Save([string]$phase) { $state.phase = $phase; $state.guestObservedRaw = [DateTimeOffset]::Now.ToString('o'); $state | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -LiteralPath $statePath }
try {
    if (Test-Path $WorkRoot) { throw "Work root already exists: $WorkRoot (never overwrite a run)" }
    foreach ($rel in $RequiredFileHashes.Keys) {
        $h = (Get-FileHash (Join-Path $SourceRoot $rel)).Hash
        if ($h -ne $RequiredFileHashes[$rel].ToUpper()) { throw "Overlay proof failed: $rel is $h, expected $($RequiredFileHashes[$rel])" }
    }
    $clientHash = (Get-FileHash (Join-Path $ClientReleaseDir 'Xdisplay.exe')).Hash
    if ($clientHash -ne $ExpectedClientSha256.ToUpper()) { throw "Xdisplay.exe in $ClientReleaseDir is $clientHash, not the pinned $ExpectedClientSha256" }
    $v = Get-Volume -DriveLetter T
    if ($v.FileSystemLabel -ne 'XDP014BUILD' -or $v.SizeRemaining -lt 12GB) { throw 'Scratch volume identity/12 GiB floor failed' }
    $other = @(Get-CimInstance Win32_Process | Where-Object ProcessId -ne $PID | Where-Object { $_.Name -match '^(wix|wixnative)\.exe$' -or ($_.Name -eq 'powershell.exe' -and $_.CommandLine -match '\s-File\s+\S*build-offline-package\.ps1') })
    if ($other.Count) { throw 'Another build process exists; no duplicate' }
    if (-not $SkipUnitTestWait) {
        Save 'WAITING_UNIT_TESTS'; $w = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $done = @(); if (Test-Path $unitLog) { $done = @(Get-Content $unitLog -ErrorAction SilentlyContinue | Where-Object { $_ -match '^EXIT ' }) }
            if ($done.Count) { break }
            if ($w.Elapsed.TotalMinutes -gt 30) { throw "unit tests did not finish within 30 min ($unitLog)" }
            Start-Sleep 10
        }
        $state.unitTestExit = [string]$done[-1]
        if ($done[-1] -ne 'EXIT 0') { throw ('unit tests failed: ' + $done[-1]) }
    }
    $temp = "T:\work\ops-temp-$Run"; [IO.Directory]::CreateDirectory($temp) | Out-Null
    $env:TEMP = $temp; $env:TMP = $temp   # WiX smartcab retries CreateFile in %TEMP% forever if the directory is missing
    $a = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $SourceRoot 'build-offline-package.ps1'),
        '-Channel', 'dev', '-SkipClientBuild', '-UseExistingBackendInputs',
        '-ClientReleaseDir', $ClientReleaseDir, '-ConverterReleaseDir', $ConverterReleaseDir,
        '-ExpectedClientSha256', $ExpectedClientSha256, '-ExpectedConverterSha256', $ExpectedConverterSha256,
        '-PrerequisitesSourceRoot', (Join-Path $SourceRoot 'inputs\prerequisites'),
        '-ExpectedInputPinsPath', $PinsPath, '-WorkRoot', $WorkRoot, '-ReportPath', $report)
    $state.actualArguments = $a; Save 'STARTING_FULL_BUILD'
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $p.Handle; $state.nativePid = $p.Id; Save 'FULLBUILD_RUNNING'; $w = [Diagnostics.Stopwatch]::StartNew()
    if (-not $p.WaitForExit($LimitSeconds * 1000)) { $state.timedOut = $true; $state.elapsedSeconds = [Math]::Round($w.Elapsed.TotalSeconds, 2); Save 'TIMEOUT_NATIVE_RETAINED_NO_KILL'; exit 2 }
    $p.Refresh(); $state.nativeExitCode = $p.ExitCode; $state.elapsedSeconds = [Math]::Round($w.Elapsed.TotalSeconds, 2)
    if ($null -eq $state.nativeExitCode) { throw 'Null native exit is not success' }
    if (Test-Path $report) { $product = [IO.File]::ReadAllText($report, [Text.Encoding]::UTF8) | ConvertFrom-Json; $state.productStatus = $product.status }
    if ($state.nativeExitCode -ne 0) { Save 'STOPPED_NATIVE_FAILURE'; exit 1 }
    Save 'NATIVE_EXIT0_ACCEPTANCE_PENDING'; exit 0
}
catch { $state.errorMessage = $_.Exception.Message; Save 'STOPPED_SEE_ERROR'; exit 1 }
