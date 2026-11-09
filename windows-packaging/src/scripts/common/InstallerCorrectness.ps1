Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-InstallRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $path = $Root
    foreach ($segment in @($RelativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $path = Join-Path $path $segment
    }
    return $path
}

function Test-IsSecretEnvKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [bool]($Name -match '(API_KEY|SECRET|TOKEN|PASSWORD|PRIVATE_KEY)')
}

function Get-RedactedEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Test-IsSecretEnvKey -Name $Name) {
        return '***REDACTED***'
    }

    return $Value
}

function Get-OptionalFeatureStateName {
    param(
        [AllowNull()]
        $Feature
    )

    if ($null -eq $Feature) {
        return ''
    }

    if ($Feature.PSObject.Properties.Name -contains 'State') {
        return [string]$Feature.State
    }

    return ''
}

function Test-IsSystemIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdentityName
    )

    return [string]::Equals(
        $IdentityName,
        'NT AUTHORITY\SYSTEM',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-RequiredComposeServiceNames {
    return @('postgres', 'redis', 'embedding-worker', 'orchestration-app')
}

function Get-RequiredAppHostPort {
    return 18001
}

function Get-WorkspacePreserveRelativePaths {
    return @('.env', '.env.local', 'secret.env')
}

function Get-WorkspaceFingerprintRelativePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath
    )

    return @($RequiredRelativePath)
}

function Get-FileSha256Lower {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileSha512Lower {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Get-PathContentFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$RelativePaths
    )

    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
        $targetPath = Join-InstallRelativePath -Root $Root -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $rows.Add("missing`0$($relativePath.Replace('\', '/'))")
            continue
        }

        $fileHash = Get-FileSha256Lower -Path $targetPath
        $rows.Add("file`0$($relativePath.Replace('\', '/'))`0$fileHash")
    }

    $payload = ($rows | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WorkspaceSyncDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath,
        [string]$LastSeedFingerprint = '',
        [string]$CurrentSeedFingerprint = ''
    )

    $requiredDestinationPath = Join-InstallRelativePath -Root $Destination -RelativePath $RequiredRelativePath
    if (-not (Test-Path -LiteralPath $Destination)) {
        return 'create'
    }

    if (-not (Test-Path -LiteralPath $requiredDestinationPath)) {
        return 'repair'
    }

    if (
        -not [string]::IsNullOrWhiteSpace($LastSeedFingerprint) -and
        -not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint) -and
        [string]::Equals($LastSeedFingerprint, $CurrentSeedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return 'keep'
    }

    $destinationFingerprint = Get-PathContentFingerprint -Root $Destination -RelativePaths @($RequiredRelativePath)
    if (
        -not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint) -and
        [string]::Equals($destinationFingerprint, $CurrentSeedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return 'keep'
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint)) {
        return 'update'
    }

    $seedFingerprint = Get-PathContentFingerprint -Root $Seed -RelativePaths @($RequiredRelativePath)
    if ([string]::Equals($destinationFingerprint, $seedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'keep'
    }

    return 'update'
}

function Merge-EnvEntries {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Defaults,
        [AllowNull()]
        [System.Collections.IDictionary]$Existing = $null,
        [AllowNull()]
        [System.Collections.IDictionary]$ForceEntries = $null
    )

    $merged = [ordered]@{}
    foreach ($key in @($Defaults.Keys)) {
        $merged[$key] = $Defaults[$key]
    }

    if ($null -ne $Existing) {
        foreach ($key in @($Existing.Keys)) {
            $merged[$key] = $Existing[$key]
        }
    }

    if ($null -ne $ForceEntries) {
        foreach ($key in @($ForceEntries.Keys)) {
            $merged[$key] = $ForceEntries[$key]
        }
    }

    return $merged
}

function Get-LegacyApplicationEnvEntries {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$RuntimeEntries = $null
    )

    $legacy = [ordered]@{}
    if ($null -eq $RuntimeEntries) {
        return $legacy
    }

    foreach ($key in @($RuntimeEntries.Keys)) {
        if ($key -like 'XDISPLAY_AI_*') {
            $legacy[$key] = $RuntimeEntries[$key]
        }
    }

    return $legacy
}

function Get-BootstrapRebootAction {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RebootRequired,
        [bool]$NoAutoReboot = $false,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$AutomaticRebootCount = 0,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaximumAutomaticReboots = 2,
        [bool]$InstallerCustomAction = $false
    )

    if (-not $RebootRequired) {
        return [pscustomobject]@{
            Name = 'continue'
            Persist = $false
            RegisterResumeTask = $false
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = $true
            Throw = $false
            NextAutomaticRebootCount = $AutomaticRebootCount
        }
    }

    $nextCount = $AutomaticRebootCount + 1
    $loopExceeded = $nextCount -gt $MaximumAutomaticReboots
    $mustExitZero = $InstallerCustomAction -or $NoAutoReboot -or (-not $loopExceeded)

    if ($loopExceeded) {
        return [pscustomobject]@{
            Name = 'abort-loop'
            Persist = $true
            RegisterResumeTask = $true
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = [bool]$InstallerCustomAction
            Throw = -not $InstallerCustomAction
            NextAutomaticRebootCount = $AutomaticRebootCount
        }
    }

    if ($NoAutoReboot) {
        return [pscustomobject]@{
            Name = 'persist-wait'
            Persist = $true
            RegisterResumeTask = $true
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = $true
            Throw = $false
            NextAutomaticRebootCount = $nextCount
        }
    }

    return [pscustomobject]@{
        Name = 'persist-reboot'
        Persist = $true
        RegisterResumeTask = $true
        AutoReboot = $true
        ClearState = $false
        UnregisterResumeTask = $false
        ExitZero = $true
        Throw = $false
        NextAutomaticRebootCount = $nextCount
    }
}

function Test-IsLocalDockerEngine {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DockerHost = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ServerOs = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OperatingSystem = ''
    )

    if ([string]::IsNullOrWhiteSpace($DockerHost)) {
        return $false
    }

    $normalizedHost = $DockerHost.Trim()
    if ($normalizedHost -match '^(tcp|http|https)://') {
        if ($normalizedHost -match '://(127\.0\.0\.1|localhost)(:|/|$)') {
            return $false
        }
        return $false
    }

    $localPipes = @(
        'npipe:////./pipe/dockerDesktopLinuxEngine',
        'npipe:////./pipe/docker_engine'
    )
    $isLocalPipe = $false
    foreach ($pipeName in $localPipes) {
        if ([string]::Equals($normalizedHost, $pipeName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isLocalPipe = $true
            break
        }
    }

    if (-not $isLocalPipe) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ServerOs) -and $ServerOs -ne 'linux') {
        return $false
    }

    if (
        -not [string]::IsNullOrWhiteSpace($OperatingSystem) -and
        ($OperatingSystem -notmatch 'docker[\s-]?desktop')
    ) {
        return $false
    }

    return $true
}

function ConvertTo-PortProxyListenEntries {
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Lines = @()
    )

    $entries = @()
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*(127\.0\.0\.1|localhost)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
            $entries += [pscustomobject]@{
                ListenAddress = $Matches[1]
                ListenPort = [int]$Matches[2]
                ConnectAddress = $Matches[3]
                ConnectPort = [int]$Matches[4]
            }
        }
    }
    return @($entries)
}

function Test-AppPortProxyPresent {
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Entries = @(),
        [int]$Port = 18001
    )

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        if ([int]$entry.ListenPort -eq $Port) {
            return $true
        }
    }
    return $false
}

function Resolve-AppHostPortContract {
    param(
        [int]$RequiredPort = 18001,
        [bool]$LoopbackFree = $true,
        [bool]$OwnedByLocalCompose = $false,
        [bool]$PortProxyPresent = $false,
        [string]$ListenerProcess = ''
    )

    if ($PortProxyPresent) {
        throw "127.0.0.1:$RequiredPort 存在 Windows portproxy 转发，不能当作本机后端。请删除该转发后重试，安装器不会改用其他端口。"
    }

    if ($OwnedByLocalCompose) {
        return $RequiredPort
    }

    if ($LoopbackFree) {
        return $RequiredPort
    }

    $listenerText = if ([string]::IsNullOrWhiteSpace($ListenerProcess)) { '未知进程' } else { $ListenerProcess }
    throw "127.0.0.1:$RequiredPort 被 $listenerText 占用，且不是本机 XDisplay compose 栈。安装器不会把 APP_HOST_PORT 改到 18002 或其他端口。请释放 18001 后重试。"
}

function Test-LocalBackendOrigin {
    param(
        [int]$HealthzStatus = 0,
        [int]$AssistantStatus = 0,
        [string]$PublishedBinding = '',
        [string]$ListenerProcess = '',
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$PortProxyEntries = @(),
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$RunningServices = @(),
        [string]$DockerHost = '',
        [string]$ServerOs = '',
        [string]$OperatingSystem = '',
        [int]$RequiredPort = 18001
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $expectedServices = @(Get-RequiredComposeServiceNames)

    if ($HealthzStatus -ne 200 -or $AssistantStatus -ne 200) {
        $reasons.Add("localhost:$RequiredPort 健康检查不是 200（healthz=$HealthzStatus assistant=$AssistantStatus）")
    }

    $expectedBinding = "127.0.0.1:$RequiredPort"
    if (-not [string]::Equals($PublishedBinding, $expectedBinding, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add("应用未发布在 $expectedBinding（实际：$PublishedBinding）")
    }

    if (Test-AppPortProxyPresent -Entries $PortProxyEntries -Port $RequiredPort) {
        $reasons.Add("127.0.0.1:$RequiredPort 存在 portproxy 转发，HTTP 200 不能证明本机后端")
    }

    if (-not (Test-IsLocalDockerEngine -DockerHost $DockerHost -ServerOs $ServerOs -OperatingSystem $OperatingSystem)) {
        $reasons.Add("Docker 引擎不是本机 Docker Desktop Linux named pipe（DockerHost=$DockerHost）")
    }

    $runningSet = @{}
    foreach ($serviceName in @($RunningServices)) {
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            $runningSet[$serviceName] = $true
        }
    }
    foreach ($expectedService in $expectedServices) {
        if (-not $runningSet.ContainsKey($expectedService)) {
            $reasons.Add("缺少本机 compose 服务：$expectedService")
        }
    }

    $listenerOk = $false
    foreach ($allowedListener in @('com.docker.backend', 'com.docker.backend.exe', 'docker-proxy', 'docker-proxy.exe')) {
        if ([string]::Equals($ListenerProcess, $allowedListener, [System.StringComparison]::OrdinalIgnoreCase)) {
            $listenerOk = $true
            break
        }
    }
    if (-not $listenerOk) {
        $reasons.Add("18001 监听进程不是本机 Docker backend（实际：$ListenerProcess）")
    }

    return [pscustomobject]@{
        Ok = ($reasons.Count -eq 0)
        Reasons = @($reasons)
    }
}

function Test-SecretLikeValue {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    if ($trimmed -like '__SET_ME__*' -or $trimmed -match '^\{\{.+\}\}$') {
        return $false
    }

    if ($trimmed -match '^sk-[A-Za-z0-9]') {
        return $true
    }
    if ($trimmed -match 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY') {
        return $true
    }
    if ($trimmed -match '^(ghp|gho|github_pat)_[A-Za-z0-9_]+') {
        return $true
    }
    if ($trimmed -match '^(xox[baprs]-)[A-Za-z0-9-]+') {
        return $true
    }

    return $false
}

function Get-RequiredOfflineInputRelativePaths {
    return @(
        'prerequisites/docker-desktop/Docker Desktop Installer.exe',
        'prerequisites/vcredist/VC_redist.x64.exe',
        'prerequisites/wsl/wsl_update_x64.msi',
        'backend/images/orches_orchestration-app_latest.tar',
        'backend/images/orches_embedding-http_latest.tar',
        'backend/images/pgvector_pgvector_pg15.tar',
        'backend/images/redis_7.tar'
    )
}

function Get-MissingOfflineInputRelativePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputsRoot,
        [AllowEmptyCollection()]
        [string[]]$RequiredRelativePaths = @()
    )

    $missing = @()
    $paths = if ($RequiredRelativePaths.Count -gt 0) {
        $RequiredRelativePaths
    }
    else {
        @(Get-RequiredOfflineInputRelativePaths)
    }

    foreach ($relativePath in $paths) {
        $absolutePath = Join-InstallRelativePath -Root $InputsRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            $missing += $relativePath
        }
    }

    return @($missing)
}

function Test-BurnPayloadSha512Binding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,
        [Parameter(Mandatory = $true)]
        [string]$PayloadPath
    )

    if (-not (Test-Path -LiteralPath $BundlePath)) {
        throw "Burn bundle 不存在：$BundlePath"
    }
    if (-not (Test-Path -LiteralPath $PayloadPath)) {
        throw "Burn 相邻 payload 不存在：$PayloadPath"
    }

    $sha = [System.Security.Cryptography.SHA512]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($PayloadPath)
        try {
            $hashBytes = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }

    $hex = ([BitConverter]::ToString($hashBytes)).Replace('-', '')
    $hexLower = $hex.ToLowerInvariant()
    $base64 = [Convert]::ToBase64String($hashBytes)
    $bundleBytes = [System.IO.File]::ReadAllBytes($BundlePath)
    $ascii = [System.Text.Encoding]::ASCII.GetString($bundleBytes)
    $unicode = [System.Text.Encoding]::Unicode.GetString($bundleBytes)

    return (
        $ascii.Contains($hex) -or
        $ascii.Contains($hexLower) -or
        $ascii.Contains($base64) -or
        $unicode.Contains($hex) -or
        $unicode.Contains($hexLower) -or
        $unicode.Contains($base64)
    )
}

function Test-WindowsAcceptanceEvidence {
    param(
        [AllowNull()]
        $Evidence
    )

    $failures = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Evidence) {
        $failures.Add('缺少隔离 Windows 验收证据；源码测试通过不能当成安装器已接受。')
        return [pscustomobject]@{
            Ok = $false
            Failures = @($failures)
        }
    }

    $fresh = $null
    $upgrade = $null
    if ($Evidence.PSObject.Properties.Name -contains 'freshOfflineRebootResume') {
        $fresh = $Evidence.freshOfflineRebootResume
    }
    if ($Evidence.PSObject.Properties.Name -contains 'oldVersionPreservation') {
        $upgrade = $Evidence.oldVersionPreservation
    }

    if ($null -eq $fresh -or [string]$fresh.status -ne 'pass') {
        $failures.Add('fresh-offline→reboot-resume→4 local containers/local 18001 验收未 PASS。')
    }
    else {
        if (-not [bool]$fresh.localBackend) {
            $failures.Add('全新安装验收未证明本机后端。')
        }
        if ([int]$fresh.containers -ne 4) {
            $failures.Add("全新安装验收容器数不是 4（实际：$($fresh.containers)）。")
        }
        if ([int]$fresh.appPort -ne 18001) {
            $failures.Add("全新安装验收应用端口不是 18001（实际：$($fresh.appPort)）。")
        }
        if ([string]$fresh.origin -ne 'local') {
            $failures.Add('全新安装验收 origin 不是 local。')
        }
    }

    if ($null -eq $upgrade -or [string]$upgrade.status -ne 'pass') {
        $failures.Add('旧版本配置/项目/数据库保留验收未 PASS。')
    }
    else {
        if (-not [bool]$upgrade.configSentinel) {
            $failures.Add('升级验收未保留配置哨兵。')
        }
        if (-not [bool]$upgrade.projects) {
            $failures.Add('升级验收未保留用户项目。')
        }
        if (-not [bool]$upgrade.dbVolumes) {
            $failures.Add('升级验收未保留数据库卷。')
        }
    }

    return [pscustomobject]@{
        Ok = ($failures.Count -eq 0)
        Failures = @($failures)
    }
}

function New-BoundedWaitStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        [Parameter(Mandatory = $true)]
        [int]$MaxAttempts,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LastError = '',
        [int]$TimeoutSeconds = 0
    )

    $errorText = if ([string]::IsNullOrWhiteSpace($LastError)) { 'none' } else { $LastError }
    if ($errorText.Length -gt 180) {
        $errorText = $errorText.Substring(0, 180)
    }

    $timeoutText = if ($TimeoutSeconds -gt 0) { " timeoutSec=$TimeoutSeconds" } else { '' }
    return "$Stage ($Attempt/$MaxAttempts)$timeoutText lastError=$errorText"
}

function Sync-WorkspaceTreeFromSeed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [AllowEmptyCollection()]
        [string[]]$PreserveRelativePaths = @()
    )

    if (-not (Test-Path -LiteralPath $Seed)) {
        throw "安装种子不存在：$Seed"
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $preserveSet = @{}
    foreach ($relativePath in @($PreserveRelativePaths)) {
        $preserveSet[$relativePath.Replace('\', '/').Trim('/')] = $true
    }

    $seedFiles = @(Get-ChildItem -LiteralPath $Seed -Recurse -File -Force)
    foreach ($seedFile in $seedFiles) {
        $relativePath = $seedFile.FullName.Substring($Seed.Length).TrimStart('\', '/').Replace('\', '/')
        $destinationPath = Join-InstallRelativePath -Root $Destination -RelativePath $relativePath
        $preserveExisting = $preserveSet.ContainsKey($relativePath) -and (Test-Path -LiteralPath $destinationPath)
        if ($preserveExisting) {
            continue
        }

        $parent = Split-Path -Path $destinationPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $seedFile.FullName -Destination $destinationPath -Force
    }
}
