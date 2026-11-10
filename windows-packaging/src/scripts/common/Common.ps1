Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:BundleMetadataCache = $null
. (Join-Path $PSScriptRoot 'InstallerCorrectness.ps1')
. (Join-Path $PSScriptRoot '..\update\PromptPinMigration.ps1')

function Get-InstallRoot {
    return $script:InstallRoot
}

function Resolve-XDisplayFileSystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = Resolve-Path -LiteralPath $Path
    if ($resolvedPath.Provider.Name -ne 'FileSystem') {
        throw "路径不是文件系统路径：$Path"
    }

    return $resolvedPath.ProviderPath
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

function Get-WorkspaceSyncStatePath {
    $layout = Get-InstallStateLayout
    return Join-Path $layout.ConfigRoot 'workspace-sync.json'
}

function Get-WorkspaceSyncSlotName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath
    )

    if ($RequiredRelativePath -match 'Xdisplay\.exe') {
        return 'clientSeedFingerprint'
    }

    return 'backendSeedFingerprint'
}

function Read-WorkspaceSyncFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SlotName
    )

    $path = Get-WorkspaceSyncStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }

    try {
        $state = Read-Utf8JsonFile -Path $path
    }
    catch {
        return ''
    }

    if ($state.PSObject.Properties.Name -contains $SlotName) {
        return [string]$state.$SlotName
    }

    return ''
}

function Save-WorkspaceSyncFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SlotName,
        [Parameter(Mandatory = $true)]
        [string]$SeedFingerprint
    )

    Initialize-InstallStateDirectories
    $path = Get-WorkspaceSyncStatePath
    $state = [pscustomobject]@{
        clientSeedFingerprint = ''
        backendSeedFingerprint = ''
        packageVersion = ''
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $existing = Read-Utf8JsonFile -Path $path
            foreach ($name in @('clientSeedFingerprint', 'backendSeedFingerprint', 'packageVersion')) {
                if ($existing.PSObject.Properties.Name -contains $name) {
                    $state.$name = [string]$existing.$name
                }
            }
        }
        catch {
        }
    }

    $metadata = Get-BundleMetadata
    if (($metadata.PSObject.Properties.Name -contains 'bundle') -and ($metadata.bundle.PSObject.Properties.Name -contains 'version')) {
        $state.packageVersion = [string]$metadata.bundle.version
    }
    $state.$SlotName = $SeedFingerprint
    $state.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-TextFileUtf8NoBom -Path $path -Content ($state | ConvertTo-Json -Depth 4)
}

function Copy-WorkspaceSeedAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath
    )

    $destinationParent = Split-Path -Path $Destination -Parent
    Ensure-Directory -Path $destinationParent
    $temporaryDestination = Join-Path $destinationParent ('.xdisplayai-seed-' + [System.Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -Path $Seed -Destination $temporaryDestination -Recurse -Force
        $copiedRequiredPath = Join-InstallRelativePath -Root $temporaryDestination -RelativePath $RequiredRelativePath
        if (-not (Test-Path -LiteralPath $copiedRequiredPath)) {
            throw "复制后的开发工作目录不完整：$RequiredRelativePath"
        }
        if (Test-Path -LiteralPath $Destination) {
            $backupDestination = Join-Path $destinationParent ('.xdisplayai-workspace-backup-' + [System.Guid]::NewGuid().ToString('N'))
            Move-Item -Path $Destination -Destination $backupDestination
            try {
                Move-Item -Path $temporaryDestination -Destination $Destination
                Remove-Item -Path $backupDestination -Recurse -Force -ErrorAction SilentlyContinue
            }
            catch {
                if (Test-Path -LiteralPath $Destination) {
                    Remove-Item -Path $Destination -Recurse -Force -ErrorAction SilentlyContinue
                }
                Move-Item -Path $backupDestination -Destination $Destination
                throw
            }
        }
        else {
            Move-Item -Path $temporaryDestination -Destination $Destination
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDestination) {
            Remove-Item -Path $temporaryDestination -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
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

    $requiredSeedPath = Join-InstallRelativePath -Root $Seed -RelativePath $RequiredRelativePath
    if (-not (Test-Path -LiteralPath $requiredSeedPath)) {
        throw "安装种子不完整，缺少：$requiredSeedPath"
    }

    $slotName = Get-WorkspaceSyncSlotName -RequiredRelativePath $RequiredRelativePath
    $currentSeedFingerprint = Get-PathContentFingerprint -Root $Seed -RelativePaths @(Get-WorkspaceFingerprintRelativePaths -RequiredRelativePath $RequiredRelativePath)
    $lastSeedFingerprint = Read-WorkspaceSyncFingerprint -SlotName $slotName
    $decision = Get-WorkspaceSyncDecision `
        -Seed $Seed `
        -Destination $Destination `
        -RequiredRelativePath $RequiredRelativePath `
        -LastSeedFingerprint $lastSeedFingerprint `
        -CurrentSeedFingerprint $currentSeedFingerprint

    if ($decision -eq 'keep') {
        return
    }

    Write-Step "按种子指纹同步工作目录（$decision）：$RequiredRelativePath"
    if ($decision -eq 'create' -or -not (Test-Path -LiteralPath $Destination)) {
        Copy-WorkspaceSeedAtomically -Seed $Seed -Destination $Destination -RequiredRelativePath $RequiredRelativePath
    }
    else {
        Sync-WorkspaceTreeFromSeed `
            -Seed $Seed `
            -Destination $Destination `
            -PreserveRelativePaths @(Get-WorkspacePreserveRelativePaths)
        $requiredDestinationPath = Join-InstallRelativePath -Root $Destination -RelativePath $RequiredRelativePath
        if (-not (Test-Path -LiteralPath $requiredDestinationPath)) {
            throw "工作目录修复后仍缺少：$requiredDestinationPath"
        }
    }

    Save-WorkspaceSyncFingerprint -SlotName $slotName -SeedFingerprint $currentSeedFingerprint
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

function Get-ComposeServiceContainerId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    $dockerCommand = Get-DockerCommand
    $layout = Get-DockerLayout
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $composeOutput = @(& $dockerCommand compose --project-name $layout.ProjectName --env-file $layout.EnvFile -f $layout.BaseCompose -f $layout.OverlayCompose ps -q $ServiceName 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        return ''
    }
    return (Select-ComposeContainerId -Output $composeOutput)
}

function Get-ExpectedS63fRuntimeFingerprintFromSeed {
    $layout = Get-InstallStateLayout
    $seed = [string]$layout.BackendSeed
    if ([string]::IsNullOrWhiteSpace($seed) -or -not (Test-Path -LiteralPath $seed)) {
        return ''
    }

    $relativePaths = @(Get-OrchestrationAppRuntimeFingerprintPaths)
    foreach ($relativePath in $relativePaths) {
        $path = Join-InstallRelativePath -Root $seed -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return ''
        }
    }

    return Get-PathContentFingerprint -Root $seed -RelativePaths $relativePaths
}

function Get-RunningOrchestrationAppImageFacts {
    $facts = [pscustomobject]@{
        ContainerId = ''
        ImageId = ''
        GitSha = ''
        Tag = ''
        RuntimeFingerprint = ''
    }

    try {
        $containerId = Get-ComposeServiceContainerId -ServiceName 'orchestration-app'
        if ([string]::IsNullOrWhiteSpace($containerId)) {
            return $facts
        }
        $facts.ContainerId = $containerId
        $dockerCommand = Get-DockerCommand
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $inspectJson = & $dockerCommand inspect $containerId 2>&1
            if ($LASTEXITCODE -ne 0) {
                return $facts
            }
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $inspected = $inspectJson | ConvertFrom-Json
        if ($inspected -is [System.Array]) {
            $inspected = $inspected[0]
        }
        $facts.ImageId = Get-ObjectPropertyText -Object $inspected -Name 'Image'
        $config = $null
        if ($inspected.PSObject.Properties.Name -contains 'Config') {
            $config = $inspected.Config
        }
        $labels = $null
        if ($null -ne $config -and $config.PSObject.Properties.Name -contains 'Labels') {
            $labels = $config.Labels
        }
        $facts.GitSha = Get-ObjectPropertyText -Object $labels -Name (Get-S63fPackagingGitShaLabelName)
        $facts.Tag = Get-ObjectPropertyText -Object $labels -Name (Get-S63fPackagingTagLabelName)
        $facts.RuntimeFingerprint = Get-ObjectPropertyText -Object $labels -Name (Get-S63fPackagingRuntimeFingerprintLabelName)
        return $facts
    }
    catch {
        return $facts
    }
}

function Test-InstalledBackendMatchesPackage {
    try {
        $imageFacts = Get-RunningOrchestrationAppImageFacts
        $imageContract = Test-BackendImageMatchesS63fContract `
            -GitSha $imageFacts.GitSha `
            -Tag $imageFacts.Tag `
            -RuntimeFingerprint $imageFacts.RuntimeFingerprint `
            -ExpectedFingerprint (Get-ExpectedS63fRuntimeFingerprintFromSeed) `
            -ImageId $imageFacts.ImageId

        $layout = Get-InstallStateLayout
        $envEntries = $null
        if (Test-Path -LiteralPath $layout.BackendEnvFile -PathType Leaf) {
            $envEntries = Read-EnvFile -Path $layout.BackendEnvFile
        }
        $promptContract = Test-BackendPromptContractFromEnvEntries -Entries $envEntries

        $reasons = New-Object System.Collections.Generic.List[string]
        foreach ($reason in @($imageContract.Reasons)) {
            $reasons.Add([string]$reason)
        }
        foreach ($reason in @($promptContract.Reasons)) {
            $reasons.Add([string]$reason)
        }

        return [pscustomobject]@{
            Ok = ([bool]$imageContract.Ok -and [bool]$promptContract.Ok)
            Reasons = @($reasons)
            Image = $imageContract
            Prompt = $promptContract
            ImageFacts = $imageFacts
        }
    }
    catch {
        $failedImage = [pscustomobject]@{ Ok = $false; Reasons = @('running app image contract could not be evaluated') }
        $failedPrompt = [pscustomobject]@{ Ok = $false; Reasons = @('prompt contract could not be evaluated'); AgentCount = 0 }
        return [pscustomobject]@{
            Ok = $false
            Reasons = @('package contract could not be evaluated; offline payload will be applied')
            Image = $failedImage
            Prompt = $failedPrompt
            ImageFacts = $null
        }
    }
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
    $stateLayout = Get-InstallStateLayout
    $backendEnvExisted = Test-Path -LiteralPath $stateLayout.BackendEnvFile
    $stateLayout = Initialize-DevelopmentWorkspace

    $dockerLayout = Get-DockerLayout
    if (-not (Test-Path $dockerLayout.EnvDefaultsFile)) {
        throw "缺少 runtime 默认配置文件：$($dockerLayout.EnvDefaultsFile)"
    }

    $runtimeDefaults = Read-EnvFile -Path $dockerLayout.EnvDefaultsFile
    $existingRuntimeEntries = $null
    if (Test-Path $dockerLayout.EnvFile) {
        $existingRuntimeEntries = Read-EnvFile -Path $dockerLayout.EnvFile
        $runtimeBackupPath = Join-Path $stateLayout.ConfigRoot ('runtime.env.bak-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))
        Copy-Item -LiteralPath $dockerLayout.EnvFile -Destination $runtimeBackupPath -Force
    }

    $legacyCandidates = @(
        $dockerLayout.EnvFile,
        (Join-Path (Get-InstallRoot) 'docker\env\runtime.env')
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$env:ProgramFiles)) {
        $legacyCandidates += (Join-Path $env:ProgramFiles 'XDisplayAI\docker\env\runtime.env')
    }
    foreach ($legacyPath in $legacyCandidates) {
        if ([string]::IsNullOrWhiteSpace([string]$legacyPath)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $legacyPath)) {
            continue
        }
        if ($null -eq $existingRuntimeEntries) {
            $existingRuntimeEntries = Read-EnvFile -Path $legacyPath
        }
        else {
            $legacyEntries = Read-EnvFile -Path $legacyPath
            $existingRuntimeEntries = Merge-EnvEntries -Defaults $legacyEntries -Existing $existingRuntimeEntries
        }
    }

    $runtimeEntries = Merge-EnvEntries `
        -Defaults $runtimeDefaults `
        -Existing $existingRuntimeEntries `
        -ForceEntries @{
            APP_HOST_PORT = [string](Get-RequiredAppHostPort)
            BACKEND_WORKSPACE_PATH = $stateLayout.BackendWorkspace.Replace('\', '/')
        } `
        -DropKeys @(Get-RetiredBackendEnvKeys)
    Write-EnvFile -Path $dockerLayout.EnvFile -Entries $runtimeEntries

    $legacyApplicationEntries = Get-LegacyApplicationEnvEntries -RuntimeEntries $runtimeEntries
    if ($legacyApplicationEntries.Count -gt 0) {
        $backendEnvPath = $stateLayout.BackendEnvFile
        $backendEntries = [ordered]@{}
        if (Test-Path -LiteralPath $backendEnvPath) {
            $backendEntries = Read-EnvFile -Path $backendEnvPath
        }
        $backendChanged = $false
        foreach ($key in @($legacyApplicationEntries.Keys)) {
            $currentBackendValue = ''
            if ($backendEntries.Contains($key)) {
                $currentBackendValue = [string]$backendEntries[$key]
            }
            $legacyWins = -not $backendEnvExisted
            $missingOrEmpty = [string]::IsNullOrWhiteSpace($currentBackendValue)
            if ($legacyWins -or $missingOrEmpty) {
                if ($currentBackendValue -ne [string]$legacyApplicationEntries[$key]) {
                    $backendEntries[$key] = $legacyApplicationEntries[$key]
                    $backendChanged = $true
                }
            }
        }
        if ($backendChanged) {
            $backendEntries = Merge-EnvEntries -Defaults $backendEntries -Existing @{} -DropKeys @(Get-RetiredBackendEnvKeys)
            Write-EnvFile -Path $backendEnvPath -Entries $backendEntries
            Write-Step '已将旧 runtime.env 中的应用配置迁入 backend .env（密钥值未写入日志）。'
        }
        elseif (Test-Path -LiteralPath $backendEnvPath) {
            Remove-RetiredBackendEnvKeys -EnvPath $backendEnvPath | Out-Null
        }
    }

    if (Test-Path -LiteralPath $stateLayout.BackendEnvFile -PathType Leaf) {
        # Retired keys were only dropped on the legacy runtime.env migration branch; an upgraded .env
        # kept XDISPLAY_AI_STAGED_DRAFTER_ENABLED forever and failed the package contract.
        $retiredRemoval = Remove-RetiredBackendEnvKeys -EnvPath $stateLayout.BackendEnvFile
        if ($retiredRemoval.Changed) {
            Write-Step ('已删除退役后端配置键：' + (@($retiredRemoval.Removed) -join ', '))
        }
        $promptMigration = Update-BackendPromptVersionPins `
            -EnvPath $stateLayout.BackendEnvFile `
            -DefaultPromptVersions (Get-S63fRegisteredPromptVersionTable)
        if ($promptMigration.Changed) {
            $changedAgents = @($promptMigration.Added + $promptMigration.Removed)
            Write-Step ('已按 s63f 注册表补全 prompt 钉扎（保留用户已有版本，删除 PAGE_HTML/STYLESHEET 别名）：' + ($changedAgents -join ', '))
        }
        $browserPins = Ensure-BackendBrowserSolverPromptPins -EnvPath $stateLayout.BackendEnvFile
        if ($browserPins.Changed) {
            Write-Step ('已补全浏览器求解器 PAGE_HTML/STYLESHEET 合同键：' + ($browserPins.Added -join ', '))
        }
    }

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
            Phase = ''
            LaunchClientRequested = $false
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
            Phase = ''
            LaunchClientRequested = $false
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

    $phase = ''
    if ($state.PSObject.Properties.Name -contains 'Phase') {
        $phase = [string]$state.Phase
    }

    $launchClientRequested = $false
    if ($state.PSObject.Properties.Name -contains 'LaunchClientRequested') {
        $launchClientRequested = [bool]$state.LaunchClientRequested
    }

    return [pscustomobject]@{
        AutomaticRebootCount = $automaticRebootCount
        LastRebootReasons = $lastRebootReasons
        UpdatedAtUtc = $updatedAtUtc
        Phase = $phase
        LaunchClientRequested = $launchClientRequested
    }
}

function Save-BootstrapState {
    param(
        [int]$AutomaticRebootCount = 0,
        [string[]]$LastRebootReasons = @(),
        [string]$Phase = 'reboot-pending',
        [bool]$LaunchClientRequested = $false
    )

    Initialize-InstallStateDirectories
    $layout = Get-InstallStateLayout
    $state = [pscustomobject]@{
        AutomaticRebootCount = $AutomaticRebootCount
        LastRebootReasons = @($LastRebootReasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        UpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Phase = $Phase
        LaunchClientRequested = $LaunchClientRequested
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

function Assert-DockerHardwareVirtualization {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$HypervisorPresent,
        [Parameter(Mandatory = $true)]
        [bool[]]$VirtualizationFirmwareEnabled
    )

    if ($HypervisorPresent -or ($VirtualizationFirmwareEnabled -contains $true)) {
        return
    }

    throw @'
Docker Desktop 无法启动：BIOS/UEFI 中未开启 CPU 硬件虚拟化。
请按以下步骤操作：
1. 打开 Windows“设置 > 系统 > 恢复 > 高级启动”，点击“立即重新启动”。
2. 依次选择“疑难解答 > 高级选项 > UEFI 固件设置 > 重启”。
3. 在 BIOS/UEFI 中开启 Intel Virtualization Technology (Intel VT-x)，或开启 AMD-V/SVM Mode。
4. 保存设置并退出（通常按 F10），进入 Windows 后重新运行 XDisplay AI 安装。
如果没有“UEFI 固件设置”，请在开机时按厂商指定的 Del、F2、F10 或 Esc 键进入 BIOS。
'@
}

function Get-LoopbackListenerProcessName {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    try {
        $connection = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $connection) {
            return ''
        }

        $process = Get-Process -Id $connection.OwningProcess -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            return ''
        }
        return [string]$process.Name
    }
    catch {
        return ''
    }
}

function Get-LocalBackendOriginFacts {
    param(
        [int]$HealthzStatus = 0,
        [int]$AssistantStatus = 0,
        [int]$RequiredPort = 18001
    )

    $facts = [pscustomobject]@{
        HealthzStatus = $HealthzStatus
        AssistantStatus = $AssistantStatus
        PublishedBinding = ''
        ListenerProcess = Get-LoopbackListenerProcessName -Port $RequiredPort
        PortProxyEntries = @()
        RunningServices = @()
        DockerHost = ''
        ServerOs = ''
        OperatingSystem = ''
    }

    try {
        $proxyLines = @(& netsh.exe interface portproxy show all 2>$null)
        $facts.PortProxyEntries = @(ConvertTo-PortProxyListenEntries -Lines $proxyLines)
    }
    catch {
        $facts.PortProxyEntries = @()
    }

    try {
        $dockerCommand = Get-DockerCommand
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $facts.DockerHost = ((& $dockerCommand context inspect --format '{{.Endpoints.docker.Host}}' | Out-String).Trim())
            $facts.ServerOs = ((& $dockerCommand info --format '{{.OSType}}' | Out-String).Trim())
            $facts.OperatingSystem = ((& $dockerCommand info --format '{{.OperatingSystem}}' | Out-String).Trim())
            $composeLines = @(& $dockerCommand compose --project-name (Get-DockerLayout).ProjectName ps --format '{{.Service}}')
            $facts.RunningServices = @($composeLines | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    catch {
    }

    try {
        $dockerCommand = Get-DockerCommand
        $layout = Get-DockerLayout
        $published = ((& $dockerCommand compose --project-name $layout.ProjectName --env-file $layout.EnvFile -f $layout.BaseCompose -f $layout.OverlayCompose port orchestration-app 8000 | Out-String).Trim())
        if ($published -match '127\.0\.0\.1:(\d+)') {
            $facts.PublishedBinding = "127.0.0.1:$($Matches[1])"
        }
        elseif ($facts.RunningServices -contains 'orchestration-app') {
            $facts.PublishedBinding = "127.0.0.1:$RequiredPort"
        }
    }
    catch {
        if ($facts.RunningServices -contains 'orchestration-app') {
            $facts.PublishedBinding = "127.0.0.1:$RequiredPort"
        }
    }

    return $facts
}
