param(
    [string]$Channel = 'dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$bundleManifest = Get-BundleManifest
$channelManifest = Get-ChannelManifest -Channel $Channel
$stagingLayout = Get-StagingLayout -Channel $Channel
$version = $bundleManifest.bundle.version
$suffix = if ([string]::IsNullOrWhiteSpace($channelManifest.bundleVersionSuffix)) { '' } else { $channelManifest.bundleVersionSuffix }
function Get-RelativeArtifactPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath
    )

    $normalizedBasePath = [System.IO.Path]::GetFullPath($BasePath).TrimEnd('\', '/')
    $normalizedArtifactPath = [System.IO.Path]::GetFullPath($ArtifactPath)
    $prefix = $normalizedBasePath + [System.IO.Path]::DirectorySeparatorChar

    if ($normalizedArtifactPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $normalizedArtifactPath.Substring($prefix.Length).Replace('\', '/')
    }

    return Split-Path -Path $normalizedArtifactPath -Leaf
}

$requiredEntryPoints = @(
    (Join-Path $stagingLayout.Dist "XDisplayAI-$version$suffix.msi")
    (Join-Path $stagingLayout.Dist "XDisplayAI-$version$suffix.exe")
)

$missingArtifacts = $requiredEntryPoints | Where-Object { -not (Test-Path $_) }
if ($missingArtifacts) {
    throw "缺少构建产物：$($missingArtifacts -join ', ')"
}
$artifactPaths = @(Get-ChildItem -Path $stagingLayout.Dist -File -Recurse | Sort-Object FullName | Select-Object -ExpandProperty FullName)
if ($artifactPaths.Count -eq 0) {
    throw "离线交付目录为空：$($stagingLayout.Dist)"
}

$artifactManifest = @()
foreach ($artifactPath in $artifactPaths) {
    $hash = Get-FileHash -Path $artifactPath -Algorithm SHA256
    $artifactManifest += [pscustomobject]@{
        relativePath = Get-RelativeArtifactPath -BasePath $stagingLayout.Dist -ArtifactPath $artifactPath
        sizeBytes = (Get-Item -Path $artifactPath).Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

$manifestPath = Join-Path $stagingLayout.Dist "artifacts-$Channel.json"
$manifestContent = $artifactManifest | ConvertTo-Json
Write-TextFileUtf8NoBom -Path $manifestPath -Content $manifestContent

Write-Step "已生成产物清单：$manifestPath"
