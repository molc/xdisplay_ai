param(
    [switch]$LaunchClient,
    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\\common\\Common.ps1')

function Invoke-ElevatedSelf {
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`""
    )

    if ($LaunchClient) {
        $argumentList += '-LaunchClient'
    }
    if ($Resume) {
        $argumentList += '-Resume'
    }

    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentList -Wait -PassThru
    exit $process.ExitCode
}

function Register-ResumeTask {
    $stateLayout = Get-InstallStateLayout
    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`"",
        '-Resume'
    )

    if ($LaunchClient) {
        $argumentList += '-LaunchClient'
    }

    try {
        Unregister-ScheduledTask -TaskName $stateLayout.ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argumentList -join ' ')
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $stateLayout.ResumeTaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Unregister-ResumeTask {
    $stateLayout = Get-InstallStateLayout
    try {
        Unregister-ScheduledTask -TaskName $stateLayout.ResumeTaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }
}
function Enable-RemoteDesktopAccess {
    Write-Step '启用 Windows 远程桌面访问。'

    $terminalServerRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty -Path $terminalServerRegistryPath -Name 'fDenyTSConnections' -Value 0

    $rdpTcpRegistryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    if (Test-Path $rdpTcpRegistryPath) {
        Set-ItemProperty -Path $rdpTcpRegistryPath -Name 'UserAuthentication' -Value 1
    }

    $remoteDesktopRules = @(Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue)
    if ($remoteDesktopRules.Count -gt 0) {
        $remoteDesktopRules | Enable-NetFirewallRule | Out-Null
    }
    else {
        & netsh advfirewall firewall set rule group='remote desktop' new enable=Yes | Out-Null
    }

    try {
        Set-Service -Name 'TermService' -StartupType Manual -ErrorAction Stop
    }
    catch {
    }

    try {
        $remoteDesktopService = Get-Service -Name 'TermService' -ErrorAction Stop
        if ($remoteDesktopService.Status -ne 'Running') {
            Start-Service -Name 'TermService' -ErrorAction Stop
        }
    }
    catch {
        Write-Warning '远程桌面服务未能立即启动，但配置已写入系统。'
    }
}

function Test-BackendHealthy {
    try {
        & (Join-Path $PSScriptRoot '..\\health\\Test-Health.ps1') -TimeoutSeconds 5 | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Start-XDisplayClient {
    $stateLayout = Get-InstallStateLayout
    $clientPath = Join-Path $stateLayout.ClientWorkspace 'Xdisplay.exe'
    if (-not (Test-Path $clientPath)) {
        throw "未找到客户端可执行文件：$clientPath"
    }

    $existingProcesses = @(Get-Process -Name 'Xdisplay' -ErrorAction SilentlyContinue)
    foreach ($existingProcess in ($existingProcesses | Sort-Object Id)) {
        try {
            if ([string]::Equals($existingProcess.Path, $clientPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Step 'XDisplay client is already running; reusing existing process.'
                return $existingProcess
            }
        }
        catch {
        }
    }

    $runtimeSettings = Get-RuntimeSettings
    $appPort = if ($runtimeSettings.Contains('APP_HOST_PORT')) { [string]$runtimeSettings['APP_HOST_PORT'] } else { '18001' }
    $baseUrl = "http://127.0.0.1:$appPort"

    Write-Step '启动 XDisplay 客户端。'
    $previousBaseUrl = [Environment]::GetEnvironmentVariable('XDISPLAY_AI_BASE_URL', 'Process')
    $previousUseMock = [Environment]::GetEnvironmentVariable('XDISPLAY_AI_USE_MOCK', 'Process')
    $process = $null
    try {
        $env:XDISPLAY_AI_BASE_URL = $baseUrl
        $env:XDISPLAY_AI_USE_MOCK = '0'
        $process = Start-Process `
            -FilePath $clientPath `
            -WorkingDirectory (Split-Path -Path $clientPath -Parent) `
            -PassThru
    }
    finally {
        if ($null -eq $previousBaseUrl) {
            Remove-Item -Path Env:XDISPLAY_AI_BASE_URL -ErrorAction SilentlyContinue
        }
        else {
            $env:XDISPLAY_AI_BASE_URL = $previousBaseUrl
        }

        if ($null -eq $previousUseMock) {
            Remove-Item -Path Env:XDISPLAY_AI_USE_MOCK -ErrorAction SilentlyContinue
        }
        else {
            $env:XDISPLAY_AI_USE_MOCK = $previousUseMock
        }
    }

    if ($null -eq $process) {
        throw '启动 XDisplay 客户端失败：未返回进程句柄。'
    }

    Start-Sleep -Seconds 3
    $process.Refresh()
    if ($process.HasExited) {
        throw "XDisplay 客户端启动后立即退出，退出码：$($process.ExitCode)"
    }
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
}

Initialize-InstallStateDirectories
$stateLayout = Get-InstallStateLayout
$maximumAutomaticReboots = 2
Start-Transcript -Path $stateLayout.BootstrapLog -Append | Out-Null

try {
    Enable-RemoteDesktopAccess
    if ($Resume) {
        Write-Step '继续执行重启后的离线安装流程。'
    }
    if (-not $Resume -and (Test-BackendHealthy)) {
        Unregister-ResumeTask
        Clear-BootstrapState
        if ($LaunchClient) {
            Write-Step '后端服务已健康，直接启动客户端。'
            Start-XDisplayClient
        }
        else {
            Write-Step '后端服务已健康，无需重复初始化。'
        }
        return
    }

    $prerequisiteResult = & (Join-Path $PSScriptRoot 'Install-OfflinePrerequisites.ps1')
    if ($prerequisiteResult.RebootRequired) {
        $bootstrapState = Get-BootstrapState
        $nextAutomaticRebootCount = [int]$bootstrapState.AutomaticRebootCount + 1
        $rebootReasons = @($prerequisiteResult.RebootReasons | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($nextAutomaticRebootCount -gt $maximumAutomaticReboots) {
            Unregister-ResumeTask
            Clear-BootstrapState
            $reasonText = if ($rebootReasons.Count -gt 0) { $rebootReasons -join '；' } else { '未提供具体原因' }
            throw "前置依赖连续请求重启，已阻止继续自动重启以避免循环：$reasonText"
        }

        Save-BootstrapState -AutomaticRebootCount $nextAutomaticRebootCount -LastRebootReasons $rebootReasons
        Register-ResumeTask
        $reasonSuffix = if ($rebootReasons.Count -gt 0) { '；原因：' + ($rebootReasons -join '；') } else { '' }
        Write-Step "5 秒后自动重启（第 $nextAutomaticRebootCount/$maximumAutomaticReboots 次），重启后继续离线安装流程$reasonSuffix"
        & shutdown.exe /r /t 5 /c "XDisplayAI installer will continue after reboot." | Out-Null
        return
    }

    & (Join-Path $PSScriptRoot 'Install-BackendPayload.ps1')
    Unregister-ResumeTask
    Clear-BootstrapState

    if ($LaunchClient) {
        Start-XDisplayClient
    }
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
