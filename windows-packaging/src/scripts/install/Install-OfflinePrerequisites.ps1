Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\\common\\Common.ps1')

Assert-Admin
Initialize-InstallStateDirectories

function Test-DockerDesktopInstalled {
    if (Test-Path 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe') {
        return $true
    }

    return Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Docker Desktop'
}

function Test-VCRuntimeInstalled {
    try {
        $runtime = Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64' -ErrorAction Stop
        return ($null -ne $runtime) -and ([int]$runtime.Installed -eq 1)
    }
    catch {
        return $false
    }
}

function Test-PendingReboot {
    $rebootSignalPaths = @(
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based Servicing\\RebootPending',
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired'
    )

    foreach ($path in $rebootSignalPaths) {
        if (Test-Path $path) {
            return $true
        }
    }

    $sessionManager = Get-ItemProperty 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager' -ErrorAction SilentlyContinue
    if ($null -eq $sessionManager) {
        return $false
    }

    $pendingRenameProperty = $sessionManager.PSObject.Properties['PendingFileRenameOperations']
    return ($null -ne $pendingRenameProperty) -and ($null -ne $pendingRenameProperty.Value)
}

$restartRequired = $false
$restartReasons = New-Object System.Collections.Generic.List[string]

Write-Step '检查并安装离线前置依赖。'

$featureNames = @(
    'Microsoft-Windows-Subsystem-Linux',
    'VirtualMachinePlatform'
)

foreach ($featureName in $featureNames) {
    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
        if ($feature.State -ne 'Enabled') {
            Write-Step "启用 Windows 可选功能：$featureName"
            $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $featureName -All -NoRestart
            $restartRequired = $true
            if ($null -ne $enableResult) {
                $restartReasons.Add("启用 Windows 可选功能：$featureName（结果状态：$($enableResult.State)）")
            }
            else {
                $restartReasons.Add("启用 Windows 可选功能：$featureName")
            }
        }
    }
    catch {
        Write-Warning "无法检测或启用可选功能 $featureName：$($_.Exception.Message)"
    }
}

if ($restartRequired) {
    Write-Warning '已变更 Windows 可选功能，将在重启后继续执行离线安装流程。'
    Write-Step '前置依赖阶段完成。'
    return [pscustomobject]@{
        RebootRequired = $true
        RebootReasons = @($restartReasons)
    }
}

Write-Step '验证 bundle 已安装关键前置依赖。'

$missingInstalledComponents = @()
if (-not (Test-VCRuntimeInstalled)) {
    $missingInstalledComponents += 'VC++ Runtime'
}
if (-not (Test-DockerDesktopInstalled)) {
    $missingInstalledComponents += 'Docker Desktop'
}

if ($missingInstalledComponents.Count -gt 0) {
    throw "以下前置依赖在 MSI 安装后仍未安装：$($missingInstalledComponents -join ', ')。请从包含 bundle.exe 的完整离线目录重新运行安装，不要单独运行 MSI 或 Complete Offline Setup。"
}

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw '未找到 wsl.exe。请确认系统已安装 WSL 组件后重新运行 bundle.exe。'
}

Write-Step '设置 WSL 默认版本为 2。'
& wsl.exe --set-default-version 2 | Out-Null
$wslDefaultVersionExitCode = $LASTEXITCODE
if ($wslDefaultVersionExitCode -ne 0) {
    if (Test-PendingReboot) {
        throw "设置 WSL 默认版本为 2 失败，退出码：$wslDefaultVersionExitCode；系统仍存在待重启标记。已停止再次自动重启以避免循环，请先完成系统重启后重新运行安装。"
    }
    throw "设置 WSL 默认版本为 2 失败，退出码：$wslDefaultVersionExitCode"
}

$pendingReboot = Test-PendingReboot
$bootstrapState = Get-BootstrapState
$pendingRebootDisposition = Get-PendingRebootDisposition `
    -PendingReboot $pendingReboot `
    -AutomaticRebootCount ([int]$bootstrapState.AutomaticRebootCount)

if ($pendingRebootDisposition -eq 'reboot') {
    $restartReasons.Add('bundle 前置依赖安装后系统仍存在待重启标记')
    Write-Warning '检测到系统待重启，将在重启后继续执行离线安装流程。'
    Write-Step '前置依赖阶段完成。'
    return [pscustomobject]@{
        RebootRequired = $true
        RebootReasons = @($restartReasons)
    }
}

if ($pendingReboot) {
    Write-Warning '重启后仍检测到待重启标记，视为残留标记并继续执行，以避免循环重启。'
}

Write-Step '前置依赖阶段完成。'

return [pscustomobject]@{
    RebootRequired = $false
    RebootReasons = @()
}
