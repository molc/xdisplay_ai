param([Parameter(Mandatory = $true)][string]$Run, [string]$Logs = 'T:\logs')
$p = Join-Path $Logs "$Run-state.json"
if (-not (Test-Path $p)) { "PHASE NO_STATE_FILE"; return }
$j = Get-Content $p -Raw | ConvertFrom-Json
"PHASE {0} exit={1} status={2} elapsed={3} err={4}" -f $j.phase, $j.nativeExitCode, $j.productStatus, $j.elapsedSeconds, $j.errorMessage
