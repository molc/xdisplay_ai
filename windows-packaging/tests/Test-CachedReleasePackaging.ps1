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

function Write-FixtureBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

$entrypointPath = Join-Path $PackagingRoot 'build-offline-package.ps1'
$entrypoint = Get-Content -LiteralPath $entrypointPath -Raw
Assert-True -Condition ($entrypoint -match '\[switch\]\$SkipClientBuild') -Message 'The one-click entrypoint must expose -SkipClientBuild.'
Assert-True -Condition ($entrypoint -match '\[string\]\$ClientReleaseDir') -Message 'The one-click entrypoint must expose -ClientReleaseDir.'
Assert-True -Condition ($entrypoint -match '\[string\]\$ConverterReleaseDir') -Message 'The one-click entrypoint must expose -ConverterReleaseDir.'
Assert-True -Condition ($entrypoint -match '\[switch\]\$UseExistingBackendInputs') -Message 'The one-click entrypoint must expose -UseExistingBackendInputs.'
Assert-True -Condition ($entrypoint -match '\[switch\]\$VerifyExistingOutputsOnly') -Message 'The one-click entrypoint must expose -VerifyExistingOutputsOnly for incremental Burn re-verify.'
Assert-True -Condition ($entrypoint -match '\[string\]\$WorkRoot') -Message 'The one-click entrypoint must expose -WorkRoot for scarce C:/P: scratch.'
Assert-True -Condition ($entrypoint -match '\[string\]\$StagingRoot') -Message 'The one-click entrypoint must expose -StagingRoot.'
Assert-True -Condition ($entrypoint -match '\[string\]\$DistRoot') -Message 'The one-click entrypoint must expose -DistRoot.'
Assert-True -Condition ($entrypoint -match '2A80890DB988157371CF28D24CA23685D7933C4E59630E5A2DCD2363B7DB5600') -Message 'Cached release must default to the pinned catalogwrite client SHA256.'
Assert-True -Condition ($entrypoint -match 'F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36') -Message 'Cached release must default to the pinned Converter SHA256.'
Assert-True -Condition ($entrypoint -match '675539394') -Message 'Cached release must pin catalogwrite Xdisplay.exe size 675539394.'
Assert-True -Condition ($entrypoint -match '529920') -Message 'Cached release must pin Converter.exe size 529920.'
Assert-True `
    -Condition ($entrypoint -match 'SkipClientBuild' -and $entrypoint -match 'build-xdisplay-from-source' -and $entrypoint -match 'if \(\$SkipClientBuild') `
    -Message 'SkipClientBuild must short-circuit the unconditional client source rebuild.'
Assert-True `
    -Condition ($entrypoint -notmatch 'C:\\work\\xdisplay' -or $entrypoint -match 'SkipClientBuild') `
    -Message 'Cached mode must not require C:\work\xdisplay.'
Assert-True `
    -Condition ($entrypoint -match 'Invoke-SecretsScan' -and $entrypoint -match 'Export-InputPins' -and $entrypoint -match 'Assert-BurnExternalPayloadBindings' -and $entrypoint -match 'Write-ReleaseHold' -and $entrypoint -match 'Assert-WindowsAcceptanceEvidence') `
    -Message 'Cached installer rebuild must keep secretscan, pins, Burn SHA512, NOT_READY, and acceptance gates.'
Assert-True `
    -Condition ($entrypoint -match 'XDISPLAYAI_STAGING_ROOT' -or $entrypoint -match 'Set-PackagingWorkLayout') `
    -Message 'WorkRoot/StagingRoot/DistRoot must be applied for child WiX scripts.'

$prepareInputs = Get-Content -LiteralPath (Join-Path $PackagingRoot 'ci\prepare-inputs.ps1') -Raw
Assert-True `
    -Condition ($prepareInputs -notmatch "复用已存在的客户端输入" -or $prepareInputs -match 'pinned' -or $prepareInputs -match 'ExpectedClientSha256') `
    -Message 'prepare-inputs must not silently reuse a stale inputs/client tree.'

$cachedReleaseScript = Join-Path $PackagingRoot 'ci\CachedRelease.ps1'
Assert-True -Condition (Test-Path -LiteralPath $cachedReleaseScript) -Message 'ci/CachedRelease.ps1 is missing.'
. $cachedReleaseScript
. (Join-Path $PackagingRoot 'ci\Common.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xdisplayai-cached-release-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $clientBytes = [System.Text.Encoding]::UTF8.GetBytes('pinned-catalogwrite-client')
    $converterBytes = [System.Text.Encoding]::UTF8.GetBytes('pinned-converter-bin')
    $wrongClientBytes = [System.Text.Encoding]::UTF8.GetBytes('old-inputs-client')
    $clientSha = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($clientBytes)
    $converterSha = (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($converterBytes)
    $clientShaText = ([BitConverter]::ToString($clientSha)).Replace('-', '')
    $converterShaText = ([BitConverter]::ToString($converterSha)).Replace('-', '')

    $sourceClient = Join-Path $testRoot 'catalogwrite-client'
    $sourceConverter = Join-Path $testRoot 'converter-bin'
    $oldInputsClient = Join-Path $testRoot 'old-inputs-client'
    foreach ($relative in @(
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
        'qrcode_about.jpg',
        'Simulator.exe',
        'avcodec-62.dll',
        'avformat-62.dll',
        'avutil-60.dll',
        'swresample-6.dll',
        'swscale-9.dll',
        'ffmpeg.exe',
        'optipng.exe'
    )) {
        Write-FixtureBytes -Path (Join-Path $sourceClient $relative) -Bytes ([byte[]](1, 2, 3))
        Write-FixtureBytes -Path (Join-Path $oldInputsClient $relative) -Bytes ([byte[]](9, 9, 9))
    }
    Write-FixtureBytes -Path (Join-Path $sourceClient 'Xdisplay.exe') -Bytes $clientBytes
    Write-FixtureBytes -Path (Join-Path $oldInputsClient 'Xdisplay.exe') -Bytes $wrongClientBytes
    Write-FixtureBytes -Path (Join-Path $sourceConverter 'Converter.exe') -Bytes $converterBytes

    $identity = Assert-PinnedFileIdentity `
        -Path (Join-Path $sourceClient 'Xdisplay.exe') `
        -ExpectedSha256 $clientShaText `
        -ExpectedBytes ([long]$clientBytes.Length) `
        -DisplayName 'Xdisplay.exe'
    Assert-True -Condition ($identity.sha256 -eq $clientShaText.ToLowerInvariant() -or $identity.sha256 -eq $clientShaText) -Message 'Pinned client identity SHA256 was not returned.'

    $wrongRejected = $false
    try {
        Assert-PinnedFileIdentity `
            -Path (Join-Path $oldInputsClient 'Xdisplay.exe') `
            -ExpectedSha256 $clientShaText `
            -ExpectedBytes ([long]$clientBytes.Length) `
            -DisplayName 'Xdisplay.exe' | Out-Null
    }
    catch {
        $wrongRejected = $_.Exception.Message -match 'Xdisplay.exe'
    }
    Assert-True -Condition $wrongRejected -Message 'A stale inputs/client Xdisplay.exe must fail the catalogwrite pin.'

    # The fixture's third-party runtime files are the (1,2,3) placeholders; pin them by their real fixture identity.
    $fixtureThirdParty = [ordered]@{}
    $placeholderSha = (Get-FileHash -Path (Join-Path $sourceClient 'avcodec-62.dll') -Algorithm SHA256).Hash
    foreach ($name in @((Get-PinnedThirdPartyRuntimeFiles).Keys)) {
        $fixtureThirdParty[$name] = @{ Sha256 = $placeholderSha; Bytes = [long]3 }
    }
    Assert-Equal -Expected 8 -Actual @((Get-PinnedThirdPartyRuntimeFiles).Keys).Count -Message 'Third-party runtime pin table must list Simulator.exe plus the five ffmpeg DLLs, ffmpeg.exe and optipng.exe.'
    foreach ($name in @((Get-PinnedThirdPartyRuntimeFiles).Keys)) {
        Assert-True -Condition ((Get-RequiredCachedClientReleaseRelativePaths) -contains $name) -Message "Required cached client list must include third-party runtime file $name."
        Assert-True -Condition ([string](Get-PinnedThirdPartyRuntimeFiles)[$name].Sha256 -match '^[0-9A-F]{64}$') -Message "Third-party runtime pin for $name must be a SHA256."
    }
    $wrongThirdParty = [ordered]@{}; foreach ($k in $fixtureThirdParty.Keys) { $wrongThirdParty[$k] = $fixtureThirdParty[$k] }
    $wrongThirdParty['avcodec-62.dll'] = @{ Sha256 = ('0' * 64); Bytes = [long]3 }
    $thirdPartyRejected = $false
    try { Assert-ThirdPartyRuntimeIdentity -ClientReleaseDir $sourceClient -Expected $wrongThirdParty | Out-Null } catch { $thirdPartyRejected = $_.Exception.Message -match 'avcodec-62.dll' }
    Assert-True -Condition $thirdPartyRejected -Message 'A third-party runtime file with the wrong SHA256 must fail qualification.'

    # Import-closure gate: pure decision plus a real PE parse (the fixtures are not PE images and must be reported as skipped).
    $missingDecision = Get-MissingImportedDlls -ReleaseDir $sourceClient -ExecutableDirectory $sourceClient -ImportedDlls @('KERNEL32.dll', 'api-ms-win-crt-runtime-l1-1-0.dll', 'Qt5Core.dll', 'avcodec-62.dll', 'Qt5NotShipped.dll')
    Assert-Equal -Expected 'Qt5NotShipped.dll' -Actual ($missingDecision -join ',') -Message 'Import closure must ignore Windows DLLs and shipped DLLs and report only the absent ones.'
    Assert-True -Condition ($null -eq (Get-PeImportedDllNames -Path (Join-Path $sourceClient 'Simulator.exe'))) -Message 'A non-PE placeholder must parse as $null (skipped), not as an empty import list.'
    if ($env:OS -eq 'Windows_NT') {
        $notepad = Join-Path $env:SystemRoot 'System32\notepad.exe'
        if (Test-Path -LiteralPath $notepad) {
            $notepadImports = @(Get-PeImportedDllNames -Path $notepad)
            Assert-True -Condition (@($notepadImports | Where-Object { $_ -match '^(KERNEL32|api-ms-win)' }).Count -gt 0) -Message 'PE import parser must read notepad.exe imports (KERNEL32 / api-ms-win-*).'
        }
    }
    $closureRejected = $false
    try { Get-MissingImportedDlls -ReleaseDir $sourceClient -ExecutableDirectory $sourceClient -ImportedDlls @('avcodec-62.dll') | Out-Null; $closureRejected = $true } catch { $closureRejected = $false }
    Assert-True -Condition $closureRejected -Message 'Shipped ffmpeg DLL must satisfy the import closure.'

    $destination = Join-Path $testRoot 'qualified-client'
    $qualified = New-QualifiedCachedClientRelease `
        -ClientReleaseDir $sourceClient `
        -ConverterReleaseDir $sourceConverter `
        -Destination $destination `
        -ExpectedClientSha256 $clientShaText `
        -ExpectedClientBytes ([long]$clientBytes.Length) `
        -ExpectedConverterSha256 $converterShaText `
        -ExpectedConverterBytes ([long]$converterBytes.Length) `
        -ExpectedThirdPartyRuntime $fixtureThirdParty

    Assert-True -Condition (Test-Path -LiteralPath (Join-Path $destination 'Xdisplay.exe')) -Message 'Qualified tree must contain Xdisplay.exe.'
    $converterInQualified = @(Get-ChildItem -LiteralPath $destination -Filter 'Converter.exe' -Recurse -File)
    Assert-True -Condition ($converterInQualified.Count -ge 1) -Message 'Qualified tree must contain overlaid Converter.exe.'
    Assert-True `
        -Condition ((Get-FileHash -Path (Join-Path $sourceClient 'Xdisplay.exe') -Algorithm SHA256).Hash -eq $clientShaText) `
        -Message 'Qualification must not modify the source catalogwrite client.'
    Assert-True `
        -Condition ((Get-FileHash -Path (Join-Path $sourceConverter 'Converter.exe') -Algorithm SHA256).Hash -eq $converterShaText) `
        -Message 'Qualification must not modify the source Converter directory.'
    Assert-True -Condition ($qualified.client.sha256.ToLowerInvariant() -eq $clientShaText.ToLowerInvariant()) -Message 'Qualified client pin was not recorded.'
    Assert-True -Condition ($qualified.converter.sha256.ToLowerInvariant() -eq $converterShaText.ToLowerInvariant()) -Message 'Qualified converter pin was not recorded.'

    $sourceTouched = (Get-Item -LiteralPath (Join-Path $sourceClient 'Xdisplay.exe')).LastWriteTimeUtc
    Start-Sleep -Milliseconds 10
    New-QualifiedCachedClientRelease `
        -ClientReleaseDir $sourceClient `
        -ConverterReleaseDir $sourceConverter `
        -Destination (Join-Path $testRoot 'qualified-client-2') `
        -ExpectedClientSha256 $clientShaText `
        -ExpectedClientBytes ([long]$clientBytes.Length) `
        -ExpectedConverterSha256 $converterShaText `
        -ExpectedConverterBytes ([long]$converterBytes.Length) | Out-Null
    Assert-True `
        -Condition ((Get-Item -LiteralPath (Join-Path $sourceClient 'Xdisplay.exe')).LastWriteTimeUtc -eq $sourceTouched) `
        -Message 'Re-qualifying must still leave the source client bytes untouched.'

    $workRoot = Join-Path $testRoot 'scratch'
    $layout = Set-PackagingWorkLayout -WorkRoot $workRoot -Channel 'dev'
    Assert-True -Condition ($layout.StagingRoot -like '*scratch*') -Message 'WorkRoot must drive staging off C:/P: when provided.'
    Assert-True -Condition ($env:XDISPLAYAI_STAGING_ROOT -eq $layout.StagingRoot) -Message 'Staging override must be exported for child scripts.'
    $staging = Get-StagingLayout -Channel 'dev'
    Assert-True -Condition ($staging.Root -eq (Join-Path $layout.StagingRoot 'dev')) -Message 'Get-StagingLayout must honor the scratch StagingRoot.'
    Assert-True -Condition ($staging.Dist -eq (Join-Path $layout.DistRoot 'dev')) -Message 'Get-StagingLayout must honor the scratch DistRoot.'

    $missingClientRejected = $false
    try {
        Assert-CachedReleaseArguments -SkipClientBuild $true -ClientReleaseDir '' -ConverterReleaseDir $sourceConverter | Out-Null
    }
    catch {
        $missingClientRejected = $true
    }
    Assert-True -Condition $missingClientRejected -Message 'SkipClientBuild without ClientReleaseDir must fail closed.'
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    foreach ($name in @('XDISPLAYAI_WORK_ROOT', 'XDISPLAYAI_STAGING_ROOT', 'XDISPLAYAI_DIST_ROOT', 'XDISPLAYAI_CACHE_ROOT', 'XDISPLAYAI_TEMP_ROOT', 'XDISPLAYAI_CLIENT_RELEASE_DIR')) {
        Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
    }
}

Write-Output 'PASS: cached-release packaging contract'
exit 0
