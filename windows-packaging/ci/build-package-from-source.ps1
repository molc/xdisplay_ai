param(
    [string]$Channel = 'dev',
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

$prepareInputsScriptPath = Join-Path $PSScriptRoot 'prepare-inputs.ps1'
$buildInstallerScriptPath = Join-Path $PSScriptRoot 'build-installer.ps1'
$publishScriptPath = Join-Path $PSScriptRoot 'publish.ps1'

foreach ($requiredScriptPath in @($prepareInputsScriptPath, $buildInstallerScriptPath, $publishScriptPath)) {
    if (-not (Test-Path $requiredScriptPath)) {
        throw "缺少脚本：$requiredScriptPath"
    }
}

Write-Step "开始执行源码直出离线打包：channel=$Channel"

$prepareInputsArgs = @{
    BackendRepoPath = $BackendRepoPath
    ClientReleaseDir = $ClientReleaseDir
    XdisplayRepoPath = $XdisplayRepoPath
    ClientBuildOutputDir = $ClientBuildOutputDir
    ClientBuildDirectory = $ClientBuildDirectory
    QmakePath = $QmakePath
    MingwMakePath = $MingwMakePath
    WinDeployQtPath = $WinDeployQtPath
    QmakeSpec = $QmakeSpec
    PrerequisitesSourceRoot = $PrerequisitesSourceRoot
}

if ($SkipClientProtoCompile) {
    $prepareInputsArgs.SkipClientProtoCompile = $true
}

if ($SkipBackendImageBuild) {
    $prepareInputsArgs.SkipBackendImageBuild = $true
}

& $prepareInputsScriptPath @prepareInputsArgs
& $buildInstallerScriptPath -Channel $Channel
& $publishScriptPath -Channel $Channel

$distDirectory = (Get-StagingLayout -Channel $Channel).Dist
$artifactManifestPath = Join-Path $distDirectory "artifacts-$Channel.json"

if (-not (Test-Path $artifactManifestPath)) {
    throw "打包完成后未找到产物清单：$artifactManifestPath"
}

Write-Step "源码直出离线打包完成：$distDirectory"
