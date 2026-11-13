<#
.SYNOPSIS
  Upload a run's dist to the control host's receiver (ops/host/recv.py), skipping files identical to a previous run.
  Runs detached; progress goes to <Logs>\upload-<Run>-progress.txt (last line DONE or ERROR).
#>
param(
    [Parameter(Mandatory = $true)][string]$Run,
    [Parameter(Mandatory = $true)][string]$ReceiverUrl,   # e.g. http://172.19.103.18:27120/
    [string]$PreviousRun = '',
    [string]$Logs = 'T:\logs'
)
$ErrorActionPreference = 'Stop'
$state = Get-Content (Join-Path $Logs "$Run-state.json") -Raw | ConvertFrom-Json
$src = Join-Path $state.workRoot 'dist\dev'
$old = ''
if ($PreviousRun) { $old = Join-Path ((Get-Content (Join-Path $Logs "$PreviousRun-state.json") -Raw | ConvertFrom-Json).workRoot) 'dist\dev' }
$prog = Join-Path $Logs "upload-$Run-progress.txt"
$script = @"
`$ErrorActionPreference='Stop'
"START `$(Get-Date -Format o)" | Set-Content '$prog'
try {
  Add-Type -AssemblyName System.Net.Http
  `$c = New-Object System.Net.Http.HttpClient; `$c.Timeout = [TimeSpan]::FromHours(2)
  foreach (`$f in (Get-ChildItem '$src' -File | Sort-Object Length)) {
    `$o = if ('$old') { Join-Path '$old' `$f.Name } else { '' }
    if (`$o -and (Test-Path `$o) -and (Get-Item `$o).Length -eq `$f.Length -and (Get-FileHash `$o).Hash -eq (Get-FileHash `$f.FullName).Hash) { "`$(`$f.Name) `$(`$f.Length) SAME-AS-PREVIOUS" | Add-Content '$prog'; continue }
    `$fs = [IO.File]::OpenRead(`$f.FullName)
    try { `$content = New-Object System.Net.Http.StreamContent(`$fs); `$resp = `$c.PutAsync('$ReceiverUrl' + [Uri]::EscapeDataString(`$f.Name), `$content).GetAwaiter().GetResult(); "`$(`$f.Name) `$(`$f.Length) HTTP `$([int]`$resp.StatusCode)" | Add-Content '$prog'; if ([int]`$resp.StatusCode -ne 200) { throw "PUT failed for `$(`$f.Name)" } } finally { `$fs.Dispose() }
  }
  "DONE `$(Get-Date -Format o)" | Add-Content '$prog'
} catch { "ERROR `$(`$_.Exception.Message)" | Add-Content '$prog' }
"@
$runner = "C:\Temp\xdai-upload-$Run.ps1"; [IO.Directory]::CreateDirectory('C:\Temp') | Out-Null
[IO.File]::WriteAllText($runner, $script, [Text.UTF8Encoding]::new($true))
$p = Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $runner" -WindowStyle Hidden -PassThru
"UPLOADER_PID $($p.Id) progress=$prog"
