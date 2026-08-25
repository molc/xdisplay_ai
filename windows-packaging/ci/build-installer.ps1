param(
    [string]$Channel = 'dev',
    [switch]$SkipStage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.Path]::GetFullPath($Path)
}

if (-not $SkipStage) {
    & (Join-Path $PSScriptRoot 'stage-payload.ps1') -Channel $Channel
}

$bundleManifest = Get-BundleManifest
$channelManifest = Get-ChannelManifest -Channel $Channel
$inputLayout = Get-InputLayout
$stagingLayout = Get-StagingLayout -Channel $Channel

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    throw '未找到 wix 命令，请在 Windows builder 上安装 WiX Toolset。'
}

$wixVersionOutput = (& wix --version | Select-Object -First 1)
$wixVersionMatch = [regex]::Match($wixVersionOutput, '\d+\.\d+\.\d+')
if (-not $wixVersionMatch.Success) {
    throw "无法解析 WiX 版本：$wixVersionOutput"
}
$wixVersion = $wixVersionMatch.Value
$globalExtensionList = (& wix extension list -g 2>$null | Out-String)

foreach ($extensionId in @('WixToolset.Util.wixext', 'WixToolset.BootstrapperApplications.wixext')) {
    $extensionLine = ($globalExtensionList -split '\r?\n' | Where-Object { $_ -match "^$([regex]::Escape($extensionId))\s" } | Select-Object -First 1)
    if ($null -eq $extensionLine -or $extensionLine -match '\(damaged\)') {
        Write-Step "安装 WiX 扩展：$extensionId/$wixVersion"
        & wix extension add -g "$extensionId/$wixVersion"
        if ($LASTEXITCODE -ne 0) {
            throw "安装 WiX 扩展失败：$extensionId/$wixVersion"
        }
    }
}

& (Join-Path $PSScriptRoot 'Generate-PayloadWxs.ps1') -Channel $Channel -PayloadRoot $stagingLayout.Payload -OutputPath $stagingLayout.GeneratedPayloadWxs
Reset-Directory -Path $stagingLayout.Dist
Ensure-Directory -Path $stagingLayout.Dist

$baseVersion = $bundleManifest.bundle.version
$fileNameSuffix = if ([string]::IsNullOrWhiteSpace($channelManifest.bundleVersionSuffix)) { '' } else { $channelManifest.bundleVersionSuffix }
$msiPath = Join-Path $stagingLayout.Dist "XDisplayAI-$baseVersion$fileNameSuffix.msi"
$bundlePath = Join-Path $stagingLayout.Dist "XDisplayAI-$baseVersion$fileNameSuffix.exe"

$dockerInstallerPath = Join-Path $inputLayout.PrerequisitesRoot $bundleManifest.prerequisites.dockerDesktop.relativePath
$vcRedistPath = Join-Path $inputLayout.PrerequisitesRoot $bundleManifest.prerequisites.vcRedist.relativePath
$wslKernelInstallerPath = Join-Path $inputLayout.PrerequisitesRoot $bundleManifest.prerequisites.wslKernel.relativePath
$productWxsPath = Join-FromRoot 'src/wix/msi/Product.wxs'
$bundleWxsPath = Join-FromRoot 'src/wix/bundle/Bundle.wxs'

Write-Step '构建 MSI。'
& wix build `
    -arch x64 `
    -ext WixToolset.Util.wixext `
    -d ProductName="$($bundleManifest.bundle.name)" `
    -d ProductVersion="$baseVersion" `
    -d Manufacturer="$($bundleManifest.bundle.manufacturer)" `
    -d InstallDirectoryName="$($bundleManifest.bundle.installDirectoryName)" `
    -d UpgradeCode="$($bundleManifest.bundle.upgradeCodes.msi)" `
    -out $msiPath `
    $productWxsPath `
    $stagingLayout.GeneratedPayloadWxs

if (-not (Test-Path $msiPath)) {
    throw "MSI 构建失败，未生成文件：$msiPath"
}

$externalCabFiles = @(Get-ChildItem -Path $stagingLayout.Dist -Filter 'xdp*.cab' -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($externalCabFiles.Count -eq 0) {
    throw 'MSI 未生成外部 CAB，当前离线布局不符合预期。'
}

Write-Step "MSI 已生成 $($externalCabFiles.Count) 个外部 CAB。"

Write-Step '构建 Burn bundle。'
& wix build `
    -arch x64 `
    -ext WixToolset.BootstrapperApplications.wixext `
    -ext WixToolset.Util.wixext `
    -d BundleName="$($bundleManifest.bundle.name)" `
    -d BundleVersion="$baseVersion" `
    -d Manufacturer="$($bundleManifest.bundle.manufacturer)" `
    -d BundleUpgradeCode="$($bundleManifest.bundle.upgradeCodes.bundle)" `
    -d AppMsiPath="$msiPath" `
    -d DockerDesktopInstallerPath="$dockerInstallerPath" `
    -d VcRedistPath="$vcRedistPath" `
    -d WslKernelInstallerPath="$wslKernelInstallerPath" `
    -out $bundlePath `
    $bundleWxsPath

if (-not (Test-Path $bundlePath)) {
    throw "Burn bundle 构建失败，未生成文件：$bundlePath"
}

$offlinePrereqArtifacts = @(
    Join-Path $stagingLayout.Dist (Split-Path -Path $dockerInstallerPath -Leaf)
    Join-Path $stagingLayout.Dist (Split-Path -Path $vcRedistPath -Leaf)
    Join-Path $stagingLayout.Dist (Split-Path -Path $wslKernelInstallerPath -Leaf)
)

$missingOfflinePrereqArtifacts = @($offlinePrereqArtifacts | Where-Object { -not (Test-Path $_) })
if ($missingOfflinePrereqArtifacts.Count -gt 0) {
    throw "Burn 未输出完整的离线外部依赖：$($missingOfflinePrereqArtifacts -join ', ')"
}

Write-Step "已确认离线目录外部依赖：$((@($offlinePrereqArtifacts | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', '))"

Write-Step "构建完成：$bundlePath"
