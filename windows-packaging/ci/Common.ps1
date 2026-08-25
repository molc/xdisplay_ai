Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[windows-packaging]" $Message -ForegroundColor Cyan
}

function Get-PackagingRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Join-FromRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    return Join-Path (Get-PackagingRoot) $RelativePath
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Read-JsonArrayFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parsedValue = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if ($null -eq $parsedValue) {
        return
    }
    if ($parsedValue -is [System.Array]) {
        foreach ($entry in $parsedValue) {
            Write-Output $entry
        }
        return
    }

    Write-Output $parsedValue
}

function Get-BundleManifest {
    return Read-JsonFile -Path (Join-FromRoot 'manifests/bundle.json')
}

function Get-ChannelManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Channel
    )

    return Read-JsonFile -Path (Join-FromRoot "manifests/channels/$Channel.json")
}

function Get-PortsManifest {
    return Read-JsonFile -Path (Join-FromRoot 'manifests/services/ports.json')
}

function Get-InputLayout {
    $manifest = Get-BundleManifest
    return [pscustomobject]@{
        ClientReleaseDir   = Join-FromRoot $manifest.paths.clientReleaseDir
        BackendSourceDir   = Join-FromRoot $manifest.paths.backendSourceDir
        BackendComposeBase = Join-FromRoot $manifest.paths.backendComposeBase
        BackendMigrationDir = Join-FromRoot $manifest.paths.backendMigrationDir
        BackendImagesDir   = Join-FromRoot $manifest.paths.backendImagesDir
        PrerequisitesRoot  = Join-FromRoot $manifest.paths.prerequisitesRoot
    }
}

function Convert-ImageRefToTarFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageRef
    )

    $sanitized = $ImageRef -replace '[:/@\\]', '_' -replace '[^A-Za-z0-9._-]', '_'
    return "$sanitized.tar"
}

function Get-BackendImageSpecs {
    $imageRefs = @(
        'orches/orchestration-app:latest',
        'orches/embedding-http:latest',
        'pgvector/pgvector:pg15',
        'redis:7'
    )

    return $imageRefs | ForEach-Object {
        [pscustomobject]@{
            ImageRef = $_
            TarFileName = Convert-ImageRefToTarFileName -ImageRef $_
        }
    }
}

function Get-StagingLayout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Channel
    )

    $channelRoot = Join-FromRoot "staging/$Channel"
    return [pscustomobject]@{
        Root               = $channelRoot
        Payload            = Join-Path $channelRoot 'payload'
        WxsGenerated       = Join-Path $channelRoot 'wix'
        GeneratedPayloadWxs = Join-Path $channelRoot 'wix/Payload.Generated.wxs'
        Dist               = Join-FromRoot "dist/$Channel"
    }
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-TextFileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Content
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        Ensure-Directory -Path $parent
    }
    if ($null -eq $Content) {
        $Content = ''
    }

    $normalizedContent = $Content -replace "`r?`n", [Environment]::NewLine

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $normalizedContent, $utf8NoBom)
}

function Reset-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Move-WinDeployQtQmlModules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDirectory,
        [Parameter(Mandatory = $true)]
        [string]$QtQmlSourceDirectory
    )

    if (-not (Test-Path $ReleaseDirectory -PathType Container)) {
        throw "Release directory does not exist: $ReleaseDirectory"
    }
    if (-not (Test-Path $QtQmlSourceDirectory -PathType Container)) {
        throw "Qt QML source directory does not exist: $QtQmlSourceDirectory"
    }

    $qmlDeploymentRoot = Join-Path $ReleaseDirectory 'qml'
    Ensure-Directory -Path $qmlDeploymentRoot

    foreach ($moduleSourceDirectory in Get-ChildItem -Path $QtQmlSourceDirectory -Directory) {
        $deployedModulePath = Join-Path $ReleaseDirectory $moduleSourceDirectory.Name
        if (-not (Test-Path $deployedModulePath -PathType Container)) {
            continue
        }

        $normalizedModulePath = Join-Path $qmlDeploymentRoot $moduleSourceDirectory.Name
        if (Test-Path $normalizedModulePath) {
            throw "Cannot normalize windeployqt QML module because the destination already exists: $normalizedModulePath"
        }

        Move-Item -Path $deployedModulePath -Destination $normalizedModulePath
    }
}

function Move-WinDeployQtPluginDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDirectory,
        [Parameter(Mandatory = $true)]
        [string]$QtPluginsSourceDirectory
    )

    if (-not (Test-Path $ReleaseDirectory -PathType Container)) {
        throw "Release directory does not exist: $ReleaseDirectory"
    }
    if (-not (Test-Path $QtPluginsSourceDirectory -PathType Container)) {
        throw "Qt plugins source directory does not exist: $QtPluginsSourceDirectory"
    }

    $pluginDeploymentRoot = Join-Path $ReleaseDirectory 'plugins'
    Ensure-Directory -Path $pluginDeploymentRoot

    foreach ($pluginSourceDirectory in Get-ChildItem -Path $QtPluginsSourceDirectory -Directory) {
        $deployedPluginPath = Join-Path $ReleaseDirectory $pluginSourceDirectory.Name
        if (-not (Test-Path $deployedPluginPath -PathType Container)) {
            continue
        }

        $normalizedPluginPath = Join-Path $pluginDeploymentRoot $pluginSourceDirectory.Name
        if (Test-Path $normalizedPluginPath) {
            throw "Cannot normalize windeployqt plugin directory because the destination already exists: $normalizedPluginPath"
        }

        Move-Item -Path $deployedPluginPath -Destination $normalizedPluginPath
    }
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )
    if (-not (Test-Path $Source)) {
        throw "源目录不存在：$Source"
    }

    Ensure-Directory -Path $Destination
    $items = Get-ChildItem -Path $Source -Force
    foreach ($item in $items) {
        Copy-Item -Path $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Render-Template {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TemplatePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [hashtable]$Tokens = @{}
    )

    $content = Get-Content -Path $TemplatePath -Raw
    foreach ($tokenName in $Tokens.Keys) {
        $content = $content.Replace("{{${tokenName}}}", [string]$Tokens[$tokenName])
    }

    if ($content -match '\{\{[A-Z0-9_]+\}\}') {
        throw "模板仍存在未替换占位符：$TemplatePath"
    }

    Write-TextFileUtf8NoBom -Path $DestinationPath -Content $content
}

function Get-RelativeContentHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-SourceContentFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$RelativePaths
    )

    if (-not (Test-Path $Root -PathType Container)) {
        throw "Fingerprint root does not exist: $Root"
    }
    if ($RelativePaths.Count -eq 0) {
        throw 'At least one relative path is required to calculate a source fingerprint.'
    }

    $resolvedRoot = (Resolve-Path $Root).Path.TrimEnd([char[]]@([char]92, [char]47))
    $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
    $fingerprintRows = New-Object System.Collections.Generic.List[string]

    foreach ($relativePath in ($RelativePaths | Sort-Object -Unique)) {
        if ([System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "Fingerprint path must stay under its source root: $relativePath"
        }

        $targetPath = Join-Path $resolvedRoot $relativePath
        if (-not (Test-Path $targetPath)) {
            throw "Fingerprint input does not exist: $relativePath"
        }

        $normalizedInputPath = $relativePath.Replace('\', '/').TrimStart('/')
        $fingerprintRows.Add("input`0$normalizedInputPath")
        $files = if (Test-Path $targetPath -PathType Container) {
            @(Get-ChildItem -Path $targetPath -File -Recurse -Force | Sort-Object FullName)
        }
        else {
            @((Get-Item -Path $targetPath -Force))
        }

        foreach ($file in $files) {
            $fullPath = [System.IO.Path]::GetFullPath($file.FullName)
            if (-not $fullPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Fingerprint input escaped its source root: $fullPath"
            }
            $normalizedFilePath = $fullPath.Substring($rootPrefix.Length).Replace('\', '/')
            $fileHash = (Get-FileHash -Path $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $fingerprintRows.Add("file`0$normalizedFilePath`0$fileHash")
        }
    }

    $fingerprintPayload = ($fingerprintRows | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($fingerprintPayload)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-BackendRuntimeCacheDecision {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$ImageExists,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedFingerprint,
        [AllowEmptyString()]
        [string]$CachedFingerprint
    )

    if (
        $ImageExists -and
        -not [string]::IsNullOrWhiteSpace($ExpectedFingerprint) -and
        [string]::Equals(
            $ExpectedFingerprint,
            $CachedFingerprint,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return 'reuse'
    }

    return 'refresh'
}

function Test-PlaceholderValue {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return $true
    }

    return $Value -like '__SET_ME__*' -or $Value -match '\{\{.+\}\}'
}

function Test-DockerDaemonReady {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DockerPath
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $DockerPath info *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Resolve-PathPrefixDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathPrefixDirectory
    )

    $separator = [string][System.IO.Path]::PathSeparator
    $pathEntries = @($PathPrefixDirectory -split [regex]::Escape($separator) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    })
    if ($pathEntries.Count -eq 0) {
        throw 'PATH prefix does not contain any directory entries.'
    }

    $resolvedPathEntries = foreach ($pathEntry in $pathEntries) {
        if (-not (Test-Path $pathEntry -PathType Container)) {
            throw "PATH prefix directory does not exist: $pathEntry"
        }

        (Resolve-Path $pathEntry).Path
    }

    return $resolvedPathEntries -join [System.IO.Path]::PathSeparator
}

function Invoke-CheckedNativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [string]$PathPrefixDirectory = '',
        [string]$LogPath = '',
        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $previousProcessPath = $env:Path
    $locationPushed = $false
    $exitCode = $null

    try {
        $ErrorActionPreference = 'Continue'

        if (-not [string]::IsNullOrWhiteSpace($PathPrefixDirectory)) {
            $resolvedPathPrefixDirectory = Resolve-PathPrefixDirectory -PathPrefixDirectory $PathPrefixDirectory
            $env:Path = $resolvedPathPrefixDirectory + [System.IO.Path]::PathSeparator + $previousProcessPath
        }

        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Push-Location $WorkingDirectory
            $locationPushed = $true
        }

        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            & $FilePath @ArgumentList
        }
        else {
            $resolvedLogPath = [System.IO.Path]::GetFullPath($LogPath)
            $logParent = Split-Path -Path $resolvedLogPath -Parent
            if (-not [string]::IsNullOrWhiteSpace($logParent)) {
                Ensure-Directory -Path $logParent
            }
            & $FilePath @ArgumentList 2>&1 | Out-File -FilePath $resolvedLogPath -Encoding utf8
        }
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($locationPushed) {
            Pop-Location
        }
        $env:Path = $previousProcessPath
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $logSuffix = if ([string]::IsNullOrWhiteSpace($LogPath)) { '' } else { " Log: $LogPath" }
        throw "$FailureMessage (exit code $exitCode).$logSuffix"
    }
}

function Assert-CanStartDockerDesktop {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdentityName
    )

    if ([string]::Equals($IdentityName, 'NT AUTHORITY\SYSTEM', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Docker Desktop must be started from an interactive Windows user session, not NT AUTHORITY\SYSTEM.'
    }
}

function Convert-BatchContentForUnattendedRun {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $convertedLines = foreach ($line in ($Content -split "`r?`n")) {
        if ($line -match '^\s*@?pause\s*$') {
            'rem Interactive pause disabled by XDisplayAI packaging.'
            continue
        }

        if ($line -match '^\s*@?echo(?:[ .]|$)') {
            -join @($line.ToCharArray() | Where-Object { [int]$_ -le 0x7F })
            continue
        }

        $line
    }

    return $convertedLines -join "`r`n"
}

function Invoke-NormalizedBatchFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BatchPath,
        [string]$WorkingDirectory = '',
        [string]$PathPrefixDirectory = ''
    )

    if (-not (Test-Path $BatchPath)) {
        throw "Batch file does not exist: $BatchPath"
    }

    $resolvedBatchPath = (Resolve-Path $BatchPath).Path
    $batchDirectory = Split-Path -Path $resolvedBatchPath -Parent
    $resolvedWorkingDirectory = if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $batchDirectory
    }
    else {
        (Resolve-Path $WorkingDirectory).Path
    }
    $temporaryBatchPath = Join-Path $batchDirectory ('.xdisplayai-' + [System.Guid]::NewGuid().ToString('N') + '.cmd')
    $previousErrorActionPreference = $ErrorActionPreference
    $previousProcessPath = $env:Path
    $locationPushed = $false

    try {
        if (-not [string]::IsNullOrWhiteSpace($PathPrefixDirectory)) {
            $resolvedPathPrefixDirectory = Resolve-PathPrefixDirectory -PathPrefixDirectory $PathPrefixDirectory
            $env:Path = $resolvedPathPrefixDirectory + [System.IO.Path]::PathSeparator + $previousProcessPath
        }

        $content = [System.IO.File]::ReadAllText($resolvedBatchPath)
        $normalizedContent = Convert-BatchContentForUnattendedRun -Content $content
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryBatchPath, $normalizedContent, $utf8NoBom)

        $ErrorActionPreference = 'Continue'
        Push-Location $resolvedWorkingDirectory
        $locationPushed = $true
        $commandText = "call `"$temporaryBatchPath`" <nul"
        & cmd.exe /d /c $commandText | Out-Host
        $exitCode = $LASTEXITCODE
        return $exitCode
    }
    finally {
        if ($locationPushed) {
            Pop-Location
        }
        $ErrorActionPreference = $previousErrorActionPreference
        $env:Path = $previousProcessPath
        if (Test-Path $temporaryBatchPath) {
            Remove-Item -Path $temporaryBatchPath -Force -ErrorAction SilentlyContinue
        }
    }
}
