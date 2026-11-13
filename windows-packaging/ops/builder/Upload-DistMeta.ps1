<# After Invoke-VerifyPass.ps1 succeeded, push the refreshed small files (manifest, release-status, pins) to the receiver. #>
param([Parameter(Mandatory = $true)][string]$Run, [Parameter(Mandatory = $true)][string]$ReceiverUrl, [string]$Logs = 'T:\logs')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
$c = New-Object System.Net.Http.HttpClient
$src = Join-Path ((Get-Content (Join-Path $Logs "$Run-state.json") -Raw | ConvertFrom-Json).workRoot) 'dist\dev'
foreach ($f in (Get-ChildItem $src -File | Where-Object { $_.Length -lt 2MB })) {
    $fs = [IO.File]::OpenRead($f.FullName)
    try { $content = New-Object System.Net.Http.StreamContent($fs); $resp = $c.PutAsync($ReceiverUrl + [Uri]::EscapeDataString($f.Name), $content).GetAwaiter().GetResult(); "{0} {1} HTTP {2}" -f $f.Name, $f.Length, [int]$resp.StatusCode } finally { $fs.Dispose() }
}
"NOT_READY present in dist: {0}" -f (Test-Path (Join-Path $src 'NOT_READY.txt'))
