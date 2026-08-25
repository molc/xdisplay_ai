Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:BundleMetadataCache = $null

function Get-InstallRoot {
    return $script:InstallRoot
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-TextFileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent
    }
    if ($null -eq $Content) {
        $Content = ''
    }

    $normalizedContent = $Content -replace "`r?`n", [Environment]::NewLine

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalizedContent, $utf8NoBom)
}

function Read-Utf8JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[xdisplayai]" $Message -ForegroundColor Green
}

function Get-BundleMetadata {
    if ($null -ne $script:BundleMetadataCache) {
        return $script:BundleMetadataCache
    }

    $metadataPath = Join-Path (Get-InstallRoot) 'metadata\bundle.json'
    if (Test-Path $metadataPath) {
        $script:BundleMetadataCache = Get-Content -Path $metadataPath -Raw | ConvertFrom-Json
        return $script:BundleMetadataCache
    }

    $script:BundleMetadataCache = [pscustomobject]@{
        runtime = [pscustomobject]@{
            projectName = 'xdisplayai'
            dataRoot = 'C:\ProgramData\XDisplayAI'
        }
    }
    return $script:BundleMetadataCache
}

function Get-InstallStateLayout {
    $metadata = Get-BundleMetadata
    $dataRoot = if ([string]::IsNullOrWhiteSpace([string]$metadata.runtime.dataRoot)) {
        'C:\ProgramData\XDisplayAI'
    }
    else {
        [string]$metadata.runtime.dataRoot
    }

    $configRoot = Join-Path $dataRoot 'config'
    $logsRoot = Join-Path $dataRoot 'logs'
    $workspaceRoot = Join-Path $dataRoot 'workspace'
    $backendWorkspace = Join-Path $workspaceRoot 'backend'
    $clientWorkspace = Join-Path $workspaceRoot 'client'

    return [pscustomobject]@{
        DataRoot = $dataRoot
        ConfigRoot = $configRoot
        LogsRoot = $logsRoot
        WorkspaceRoot = $workspaceRoot
        BackendWorkspace = $backendWorkspace
        ClientWorkspace = $clientWorkspace
        BackendEnvFile = Join-Path $backendWorkspace '.env'
        BackendSeed = Join-Path (Get-InstallRoot) 'seed\backend'
        ClientSeed = Join-Path (Get-InstallRoot) 'seed\client'
        RuntimeEnvFile = Join-Path $configRoot 'runtime.env'
        RuntimeDefaultsFile = Join-Path (Get-InstallRoot) 'docker\env\runtime.defaults.env'
        BootstrapLog = Join-Path $logsRoot 'bootstrap.log'
        BootstrapStateFile = Join-Path $configRoot 'bootstrap-state.json'
        ResumeTaskName = 'XDisplayAI-ResumeSetup'
    }
}

function Initialize-InstallStateDirectories {
    $layout = Get-InstallStateLayout
    Ensure-Directory -Path $layout.DataRoot
    Ensure-Directory -Path $layout.ConfigRoot
    Ensure-Directory -Path $layout.LogsRoot
    Ensure-Directory -Path $layout.WorkspaceRoot
}

function Initialize-WorkspaceDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath
    )

    $requiredDestinationPath = Join-Path $Destination $RequiredRelativePath
    if (Test-Path $Destination) {
        if (-not (Test-Path $requiredDestinationPath)) {
            throw "开发工作目录不完整，缺少：$requiredDestinationPath"
        }
        return
    }

    $requiredSeedPath = Join-Path $Seed $RequiredRelativePath
    if (-not (Test-Path $requiredSeedPath)) {
        throw "安装种子不完整，缺少：$requiredSeedPath"
    }

    $destinationParent = Split-Path -Path $Destination -Parent
    Ensure-Directory -Path $destinationParent
    $temporaryDestination = Join-Path $destinationParent ('.xdisplayai-seed-' + [System.Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -Path $Seed -Destination $temporaryDestination -Recurse -Force
        if (-not (Test-Path (Join-Path $temporaryDestination $RequiredRelativePath))) {
            throw "复制后的开发工作目录不完整：$RequiredRelativePath"
        }
        Move-Item -Path $temporaryDestination -Destination $Destination
    }
    finally {
        if (Test-Path $temporaryDestination) {
            Remove-Item -Path $temporaryDestination -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-DevelopmentWorkspace {
    Initialize-InstallStateDirectories
    $layout = Get-InstallStateLayout
    Initialize-WorkspaceDirectory `
        -Seed $layout.BackendSeed `
        -Destination $layout.BackendWorkspace `
        -RequiredRelativePath 'app\main.py'
    Initialize-WorkspaceDirectory `
        -Seed $layout.ClientSeed `
        -Destination $layout.ClientWorkspace `
        -RequiredRelativePath 'Xdisplay.exe'

    return $layout
}

function Get-DockerLayout {
    $root = Get-InstallRoot
    $stateLayout = Get-InstallStateLayout
    $metadata = Get-BundleMetadata
    $projectName = if ([string]::IsNullOrWhiteSpace([string]$metadata.runtime.projectName)) {
        'xdisplayai'
    }
    else {
        [string]$metadata.runtime.projectName
    }

    return [pscustomobject]@{
        BaseCompose = Join-Path $root 'docker\compose\docker-compose.yml'
        OverlayCompose = Join-Path $root 'docker\compose\compose.windows.yml'
        EnvFile = $stateLayout.RuntimeEnvFile
        EnvDefaultsFile = $stateLayout.RuntimeDefaultsFile
        ImagesDir = Join-Path $root 'docker\images'
        MigrationsDir = Join-Path $root 'docker\migrations'
        PrereqRoot = Join-Path $root 'prerequisites'
        MetadataRoot = Join-Path $root 'metadata'
        ProjectName = $projectName
    }
}

function Assert-Admin {
    if (-not (Test-IsAdministrator)) {
        throw '需要以管理员权限运行。'
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ($Name -eq 'docker') {
        Get-DockerCommand | Out-Null
        return
    }

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "未找到命令：$Name"
    }
}
function Get-DockerCommand {
    $command = Get-Command 'docker' -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    foreach ($candidate in @(
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe',
        'C:\Program Files\Docker\Docker\resources\bin\docker'
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw '未找到命令：docker'
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )
    $dockerCommand = Get-DockerCommand
    Assert-Command -Name 'docker'
    $layout = Get-DockerLayout
    & $dockerCommand compose --project-name $layout.ProjectName --env-file $layout.EnvFile -f $layout.BaseCompose -f $layout.OverlayCompose @Arguments
}

function Read-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $entries = [ordered]@{}
    if (-not (Test-Path $Path)) {
        return $entries
    }

    foreach ($line in Get-Content -Path $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line.TrimStart().StartsWith('#')) {
            continue
        }

        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2) {
            $entries[$parts[0]] = $parts[1]
        }
        elseif ($parts.Count -eq 1) {
            $entries[$parts[0]] = ''
        }
    }

    return $entries
}

function Write-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries
    )

    $lines = @(
        foreach ($key in $Entries.Keys) {
            "$key=$($Entries[$key])"
        }
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent
    }
    $content = if ($lines.Count -gt 0) {
        ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    }
    else {
        ''
    }

    Write-TextFileUtf8NoBom -Path $Path -Content $content
}

function Get-RuntimeSettings {
    $layout = Get-DockerLayout
    return Read-EnvFile -Path $layout.EnvFile
}

function Initialize-RuntimeEnvironment {
    $stateLayout = Initialize-DevelopmentWorkspace

    $dockerLayout = Get-DockerLayout
    if (-not (Test-Path $dockerLayout.EnvDefaultsFile)) {
        throw "缺少 runtime 默认配置文件：$($dockerLayout.EnvDefaultsFile)"
    }

    $runtimeEntries = Read-EnvFile -Path $dockerLayout.EnvDefaultsFile
    $runtimeEntries['BACKEND_WORKSPACE_PATH'] = $stateLayout.BackendWorkspace.Replace('\', '/')
    Write-EnvFile -Path $dockerLayout.EnvFile -Entries $runtimeEntries

    return [pscustomobject]@{
        RuntimeEnvFile = $dockerLayout.EnvFile
        BackendWorkspace = $stateLayout.BackendWorkspace
        ClientWorkspace = $stateLayout.ClientWorkspace
    }
}

function Get-BootstrapState {
    $layout = Get-InstallStateLayout
    if (-not (Test-Path $layout.BootstrapStateFile)) {
        return [pscustomobject]@{
            AutomaticRebootCount = 0
            LastRebootReasons = @()
            UpdatedAtUtc = ''
        }
    }

    try {
        $state = Read-Utf8JsonFile -Path $layout.BootstrapStateFile
    }
    catch {
        return [pscustomobject]@{
            AutomaticRebootCount = 0
            LastRebootReasons = @()
            UpdatedAtUtc = ''
        }
    }

    $automaticRebootCount = 0
    if ($state.PSObject.Properties.Name -contains 'AutomaticRebootCount') {
        $automaticRebootCount = [int]$state.AutomaticRebootCount
    }

    $lastRebootReasons = @()
    if (($state.PSObject.Properties.Name -contains 'LastRebootReasons') -and ($null -ne $state.LastRebootReasons)) {
        $lastRebootReasons = @($state.LastRebootReasons | ForEach-Object { [string]$_ })
    }

    $updatedAtUtc = ''
    if ($state.PSObject.Properties.Name -contains 'UpdatedAtUtc') {
        $updatedAtUtc = [string]$state.UpdatedAtUtc
    }

    return [pscustomobject]@{
        AutomaticRebootCount = $automaticRebootCount
        LastRebootReasons = $lastRebootReasons
        UpdatedAtUtc = $updatedAtUtc
    }
}

function Save-BootstrapState {
    param(
        [int]$AutomaticRebootCount = 0,
        [string[]]$LastRebootReasons = @()
    )

    Initialize-InstallStateDirectories
    $layout = Get-InstallStateLayout
    $state = [pscustomobject]@{
        AutomaticRebootCount = $AutomaticRebootCount
        LastRebootReasons = @($LastRebootReasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }

    $content = $state | ConvertTo-Json -Depth 4
    Write-TextFileUtf8NoBom -Path $layout.BootstrapStateFile -Content $content
}

function Clear-BootstrapState {
    $layout = Get-InstallStateLayout
    if (Test-Path $layout.BootstrapStateFile) {
        Remove-Item -Path $layout.BootstrapStateFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PendingRebootDisposition {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$PendingReboot,
        [Parameter(Mandatory = $true)]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$AutomaticRebootCount
    )

    if (-not $PendingReboot) {
        return 'continue'
    }

    if ($AutomaticRebootCount -eq 0) {
        return 'reboot'
    }

    return 'continue'
}
