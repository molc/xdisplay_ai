param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('start', 'stop', 'restart', 'status')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')
Initialize-RuntimeEnvironment | Out-Null


switch ($Action) {
    'start' {
        Write-Step '启动后端服务栈。'
        Invoke-Compose -Arguments @('up', '-d')
    }
    'stop' {
        Write-Step '停止后端服务栈。'
        Invoke-Compose -Arguments @('stop')
    }
    'restart' {
        Write-Step '重启后端服务栈。'
        Invoke-Compose -Arguments @('restart')
    }
    'status' {
        Write-Step '查看后端服务栈状态。'
        Invoke-Compose -Arguments @('ps')
    }
}
