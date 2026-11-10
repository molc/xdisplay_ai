Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')
. (Join-Path $PSScriptRoot '..\src\scripts\common\InstallerCorrectness.ps1')

function Get-PinnedCatalogwriteClientSha256 {
    return '2A80890DB988157371CF28D24CA23685D7933C4E59630E5A2DCD2363B7DB5600'
}

function Get-PinnedConverterSha256 {
    return 'F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36'
}

function Get-PinnedCatalogwriteClientBytes {
    return [long]675539394
}

function Get-PinnedConverterBytes {
    return [long]529920
}

function Get-RequiredCachedClientReleaseRelativePaths {
    return @(
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
        'data/keyboard_e/keypage.json',
        'data/keyboard_d/image/data_image.json',
        'data/keyboard_d/font/data_font.json',
        'data/keyboard_d/text/data_text.json',
        'data/keyboard_d/var/data_var.json',
        'images/bartitle/titlelogo.png',
        'images/launch/logo_tricolor.png',
        'res/pinyin.bin',
        'doc/Xdisplay使用手册V2.4.4.pdf',
        'qrcode_about.jpg'
    )
}

function Convert-ToNormalizedSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return $Value.Replace('-', '').Trim().ToUpperInvariant()
}

function Assert-CachedReleaseArguments {
    param(
        [bool]$SkipClientBuild = $false,
        [string]$ClientReleaseDir = '',
        [string]$ConverterReleaseDir = ''
    )

    if (-not $SkipClientBuild) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ClientReleaseDir)) {
        throw 'SkipClientBuild requires -ClientReleaseDir pointing at the full pinned catalogwrite client tree (Xdisplay.exe). Do not rebuild from source and do not use the stale default inputs/client tree.'
    }
}

function Assert-PinnedFileIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedSha256,
        [Parameter(Mandatory = $true)]
        [long]$ExpectedBytes,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$DisplayName pin failed: file does not exist: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    if ($item.Length -ne $ExpectedBytes) {
        throw "$DisplayName pin failed: size $($item.Length) did not match expected $ExpectedBytes ($Path)."
    }

    $actualSha256 = Convert-ToNormalizedSha256 -Value (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    $expected = Convert-ToNormalizedSha256 -Value $ExpectedSha256
    if (-not [string]::Equals($actualSha256, $expected, [StringComparison]::Ordinal)) {
        throw "$DisplayName pin failed: SHA256 $actualSha256 did not match expected $expected ($Path). Refusing a stale or rebuilt binary."
    }

    return [pscustomobject]@{
        path = $item.FullName
        sizeBytes = [long]$item.Length
        sha256 = $actualSha256
        displayName = $DisplayName
    }
}

function Find-ConverterExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConverterReleaseDir
    )

    if ([string]::IsNullOrWhiteSpace($ConverterReleaseDir)) {
        throw 'ConverterReleaseDir is required to overlay the pinned Converter.exe.'
    }

    if (Test-Path -LiteralPath $ConverterReleaseDir -PathType Leaf) {
        return (Resolve-Path -LiteralPath $ConverterReleaseDir).Path
    }

    if (-not (Test-Path -LiteralPath $ConverterReleaseDir -PathType Container)) {
        throw "ConverterReleaseDir does not exist: $ConverterReleaseDir"
    }

    $direct = Join-Path $ConverterReleaseDir 'Converter.exe'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        return (Resolve-Path -LiteralPath $direct).Path
    }

    $nestedBin = Join-Path $ConverterReleaseDir 'bin\Converter.exe'
    if (Test-Path -LiteralPath $nestedBin -PathType Leaf) {
        return (Resolve-Path -LiteralPath $nestedBin).Path
    }

    $matches = @(Get-ChildItem -LiteralPath $ConverterReleaseDir -Filter 'Converter.exe' -File -Recurse -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 1) {
        return $matches[0].FullName
    }
    if ($matches.Count -gt 1) {
        throw "ConverterReleaseDir contains multiple Converter.exe files: $ConverterReleaseDir"
    }

    throw "ConverterReleaseDir does not contain Converter.exe: $ConverterReleaseDir"
}

function Assert-CachedClientReleaseTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientReleaseDir
    )

    foreach ($relativePath in @(Get-RequiredCachedClientReleaseRelativePaths)) {
        $absolutePath = $ClientReleaseDir
        foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $absolutePath = Join-Path $absolutePath $segment
        }
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            throw "Cached client release is incomplete. Missing: $relativePath"
        }
    }
}

function New-QualifiedCachedClientRelease {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientReleaseDir,
        [Parameter(Mandatory = $true)]
        [string]$ConverterReleaseDir,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [string]$ExpectedClientSha256 = (Get-PinnedCatalogwriteClientSha256),
        [long]$ExpectedClientBytes = (Get-PinnedCatalogwriteClientBytes),
        [string]$ExpectedConverterSha256 = (Get-PinnedConverterSha256),
        [long]$ExpectedConverterBytes = (Get-PinnedConverterBytes)
    )

    if ([string]::IsNullOrWhiteSpace($ClientReleaseDir) -or -not (Test-Path -LiteralPath $ClientReleaseDir -PathType Container)) {
        throw "ClientReleaseDir does not exist: $ClientReleaseDir"
    }

    $sourceClient = (Resolve-Path -LiteralPath $ClientReleaseDir).Path
    $sourceConverter = Find-ConverterExecutable -ConverterReleaseDir $ConverterReleaseDir
    $sourceClientExe = Join-Path $sourceClient 'Xdisplay.exe'
    $clientIdentity = Assert-PinnedFileIdentity `
        -Path $sourceClientExe `
        -ExpectedSha256 $ExpectedClientSha256 `
        -ExpectedBytes $ExpectedClientBytes `
        -DisplayName 'Xdisplay.exe'
    $converterIdentity = Assert-PinnedFileIdentity `
        -Path $sourceConverter `
        -ExpectedSha256 $ExpectedConverterSha256 `
        -ExpectedBytes $ExpectedConverterBytes `
        -DisplayName 'Converter.exe'
    Assert-CachedClientReleaseTree -ClientReleaseDir $sourceClient

    $destinationPath = [System.IO.Path]::GetFullPath($Destination)
    if ([string]::Equals($destinationPath.TrimEnd('\', '/'), $sourceClient.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Qualified client destination must not be the source catalogwrite tree; source binaries must stay unmodified.'
    }

    Reset-Directory -Path $destinationPath
    Copy-Tree -Source $sourceClient -Destination $destinationPath

    $existingConverters = @(Get-ChildItem -LiteralPath $destinationPath -Filter 'Converter.exe' -File -Recurse -ErrorAction SilentlyContinue)
    if ($existingConverters.Count -gt 0) {
        foreach ($existingConverter in $existingConverters) {
            Copy-Item -LiteralPath $sourceConverter -Destination $existingConverter.FullName -Force
        }
    }
    else {
        $converterDestination = Join-Path $destinationPath 'bin\Converter.exe'
        Ensure-Directory -Path (Split-Path -Path $converterDestination -Parent)
        Copy-Item -LiteralPath $sourceConverter -Destination $converterDestination -Force
    }

    $qualifiedClientExe = Join-Path $destinationPath 'Xdisplay.exe'
    Assert-PinnedFileIdentity `
        -Path $qualifiedClientExe `
        -ExpectedSha256 $ExpectedClientSha256 `
        -ExpectedBytes $ExpectedClientBytes `
        -DisplayName 'Xdisplay.exe' | Out-Null
    $qualifiedConverters = @(Get-ChildItem -LiteralPath $destinationPath -Filter 'Converter.exe' -File -Recurse)
    if ($qualifiedConverters.Count -eq 0) {
        throw 'Qualified client tree is missing Converter.exe after overlay.'
    }
    foreach ($qualifiedConverter in $qualifiedConverters) {
        Assert-PinnedFileIdentity `
            -Path $qualifiedConverter.FullName `
            -ExpectedSha256 $ExpectedConverterSha256 `
            -ExpectedBytes $ExpectedConverterBytes `
            -DisplayName 'Converter.exe' | Out-Null
    }
    Assert-CachedClientReleaseTree -ClientReleaseDir $destinationPath

    return [pscustomobject]@{
        destination = $destinationPath
        client = $clientIdentity
        converter = $converterIdentity
    }
}

function Set-PackagingWorkLayout {
    param(
        [string]$WorkRoot = '',
        [string]$StagingRoot = '',
        [string]$DistRoot = '',
        [string]$CacheRoot = '',
        [string]$TempRoot = '',
        [string]$Channel = 'dev'
    )

    if (-not [string]::IsNullOrWhiteSpace($WorkRoot)) {
        $resolvedWorkRoot = [System.IO.Path]::GetFullPath($WorkRoot)
        if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
            $StagingRoot = Join-Path $resolvedWorkRoot 'staging'
        }
        if ([string]::IsNullOrWhiteSpace($DistRoot)) {
            $DistRoot = Join-Path $resolvedWorkRoot 'dist'
        }
        if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
            $CacheRoot = Join-Path $resolvedWorkRoot 'cache'
        }
        if ([string]::IsNullOrWhiteSpace($TempRoot)) {
            $TempRoot = Join-Path $resolvedWorkRoot 'temp'
        }
        $env:XDISPLAYAI_WORK_ROOT = $resolvedWorkRoot
    }
    else {
        $resolvedWorkRoot = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($StagingRoot)) {
        $StagingRoot = [System.IO.Path]::GetFullPath($StagingRoot)
        $env:XDISPLAYAI_STAGING_ROOT = $StagingRoot
        Ensure-Directory -Path $StagingRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($DistRoot)) {
        $DistRoot = [System.IO.Path]::GetFullPath($DistRoot)
        $env:XDISPLAYAI_DIST_ROOT = $DistRoot
        Ensure-Directory -Path $DistRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = [System.IO.Path]::GetFullPath($CacheRoot)
        $env:XDISPLAYAI_CACHE_ROOT = $CacheRoot
        Ensure-Directory -Path $CacheRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($TempRoot)) {
        $TempRoot = [System.IO.Path]::GetFullPath($TempRoot)
        $env:XDISPLAYAI_TEMP_ROOT = $TempRoot
        Ensure-Directory -Path $TempRoot
    }

    $qualifiedClientRoot = if (-not [string]::IsNullOrWhiteSpace($resolvedWorkRoot)) {
        Join-Path $resolvedWorkRoot 'qualified-client'
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CacheRoot)) {
        Join-Path $CacheRoot 'qualified-client'
    }
    else {
        Join-FromRoot 'cache/qualified-client'
    }

    return [pscustomobject]@{
        WorkRoot = $resolvedWorkRoot
        StagingRoot = $StagingRoot
        DistRoot = $DistRoot
        CacheRoot = $CacheRoot
        TempRoot = $TempRoot
        QualifiedClientRoot = $qualifiedClientRoot
        Channel = $Channel
    }
}

function Get-InputsRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $absolutePath = $Root
    foreach ($segment in @($RelativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $absolutePath = Join-Path $absolutePath $segment
    }
    return $absolutePath
}

function Get-DockerInspectImageDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing Docker inspect companion $Path. Rebuild the s63f app image with the sanctioned recipe and write docker inspect JSON next to the tar. A renamed F3EECC91 tar is not proof."
    }

    $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        throw "Docker inspect companion $Path is empty."
    }
    if ($parsed -is [System.Array]) {
        if ($parsed.Count -lt 1) {
            throw "Docker inspect companion $Path has no images."
        }
        return $parsed[0]
    }
    return $parsed
}

function Get-DockerInspectLabelValue {
    param(
        [Parameter(Mandatory = $true)]
        $Image,
        [Parameter(Mandatory = $true)]
        [string]$LabelName
    )

    if ($null -eq $Image.Config -or $null -eq $Image.Config.Labels) {
        return ''
    }
    $property = $Image.Config.Labels.PSObject.Properties[$LabelName]
    if ($null -eq $property) {
        return ''
    }
    return [string]$property.Value
}

function Assert-S63fMigrationSet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MigrationDir
    )

    $expected = @(Get-S63fMigrationFileNames)
    $migrationFiles = @(Get-ChildItem -LiteralPath $MigrationDir -Filter '*.sql' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($migrationFiles.Count -eq 0) {
        throw "UseExistingBackendInputs is missing SQL migrations under $MigrationDir."
    }
    $actual = @($migrationFiles | ForEach-Object { $_.Name })
    $unexpected = @($actual | Where-Object { $expected -notcontains $_ })
    $missing = @($expected | Where-Object { $actual -notcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        throw "s63f ships db/migrations $($expected -join ', ') only (no new data migration). Found: $($actual -join ', ')."
    }
}

function Assert-S63fXdRenderCliSourcePresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    foreach ($relativePath in @(Get-OrchestrationAppRuntimeFingerprintPaths)) {
        $absolutePath = Get-InputsRelativePath -Root $SourceRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            throw "s63f runtime fingerprint input is missing: $relativePath. docker/export_runtime_requirements.py and docker/strict-ocr are not part of this tree."
        }
    }

    $binaryPath = Get-InputsRelativePath -Root $SourceRoot -RelativePath 'external\xdisplay\bin\xd_render_cli\xd_render_cli'
    if (Test-Path -LiteralPath $binaryPath -PathType Leaf) {
        # Sanctioned export may include a 50200-byte Mach-O leftover (SHA256 58618EC2...).
        # Dockerfile qt_builder does `rm -f xd_render_cli && qmake6 xd_render_cli.pro && make`
        # on python:3.11-slim-bookworm with qt6-base-dev/libgl-dev. Presence or absence of
        # that leftover must not block packaging, and a cached Linux ELF is not required.
        return
    }
}

function Assert-S63fAppImageCompanionInspect {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InspectPath,
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedRevision
    )

    $image = Get-DockerInspectImageDocument -Path $InspectPath
    $gitSha = (Get-DockerInspectLabelValue -Image $image -LabelName 'xdisplayai.packaging.git-sha').Trim()
    $tag = (Get-DockerInspectLabelValue -Image $image -LabelName 'xdisplayai.packaging.tag').Trim()
    $fingerprintLabel = (Get-DockerInspectLabelValue -Image $image -LabelName 'xdisplayai.packaging.runtime-fingerprint').Trim()
    if (-not $gitSha.StartsWith((Get-ApprovedBackendRevisionPrefix), [StringComparison]::OrdinalIgnoreCase)) {
        throw "App image inspect git-sha '$gitSha' is not s63f tip $(Get-ApprovedBackendRevisionPrefix). Do not reuse F3EECC91."
    }
    $revisionMatchesInspect = [string]::Equals($gitSha, $ExpectedRevision, [StringComparison]::OrdinalIgnoreCase) -or
        $gitSha.StartsWith($ExpectedRevision, [StringComparison]::OrdinalIgnoreCase) -or
        $ExpectedRevision.StartsWith($gitSha, [StringComparison]::OrdinalIgnoreCase)
    if (-not $revisionMatchesInspect) {
        throw "App image inspect git-sha '$gitSha' does not match SOURCE_REVISION '$ExpectedRevision'."
    }
    if ($tag -ne (Get-ApprovedBackendTag)) {
        throw "App image inspect tag '$tag' is not $(Get-ApprovedBackendTag)."
    }

    $repoTags = @()
    if ($null -ne $image.RepoTags) {
        $repoTags = @($image.RepoTags | ForEach-Object { [string]$_ })
    }
    foreach ($requiredTag in @(Get-S63fAppImageCompanionTags)) {
        if ($repoTags -notcontains $requiredTag) {
            throw "App image inspect is missing companion tag $requiredTag (found: $($repoTags -join ', '))."
        }
    }

    $expectedFingerprint = Get-SourceContentFingerprint `
        -Root $SourceRoot `
        -RelativePaths @(Get-OrchestrationAppRuntimeFingerprintPaths)
    if (-not [string]::Equals($expectedFingerprint, $fingerprintLabel, [StringComparison]::OrdinalIgnoreCase)) {
        throw "App image runtime-fingerprint label '$fingerprintLabel' does not match source snapshot fingerprint '$expectedFingerprint'. Image and bind-mounted source must be a pair; do not retag an old cache."
    }

    if ([string]::IsNullOrWhiteSpace([string]$image.Id)) {
        throw "App image inspect is missing Id."
    }
}

function Assert-SkipBackendImageBuildFromSource {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$SkipBackendImageBuild,
        [Parameter(Mandatory = $true)]
        [bool]$UseExistingBackendInputs
    )

    if ($SkipBackendImageBuild -and -not $UseExistingBackendInputs) {
        throw (
            'SkipBackendImageBuild is invalid for s63f from-source packaging. ' +
            'docker/export_runtime_requirements.py and docker/strict-ocr do not exist at prod/s63f. ' +
            'The app image must be built from Dockerfile (qt_builder qmake6 + pip + playwright 1.56 Chromium 1194). ' +
            'Do not require a cached Linux xd_render_cli ELF; Dockerfile rm -f of the Mach-O leftover and rebuilds it. ' +
            'Parent Docker builder runs the sanctioned rebuild-orches-app-image.sh, then Windows packaging uses -UseExistingBackendInputs with companion inspect JSON. ' +
            'Do not reuse F3EECC91.'
        )
    }
}

function Assert-ExistingBackendInputs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputsRoot,
        [string]$PinManifestPath = ''
    )

    if (-not (Test-Path -LiteralPath $InputsRoot -PathType Container)) {
        throw "Existing backend/prereq inputs root does not exist: $InputsRoot"
    }

    $requiredRelativePaths = @(
        'prerequisites/docker-desktop/Docker Desktop Installer.exe',
        'prerequisites/vcredist/VC_redist.x64.exe',
        'prerequisites/wsl/wsl_update_x64.msi',
        'backend/images/orches_orchestration-app_latest.tar',
        'backend/images/orches_embedding-http_latest.tar',
        'backend/images/pgvector_pgvector_pg15.tar',
        'backend/images/redis_7.tar',
        'backend/source/app/main.py',
        'backend/compose/upstream/docker-compose.yml'
    )
    foreach ($relativePath in $requiredRelativePaths) {
        $absolutePath = Get-InputsRelativePath -Root $InputsRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            throw "UseExistingBackendInputs is missing $relativePath under $InputsRoot. Source clones are not a permitted workaround."
        }
    }

    $sourceRoot = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/source'
    $migrationDir = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/migrations'

    if ([string]::IsNullOrWhiteSpace($PinManifestPath)) {
        $migrationFiles = @(Get-ChildItem -LiteralPath $migrationDir -Filter '*.sql' -File -ErrorAction SilentlyContinue)
        if ($migrationFiles.Count -eq 0) {
            throw "UseExistingBackendInputs is missing SQL migrations under $migrationDir."
        }
        return
    }
    if (-not (Test-Path -LiteralPath $PinManifestPath -PathType Leaf)) {
        throw "Input pin manifest does not exist: $PinManifestPath"
    }

    $manifest = Get-Content -LiteralPath $PinManifestPath -Raw | ConvertFrom-Json
    $requiredPrefix = ''
    $forbiddenAppSha = ''
    if ($null -ne $manifest.backend) {
        $requiredPrefix = [string]$manifest.backend.requiredRevisionPrefix
        $forbiddenAppSha = [string]$manifest.backend.forbiddenAppImageSha256
    }
    if ([string]::IsNullOrWhiteSpace($requiredPrefix)) {
        $requiredPrefix = Get-ApprovedBackendRevisionPrefix
    }
    if ([string]::IsNullOrWhiteSpace($forbiddenAppSha)) {
        $forbiddenAppSha = Get-ForbiddenS63fAppImageSha256
    }

    $revisionFile = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/source/SOURCE_REVISION.txt'
    if (-not (Test-Path -LiteralPath $revisionFile -PathType Leaf)) {
        throw "s63f backend source snapshot is missing SOURCE_REVISION.txt under $InputsRoot. Refusing to treat an unproven tree as dd6ab3d50."
    }
    $revision = ([System.IO.File]::ReadAllText($revisionFile)).Trim()
    if (-not $revision.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Backend SOURCE_REVISION '$revision' is not the author-approved s63f tip $requiredPrefix (tag prod/s63f). HEAD and stale snapshots are rejected."
    }

    $tagFile = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/source/SOURCE_TAG.txt'
    if (-not (Test-Path -LiteralPath $tagFile -PathType Leaf)) {
        throw 's63f backend source snapshot is missing SOURCE_TAG.txt (expected prod/s63f).'
    }
    $tag = ([System.IO.File]::ReadAllText($tagFile)).Trim()
    if ($tag -ne (Get-ApprovedBackendTag)) {
        throw "Backend SOURCE_TAG '$tag' is not $(Get-ApprovedBackendTag)."
    }

    $submoduleFile = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/source/SOURCE_SUBMODULE.txt'
    if (-not (Test-Path -LiteralPath $submoduleFile -PathType Leaf)) {
        throw 's63f backend source snapshot is missing SOURCE_SUBMODULE.txt.'
    }
    $submoduleText = [System.IO.File]::ReadAllText($submoduleFile)
    if ($submoduleText -notmatch [regex]::Escape((Get-ApprovedXdisplaySubmoduleCommit))) {
        throw "SOURCE_SUBMODULE.txt does not record xdisplay gitlink $(Get-ApprovedXdisplaySubmoduleCommit)."
    }

    Assert-S63fXdRenderCliSourcePresent -SourceRoot $sourceRoot
    Assert-S63fMigrationSet -MigrationDir $migrationDir

    $dockerfile = Get-Content -LiteralPath (Get-InputsRelativePath -Root $sourceRoot -RelativePath 'Dockerfile') -Raw
    if ($dockerfile -notmatch 'PLAYWRIGHT_VERSION=1\.56\.0' -or $dockerfile -notmatch 'CHROMIUM_REVISION=1194') {
        throw 's63f Dockerfile must pin playwright 1.56.0 and Chromium revision 1194.'
    }
    if ($dockerfile -notmatch 'qmake6 xd_render_cli\.pro' -or $dockerfile -notmatch 'rm -f xd_render_cli') {
        throw 's63f Dockerfile must rebuild Linux xd_render_cli in qt_builder (rm -f leftover binary, qmake6, make). Do not require a cached ELF.'
    }
    $dockerIgnore = Get-Content -LiteralPath (Get-InputsRelativePath -Root $sourceRoot -RelativePath '.dockerignore') -Raw
    if ($dockerIgnore -notmatch '(?m)^uv\.lock$') {
        throw 's63f .dockerignore must ignore uv.lock; image build uses pip from Dockerfile, not uv.lock.'
    }

    $appTarPath = Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/images/orches_orchestration-app_latest.tar'
    $actualAppSha = Convert-ToNormalizedSha256 -Value (Get-FileHash -Path $appTarPath -Algorithm SHA256).Hash
    $forbiddenNormalized = Convert-ToNormalizedSha256 -Value $forbiddenAppSha
    if ([string]::Equals($actualAppSha, $forbiddenNormalized, [StringComparison]::Ordinal)) {
        throw "App image $appTarPath SHA256 $actualAppSha is the forbidden previous 0.1.4 tar F3EECC91... — it is not proven s63f. Do not rename the old tar; rebuild from dd6ab3d50 / prod/s63f."
    }

    Assert-S63fAppImageCompanionInspect `
        -InspectPath (Get-InputsRelativePath -Root $InputsRoot -RelativePath 'backend/images/orches_orchestration-app_latest.inspect.json') `
        -SourceRoot $sourceRoot `
        -ExpectedRevision $revision

    foreach ($entry in @($manifest.files)) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        $assertSha = $true
        if ($entry.PSObject.Properties.Name -contains 'assertSha256') {
            $assertSha = [bool]$entry.assertSha256
        }
        if (-not $assertSha -or [string]::IsNullOrWhiteSpace([string]$entry.sha256)) {
            continue
        }
        $absolutePath = Get-InputsRelativePath -Root $InputsRoot -RelativePath $relativePath
        Assert-PinnedFileIdentity `
            -Path $absolutePath `
            -ExpectedSha256 ([string]$entry.sha256) `
            -ExpectedBytes ([long]$entry.sizeBytes) `
            -DisplayName $relativePath | Out-Null
    }
}

function Export-CachedReleasePins {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$QualifiedRelease,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $payload = [pscustomobject]@{
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        status = 'pinned-cached-release'
        backend = [pscustomobject]@{
            requiredRevisionPrefix = Get-ApprovedBackendRevisionPrefix
            requiredRevisionFull = Get-ApprovedBackendRevisionFull
            requiredTag = Get-ApprovedBackendTag
            xdisplaySubmodule = Get-ApprovedXdisplaySubmoduleCommit
            forbiddenAppImageSha256 = Get-ForbiddenS63fAppImageSha256
            skipBackendImageBuild = 'invalid-from-source; UseExistingBackendInputs only after sanctioned Docker rebuild + inspect companion'
            linuxRenderCli = 'built-in-qt_builder; Mach-O leftover optional; cached ELF not required'
        }
        client = $QualifiedRelease.client
        converter = $QualifiedRelease.converter
        clientProvenance = [pscustomobject]@{
            policy = 'retain-word-fix-superset'
            notAuthorC180MailBytes = $true
            authorClientCard = '2026-11-07-c180'
            catalogwriteSha256 = Get-PinnedCatalogwriteClientSha256
            converterSha256 = Get-PinnedConverterSha256
        }
        destination = $QualifiedRelease.destination
    }
    Write-TextFileUtf8NoBom -Path $OutputPath -Content ($payload | ConvertTo-Json -Depth 6)
    return $payload
}
