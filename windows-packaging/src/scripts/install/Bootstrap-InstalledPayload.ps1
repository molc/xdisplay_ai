param(
    [switch]$LaunchClient,
    [switch]$Resume,
    [switch]$NoAutoReboot
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
    if ($NoAutoReboot) {
        $argumentList += '-NoAutoReboot'
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
    if ($NoAutoReboot) {
        $argumentList += '-NoAutoReboot'
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

function Test-LocalBackendFullyReady {
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
    $appPort = if ($runtimeSettings.Contains('APP_HOST_PORT')) { [string]$runtimeSettings['APP_HOST_PORT'] } else { [string](Get-RequiredAppHostPort) }
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
    if ($Resume) {
        Write-Step '继续执行重启后的离线安装流程。'
    }
    if (-not $Resume -and (Test-LocalBackendFullyReady)) {
        Unregister-ResumeTask
        Clear-BootstrapState
        if ($LaunchClient) {
            Write-Step '本机后端已在 127.0.0.1:18001 就绪，直接启动客户端。'
            Start-XDisplayClient
        }
        else {
            Write-Step '本机后端已在 127.0.0.1:18001 就绪，无需重复初始化。'
        }
        return
    }

    $prerequisiteResult = & (Join-Path $PSScriptRoot 'Install-OfflinePrerequisites.ps1')
    $bootstrapState = Get-BootstrapState
    $rebootAction = Get-BootstrapRebootAction `
        -RebootRequired ([bool]$prerequisiteResult.RebootRequired) `
        -NoAutoReboot:$NoAutoReboot `
        -AutomaticRebootCount ([int]$bootstrapState.AutomaticRebootCount) `
        -MaximumAutomaticReboots $maximumAutomaticReboots `
        -InstallerCustomAction:$NoAutoReboot

    if ($rebootAction.Name -ne 'continue') {
        $rebootReasons = @($prerequisiteResult.RebootReasons | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $reasonText = if ($rebootReasons.Count -gt 0) { $rebootReasons -join '；' } else { 'Windows 可选功能或前置依赖仍待重启' }

        if ($rebootAction.Persist) {
            Save-BootstrapState `
                -AutomaticRebootCount ([int]$rebootAction.NextAutomaticRebootCount) `
                -LastRebootReasons $rebootReasons `
                -Phase 'reboot-pending' `
                -LaunchClientRequested:([bool]$LaunchClient)
        }
        if ($rebootAction.RegisterResumeTask) {
            Register-ResumeTask
            Write-Step "已注册登录后继续任务：$($stateLayout.ResumeTaskName)。状态已写入 $($stateLayout.BootstrapStateFile)"
        }

        if ($rebootAction.Throw) {
            throw "前置依赖连续请求重启，已阻止继续自动重启以避免循环：$reasonText。已保留恢复状态，请手动重启后由 Resume 任务继续，或运行 Complete Offline Setup。"
        }

        if ($rebootAction.AutoReboot) {
            Write-Step "5 秒后自动重启（第 $($rebootAction.NextAutomaticRebootCount)/$maximumAutomaticReboots 次），重启后在交互用户会话继续离线安装直到本机 18001 就绪。原因：$reasonText"
            & shutdown.exe /r /t 5 /c "XDisplayAI installer will continue after reboot." | Out-Null
            return
        }

        Write-Step "安装文件已提交。需要重启才能完成 WSL/VirtualMachinePlatform。当前指定了 -NoAutoReboot，不会自动关机。请手动重启；重启后任务 $($stateLayout.ResumeTaskName) 会在交互会话继续，直到四个本机容器和 127.0.0.1:18001 就绪。原因：$reasonText"
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
