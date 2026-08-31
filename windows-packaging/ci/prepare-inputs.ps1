param(
    [string]$BackendRepoPath = '',
    [string]$ClientReleaseDir = '',
    [string]$XdisplayRepoPath = '',
    [string]$ClientBuildOutputDir = '',
    [string]$ClientBuildDirectory = '',
    [string]$QmakePath = '',
    [string]$MingwMakePath = '',
    [string]$WinDeployQtPath = '',
    [string]$QmakeSpec = 'win32-g++',
    [string]$PrerequisitesSourceRoot = '',
    [switch]$SkipClientProtoCompile,
    [switch]$SkipBackendImageBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Resolve-ExistingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        throw "$DisplayName 不能为空。"
    }

    if (-not (Test-Path $PathValue)) {
        throw "$DisplayName 不存在：$PathValue"
    }

    return (Resolve-Path $PathValue).Path
}

function Resolve-BackendRepoPath {
    param(
        [AllowEmptyString()]
        [string]$PathValue
    )

    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        return Resolve-ExistingPath -PathValue $PathValue -DisplayName 'BackendRepoPath'
    }

    $candidatePaths = @(
        (Join-Path $PSScriptRoot '..\..\..\ai-orchestration-page-engineering-unified'),
        (Join-Path $PSScriptRoot '..\..\ai-orchestration-page-engineering-unified')
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
            $resolvedPath = (Resolve-Path $candidatePath).Path
            Write-Step "自动定位 BackendRepoPath：$resolvedPath"
            return $resolvedPath
        }
    }

    throw '未提供 BackendRepoPath，且默认候选目录中未找到 ai-orchestration-page-engineering-unified。'
}

function Resolve-ClientReleaseDir {
    param(
        [AllowEmptyString()]
        [string]$PathValue,
        [AllowEmptyString()]
        [string]$SourceRepoPath,
        [AllowEmptyString()]
        [string]$BuildOutputDir,
        [AllowEmptyString()]
        [string]$BuildDirectory,
        [AllowEmptyString()]
        [string]$ResolvedQmakePath,
        [AllowEmptyString()]
        [string]$ResolvedMingwMakePath,
        [AllowEmptyString()]
        [string]$ResolvedWinDeployQtPath,
        [string]$ResolvedQmakeSpec,
        [bool]$ShouldSkipProtoCompile
    )

    $sourceBuildRequested = `
        (-not [string]::IsNullOrWhiteSpace($SourceRepoPath)) -or `
        (-not [string]::IsNullOrWhiteSpace($BuildOutputDir)) -or `
        (-not [string]::IsNullOrWhiteSpace($BuildDirectory)) -or `
        (-not [string]::IsNullOrWhiteSpace($ResolvedQmakePath)) -or `
        (-not [string]::IsNullOrWhiteSpace($ResolvedMingwMakePath)) -or `
        (-not [string]::IsNullOrWhiteSpace($ResolvedWinDeployQtPath)) -or `
        ($ShouldSkipProtoCompile) -or `
        (-not [string]::Equals($ResolvedQmakeSpec, 'win32-g++', [System.StringComparison]::OrdinalIgnoreCase))

    if (-not [string]::IsNullOrWhiteSpace($PathValue) -and $sourceBuildRequested) {
        throw 'ClientReleaseDir 与源码构建参数不能同时提供，请二选一。'
    }

    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        return Resolve-ExistingPath -PathValue $PathValue -DisplayName 'ClientReleaseDir'
    }

    $stagedClientDir = Join-FromRoot 'inputs/client/xdisplay-win64'
    $stagedClientExecutable = Join-Path $stagedClientDir 'Xdisplay.exe'
    if (-not $sourceBuildRequested -and (Test-Path $stagedClientExecutable)) {
        $resolvedPath = (Resolve-Path $stagedClientDir).Path
        Write-Step "复用已存在的客户端输入：$resolvedPath"
        return $resolvedPath
    }
    return Build-ClientReleaseFromSource `
        -SourceRepoPath $SourceRepoPath `
        -BuildOutputDir $BuildOutputDir `
        -BuildDirectory $BuildDirectory `
        -ResolvedQmakePath $ResolvedQmakePath `
        -ResolvedMingwMakePath $ResolvedMingwMakePath `
        -ResolvedWinDeployQtPath $ResolvedWinDeployQtPath `
        -ResolvedQmakeSpec $ResolvedQmakeSpec `
        -ShouldSkipProtoCompile $ShouldSkipProtoCompile
}

function Resolve-ClientBuildOutputPath {
    param(
        [AllowEmptyString()]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return [System.IO.Path]::GetFullPath((Join-FromRoot 'cache/client-release-from-source/xdisplay-win64'))
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Resolve-ClientBuildDirectoryPath {
    param(
        [AllowEmptyString()]
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return [System.IO.Path]::GetFullPath((Join-FromRoot 'cache/xdisplay-build'))
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Build-ClientReleaseFromSource {
    param(
        [AllowEmptyString()]
        [string]$SourceRepoPath,
        [AllowEmptyString()]
        [string]$BuildOutputDir,
        [AllowEmptyString()]
        [string]$BuildDirectory,
        [AllowEmptyString()]
        [string]$ResolvedQmakePath,
        [AllowEmptyString()]
        [string]$ResolvedMingwMakePath,
        [AllowEmptyString()]
        [string]$ResolvedWinDeployQtPath,
        [string]$ResolvedQmakeSpec,
        [bool]$ShouldSkipProtoCompile
    )

    $buildClientScriptPath = Join-Path $PSScriptRoot 'build-xdisplay-from-source.ps1'
    if (-not (Test-Path $buildClientScriptPath)) {
        throw "缺少客户端源码构建脚本：$buildClientScriptPath"
    }

    $resolvedBuildOutputDir = Resolve-ClientBuildOutputPath -PathValue $BuildOutputDir
    $resolvedBuildDirectory = Resolve-ClientBuildDirectoryPath -PathValue $BuildDirectory

    Write-Step '将从 xdisplay 源码生成客户端发布目录。'

    $buildClientArgs = @{
        OutputDir = $resolvedBuildOutputDir
        BuildDirectory = $resolvedBuildDirectory
        QmakeSpec = $ResolvedQmakeSpec
    }

    if (-not [string]::IsNullOrWhiteSpace($SourceRepoPath)) {
        $buildClientArgs.XdisplayRepoPath = Resolve-ExistingPath -PathValue $SourceRepoPath -DisplayName 'XdisplayRepoPath'
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedQmakePath)) {
        $buildClientArgs.QmakePath = $ResolvedQmakePath
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedMingwMakePath)) {
        $buildClientArgs.MingwMakePath = $ResolvedMingwMakePath
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedWinDeployQtPath)) {
        $buildClientArgs.WinDeployQtPath = $ResolvedWinDeployQtPath
    }

    if ($ShouldSkipProtoCompile) {
        $buildClientArgs.SkipProtoCompile = $true
    }

    & $buildClientScriptPath @buildClientArgs
    return $resolvedBuildOutputDir
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue
    )

    $fullyQualifiedPath = if (Test-Path $PathValue) {
        [System.IO.Path]::GetFullPath((Resolve-Path $PathValue).Path)
    }
    else {
        [System.IO.Path]::GetFullPath($PathValue)
    }

    return $fullyQualifiedPath.TrimEnd([char[]]@([char]92, [char]47))
}

function Test-PathIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LeftPath,
        [Parameter(Mandatory = $true)]
        [string]$RightPath
    )

    return [string]::Equals(
        (Get-NormalizedPath -PathValue $LeftPath),
        (Get-NormalizedPath -PathValue $RightPath),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Sync-DirectorySnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if (Test-PathIdentity -LeftPath $Source -RightPath $Destination) {
        Ensure-Directory -Path $Destination
        Write-Step "$DisplayName 已指向当前 inputs 目录，保留现有内容。"
        return
    }

    Reset-Directory -Path $Destination
    Copy-Tree -Source $Source -Destination $Destination
}

function Sync-BackendSourceSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (Test-PathIdentity -LeftPath $Source -RightPath $Destination) {
        throw 'BackendRepoPath 不能指向 inputs/backend/source；源目录必须是独立副本。'
    }

    Reset-Directory -Path $Destination
    $excludedDirectories = @(
        '.git',
        '.venv',
        '.mypy_cache',
        '.pytest_cache',
        '.ruff_cache',
        '__pycache__',
        'node_modules',
        'scratchpad-logs',
        'render_debug'
    )
    $robocopyArguments = @(
        $Source,
        $Destination,
        '/MIR',
        '/R:2',
        '/W:1',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP',
        '/XF',
        '.env',
        '.DS_Store',
        '/XD'
    ) + $excludedDirectories

    & robocopy.exe @robocopyArguments | Out-Host
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "后端源码快照同步失败，robocopy exit code: $robocopyExitCode"
    }

    if (-not (Test-Path (Join-Path $Destination 'app\main.py'))) {
        throw '后端源码快照缺少 app\main.py。'
    }
}

function Export-BackendImages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'prepare-inputs 需要 docker 命令来导出离线镜像。'
    }

    Ensure-Directory -Path $DestinationDirectory
    $expectedTarFileNames = @{}

    foreach ($imageSpec in Get-BackendImageSpecs) {
        $expectedTarFileNames[$imageSpec.TarFileName] = $true
        $tarPath = Join-Path $DestinationDirectory $imageSpec.TarFileName

        Write-Step "校验离线镜像：$($imageSpec.ImageRef)"
        & docker image inspect $imageSpec.ImageRef > $null 2> $null
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path $tarPath) {
                Write-Step "本地缺少镜像，保留已有 tar：$($imageSpec.TarFileName)"
                continue
            }

            throw "本地缺少镜像：$($imageSpec.ImageRef)"
        }

        $temporaryTarPath = "$tarPath.partial"
        if (Test-Path $temporaryTarPath) {
            Remove-Item -Path $temporaryTarPath -Force
        }

        Write-Step "导出离线镜像：$($imageSpec.ImageRef) -> $($imageSpec.TarFileName)"
        & docker save --output $temporaryTarPath $imageSpec.ImageRef
        if ($LASTEXITCODE -ne 0) {
            if (Test-Path $temporaryTarPath) {
                Remove-Item -Path $temporaryTarPath -Force
            }

            throw "导出镜像失败：$($imageSpec.ImageRef)"
        }

        Move-Item -Path $temporaryTarPath -Destination $tarPath -Force
    }

    Get-ChildItem -Path $DestinationDirectory -Filter '*.tar' -File -ErrorAction SilentlyContinue | Where-Object {
        -not $expectedTarFileNames.ContainsKey($_.Name)
    } | Remove-Item -Force
}

function Build-BackendImagesFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackendRepoPath
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'prepare-inputs 需要 docker 命令来构建后端镜像。'
    }

    $imageBuilds = @(
        [pscustomobject]@{
            ImageRef = 'orches/orchestration-app:latest'
            RuntimeImageRef = 'orches/orchestration-app:xdisplayai-runtime-cache'
            Dockerfile = 'Dockerfile'
            RuntimeFingerprintPaths = @(
                'Dockerfile',
                'external\xdisplay\bin\xd_render_cli'
            )
        },
        [pscustomobject]@{
            ImageRef = 'orches/embedding-http:latest'
            RuntimeImageRef = 'orches/embedding-http:xdisplayai-runtime-cache'
            Dockerfile = 'Dockerfile.embedding'
            RuntimeFingerprintPaths = @('Dockerfile.embedding')
        }
    )

    foreach ($imageBuild in $imageBuilds) {
        $dockerfilePath = Join-Path $BackendRepoPath $imageBuild.Dockerfile
        if (-not (Test-Path $dockerfilePath)) {
            throw "未找到 Dockerfile：$dockerfilePath"
        }

        if ($SkipBackendImageBuild) {
            Write-Step "跳过基础镜像构建，复用运行时依赖缓存：$($imageBuild.RuntimeImageRef)"
            & docker image inspect $imageBuild.RuntimeImageRef > $null 2> $null
            if ($LASTEXITCODE -ne 0) {
                throw "缺少可复用的后端基础镜像：$($imageBuild.RuntimeImageRef)"
            }
            & docker image tag $imageBuild.RuntimeImageRef $imageBuild.ImageRef
            if ($LASTEXITCODE -ne 0) {
                throw "标记后端基础镜像失败：$($imageBuild.ImageRef)"
            }
            continue
        }

        $runtimeFingerprint = Get-SourceContentFingerprint `
            -Root $BackendRepoPath `
            -RelativePaths $imageBuild.RuntimeFingerprintPaths
        $runtimeMetadata = Get-DockerImageMetadata -ImageRef $imageBuild.RuntimeImageRef
        $runtimeImageExists = $null -ne $runtimeMetadata
        $cachedFingerprint = if ($runtimeImageExists) {
            Get-DockerImageLabelValue `
                -ImageMetadata $runtimeMetadata `
                -LabelName 'xdisplayai.packaging.runtime-fingerprint'
        }
        else {
            ''
        }
        $cacheDecision = Get-BackendRuntimeCacheDecision `
            -ImageExists $runtimeImageExists `
            -ExpectedFingerprint $runtimeFingerprint `
            -CachedFingerprint $cachedFingerprint

        if ($cacheDecision -eq 'refresh') {
            Write-Step "运行时依赖缓存缺失或指纹不匹配，完整构建：$($imageBuild.RuntimeImageRef)"
            & docker build `
                --file $dockerfilePath `
                --label "xdisplayai.packaging.runtime-fingerprint=$runtimeFingerprint" `
                --label "xdisplayai.packaging.build-method=full-runtime-cache" `
                --tag $imageBuild.RuntimeImageRef `
                $BackendRepoPath
            if ($LASTEXITCODE -ne 0) {
                throw (
                    "后端运行时依赖缓存刷新失败：$($imageBuild.ImageRef)。" +
                    "期望指纹=$runtimeFingerprint；缓存指纹=$cachedFingerprint。" +
                    '源码依赖或 Dockerfile 变化后必须先在可联网环境刷新 runtime-cache 镜像，' +
                    '普通 app/data 源码更新可继续离线一键打包。'
                )
            }
        }
        else {
            Write-Step "复用匹配的后端运行时依赖缓存：$($imageBuild.RuntimeImageRef)"
        }

        Write-Step "将运行时依赖缓存标记为开发版基础镜像：$($imageBuild.ImageRef)"
        & docker image tag $imageBuild.RuntimeImageRef $imageBuild.ImageRef
        if ($LASTEXITCODE -ne 0) {
            throw "标记后端基础镜像失败：$($imageBuild.ImageRef)"
        }
    }
}

function Get-DockerImageMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageRef
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $inspectOutput = (& docker image inspect $ImageRef 2>$null | Out-String)
        $inspectExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($inspectExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($inspectOutput)) {
        return $null
    }

    $metadata = @($inspectOutput | ConvertFrom-Json)
    if ($metadata.Count -ne 1) {
        throw "Docker image inspect 返回了意外的结果数量：$ImageRef"
    }
    return $metadata[0]
}

function Get-DockerImageLabelValue {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$ImageMetadata,
        [Parameter(Mandatory = $true)]
        [string]$LabelName
    )

    if ($null -eq $ImageMetadata.Config -or $null -eq $ImageMetadata.Config.Labels) {
        return ''
    }
    $labelProperty = $ImageMetadata.Config.Labels.PSObject.Properties[$LabelName]
    if ($null -eq $labelProperty) {
        return ''
    }
    return [string]$labelProperty.Value
}

function Invoke-DockerSmokeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    # Windows PowerShell 5.1 turns any native stderr line into an ErrorRecord.
    # Some successful backend imports intentionally emit structured diagnostics
    # to stderr, so temporarily allow that stream and trust the process exit code.
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $nativeOutput = @(& docker @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    foreach ($outputLine in $nativeOutput) {
        Write-Host ([string]$outputLine)
    }

    return $exitCode
}

function Test-BackendImageSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RunArguments,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'prepare-inputs 需要 docker 命令来验证离线镜像。'
    }

    Write-Step "验证离线镜像：$DisplayName"
    $exitCode = Invoke-DockerSmokeCommand -Arguments (@('run', '--rm') + $RunArguments)
    if ($exitCode -ne 0) {
        throw "离线镜像验证失败：$DisplayName"
    }
}

function Test-BackendImages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackendRepoPath
    )

    Test-BackendImageSmoke `
        -RunArguments @('--mount', "type=bind,source=$BackendRepoPath,target=/app", 'orches/orchestration-app:latest', 'python', '-c', 'import app.main') `
        -DisplayName 'orchestration-app import bind-mounted app.main'

    Test-BackendImageSmoke `
        -RunArguments @('--mount', "type=bind,source=$BackendRepoPath,target=/app", 'orches/embedding-http:latest', 'python', '-m', 'py_compile', 'scripts/embedding_http_service.py') `
        -DisplayName 'embedding-http compile bind-mounted current service source'
}

$resolvedBackendRepoPath = Resolve-BackendRepoPath -PathValue $BackendRepoPath
$resolvedClientReleaseDir = Resolve-ClientReleaseDir `
    -PathValue $ClientReleaseDir `
    -SourceRepoPath $XdisplayRepoPath `
    -BuildOutputDir $ClientBuildOutputDir `
    -BuildDirectory $ClientBuildDirectory `
    -ResolvedQmakePath $QmakePath `
    -ResolvedMingwMakePath $MingwMakePath `
    -ResolvedWinDeployQtPath $WinDeployQtPath `
    -ResolvedQmakeSpec $QmakeSpec `
    -ShouldSkipProtoCompile $SkipClientProtoCompile.IsPresent
$resolvedPrerequisitesSourceRoot = if ([string]::IsNullOrWhiteSpace($PrerequisitesSourceRoot)) {
    $null
}
else {
    Resolve-ExistingPath -PathValue $PrerequisitesSourceRoot -DisplayName 'PrerequisitesSourceRoot'
}

Write-Step "准备后端静态输入：$resolvedBackendRepoPath"
Write-Step "准备客户端发布输入：$resolvedClientReleaseDir"
if (-not [string]::IsNullOrWhiteSpace($XdisplayRepoPath)) {
    Write-Step "客户端源码仓：$XdisplayRepoPath"
}
if ($resolvedPrerequisitesSourceRoot) {
    Write-Step "准备前置依赖输入：$resolvedPrerequisitesSourceRoot"
}

$composeSource = Join-Path $resolvedBackendRepoPath 'docker-compose.yml'
$envExampleSource = Join-Path $resolvedBackendRepoPath '.env.orches.example'
$migrationSourceDir = Join-Path $resolvedBackendRepoPath 'db/migrations'

$clientExecutableSource = Join-Path $resolvedClientReleaseDir 'Xdisplay.exe'
if (-not (Test-Path $clientExecutableSource)) {
    throw "客户端发布目录缺少 Xdisplay.exe：$clientExecutableSource"
}

if (-not (Test-Path $composeSource)) {
    throw "未找到 docker-compose.yml：$composeSource"
}

if (-not (Test-Path $migrationSourceDir)) {
    throw "未找到迁移目录：$migrationSourceDir"
}

$composeTargetDir = Join-FromRoot 'inputs/backend/compose/upstream'
$migrationTargetDir = Join-FromRoot 'inputs/backend/migrations'
$imageTargetDir = Join-FromRoot 'inputs/backend/images'
$backendSourceTargetDir = Join-FromRoot 'inputs/backend/source'
$clientTargetDir = Join-FromRoot 'inputs/client/xdisplay-win64'
$prerequisitesTargetRoot = Join-FromRoot 'inputs/prerequisites'

Reset-Directory -Path $composeTargetDir
Reset-Directory -Path $migrationTargetDir

Copy-Item -Path $composeSource -Destination (Join-Path $composeTargetDir 'docker-compose.yml') -Force

if (Test-Path $envExampleSource) {
    Copy-Item -Path $envExampleSource -Destination (Join-Path $composeTargetDir '.env.orches.example') -Force
}

Get-ChildItem -Path $migrationSourceDir -Filter '*.sql' -File | Sort-Object Name | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $migrationTargetDir -Force
}

Sync-DirectorySnapshot -Source $resolvedClientReleaseDir -Destination $clientTargetDir -DisplayName '客户端发布目录'
Sync-BackendSourceSnapshot -Source $resolvedBackendRepoPath -Destination $backendSourceTargetDir
Build-BackendImagesFromSource -BackendRepoPath $resolvedBackendRepoPath
Test-BackendImages -BackendRepoPath $resolvedBackendRepoPath

Export-BackendImages -DestinationDirectory $imageTargetDir

if ($resolvedPrerequisitesSourceRoot) {
    Sync-DirectorySnapshot -Source $resolvedPrerequisitesSourceRoot -Destination $prerequisitesTargetRoot -DisplayName '前置依赖目录'
    Write-Step "已同步前置依赖目录：$resolvedPrerequisitesSourceRoot"
}
else {
    Write-Step '未提供 PrerequisitesSourceRoot，保留现有 inputs/prerequisites 内容供后续 validate 使用。'
}

Write-Step '客户端发布目录、后端 compose/迁移脚本和离线镜像已同步到 inputs。'
Write-Step '后端 compose 与迁移脚本已同步到 inputs/backend。'
