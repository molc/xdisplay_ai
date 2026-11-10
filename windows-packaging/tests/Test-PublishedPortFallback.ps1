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

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
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

Assert-True `
    -Condition (Test-PublishedPortExcluded -Port 18001 -Ranges $ranges) `
    -Message 'The 18001 exclusion range must be detected as covering APP_HOST_PORT.'

$blocked = Find-NextPublishedPort -StartPort 55432 -ExcludedRanges $ranges -ReservedPorts @()
if ($blocked -le 55440) {
    throw "A preferred AUXILIARY port inside a Windows exclusion range must move past that range. Actual=$blocked"
}

$skipped = Find-NextPublishedPort -StartPort 20000 -ExcludedRanges @() -ReservedPorts @(20000, 20001)
Assert-Equal -Expected 20002 -Actual $skipped -Message 'Reserved auxiliary ports must be skipped before a free port is accepted.'

$legacyAppFallback = Find-NextPublishedPort -StartPort 18001 -ExcludedRanges $ranges -ReservedPorts @()
Assert-True `
    -Condition ($legacyAppFallback -ne 18001) `
    -Message 'Find-NextPublishedPort still skips 18001 when excluded; that helper must not assign APP_HOST_PORT.'
Assert-True `
    -Condition ($legacyAppFallback -ge 18002) `
    -Message "Find-NextPublishedPort's old 18001 skip landed on an unexpected port: $legacyAppFallback"

$appPort = Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree $true -OwnedByLocalCompose $false -PortProxyPresent $false
Assert-Equal -Expected 18001 -Actual $appPort -Message 'APP_HOST_PORT must stay 18001 when the loopback port is free.'

$reused = Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree $false -OwnedByLocalCompose $true -PortProxyPresent $false -ListenerProcess 'com.docker.backend'
Assert-Equal -Expected 18001 -Actual $reused -Message 'Own compose stack may reuse 18001; it must not move.'

$foreignRejected = $false
try {
    Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree $false -OwnedByLocalCompose $false -PortProxyPresent $false -ListenerProcess 'python' | Out-Null
}
catch {
    $foreignRejected = ($_.Exception.Message -match '18002') -and ($_.Exception.Message -notmatch '改用 18002$')
    if (-not ($_.Exception.Message -match '不会把 APP_HOST_PORT 改到 18002')) {
        $foreignRejected = $false
    }
}
Assert-True -Condition $foreignRejected -Message 'Occupied 18001 must fail closed and must not return a fallback port.'

$backendInstallScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1') -Raw
Assert-True `
    -Condition ($backendInstallScriptContent -match "foreach \(\`$key in @\('POSTGRES_HOST_PORT', 'REDIS_HOST_PORT', 'EMBEDDING_HOST_PORT'\)\)") `
    -Message 'Find-NextPublishedPort may only run for auxiliary ports, never APP_HOST_PORT.'
Assert-True `
    -Condition ($backendInstallScriptContent -match "\`$runtime\['APP_HOST_PORT'\] = \[string\]\`$appPort") `
    -Message 'APP_HOST_PORT must be assigned from Resolve-AppHostPortContract, not Find-NextPublishedPort.'
Assert-True `
    -Condition ($backendInstallScriptContent -match '安装器不会改用 18002') `
    -Message 'An excluded 18001 range must throw instead of skipping to 18002.'
Assert-True `
    -Condition ($backendInstallScriptContent -notmatch "foreach \(\`$key in @\('APP_HOST_PORT'") `
    -Message 'APP_HOST_PORT must not remain in the published-port fallback loop.'

Write-Output 'Auxiliary published-port fallback and APP_HOST_PORT 18001 contract checks passed.'
exit 0
