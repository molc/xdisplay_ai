param(
    [string]$XdisplayRepoPath = '',
    [string]$OutputDir = '',
    [string]$BuildDirectory = '',
    [string]$QmakePath = '',
    [string]$MingwMakePath = '',
    [string]$WinDeployQtPath = '',
    [string]$QmakeSpec = 'win32-g++',
    [switch]$SkipProtoCompile
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

function Resolve-XdisplayRepoPath {
    param(
        [AllowEmptyString()]
        [string]$PathValue
    )

    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        return Resolve-ExistingPath -PathValue $PathValue -DisplayName 'XdisplayRepoPath'
    }

    $candidatePaths = @(
        (Join-Path $PSScriptRoot '..\..\..\xdisplay'),
        (Join-Path $PSScriptRoot '..\..\xdisplay')
    )

    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path $candidatePath) {
            $resolvedPath = (Resolve-Path $candidatePath).Path
            Write-Step "自动定位 XdisplayRepoPath：$resolvedPath"
            return $resolvedPath
        }
    }

    throw '未提供 XdisplayRepoPath，且默认候选目录中未找到 xdisplay。'
}

function Resolve-OptionalOutputPath {
    param(
        [AllowEmptyString()]
        [string]$PathValue,
        [Parameter(Mandatory = $true)]
        [string]$DefaultRelativePath
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return [System.IO.Path]::GetFullPath((Join-FromRoot $DefaultRelativePath))
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,
        [AllowEmptyString()]
        [string]$ExplicitPath,
        [string[]]$CandidatePaths = @()
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $resolvedExplicitPath = Resolve-ExistingPath -PathValue $ExplicitPath -DisplayName $ToolName
        Write-Step "使用显式 $ToolName：$resolvedExplicitPath"
        return $resolvedExplicitPath
    }

    $command = Get-Command $ToolName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
        $resolvedCommandPath = (Resolve-Path $command.Source).Path
        Write-Step "在 PATH 中找到 $ToolName：$resolvedCommandPath"
        return $resolvedCommandPath
    }

    foreach ($candidatePath in $CandidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        if (Test-Path $candidatePath) {
            $resolvedCandidatePath = (Resolve-Path $candidatePath).Path
            Write-Step "使用候选 $ToolName：$resolvedCandidatePath"
            return $resolvedCandidatePath
        }
    }

    throw "未找到 $ToolName，请显式提供路径或确保它已进入 PATH。"
}

function Invoke-BatchWithoutPause {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchPath,
        [string]$WorkingDirectory = '',
        [string]$PathPrefixDirectory = '',
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $exitCode = Invoke-NormalizedBatchFile `
        -BatchPath $BatchPath `
        -WorkingDirectory $WorkingDirectory `
        -PathPrefixDirectory $PathPrefixDirectory
    if ($exitCode -ne 0) {
        throw $FailureMessage
    }
}

function Ensure-ClientReleaseRequirements {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDirectory
    )

    foreach ($requiredRelativePath in @(
        'Xdisplay.exe',
        'caesium.dll',
        'UpdateUnpack.exe',
        'qt.conf',
        'Qt5Core.dll',
        'Qt5Gui.dll',
        'Qt5Widgets.dll',
        'plugins/platforms/qwindows.dll',
        'qml/QtQuick/Controls.2/Action.qml'
    )) {
        $requiredPath = Join-Path $ReleaseDirectory $requiredRelativePath
        if (-not (Test-Path $requiredPath)) {
            throw "客户端源码构建产物缺少必需文件：$requiredRelativePath"
        }
    }
}

function Copy-ApplicationRuntimeArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDirectory
    )

    $artifactSpecs = @(
        [pscustomobject]@{
            SourcePath = Join-Path $RepoRoot 'src/Service_Caesium/caesium/caesium.dll'
            RelativeDestinationPath = 'caesium.dll'
        },
        [pscustomobject]@{
            SourcePath = Join-Path $RepoRoot 'src/Service_PackL/res/UpdateUnpack.exe'
            RelativeDestinationPath = 'UpdateUnpack.exe'
        }
    )

    foreach ($artifactSpec in $artifactSpecs) {
        if (-not (Test-Path $artifactSpec.SourcePath)) {
            throw "缺少客户端运行时文件：$($artifactSpec.SourcePath)"
        }

        $destinationPath = Join-Path $ReleaseDirectory $artifactSpec.RelativeDestinationPath
        $destinationParent = Split-Path -Path $destinationPath -Parent
        Ensure-Directory -Path $destinationParent
        Copy-Item -Path $artifactSpec.SourcePath -Destination $destinationPath -Force
    }
}

$resolvedXdisplayRepoPath = Resolve-XdisplayRepoPath -PathValue $XdisplayRepoPath
$resolvedOutputDir = Resolve-OptionalOutputPath -PathValue $OutputDir -DefaultRelativePath 'cache/client-release-from-source/xdisplay-win64'
$resolvedBuildDirectory = Resolve-OptionalOutputPath -PathValue $BuildDirectory -DefaultRelativePath 'cache/xdisplay-build'

$projectFilePath = Join-Path $resolvedXdisplayRepoPath 'src/Xdisplay_V2.pro'
$protoCompileScriptPath = Join-Path $resolvedXdisplayRepoPath 'src/Service_PB/compile_all_proto.bat'
$sourceBinaryPath = Join-Path $resolvedXdisplayRepoPath 'bin/Xdisplay.exe'
$sourceBinaryDirectory = Split-Path -Path $sourceBinaryPath -Parent
$caesiumLinkSourcePath = Join-Path $resolvedXdisplayRepoPath 'src/Service_Caesium/caesium/caesium.dll'
$caesiumLinkDestinationPath = Join-Path $sourceBinaryDirectory 'caesium.dll'
$qmakeSourceDir = Join-Path $resolvedXdisplayRepoPath 'src'
$windowsCompatibilityHeaderPath = Join-FromRoot 'compat/xdisplay-windows-posix-compat.h'
$qmakeLogPath = Join-FromRoot 'logs/xdisplay-qmake.log'
$makeLogPath = Join-FromRoot 'logs/xdisplay-make.log'
$winDeployQtLogPath = Join-FromRoot 'logs/xdisplay-windeployqt.log'
$winDeployQtReleaseFailureLogPath = Join-FromRoot 'logs/xdisplay-windeployqt-release-failure.log'

foreach ($requiredSourcePath in @($projectFilePath, $protoCompileScriptPath, $qmakeSourceDir, $caesiumLinkSourcePath, $windowsCompatibilityHeaderPath)) {
    if (-not (Test-Path $requiredSourcePath)) {
        throw "xdisplay 源码结构不完整，缺少：$requiredSourcePath"
    }
}

$qmakeCandidatePaths = @(
    'C:\Qt\5.15.2\mingw81_64\bin\qmake.exe',
    'C:\Qt\Qt5.15.2\5.15.2\mingw81_64\bin\qmake.exe'
)
if (-not [string]::IsNullOrWhiteSpace($env:QTDIR)) {
    $qmakeCandidatePaths = @((Join-Path $env:QTDIR 'bin\qmake.exe')) + $qmakeCandidatePaths
}

$resolvedQmakePath = Resolve-ToolPath -ToolName 'qmake' -ExplicitPath $QmakePath -CandidatePaths $qmakeCandidatePaths

$qmakeBinDirectory = Split-Path -Path $resolvedQmakePath -Parent
$resolvedWinDeployQtPath = Resolve-ToolPath -ToolName 'windeployqt' -ExplicitPath $WinDeployQtPath -CandidatePaths @(
    (Join-Path $qmakeBinDirectory 'windeployqt.exe')
)

$resolvedMingwMakePath = Resolve-ToolPath -ToolName 'mingw32-make' -ExplicitPath $MingwMakePath -CandidatePaths @(
    (Join-Path $qmakeBinDirectory 'mingw32-make.exe'),
    (Join-Path $qmakeBinDirectory '..\..\..\Tools\mingw810_64\bin\mingw32-make.exe'),
    'C:\Qt\Tools\mingw810_64\bin\mingw32-make.exe',
    'C:\Qt\Qt5.15.2\Tools\mingw810_64\bin\mingw32-make.exe'
)
$mingwBinDirectory = Split-Path -Path $resolvedMingwMakePath -Parent
$deploymentPathPrefix = "$qmakeBinDirectory;$mingwBinDirectory"
$qtRootDirectory = Split-Path -Path $qmakeBinDirectory -Parent
$qtQmlSourceDirectory = Join-Path $qtRootDirectory 'qml'
$qtPluginsSourceDirectory = Join-Path $qtRootDirectory 'plugins'
$qmakeCompatibilityHeaderPath = $windowsCompatibilityHeaderPath.Replace('\', '/')

if (-not (Test-Path $qtQmlSourceDirectory -PathType Container)) {
    throw "Qt QML 模块目录不存在：$qtQmlSourceDirectory"
}
if (-not (Test-Path $qtPluginsSourceDirectory -PathType Container)) {
    throw "Qt 插件目录不存在：$qtPluginsSourceDirectory"
}

Write-Step "准备从源码构建客户端：$resolvedXdisplayRepoPath"
Write-Step "客户端 shadow build 目录：$resolvedBuildDirectory"
Write-Step "客户端发布输出目录：$resolvedOutputDir"

if (-not $SkipProtoCompile) {
    Write-Step '先执行 proto 重编。'
    Invoke-BatchWithoutPause `
        -BatchPath $protoCompileScriptPath `
        -WorkingDirectory (Split-Path -Path $protoCompileScriptPath -Parent) `
        -PathPrefixDirectory $mingwBinDirectory `
        -FailureMessage '重新编译 xdisplay proto 失败。'
}
else {
    Write-Step '已显式跳过 proto 重编。'
}

Reset-Directory -Path $resolvedBuildDirectory
Reset-Directory -Path $resolvedOutputDir

Write-Step '执行 qmake 生成 Windows release Makefile。'
Invoke-CheckedNativeCommand `
    -FilePath $resolvedQmakePath `
    -ArgumentList @(
        $projectFilePath,
        '-spec',
        $QmakeSpec,
        '-o',
        'Makefile',
        'CONFIG+=release',
        'CONFIG-=debug',
        'QMAKE_CXXFLAGS+=-include',
        "QMAKE_CXXFLAGS+=$qmakeCompatibilityHeaderPath"
    ) `
    -WorkingDirectory $resolvedBuildDirectory `
    -PathPrefixDirectory $mingwBinDirectory `
    -LogPath $qmakeLogPath `
    -FailureMessage 'qmake 生成 Makefile 失败。'

Write-Step '执行 mingw32-make 编译 Xdisplay.exe。'
Ensure-Directory -Path $sourceBinaryDirectory
Copy-Item -Path $caesiumLinkSourcePath -Destination $caesiumLinkDestinationPath -Force
if (Test-Path $sourceBinaryPath) {
    Remove-Item -Path $sourceBinaryPath -Force
}
Invoke-CheckedNativeCommand `
    -FilePath $resolvedMingwMakePath `
    -ArgumentList @('-f', 'Makefile.Release', '-j', [string][Environment]::ProcessorCount) `
    -WorkingDirectory $resolvedBuildDirectory `
    -PathPrefixDirectory $mingwBinDirectory `
    -LogPath $makeLogPath `
    -FailureMessage 'mingw32-make 编译 xdisplay 失败。'

if (-not (Test-Path $sourceBinaryPath)) {
    throw "未找到编译产物：$sourceBinaryPath"
}

Copy-Item -Path $sourceBinaryPath -Destination (Join-Path $resolvedOutputDir 'Xdisplay.exe') -Force
Copy-ApplicationRuntimeArtifacts -RepoRoot $resolvedXdisplayRepoPath -ReleaseDirectory $resolvedOutputDir

Write-Step '执行 windeployqt 生成客户端发布目录。'
try {
    Invoke-CheckedNativeCommand `
        -FilePath $resolvedWinDeployQtPath `
        -ArgumentList @('--release', '--compiler-runtime', '--qmldir', $qmakeSourceDir, (Join-Path $resolvedOutputDir 'Xdisplay.exe')) `
        -PathPrefixDirectory $deploymentPathPrefix `
        -LogPath $winDeployQtLogPath `
        -FailureMessage 'windeployqt 部署客户端运行时失败。'
}
catch {
    $releaseDeployLog = if (Test-Path $winDeployQtLogPath) {
        Get-Content -Path $winDeployQtLogPath -Raw
    }
    else {
        ''
    }

    if ($releaseDeployLog -notmatch 'Unable to find the platform plugin\.') {
        throw
    }

    Copy-Item -Path $winDeployQtLogPath -Destination $winDeployQtReleaseFailureLogPath -Force
    Write-Step '当前 Qt 5.15.2 将 release 插件误判为 debug；改用 debug 匹配规则重试部署。'
    Invoke-CheckedNativeCommand `
        -FilePath $resolvedWinDeployQtPath `
        -ArgumentList @('--debug', '--compiler-runtime', '--qmldir', $qmakeSourceDir, (Join-Path $resolvedOutputDir 'Xdisplay.exe')) `
        -PathPrefixDirectory $deploymentPathPrefix `
        -LogPath $winDeployQtLogPath `
        -FailureMessage 'windeployqt 使用兼容匹配规则部署客户端运行时失败。'
}

Write-Step '规范化 windeployqt 的 QML 模块目录。'
Move-WinDeployQtQmlModules `
    -ReleaseDirectory $resolvedOutputDir `
    -QtQmlSourceDirectory $qtQmlSourceDirectory

Write-Step '规范化 windeployqt 的插件目录。'
Move-WinDeployQtPluginDirectories `
    -ReleaseDirectory $resolvedOutputDir `
    -QtPluginsSourceDirectory $qtPluginsSourceDirectory

$qtConfPath = Join-Path $resolvedOutputDir 'qt.conf'
Write-Step '写入客户端 qt.conf。'
Write-TextFileUtf8NoBom -Path $qtConfPath -Content @"
[Paths]
Prefix = .
Plugins = plugins
Imports = qml
Qml2Imports = qml
"@

Ensure-ClientReleaseRequirements -ReleaseDirectory $resolvedOutputDir
Write-Step "客户端源码构建完成：$resolvedOutputDir"
