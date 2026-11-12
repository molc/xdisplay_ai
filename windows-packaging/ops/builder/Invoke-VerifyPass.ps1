<#
.SYNOPSIS
  Feed the .29 acceptance evidence to build-offline-package.ps1 -VerifyExistingOutputsOnly so the release gate can
  flip release-status.json to "pass" and remove NOT_READY.txt. Runs detached; watch <Logs>\<Run>-verify-pass.stdout.log
  for a final "EXIT <code>" line.
#>
param(
    [Parameter(Mandatory = $true)][string]$Run,
    [Parameter(Mandatory = $true)][string]$EvidenceUrl,    # http://172.19.103.18:18049/<run>/windows-pass-dot29.json
    [string]$SourceRoot = 'T:\source-e2e27dd8\windows-packaging',
    [string]$Logs = 'T:\logs',
    [string]$ConverterReleaseDir = 'P:\converter-fix-10b7\bin'
)
$ErrorActionPreference = 'Stop'
$state = Get-Content (Join-Path $Logs "$Run-state.json") -Raw | ConvertFrom-Json
$script:buildArgs = @($state.actualArguments)   # not $args: inside a function $args is the function's own automatic variable
function Arg([string]$name) { $i = [array]::IndexOf($script:buildArgs, $name); if ($i -lt 0) { throw "state has no $name" }; return $script:buildArgs[$i + 1] }
$ev = Join-Path $Logs "windows-pass-$Run.json"
Invoke-WebRequest -UseBasicParsing $EvidenceUrl -OutFile $ev
$evidence = Get-Content $ev -Raw | ConvertFrom-Json
$bundle = Join-Path $state.workRoot 'dist\dev\XDisplayAI-0.1.4-dev.exe'
$actual = (Get-FileHash $bundle).Hash.ToLower()
if ($evidence.candidate.bundleSha256.ToLower() -ne $actual) { throw "evidence bundle sha $($evidence.candidate.bundleSha256) != dist $actual" }
$log = Join-Path $Logs "$Run-verify-pass.stdout.log"
$reportOut = Join-Path $Logs "$Run-verify-pass-report.json"
$script = @"
`$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$SourceRoot\build-offline-package.ps1' -Channel dev -SkipClientBuild -UseExistingBackendInputs -VerifyExistingOutputsOnly -ClientReleaseDir '$(Arg '-ClientReleaseDir')' -ConverterReleaseDir '$ConverterReleaseDir' -ExpectedClientSha256 '$(Arg '-ExpectedClientSha256')' -ExpectedConverterSha256 '$(Arg '-ExpectedConverterSha256')' -PrerequisitesSourceRoot '$(Arg '-PrerequisitesSourceRoot')' -ExpectedInputPinsPath '$(Arg '-ExpectedInputPinsPath')' -WorkRoot '$($state.workRoot)' -AcceptanceEvidencePath '$ev' -ReportPath '$reportOut' *>> '$log'
"EXIT `$LASTEXITCODE" | Add-Content '$log'
"@
$runner = "C:\Temp\xdai-verify-pass-$Run.ps1"; [IO.Directory]::CreateDirectory('C:\Temp') | Out-Null
[IO.File]::WriteAllText($runner, $script, [Text.UTF8Encoding]::new($true))
$p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $runner" -WindowStyle Hidden -PassThru
"VERIFY_PID $($p.Id) log=$log"
