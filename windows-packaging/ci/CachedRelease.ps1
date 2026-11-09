Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

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
        'data/keyboard_d/var/data_var.json'
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
        $absolutePath = $InputsRoot
        foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $absolutePath = Join-Path $absolutePath $segment
        }
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            throw "UseExistingBackendInputs is missing $relativePath under $InputsRoot. Source clones are not a permitted workaround."
        }
    }

    $migrationDir = Join-Path $InputsRoot 'backend\migrations'
    $migrationFiles = @(Get-ChildItem -LiteralPath $migrationDir -Filter '*.sql' -File -ErrorAction SilentlyContinue)
    if ($migrationFiles.Count -eq 0) {
        throw "UseExistingBackendInputs is missing SQL migrations under $migrationDir."
    }

    if ([string]::IsNullOrWhiteSpace($PinManifestPath)) {
        return
    }
    if (-not (Test-Path -LiteralPath $PinManifestPath -PathType Leaf)) {
        throw "Input pin manifest does not exist: $PinManifestPath"
    }

    $manifest = Get-Content -LiteralPath $PinManifestPath -Raw | ConvertFrom-Json
    foreach ($entry in @($manifest.files)) {
        $relativePath = [string]$entry.relativePath
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        $absolutePath = $InputsRoot
        foreach ($segment in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $absolutePath = Join-Path $absolutePath $segment
        }
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
        client = $QualifiedRelease.client
        converter = $QualifiedRelease.converter
        destination = $QualifiedRelease.destination
    }
    Write-TextFileUtf8NoBom -Path $OutputPath -Content ($payload | ConvertTo-Json -Depth 6)
    return $payload
}
