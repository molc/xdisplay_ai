param(
    [switch]$RemoveVolumes,
    [switch]$RemoveDataDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\\common\\Common.ps1')

function Remove-ScheduledTaskIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }
}

Assert-Admin
Initialize-InstallStateDirectories
$stateLayout = Get-InstallStateLayout

$downArguments = @('down')
if ($RemoveVolumes) {
    $downArguments += '--volumes'
}

Write-Step '停止并移除后端服务栈。'
Invoke-Compose -Arguments $downArguments
Remove-ScheduledTaskIfPresent -TaskName $stateLayout.ResumeTaskName
Remove-ScheduledTaskIfPresent -TaskName 'XDisplayAI-BackendStartupValidation'
Clear-BootstrapState

if ($RemoveDataDirectory) {
    if (Test-Path $stateLayout.DataRoot) {
        Write-Step "删除数据目录：$($stateLayout.DataRoot)"
        Remove-Item -Path $stateLayout.DataRoot -Recurse -Force
    }
}
