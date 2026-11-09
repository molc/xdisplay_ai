param(
    [string]$PackagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1')

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Expected,
        [Parameter(Mandatory = $true)]
        [int]$Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "$Message Expected=$Expected Actual=$Actual"
    }
}

$ranges = @(ConvertTo-TcpExcludedPortRanges -Lines @(
    'Protocol tcp Port Exclusion Ranges',
    '',
    'Start Port    End Port',
    '----------    --------',
    '     55432       55440     *',
    '     18001       18001'
))
if (@($ranges).Count -ne 2) {
    throw "Excluded port parser missed a starred or plain range. Count=$(@($ranges).Count)"
}

$blocked = Find-NextPublishedPort -StartPort 55432 -ExcludedRanges $ranges -ReservedPorts @()
if ($blocked -le 55440) {
    throw "A preferred port inside a Windows exclusion range must move past that range. Actual=$blocked"
}

$skipped = Find-NextPublishedPort -StartPort 20000 -ExcludedRanges @() -ReservedPorts @(20000, 20001)
Assert-Equal -Expected 20002 -Actual $skipped -Message 'Reserved ports must be skipped before a free port is accepted.'

$appPort = Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree $true -OwnedByLocalCompose $false -PortProxyPresent $false
Assert-Equal -Expected 18001 -Actual $appPort -Message 'APP_HOST_PORT must stay 18001 when the loopback port is free.'

Write-Output 'Published port fallback checks passed.'
exit 0
