param(
    [string]$Channel = 'dev',
    [switch]$RequirePayloads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Test-ClientReleaseRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientReleaseDir,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $segments = @($RelativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($segments.Count -eq 0) {
        return $false
    }

    $normalizedPath = $ClientReleaseDir
    foreach ($segment in $segments) {
        $normalizedPath = Join-Path $normalizedPath $segment
    }
    if (Test-Path $normalizedPath) {
        return $true
    }

    $legacyFlattenedPath = Join-Path $ClientReleaseDir ($segments -join '\')
    return (Test-Path -LiteralPath $legacyFlattenedPath)
}

$bundleManifest = Get-BundleManifest
$channelManifest = Get-ChannelManifest -Channel $Channel
$portsManifest = Get-PortsManifest
$inputLayout = Get-InputLayout

$requiredPaths = @(
    'manifests/bundle.json',
    "manifests/channels/$Channel.json",
    'manifests/services/ports.json',
    'manifests/services/healthchecks.json',
    'manifests/services/dependencies.json',
    'src/templates/compose/compose.windows.yml.tmpl',
    'src/templates/env/backend.env.tmpl',
    'src/templates/env/runtime.env.tmpl',
    'src/templates/launcher/Launch-XDisplay.cmd.tmpl',
    'src/templates/launcher/Complete-Offline-Setup.cmd.tmpl',
    'src/scripts/common/Common.ps1',
    'src/scripts/install/Bootstrap-InstalledPayload.ps1',
    'src/scripts/install/Install-OfflinePrerequisites.ps1',
    'src/scripts/install/Install-BackendPayload.ps1',
    'src/scripts/update/PromptPinMigration.ps1',
    'src/scripts/update/Update-BackendSource.ps1',
    'src/scripts/update/Update-XDisplayClient.ps1',
    'src/scripts/runtime/Invoke-Stack.ps1',
    'src/scripts/health/Test-Health.ps1',
    'src/scripts/diagnostics/Export-Diagnostics.ps1',
    'src/scripts/uninstall/Remove-XDisplayAI.ps1',
    'src/wix/bundle/Bundle.wxs',
    'src/wix/msi/Product.wxs'
)

foreach ($relativePath in $requiredPaths) {
    $absolutePath = Join-FromRoot $relativePath
    if (-not (Test-Path $absolutePath)) {
        throw "缺少文件：$relativePath"
    }
}

if (-not ($portsManifest.ports.app -and $portsManifest.ports.postgres -and $portsManifest.ports.redis -and $portsManifest.ports.embedding)) {
    throw '端口 manifest 不完整。'
}

if (-not (Test-Path $inputLayout.BackendComposeBase)) {
    throw "缺少 compose 基础文件：$($inputLayout.BackendComposeBase)"
}

$migrationFiles = Get-ChildItem -Path $inputLayout.BackendMigrationDir -Filter '*.sql' -File -ErrorAction SilentlyContinue
if (-not $migrationFiles) {
    throw "缺少数据库迁移文件：$($inputLayout.BackendMigrationDir)"
}

if ([string]::IsNullOrWhiteSpace($channelManifest.logLevel)) {
    throw 'channel manifest 缺少 logLevel。'
}

$llmMetadata = $bundleManifest.runtime.llm
if ($llmMetadata.PSObject.Properties.Name -contains 'apiKey') {
    throw 'bundle runtime.llm 不允许包含 inline apiKey。'
}

foreach ($requiredRuntimeField in @('provider', 'baseUrl', 'modelDefault')) {
    $value = $llmMetadata.$requiredRuntimeField
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        throw "bundle runtime.llm 缺少字段：$requiredRuntimeField"
    }
    if (Test-PlaceholderValue -Value ([string]$value)) {
        throw "bundle runtime.llm.$requiredRuntimeField 仍为占位值。"
    }
}

if ($RequirePayloads) {
    $backendEntryPoint = Join-Path $inputLayout.BackendSourceDir 'app\main.py'
    if (-not (Test-Path $backendEntryPoint -PathType Leaf)) {
        throw "后端源码快照缺少 app\main.py：$backendEntryPoint"
    }
    if (Test-Path (Join-Path $inputLayout.BackendSourceDir '.env') -PathType Leaf) {
        throw '后端源码输入不得携带 .env；安装时只生成无服务端 LLM key 的开发配置。'
    }

    foreach ($requiredClientRelativePath in @(
        'Xdisplay.exe',
        'caesium.dll',
        'UpdateUnpack.exe',
        'qt.conf',
        'Qt5Core.dll',
        'Qt5Gui.dll',
        'Qt5Widgets.dll',
        'plugins/platforms/qwindows.dll',
        'qml/QtQuick/Controls.2/Action.qml',
        'data/keyboard_a/keypage.json',
        'data/keyboard_b/keypage.json',
        'data/keyboard_c/keypage.json',
        'data/keyboard_d/keypage.json',
        'data/keyboard_e/keypage.json'
    )) {
        if (-not (Test-ClientReleaseRelativePath -ClientReleaseDir $inputLayout.ClientReleaseDir -RelativePath $requiredClientRelativePath)) {
            throw "客户端发布目录缺少必需文件：$requiredClientRelativePath"
        }
    }

    foreach ($imageSpec in Get-BackendImageSpecs) {
        $tarPath = Join-Path $inputLayout.BackendImagesDir $imageSpec.TarFileName
        if (-not (Test-Path $tarPath)) {
            throw "缺少离线镜像 tar：$tarPath"
        }
    }

    foreach ($prereqName in @('dockerDesktop', 'vcRedist', 'wslKernel')) {
        $relativePath = $bundleManifest.prerequisites.$prereqName.relativePath
        $absolutePath = Join-Path $inputLayout.PrerequisitesRoot $relativePath
        if (-not (Test-Path $absolutePath)) {
            throw "缺少离线前置依赖：$absolutePath"
        }
    }

    if (Test-PlaceholderValue -Value $bundleManifest.runtime.rag.embeddingVersion) {
        throw 'bundle.runtime.rag.embeddingVersion 仍为占位值。'
    }
}

Write-Step "校验通过：channel=$Channel"
