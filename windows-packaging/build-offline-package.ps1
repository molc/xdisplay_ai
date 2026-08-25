param(
    [string]$Channel = 'dev',
    [string]$BackendRepoPath = 'C:\work\backend',
    [string]$XdisplayRepoPath = 'C:\work\xdisplay',
    [string]$PrerequisitesSourceRoot = '',
    [string]$QmakePath = '',
    [string]$MingwMakePath = '',
    [string]$WinDeployQtPath = '',
    [string]$QmakeSpec = 'win32-g++',
    [string]$ReportPath = '',
    [switch]$PreflightOnly,
    [switch]$SkipClientProtoCompile,
    [switch]$SkipBackendImageBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$packagingRoot = (Resolve-Path $PSScriptRoot).Path
$startedAtUtc = [DateTime]::UtcNow
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

. (Join-Path $packagingRoot 'ci\Common.ps1')

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-BuildStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[one-click-build] $Message" -ForegroundColor Cyan
}

function Resolve-RequiredPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$DisplayName is required."
    }
    if (-not (Test-Path $Path)) {
        throw "$DisplayName does not exist: $Path"
    }

    return (Resolve-Path $Path).Path
}

function Assert-RequiredRelativePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string[]]$RelativePaths
    )

    $missingPaths = @()
    foreach ($relativePath in $RelativePaths) {
        $absolutePath = Join-Path $Root $relativePath
        if (-not (Test-Path $absolutePath)) {
            $missingPaths += $relativePath
        }
    }

    if ($missingPaths.Count -gt 0) {
        throw "$DisplayName is incomplete. Missing: $($missingPaths -join ', ')"
    }
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        [string]$ExplicitPath = '',
        [string[]]$CandidatePaths = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return Resolve-RequiredPath -Path $ExplicitPath -DisplayName $ToolName
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return (Resolve-Path $command.Source).Path
    }

    foreach ($candidatePath in $CandidatePaths) {
        if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and (Test-Path $candidatePath)) {
            return (Resolve-Path $candidatePath).Path
        }
    }

    throw "Required build tool was not found: $ToolName"
}

function Get-SourceRevision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    $revisionFile = Join-Path $SourceRoot 'SOURCE_REVISION.txt'
    if (Test-Path $revisionFile) {
        $revision = (Get-Content -Path $revisionFile -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($revision)) {
            return $revision
        }
    }

    if ((Test-Path (Join-Path $SourceRoot '.git')) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        try {
            $revision = (& git -C $SourceRoot rev-parse HEAD 2>$null | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($revision)) {
                return $revision
            }
        }
        catch {
        }
    }

    return 'unknown'
}

function Write-BuildReport {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent
    }

    $content = $Report | ConvertTo-Json -Depth 8
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $content, $utf8NoBom)
}

function Wait-ForDockerDaemon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerPath,
        [int]$MaxAttempts = 120,
        [int]$SleepSeconds = 5
    )

    if (Test-DockerDaemonReady -DockerPath $DockerPath) {
        Write-BuildStep 'Docker daemon is ready.'
        return
    }

    $currentIdentityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    Assert-CanStartDockerDesktop -IdentityName $currentIdentityName

    $dockerService = Get-Service -Name 'com.docker.service' -ErrorAction SilentlyContinue
    if ($null -ne $dockerService -and $dockerService.Status -ne 'Running') {
        Write-BuildStep 'Starting Docker Desktop service.'
        Start-Service -Name 'com.docker.service'
    }

    $dockerDesktopPath = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    if ((Test-Path $dockerDesktopPath) -and -not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
        Write-BuildStep 'Starting Docker Desktop.'
        Start-Process -FilePath $dockerDesktopPath | Out-Null
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Test-DockerDaemonReady -DockerPath $DockerPath) {
            Write-BuildStep 'Docker daemon is ready.'
            return
        }

        Write-BuildStep "Waiting for Docker daemon ($attempt/$MaxAttempts)."
        Start-Sleep -Seconds $SleepSeconds
    }

    throw 'Docker daemon did not become ready.'
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $normalizedRoot + [System.IO.Path]::DirectorySeparatorChar
    if (-not $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside delivery root: $Path"
    }

    return $normalizedPath.Substring($prefix.Length).Replace('\', '/')
}

function Test-DeliveryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistDirectory,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactManifestPath,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredArtifactNames
    )

    if (-not (Test-Path $DistDirectory)) {
        throw "Delivery directory was not created: $DistDirectory"
    }

    foreach ($artifactName in $RequiredArtifactNames) {
        $artifactPath = Join-Path $DistDirectory $artifactName
        if (-not (Test-Path $artifactPath)) {
            throw "Required delivery artifact is missing: $artifactName"
        }
        if ((Get-Item -Path $artifactPath).Length -le 0) {
            throw "Required delivery artifact is empty: $artifactName"
        }
    }

    $cabFiles = @(Get-ChildItem -Path $DistDirectory -Filter 'xdp*.cab' -File -ErrorAction SilentlyContinue)
    if ($cabFiles.Count -eq 0) {
        throw 'Delivery directory does not contain any external xdp*.cab files.'
    }

    if (-not (Test-Path $ArtifactManifestPath)) {
        throw "Artifact manifest is missing: $ArtifactManifestPath"
    }

    $manifestEntries = @(Read-JsonArrayFile -Path $ArtifactManifestPath)
    if ($manifestEntries.Count -eq 0) {
        throw 'Artifact manifest is empty.'
    }

    $manifestByPath = @{}
    foreach ($entry in $manifestEntries) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            throw 'Artifact manifest contains an empty relativePath.'
        }

        $artifactPath = Join-Path $DistDirectory $relativePath.Replace('/', '\')
        if (-not (Test-Path $artifactPath)) {
            throw "Artifact manifest references a missing file: $relativePath"
        }

        $file = Get-Item -Path $artifactPath
        if ([long]$entry.sizeBytes -ne $file.Length) {
            throw "Artifact size mismatch: $relativePath"
        }

        $actualHash = (Get-FileHash -Path $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals($actualHash, [string]$entry.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Artifact SHA256 mismatch: $relativePath"
        }

        $manifestByPath[$relativePath.ToLowerInvariant()] = $true
    }

    $actualArtifacts = @(Get-ChildItem -Path $DistDirectory -File -Recurse | Where-Object {
        -not [string]::Equals($_.FullName, $ArtifactManifestPath, [System.StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($artifact in $actualArtifacts) {
        $relativePath = Get-RelativePathFromRoot -Root $DistDirectory -Path $artifact.FullName
        if (-not $manifestByPath.ContainsKey($relativePath.ToLowerInvariant())) {
            throw "Delivery artifact is not recorded in the manifest: $relativePath"
        }
    }

    return [pscustomobject]@{
        fileCount = $actualArtifacts.Count + 1
        cabCount = $cabFiles.Count
        manifestEntryCount = $manifestEntries.Count
    }
}

if ([string]::IsNullOrWhiteSpace($PrerequisitesSourceRoot)) {
    $PrerequisitesSourceRoot = Join-Path $packagingRoot 'inputs\prerequisites'
}

if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $ReportPath = Join-Path $packagingRoot "logs\build-$Channel-$timestamp.json"
}
else {
    $ReportPath = [System.IO.Path]::GetFullPath($ReportPath)
}

$transcriptPath = [System.IO.Path]::ChangeExtension($ReportPath, '.log')
$report = [pscustomobject]@{
    schemaVersion = 1
    status = 'starting'
    channel = $Channel
    startedAtUtc = $startedAtUtc.ToString('o')
    finishedAtUtc = ''
    packagingRoot = $packagingRoot
    sources = [pscustomobject]@{
        backend = [pscustomobject]@{ path = ''; revision = 'unknown' }
        xdisplay = [pscustomobject]@{ path = ''; revision = 'unknown' }
    }
    prerequisitesRoot = ''
    tools = [pscustomobject]@{
        docker = ''
        wix = ''
        qmake = ''
        mingwMake = ''
        winDeployQt = ''
    }
    output = [pscustomobject]@{
        directory = ''
        bundle = ''
        msi = ''
        artifactManifest = ''
        fileCount = 0
        cabCount = 0
    }
    reportPath = $ReportPath
    transcriptPath = $transcriptPath
    error = ''
}

$transcriptStarted = $false

try {
    $reportParent = Split-Path -Path $ReportPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($reportParent)) {
        Ensure-Directory -Path $reportParent
    }
    Start-Transcript -Path $transcriptPath -Force | Out-Null
    $transcriptStarted = $true

    Write-BuildStep 'Running source and environment preflight.'

    $resolvedBackendRepoPath = Resolve-RequiredPath -Path $BackendRepoPath -DisplayName 'BackendRepoPath'
    $resolvedXdisplayRepoPath = Resolve-RequiredPath -Path $XdisplayRepoPath -DisplayName 'XdisplayRepoPath'
    $resolvedPrerequisitesRoot = Resolve-RequiredPath -Path $PrerequisitesSourceRoot -DisplayName 'PrerequisitesSourceRoot'

    Assert-RequiredRelativePaths -Root $resolvedBackendRepoPath -DisplayName 'Backend source' -RelativePaths @(
        'Dockerfile',
        'Dockerfile.embedding',
        'docker-compose.yml',
        'db\migrations',
        'data\chunks\component_capabilities_v1.jsonl',
        'external\xdisplay\bin\xd_render_cli\xd_render_cli.pro'
    )
    Assert-RequiredRelativePaths -Root $resolvedXdisplayRepoPath -DisplayName 'Xdisplay source' -RelativePaths @(
        'src\Xdisplay_V2.pro',
        'src\Service_PB\compile_all_proto.bat',
        'src\Service_Caesium\caesium\caesium.dll',
        'src\Service_PackL\res\UpdateUnpack.exe'
    )
    Assert-RequiredRelativePaths -Root $resolvedPrerequisitesRoot -DisplayName 'Offline prerequisites' -RelativePaths @(
        'docker-desktop\Docker Desktop Installer.exe',
        'vcredist\VC_redist.x64.exe',
        'wsl\wsl_update_x64.msi'
    )

    $buildPackageScriptPath = Join-Path $packagingRoot 'ci\build-package-from-source.ps1'
    Assert-RequiredRelativePaths -Root $packagingRoot -DisplayName 'Packaging scripts' -RelativePaths @(
        'ci\build-package-from-source.ps1',
        'ci\prepare-inputs.ps1',
        'ci\build-xdisplay-from-source.ps1',
        'ci\build-installer.ps1',
        'ci\publish.ps1',
        'compat\xdisplay-windows-posix-compat.h',
        "manifests\channels\$Channel.json"
    )

    $qmakeCandidates = @(
        'C:\Qt\5.15.2\mingw81_64\bin\qmake.exe',
        'C:\Qt\Qt5.15.2\5.15.2\mingw81_64\bin\qmake.exe'
    )
    if (-not [string]::IsNullOrWhiteSpace($env:QTDIR)) {
        $qmakeCandidates = @((Join-Path $env:QTDIR 'bin\qmake.exe')) + $qmakeCandidates
    }

    $resolvedQmakePath = Resolve-ToolPath -ToolName 'qmake' -ExplicitPath $QmakePath -CandidatePaths $qmakeCandidates
    $qmakeBinDirectory = Split-Path -Path $resolvedQmakePath -Parent
    $resolvedWinDeployQtPath = Resolve-ToolPath -ToolName 'windeployqt' -ExplicitPath $WinDeployQtPath -CandidatePaths @(
        (Join-Path $qmakeBinDirectory 'windeployqt.exe')
    )
    $resolvedMingwMakePath = Resolve-ToolPath -ToolName 'mingw32-make' -ExplicitPath $MingwMakePath -CandidatePaths @(
        (Join-Path $qmakeBinDirectory 'mingw32-make.exe'),
        'C:\Qt\Tools\mingw810_64\bin\mingw32-make.exe',
        'C:\Qt\Qt5.15.2\Tools\mingw810_64\bin\mingw32-make.exe'
    )
    $resolvedDockerPath = Resolve-ToolPath -ToolName 'docker' -CandidatePaths @(
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    )
    $resolvedWixPath = Resolve-ToolPath -ToolName 'wix'

    $report.sources.backend.path = $resolvedBackendRepoPath
    $report.sources.backend.revision = Get-SourceRevision -SourceRoot $resolvedBackendRepoPath
    $report.sources.xdisplay.path = $resolvedXdisplayRepoPath
    $report.sources.xdisplay.revision = Get-SourceRevision -SourceRoot $resolvedXdisplayRepoPath
    $report.prerequisitesRoot = $resolvedPrerequisitesRoot
    $report.tools.docker = $resolvedDockerPath
    $report.tools.wix = $resolvedWixPath
    $report.tools.qmake = $resolvedQmakePath
    $report.tools.mingwMake = $resolvedMingwMakePath
    $report.tools.winDeployQt = $resolvedWinDeployQtPath

    if ($PreflightOnly) {
        $report.status = 'preflight_passed'
        $report.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-BuildReport -Report $report -Path $ReportPath
        Write-BuildStep "Preflight passed. Report: $ReportPath"
        return
    }

    Wait-ForDockerDaemon -DockerPath $resolvedDockerPath

    $report.status = 'building'
    Write-BuildReport -Report $report -Path $ReportPath

    $buildArguments = @{
        Channel = $Channel
        BackendRepoPath = $resolvedBackendRepoPath
        XdisplayRepoPath = $resolvedXdisplayRepoPath
        QmakePath = $resolvedQmakePath
        MingwMakePath = $resolvedMingwMakePath
        WinDeployQtPath = $resolvedWinDeployQtPath
        QmakeSpec = $QmakeSpec
        PrerequisitesSourceRoot = $resolvedPrerequisitesRoot
    }
    if ($SkipClientProtoCompile) {
        $buildArguments.SkipClientProtoCompile = $true
    }
    if ($SkipBackendImageBuild) {
        $buildArguments.SkipBackendImageBuild = $true
    }

    Write-BuildStep 'Building client, backend images, MSI, and offline bundle.'
    & $buildPackageScriptPath @buildArguments

    $bundleManifest = Get-Content -Path (Join-Path $packagingRoot 'manifests\bundle.json') -Raw | ConvertFrom-Json
    $channelManifest = Get-Content -Path (Join-Path $packagingRoot "manifests\channels\$Channel.json") -Raw | ConvertFrom-Json
    $versionSuffix = if ([string]::IsNullOrWhiteSpace([string]$channelManifest.bundleVersionSuffix)) { '' } else { [string]$channelManifest.bundleVersionSuffix }
    $version = [string]$bundleManifest.bundle.version
    $distDirectory = Join-Path $packagingRoot "dist\$Channel"
    $bundleName = "XDisplayAI-$version$versionSuffix.exe"
    $msiName = "XDisplayAI-$version$versionSuffix.msi"
    $artifactManifestName = "artifacts-$Channel.json"
    $artifactManifestPath = Join-Path $distDirectory $artifactManifestName

    Write-BuildStep 'Verifying the complete offline delivery directory and SHA256 manifest.'
    $deliverySummary = Test-DeliveryDirectory `
        -DistDirectory $distDirectory `
        -ArtifactManifestPath $artifactManifestPath `
        -RequiredArtifactNames @(
            $bundleName,
            $msiName,
            'Docker Desktop Installer.exe',
            'VC_redist.x64.exe',
            'wsl_update_x64.msi'
        )

    $report.status = 'succeeded'
    $report.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $report.output.directory = $distDirectory
    $report.output.bundle = Join-Path $distDirectory $bundleName
    $report.output.msi = Join-Path $distDirectory $msiName
    $report.output.artifactManifest = $artifactManifestPath
    $report.output.fileCount = $deliverySummary.fileCount
    $report.output.cabCount = $deliverySummary.cabCount
    Write-BuildReport -Report $report -Path $ReportPath

    Write-BuildStep "Build succeeded. Delivery directory: $distDirectory"
    Write-BuildStep "Installer: $($report.output.bundle)"
    Write-BuildStep "Report: $ReportPath"
}
catch {
    $report.status = 'failed'
    $report.finishedAtUtc = [DateTime]::UtcNow.ToString('o')
    $report.error = $_.Exception.Message
    try {
        Write-BuildReport -Report $report -Path $ReportPath
    }
    catch {
    }
    Write-Error $_
    exit 1
}
finally {
    if ($transcriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
        }
    }
}
