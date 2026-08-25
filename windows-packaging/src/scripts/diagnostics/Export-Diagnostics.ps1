Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')
Initialize-InstallStateDirectories
Initialize-RuntimeEnvironment | Out-Null

$layout = Get-DockerLayout
$stateLayout = Get-InstallStateLayout
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputRoot = Join-Path $env:TEMP "xdisplayai-diagnostics-$timestamp"

New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

Write-Step "导出诊断到 $outputRoot"

Invoke-Compose -Arguments @('ps') | Out-File -FilePath (Join-Path $outputRoot 'compose-ps.txt') -Encoding utf8
Invoke-Compose -Arguments @('logs', '--no-color') | Out-File -FilePath (Join-Path $outputRoot 'compose-logs.txt') -Encoding utf8
if (Test-Path $layout.EnvFile) {
    $redactedLines = Get-Content -Path $layout.EnvFile | ForEach-Object {
        if ($_ -match '^[A-Z0-9_]*(API_KEY|TOKEN|SECRET)[A-Z0-9_]*=') {
            $name = $_.Split('=', 2)[0]
            "$name=***REDACTED***"
        }
        else {
            $_
        }
    }
    $redactedLines | Out-File -FilePath (Join-Path $outputRoot 'runtime.env') -Encoding utf8
}

if (Test-Path $stateLayout.BootstrapLog) {
    Copy-Item -Path $stateLayout.BootstrapLog -Destination (Join-Path $outputRoot 'bootstrap.log') -Force
}
try {
    & (Join-Path $PSScriptRoot '..\health\Test-Health.ps1') | Out-File -FilePath (Join-Path $outputRoot 'health.json') -Encoding utf8
}
catch {
    $_.Exception.Message | Out-File -FilePath (Join-Path $outputRoot 'health-error.txt') -Encoding utf8
}

$zipPath = "$outputRoot.zip"
Compress-Archive -Path (Join-Path $outputRoot '*') -DestinationPath $zipPath -Force
Write-Step "诊断包已生成：$zipPath"
