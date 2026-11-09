Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')
function Test-DockerDaemonReady {
    try {
        & $dockerCommand info *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Start-DockerDesktopIfNeeded {
    $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    if (($null -ne $dockerService) -and ($dockerService.Status -ne 'Running')) {
        Write-Step '启动 Docker Desktop 服务。'
        Start-Service -Name 'com.docker.service'
        Start-Sleep -Seconds 5
    }

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if (Test-IsSystemIdentity -IdentityName $currentUser) {
        Write-Warning '当前是 NT AUTHORITY\SYSTEM，不会启动 Docker Desktop GUI。需要交互用户会话才能完成 Docker Desktop 就绪。'
        return
    }

    $dockerDesktopPath = 'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe'
    if (-not (Test-Path $dockerDesktopPath)) {
        return
    }

    if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-Step '启动 Docker Desktop。'
        Start-Process -FilePath $dockerDesktopPath | Out-Null
        Start-Sleep -Seconds 5
    }
}

function Assert-HostDockerHardwareVirtualization {
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $processors = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
    }
    catch {
        Write-Warning "无法自动检查 BIOS/UEFI 虚拟化状态，将继续等待 Docker Desktop：$($_.Exception.Message)"
        return
    }

    if (($null -eq $computerSystem) -or ($processors.Count -eq 0)) {
        Write-Warning '无法自动检查 BIOS/UEFI 虚拟化状态，将继续等待 Docker Desktop。'
        return
    }

    $firmwareVirtualizationStates = @(
        $processors | ForEach-Object { [bool]$_.VirtualizationFirmwareEnabled }
    )
    Assert-DockerHardwareVirtualization `
        -HypervisorPresent ([bool]$computerSystem.HypervisorPresent) `
        -VirtualizationFirmwareEnabled $firmwareVirtualizationStates
}

function Wait-For-DockerReady {
    param(
        [int]$MaxAttempts = 120,
        [int]$SleepSeconds = 5
    )

    if (Test-DockerDaemonReady) {
        return
    }

    Assert-HostDockerHardwareVirtualization
    Start-DockerDesktopIfNeeded

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-DockerDaemonReady) {
            return
        }

        Write-Step (New-BoundedWaitStatus -Stage '等待 Docker Desktop 就绪' -Attempt $attempt -MaxAttempts $MaxAttempts -LastError 'docker info 未成功' -TimeoutSeconds ($MaxAttempts * $SleepSeconds))

        if (($attempt % 6) -eq 0) {
            Start-DockerDesktopIfNeeded
        }
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Docker daemon 未在 $($MaxAttempts * $SleepSeconds) 秒内就绪。请在交互用户会话确认 Docker Desktop 已启动，并检查 WSL2/虚拟化，而不是改用其他端口或外部转发。"
}

function ConvertTo-TcpExcludedPortRanges {
    param(
        [AllowEmptyCollection()]
        [string[]]$Lines = @()
    )

    $ranges = @()
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*(\d+)\s+(\d+)(?:\s+\*)?\s*$') {
            $ranges += [pscustomobject]@{
                Start = [int]$Matches[1]
                End = [int]$Matches[2]
            }
        }
    }
    return @($ranges)
}

function Get-TcpExcludedPortRanges {
    $output = @(& netsh interface ipv4 show excludedportrange protocol=tcp)
    return @(ConvertTo-TcpExcludedPortRanges -Lines $output)
}

function Test-PublishedPortExcluded {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port,
        [Parameter(Mandatory = $true)]
        [object[]]$Ranges
    )

    foreach ($range in $Ranges) {
        if ($Port -ge $range.Start -and $Port -le $range.End) {
            return $true
        }
    }
    return $false
}

function Test-LoopbackTcpPortFree {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

function Find-NextPublishedPort {
    param(
        [Parameter(Mandatory = $true)]
        [int]$StartPort,
        [AllowEmptyCollection()]
        [object[]]$ExcludedRanges = @(),
        [AllowEmptyCollection()]
        [int[]]$ReservedPorts = @()
    )

    $candidate = $StartPort
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        if ($candidate -gt 65535) {
            break
        }
        if ($ReservedPorts -contains $candidate) {
            $candidate++
            continue
        }

        $coveredRange = $null
        foreach ($range in @($ExcludedRanges)) {
            if ($null -eq $range) {
                continue
            }
            if ($candidate -ge $range.Start -and $candidate -le $range.End) {
                $coveredRange = $range
                break
            }
        }
        if ($null -ne $coveredRange) {
            $candidate = [int]$coveredRange.End + 1
            continue
        }
        if (Test-LoopbackTcpPortFree -Port $candidate) {
            return $candidate
        }
        $candidate++
    }

    throw "从端口 $StartPort 起没有可用的本机端口。"
}

function Test-AppPortOwnedByLocalCompose {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    try {
        $containerId = Get-ComposeServiceContainerId -ServiceName 'orchestration-app'
        if ([string]::IsNullOrWhiteSpace($containerId)) {
            return $false
        }

        $published = (& $dockerCommand port $containerId '8000' | Out-String)
        return [bool]($published -match "127\.0\.0\.1:$Port")
    }
    catch {
        return $false
    }
}

function Update-PublishedHostPorts {
    $layout = Get-DockerLayout
    $defaults = Read-EnvFile -Path $layout.EnvDefaultsFile
    $runtime = Read-EnvFile -Path $layout.EnvFile
    $ranges = @(Get-TcpExcludedPortRanges)
    $requiredAppPort = Get-RequiredAppHostPort
    if (Test-PublishedPortExcluded -Port $requiredAppPort -Ranges $ranges) {
        $ownedDuringExclusion = Test-AppPortOwnedByLocalCompose -Port $requiredAppPort
        if (-not $ownedDuringExclusion) {
            throw "127.0.0.1:$requiredAppPort 位于 Windows 排除端口范围。安装器不会改用 18002。请释放该排除范围后重试。"
        }
    }

    $proxyEntries = @()
    try {
        $proxyEntries = @(ConvertTo-PortProxyListenEntries -Lines @(& netsh.exe interface portproxy show all 2>$null))
    }
    catch {
        $proxyEntries = @()
    }

    $appPort = Resolve-AppHostPortContract `
        -RequiredPort $requiredAppPort `
        -LoopbackFree (Test-LoopbackTcpPortFree -Port $requiredAppPort) `
        -OwnedByLocalCompose (Test-AppPortOwnedByLocalCompose -Port $requiredAppPort) `
        -PortProxyPresent (Test-AppPortProxyPresent -Entries $proxyEntries -Port $requiredAppPort) `
        -ListenerProcess (Get-LoopbackListenerProcessName -Port $requiredAppPort)
    $runtime['APP_HOST_PORT'] = [string]$appPort
    $chosen = @($appPort)

    foreach ($key in @('POSTGRES_HOST_PORT', 'REDIS_HOST_PORT', 'EMBEDDING_HOST_PORT')) {
        $start = [int]$defaults[$key]
        $port = Find-NextPublishedPort -StartPort $start -ExcludedRanges $ranges -ReservedPorts $chosen
        if ($port -ne $start) {
            Write-Step "$key 端口 $start 不可用，改用 $port。APP_HOST_PORT 仍固定为 $requiredAppPort。"
        }
        $runtime[$key] = [string]$port
        $chosen += $port
    }
    Write-EnvFile -Path $layout.EnvFile -Entries $runtime

    $stateLayout = Get-InstallStateLayout
    if (Test-Path $stateLayout.BackendEnvFile) {
        $backendEntries = Read-EnvFile -Path $stateLayout.BackendEnvFile
        if ($backendEntries.Contains('XDISPLAY_AI_SERVER_BASE_URL')) {
            $backendEntries['XDISPLAY_AI_SERVER_BASE_URL'] = "http://127.0.0.1:$($runtime['APP_HOST_PORT'])"
            Write-EnvFile -Path $stateLayout.BackendEnvFile -Entries $backendEntries
        }
    }

    return $runtime
}

function Get-ComposeServiceContainerId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    $layout = Get-DockerLayout
    $containerId = & $dockerCommand compose --project-name $layout.ProjectName --env-file $layout.EnvFile -f $layout.BaseCompose -f $layout.OverlayCompose ps -q $ServiceName
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$containerId)) {
        return ''
    }
    return ([string]$containerId).Trim()
}

function Invoke-PostgresSql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PostgresContainerId,
        [Parameter(Mandatory = $true)]
        [string]$Sql,
        [string]$Database = 'ai_orchestration'
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $dockerCommand exec $PostgresContainerId psql -U postgres -d $Database -t -A -v ON_ERROR_STOP=1 -c $Sql 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = ((@($output) | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
}

function Wait-For-PostgresReady {
    param(
        [int]$MaxAttempts = 120,
        [int]$SleepSeconds = 3
    )

    $consecutive = 0
    $lastError = 'postgres 容器尚未接受 ai_orchestration 查询'
    $stabilityDelaySeconds = Get-PostgresReadyStabilityDelaySeconds
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $postgresContainerId = Get-ComposeServiceContainerId -ServiceName 'postgres'
        if ($postgresContainerId) {
            $query = Invoke-PostgresSql -PostgresContainerId $postgresContainerId -Sql 'SELECT 1;'
            $probe = ConvertTo-PostgresQueryProbeResult -ExitCode $query.ExitCode -Output $query.Output
            if (-not [string]::IsNullOrWhiteSpace([string]$probe.Detail)) {
                $lastError = [string]$probe.Detail
            }
            $consecutive = Update-PostgresReadyConsecutiveCount -CurrentCount $consecutive -ProbeReady ([bool]$probe.Ready)
            if (Test-PostgresReadyConsecutiveCountMet -ConsecutiveCount $consecutive) {
                return $postgresContainerId
            }
            if ($probe.Ready) {
                Write-Step (New-BoundedWaitStatus -Stage '确认 PostgreSQL 已越过 docker-entrypoint 临时进程' -Attempt $consecutive -MaxAttempts (Get-PostgresReadyConsecutiveSuccessTarget) -LastError 'SELECT 1 成功，但冷启动需要连续两次查询成功' -TimeoutSeconds ($MaxAttempts * $SleepSeconds))
                Start-Sleep -Seconds $stabilityDelaySeconds
                continue
            }
        }
        else {
            $consecutive = 0
            $lastError = 'postgres 容器尚未出现'
        }

        Write-Step (New-BoundedWaitStatus -Stage '等待 PostgreSQL 接受迁移查询' -Attempt $attempt -MaxAttempts $MaxAttempts -LastError $lastError -TimeoutSeconds ($MaxAttempts * $SleepSeconds))
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "PostgreSQL 未在 $($MaxAttempts * $SleepSeconds) 秒内稳定接受 ai_orchestration 查询（docker-entrypoint 冷启动临时进程会在 shutdown 窗口误报监听就绪）。最后错误：$lastError"
}

function Ensure-MigrationHistoryTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PostgresContainerId,
        [int]$MaxAttempts = 30,
        [int]$SleepSeconds = 2
    )

    $createSql = 'CREATE TABLE IF NOT EXISTS offline_migration_history (migration_name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());'
    $presenceSql = "SELECT COALESCE(to_regclass('public.offline_migration_history')::text, '');"
    $lastError = 'offline_migration_history 尚未创建'
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $create = Invoke-PostgresSql -PostgresContainerId $PostgresContainerId -Sql $createSql
        if ($create.ExitCode -ne 0) {
            $lastError = [string]$create.Output
            if (-not (Test-IsPostgresTransientUnavailableMessage -Message $create.Output)) {
                throw "初始化 offline_migration_history 失败。$lastError"
            }
            Write-Step (New-BoundedWaitStatus -Stage '初始化 offline_migration_history' -Attempt $attempt -MaxAttempts $MaxAttempts -LastError $lastError -TimeoutSeconds ($MaxAttempts * $SleepSeconds))
            Start-Sleep -Seconds $SleepSeconds
            continue
        }

        $presence = Invoke-PostgresSql -PostgresContainerId $PostgresContainerId -Sql $presenceSql
        $presenceResult = ConvertTo-PostgresHistoryTablePresenceResult -ExitCode $presence.ExitCode -Output $presence.Output
        if ($presenceResult.Present) {
            return
        }

        $lastError = [string]$presence.Output
        if (($presence.ExitCode -ne 0) -and -not $presenceResult.Transient) {
            throw "初始化 offline_migration_history 失败：CREATE 返回成功但无法确认表存在。$lastError"
        }

        Write-Step (New-BoundedWaitStatus -Stage '确认 offline_migration_history 已存在' -Attempt $attempt -MaxAttempts $MaxAttempts -LastError $lastError -TimeoutSeconds ($MaxAttempts * $SleepSeconds))
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "初始化 offline_migration_history 失败。$lastError"
}

function Test-MigrationApplied {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PostgresContainerId,
        [Parameter(Mandatory = $true)]
        [string]$MigrationName
    )

    $escapedMigrationName = $MigrationName.Replace("'", "''")
    $sql = "SELECT 1 FROM offline_migration_history WHERE migration_name = '$escapedMigrationName' LIMIT 1;"
    $result = (& $dockerCommand exec $PostgresContainerId psql -U postgres -d ai_orchestration -t -A -c $sql | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "检查迁移状态失败：$MigrationName"
    }
    return $result -eq '1'
}

function Mark-MigrationApplied {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PostgresContainerId,
        [Parameter(Mandatory = $true)]
        [string]$MigrationName
    )

    $escapedMigrationName = $MigrationName.Replace("'", "''")
    $sql = "INSERT INTO offline_migration_history (migration_name) VALUES ('$escapedMigrationName') ON CONFLICT (migration_name) DO NOTHING;"
    & $dockerCommand exec $PostgresContainerId psql -U postgres -d ai_orchestration -v ON_ERROR_STOP=1 -c $sql | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "记录迁移历史失败：$MigrationName"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
Assert-Admin
Initialize-InstallStateDirectories
Assert-Command -Name 'docker'
$dockerCommand = Get-DockerCommand

Initialize-RuntimeEnvironment | Out-Null

Wait-For-DockerReady

$layout = Get-DockerLayout

Write-Step '导入离线 Docker 镜像。'
$imageFiles = Get-ChildItem -Path $layout.ImagesDir -Filter '*.tar' -File | Sort-Object Name
if (-not $imageFiles) {
    throw "未找到镜像 tar：$($layout.ImagesDir)"
}

foreach ($imageFile in $imageFiles) {
    Write-Step "docker load -i $($imageFile.Name)"
    & $dockerCommand load -i $imageFile.FullName | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "导入镜像失败：$($imageFile.FullName)"
    }
}

Write-Step '选择可用的本机发布端口。'
Update-PublishedHostPorts | Out-Null

Write-Step '启动离线后端服务栈。'
Invoke-Compose -Arguments @('up', '-d')
if ($LASTEXITCODE -ne 0) {
    throw "启动离线后端服务栈失败，退出码：$LASTEXITCODE"
}

$postgresContainerId = Wait-For-PostgresReady

Write-Step '执行数据库迁移。'
Ensure-MigrationHistoryTable -PostgresContainerId $postgresContainerId
$migrationFiles = Get-ChildItem -Path $layout.MigrationsDir -Filter '*.sql' -File | Sort-Object Name
foreach ($migrationFile in $migrationFiles) {
    if (Test-MigrationApplied -PostgresContainerId $postgresContainerId -MigrationName $migrationFile.Name) {
        Write-Step "跳过已执行迁移：$($migrationFile.Name)"
        continue
    }

    $containerPath = "/tmp/$($migrationFile.Name)"
    & $dockerCommand cp $migrationFile.FullName "${postgresContainerId}:${containerPath}" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "拷贝迁移文件失败：$($migrationFile.FullName)"
    }

    Write-Step "执行迁移：$($migrationFile.Name)"
    & $dockerCommand exec $postgresContainerId psql -U postgres -d ai_orchestration -v ON_ERROR_STOP=1 -f $containerPath | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "执行迁移失败：$($migrationFile.Name)"
    }

    Mark-MigrationApplied -PostgresContainerId $postgresContainerId -MigrationName $migrationFile.Name
    & $dockerCommand exec $postgresContainerId rm -f $containerPath | Out-Null
}

Write-Step '等待应用健康检查通过。'
& (Join-Path $PSScriptRoot '..\\health\\Test-Health.ps1') -TimeoutSeconds 300
}
