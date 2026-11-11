<#
.SYNOPSIS
  Patch the builder's source tree with files served by the control host, verify their SHA256, then run the source
  unit tests into <Logs>\<Run>-unit-tests.log (Invoke-NativeBuild.ps1 waits for its "EXIT 0" line).
.DESCRIPTION
  The builder has no git. ops/host/stage-overlay.sh writes <overlay dir>/<run>/manifest.json
  ({"files": {"ci/validate.ps1": "<SHA256>", ...}}) next to the files; this script downloads each file to the same
  relative path under -SourceRoot, keeping a .<run>bak copy of what it replaces.
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^r\d+$')][string]$Run,
    [Parameter(Mandatory = $true)][string]$BaseUrl,          # e.g. http://172.19.103.18:18049/r12
    [string]$SourceRoot = 'T:\source-e2e27dd8\windows-packaging',
    [string]$Logs = 'T:\logs',
    [switch]$SkipUnitTests
)
$ErrorActionPreference = 'Stop'
$manifest = (Invoke-WebRequest -UseBasicParsing "$BaseUrl/manifest.json").Content | ConvertFrom-Json
$files = $manifest.files
$count = 0
foreach ($prop in $files.PSObject.Properties) {
    $rel = $prop.Name; $expected = ([string]$prop.Value).ToUpper()
    $dst = Join-Path $SourceRoot ($rel -replace '/', '\')
    [IO.Directory]::CreateDirectory((Split-Path $dst -Parent)) | Out-Null
    if (Test-Path $dst) { Copy-Item $dst "$dst.${Run}bak" -Force }
    Invoke-WebRequest -UseBasicParsing "$BaseUrl/$rel" -OutFile $dst
    $h = (Get-FileHash $dst).Hash
    if ($h -ne $expected) { throw "hash mismatch for $rel : got $h expected $expected" }
    $count++
}
"overlaid $count file(s) into $SourceRoot"
if ($SkipUnitTests) { return }
$log = Join-Path $Logs "$Run-unit-tests.log"
if (Test-Path $log) { Remove-Item $log -Force }
$ErrorActionPreference = 'Continue'
try { & (Join-Path $SourceRoot 'tests\Invoke-SourceUnitTests.ps1') *> $log; 'EXIT 0' | Add-Content $log } catch { ('EXIT 1 ' + $_.Exception.Message) | Add-Content $log }
Get-Content $log | Select-Object -Last 4
