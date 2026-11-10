param(
    [string]$PackagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

. (Join-Path $PackagingRoot 'src\scripts\common\InstallerCorrectness.ps1')
. (Join-Path $PackagingRoot 'ci\InstallerPackagingGates.ps1')

$officialManifest = Join-Path $PackagingRoot 'tests\fixtures\wix5-burn-manifest-r2.xml'
Assert-True -Condition (Test-Path -LiteralPath $officialManifest) -Message 'WiX 5 official BurnManifest fixture from native r2 extract is missing.'

$officialPayloads = @(Get-BurnManifestExternalPayloads -ManifestPath $officialManifest)
Assert-True -Condition ($officialPayloads.Count -eq 15) -Message "Official WiX 5.0.2 manifest must list 15 external payloads. Actual=$($officialPayloads.Count)"
$officialNames = @($officialPayloads | ForEach-Object { [string]$_.FileName })
foreach ($requiredName in @(
    'XDisplayAI-0.1.4-dev.msi',
    'Docker Desktop Installer.exe',
    'VC_redist.x64.exe',
    'wsl_update_x64.msi'
)) {
    Assert-True -Condition ($officialNames -contains $requiredName) -Message "Official BurnManifest must include $requiredName Hash. Grepping uncompressed EXE bytes missed these four on native r2."
}
foreach ($cabName in @('xdp1.cab', 'xdp2.cab', 'xdp2a.cab', 'xdp2b.cab', 'xdp3.cab', 'xdp4.cab', 'xdp5.cab', 'xdp6.cab', 'xdp7.cab', 'xdp8.cab', 'xdp9.cab')) {
    Assert-True -Condition ($officialNames -contains $cabName) -Message "Official BurnManifest must include $cabName."
}
$dockerEntry = @($officialPayloads | Where-Object { $_.FileName -eq 'Docker Desktop Installer.exe' } | Select-Object -First 1)[0]
Assert-True -Condition ($dockerEntry.Hash.Length -eq 128) -Message 'WiX 5 Hash attributes are SHA512 hex, not missing.'
Assert-True -Condition ($dockerEntry.FileSize -eq 628979632) -Message 'Official Docker Desktop payload size must parse from FileSize.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('burn-sha512-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    function Write-Utf8NoBom {
        param([string]$Path, [string]$Content)
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($Path, $Content, $utf8)
    }

    function New-PayloadFile {
        param([string]$Path, [string]$Content)
        $parent = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Utf8NoBom -Path $Path -Content $Content
        return [pscustomobject]@{
            Path = $Path
            Hash = Convert-ToNormalizedSha512 -Value ((Get-FileHash -LiteralPath $Path -Algorithm SHA512).Hash)
            Size = [int64](Get-Item -LiteralPath $Path).Length
        }
    }

    $msi = New-PayloadFile -Path (Join-Path $testRoot 'XDisplayAI-0.1.4-dev.msi') -Content 'msi-bytes'
    $docker = New-PayloadFile -Path (Join-Path $testRoot 'Docker Desktop Installer.exe') -Content 'docker-bytes'
    $vc = New-PayloadFile -Path (Join-Path $testRoot 'VC_redist.x64.exe') -Content 'vc-bytes'
    $wsl = New-PayloadFile -Path (Join-Path $testRoot 'wsl_update_x64.msi') -Content 'wsl-bytes'
    $cab = New-PayloadFile -Path (Join-Path $testRoot 'xdp1.cab') -Content 'cab-bytes'
    $bundle = Join-Path $testRoot 'XDisplayAI-0.1.4-dev.exe'
    Write-Utf8NoBom -Path $bundle -Content ('not-a-real-pe ' + $msi.Hash)

    $manifestPath = Join-Path $testRoot 'manifest.xml'
    $manifestXml = @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest EngineVersion="5.0.2.0" xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">
  <UX PrimaryPayloadId="WixStandardBootstrapperApplication_X64">
    <Payload Id="payTheme" FilePath="thm.xml" SourcePath="u0" />
  </UX>
  <Payload Id="XDisplayAIPayload" FilePath="XDisplayAI-0.1.4-dev.msi" FileSize="$($msi.Size)" Hash="$($msi.Hash)" Packaging="external" SourcePath="XDisplayAI-0.1.4-dev.msi" />
  <Payload Id="DockerDesktopPrereq" FilePath="Docker Desktop Installer.exe" FileSize="$($docker.Size)" Hash="$($docker.Hash)" Packaging="external" SourcePath="Docker Desktop Installer.exe" />
  <Payload Id="VcRedist" FilePath="VC_redist.x64.exe" FileSize="$($vc.Size)" Hash="$($vc.Hash)" Packaging="external" SourcePath="VC_redist.x64.exe" />
  <Payload Id="WslKernelUpdate" FilePath="wsl_update_x64.msi" FileSize="$($wsl.Size)" Hash="$($wsl.Hash)" Packaging="external" SourcePath="wsl_update_x64.msi" />
  <Payload Id="cab1" FilePath="xdp1.cab" FileSize="$($cab.Size)" Hash="$($cab.Hash)" Packaging="external" SourcePath="xdp1.cab" />
</BurnManifest>
"@
    Write-Utf8NoBom -Path $manifestPath -Content $manifestXml

    Assert-True `
        -Condition (Test-BurnPayloadSha512Binding -BundlePath $bundle -PayloadPath $msi.Path -ManifestXmlPath $manifestPath) `
        -Message 'WiX 5 BurnManifest Hash must bind the MSI even when the EXE does not contain uncompressed hex.'
    Assert-True `
        -Condition (Test-BurnPayloadSha512Binding -BundlePath $bundle -PayloadPath $docker.Path -ManifestXmlPath $manifestPath) `
        -Message 'FilePath with spaces (Docker Desktop Installer.exe) must resolve from BurnManifest.'

    $hexOnlyManifest = Join-Path $testRoot 'hex-only.xml'
    Write-Utf8NoBom -Path $hexOnlyManifest -Content @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">
  <Payload Id="UxOnly" FilePath="thm.xml" SourcePath="u0" />
</BurnManifest>
"@
    Assert-True `
        -Condition (-not (Test-BurnPayloadSha512Binding -BundlePath $bundle -PayloadPath $msi.Path -ManifestXmlPath $hexOnlyManifest)) `
        -Message 'Uncompressed SHA512 hex inside the EXE is not a Burn binding.'

    Assert-BurnExternalPayloadBindings `
        -BundlePath $bundle `
        -PayloadPaths @($msi.Path, $docker.Path, $vc.Path, $wsl.Path) `
        -ManifestXmlPath $manifestPath

    $missingRejected = $false
    try {
        Assert-BurnExternalPayloadBindings `
            -BundlePath $bundle `
            -PayloadPaths @($msi.Path, $docker.Path, $vc.Path, $wsl.Path) `
            -ManifestXmlPath $hexOnlyManifest | Out-Null
    }
    catch {
        $missingRejected = $_.Exception.Message -match '未在 bundle 中找到这些相邻 payload 的哈希' -and
            $_.Exception.Message -match 'XDisplayAI-0.1.4-dev.msi' -and
            $_.Exception.Message -match 'Docker Desktop Installer.exe' -and
            $_.Exception.Message -match 'VC_redist.x64.exe' -and
            $_.Exception.Message -match 'wsl_update_x64.msi'
    }
    Assert-True -Condition $missingRejected -Message 'The native r2 missing-principal error must stay fail-closed when BurnManifest has no Hash for those four files.'

    $changed = Join-Path $testRoot 'changed'
    New-Item -ItemType Directory -Path $changed -Force | Out-Null
    Copy-Item -LiteralPath $bundle -Destination (Join-Path $changed 'XDisplayAI-0.1.4-dev.exe')
    foreach ($item in @($msi, $docker, $vc, $wsl, $cab)) {
        Copy-Item -LiteralPath $item.Path -Destination (Join-Path $changed ([IO.Path]::GetFileName($item.Path)))
    }
    $changedMsi = Join-Path $changed 'XDisplayAI-0.1.4-dev.msi'
    Write-Utf8NoBom -Path $changedMsi -Content 'changed-msi-bytes'
    $hashRejected = $false
    try {
        Assert-BurnExternalPayloadBindings `
            -BundlePath (Join-Path $changed 'XDisplayAI-0.1.4-dev.exe') `
            -PayloadPaths @(
                $changedMsi,
                (Join-Path $changed 'Docker Desktop Installer.exe'),
                (Join-Path $changed 'VC_redist.x64.exe'),
                (Join-Path $changed 'wsl_update_x64.msi')
            ) `
            -ManifestXmlPath $manifestPath | Out-Null
    }
    catch {
        $hashRejected = $_.Exception.Message -match '大小或 SHA512 与 BurnManifest 不一致' -and
            $_.Exception.Message -match 'XDisplayAI-0.1.4-dev.msi'
    }
    Assert-True -Condition $hashRejected -Message 'Changed adjacent payload bytes must fail the Burn SHA512 gate.'

    $sizeManifest = Join-Path $testRoot 'size-mismatch.xml'
    Write-Utf8NoBom -Path $sizeManifest -Content @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">
  <Payload Id="XDisplayAIPayload" FilePath="XDisplayAI-0.1.4-dev.msi" FileSize="1" Hash="$($msi.Hash)" Packaging="external" SourcePath="XDisplayAI-0.1.4-dev.msi" />
  <Payload Id="DockerDesktopPrereq" FilePath="Docker Desktop Installer.exe" FileSize="$($docker.Size)" Hash="$($docker.Hash)" Packaging="external" SourcePath="Docker Desktop Installer.exe" />
  <Payload Id="VcRedist" FilePath="VC_redist.x64.exe" FileSize="$($vc.Size)" Hash="$($vc.Hash)" Packaging="external" SourcePath="VC_redist.x64.exe" />
  <Payload Id="WslKernelUpdate" FilePath="wsl_update_x64.msi" FileSize="$($wsl.Size)" Hash="$($wsl.Hash)" Packaging="external" SourcePath="wsl_update_x64.msi" />
</BurnManifest>
"@
    $sizeRejected = $false
    try {
        Assert-BurnExternalPayloadBindings `
            -BundlePath $bundle `
            -PayloadPaths @($msi.Path, $docker.Path, $vc.Path, $wsl.Path) `
            -ManifestXmlPath $sizeManifest | Out-Null
    }
    catch {
        $sizeRejected = $_.Exception.Message -match '大小或 SHA512 与 BurnManifest 不一致'
    }
    Assert-True -Condition $sizeRejected -Message 'FileSize mismatch against BurnManifest must fail closed.'

    $missingFileRejected = $false
    try {
        Assert-BurnExternalPayloadBindings `
            -BundlePath $bundle `
            -PayloadPaths @((Join-Path $testRoot 'absent.msi'), $docker.Path, $vc.Path, $wsl.Path) `
            -ManifestXmlPath $manifestPath | Out-Null
    }
    catch {
        $missingFileRejected = $_.Exception.Message -match 'absent.msi'
    }
    Assert-True -Condition $missingFileRejected -Message 'A missing adjacent payload file must fail the Burn gate.'

    Remove-Item -LiteralPath $cab.Path -Force
    $missingCabRejected = $false
    try {
        Assert-BurnExternalPayloadBindings `
            -BundlePath $bundle `
            -PayloadPaths @($msi.Path, $docker.Path, $vc.Path, $wsl.Path) `
            -ManifestXmlPath $manifestPath | Out-Null
    }
    catch {
        $missingCabRejected = $_.Exception.Message -match 'xdp1.cab'
    }
    Assert-True -Condition $missingCabRejected -Message 'External CABs listed in BurnManifest must be verified next to the bundle, not ignored.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$entrypoint = Get-Content -LiteralPath (Join-Path $PackagingRoot 'build-offline-package.ps1') -Raw
Assert-True -Condition ($entrypoint -match '\[switch\]\$VerifyExistingOutputsOnly') -Message 'Incremental re-verify of an existing dist tree must be a first-class switch.'
Assert-True -Condition ($entrypoint -match 'Assert-BurnExternalPayloadBindings') -Message 'Burn SHA512 gate must remain on the one-click path.'
Assert-True -Condition ($entrypoint -match 'Write-ReleaseHold') -Message 'NOT_READY hold must remain after Burn verification.'

Write-Output 'PASS: Burn SHA512 WiX 5 BurnManifest bindings'
exit 0
