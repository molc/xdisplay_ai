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
    if ($currentUser -eq 'NT AUTHORITY\\SYSTEM') {
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

        Write-Step "等待 Docker Desktop 就绪（$attempt/$MaxAttempts）"

        if (($attempt % 6) -eq 0) {
            Start-DockerDesktopIfNeeded
        }
        Start-Sleep -Seconds $SleepSeconds
    }

    throw 'Docker daemon 未就绪。'
}

function Get-ComposeServiceContainerId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    $layout = Get-DockerLayout
    return (& $dockerCommand compose --project-name $layout.ProjectName --env-file $layout.EnvFile -f $layout.BaseCompose -f $layout.OverlayCompose ps -q $ServiceName).Trim()
}

function Wait-For-PostgresReady {
    param(
        [int]$MaxAttempts = 120,
        [int]$SleepSeconds = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $postgresContainerId = Get-ComposeServiceContainerId -ServiceName 'postgres'
        if ($postgresContainerId) {
            & $dockerCommand exec $postgresContainerId pg_isready -U postgres 2> $null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                return $postgresContainerId
            }
        }

        Write-Step "等待 PostgreSQL 就绪（$attempt/$MaxAttempts）"
        Start-Sleep -Seconds $SleepSeconds
    }

    throw 'PostgreSQL 容器未就绪。'
}

function Ensure-MigrationHistoryTable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PostgresContainerId
    )

    $sql = 'CREATE TABLE IF NOT EXISTS offline_migration_history (migration_name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW());'
    & $dockerCommand exec $PostgresContainerId psql -U postgres -d ai_orchestration -v ON_ERROR_STOP=1 -c $sql | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw '初始化 offline_migration_history 失败。'
    }
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

Write-Step '启动离线后端服务栈。'
Invoke-Compose -Arguments @('up', '-d')

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
