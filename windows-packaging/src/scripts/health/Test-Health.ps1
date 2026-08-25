param(
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')

Initialize-RuntimeEnvironment | Out-Null

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$runtimeSettings = Get-RuntimeSettings
$appPort = if ($runtimeSettings.Contains('APP_HOST_PORT')) { $runtimeSettings['APP_HOST_PORT'] } else { '18001' }
$baseUrl = "http://127.0.0.1:$appPort"
$lastError = $null

while ((Get-Date) -lt $deadline) {
    try {
        $healthz = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/healthz"
        $assistant = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/api/v1/assistant/health"
        if ($healthz.StatusCode -eq 200 -and $assistant.StatusCode -eq 200) {
            [pscustomobject]@{
                baseUrl = $baseUrl
                healthz = $healthz.StatusCode
                assistantApi = $assistant.StatusCode
                status = 'ok'
            } | ConvertTo-Json
            return
        }
    }
    catch {
        $lastError = $_.Exception.Message
    }

    Start-Sleep -Seconds 5
}

throw "应用健康检查失败：$lastError"
