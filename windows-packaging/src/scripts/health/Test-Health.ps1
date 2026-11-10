param(
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')

Initialize-InstallStateDirectories
$stateLayout = Get-InstallStateLayout
if (-not (Test-Path -LiteralPath $stateLayout.RuntimeEnvFile)) {
    Initialize-RuntimeEnvironment | Out-Null
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$runtimeSettings = Get-RuntimeSettings
$requiredPort = Get-RequiredAppHostPort
$appPort = if ($runtimeSettings.Contains('APP_HOST_PORT') -and -not [string]::IsNullOrWhiteSpace([string]$runtimeSettings['APP_HOST_PORT'])) {
    [int]$runtimeSettings['APP_HOST_PORT']
}
else {
    $requiredPort
}
if ($appPort -ne $requiredPort) {
    throw "runtime.env 的 APP_HOST_PORT=$appPort，合同要求必须是 $requiredPort。安装器不会改用其他端口。"
}

$baseUrl = "http://127.0.0.1:$requiredPort"
$lastError = ''
$attempt = 0
$probeTimeoutSec = 15
if ($probeTimeoutSec -gt $TimeoutSeconds) {
    $probeTimeoutSec = [Math]::Max(1, $TimeoutSeconds)
}

$healthzStatus = 0
$assistantStatus = 0

while ((Get-Date) -lt $deadline) {
    $attempt++
    $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)
    $requestTimeout = [Math]::Min($probeTimeoutSec, [Math]::Max(1, $remaining))
    try {
        $healthz = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/healthz" -TimeoutSec $requestTimeout
        $assistant = Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/api/v1/assistant/health" -TimeoutSec $requestTimeout
        $healthzStatus = [int]$healthz.StatusCode
        $assistantStatus = [int]$assistant.StatusCode
        if ($healthzStatus -eq 200 -and $assistantStatus -eq 200) {
            $facts = Get-LocalBackendOriginFacts -HealthzStatus $healthzStatus -AssistantStatus $assistantStatus -RequiredPort $requiredPort
            $origin = Test-LocalBackendOrigin `
                -HealthzStatus $facts.HealthzStatus `
                -AssistantStatus $facts.AssistantStatus `
                -PublishedBinding $facts.PublishedBinding `
                -ListenerProcess $facts.ListenerProcess `
                -PortProxyEntries $facts.PortProxyEntries `
                -RunningServices $facts.RunningServices `
                -DockerHost $facts.DockerHost `
                -ServerOs $facts.ServerOs `
                -OperatingSystem $facts.OperatingSystem `
                -RequiredPort $requiredPort
            if (-not $origin.Ok) {
                throw ("本机后端归属检查失败：" + ($origin.Reasons -join '；'))
            }

            [pscustomobject]@{
                baseUrl = $baseUrl
                healthz = $healthzStatus
                assistantApi = $assistantStatus
                origin = 'local'
                status = 'ok'
            } | ConvertTo-Json
            return
        }
        $lastError = "healthz=$healthzStatus assistant=$assistantStatus"
    }
    catch {
        $lastError = $_.Exception.Message
        $healthzStatus = 0
        $assistantStatus = 0
    }

    Write-Step (New-BoundedWaitStatus -Stage '等待本机 127.0.0.1:18001 健康检查' -Attempt $attempt -MaxAttempts ([Math]::Max($attempt, [int][Math]::Ceiling($TimeoutSeconds / 5))) -LastError $lastError -TimeoutSeconds $remaining)
    Start-Sleep -Seconds 5
}

throw "应用健康检查失败（本机 $baseUrl，$TimeoutSeconds 秒内未同时满足 HTTP 200 与本地 Docker 归属）：$lastError"
