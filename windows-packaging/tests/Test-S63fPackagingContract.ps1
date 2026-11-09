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
. (Join-Path $PackagingRoot 'ci\CachedRelease.ps1')

$tmpl = Get-Content -LiteralPath (Join-Path $PackagingRoot 'src\templates\env\backend.env.tmpl') -Raw
Assert-True -Condition ($tmpl -notmatch 'XDISPLAY_AI_STAGED_DRAFTER_ENABLED') -Message 'Seed backend.env must not ship retired XDISPLAY_AI_STAGED_DRAFTER_ENABLED.'
Assert-True -Condition ($tmpl -match 'XDISPLAY_AI_PROMPT_VERSIONS=') -Message 'Seed backend.env must pin s63f prompt versions.'
Assert-True -Condition ($tmpl -match 'intent_extractor:v2.24') -Message 's63f seed must pin intent_extractor v2.24.'
Assert-True -Condition ($tmpl -match 'PAGE_HTML:v19') -Message 's63f seed must pin PAGE_HTML v19.'
Assert-True -Condition ($tmpl -match 'read_display_declarer:v1.15') -Message 's63f seed must pin read_display_declarer v1.15.'
Assert-True -Condition ($tmpl -match 'write_action_declarer:v1.10') -Message 's63f seed must pin write_action_declarer v1.10.'
Assert-True -Condition ($tmpl -match 'write_action_declarer_link:v1.8') -Message 's63f seed must pin write_action_declarer_link v1.8.'
Assert-True -Condition ($tmpl -match 'sketch_interpreter:v4.0') -Message 's63f seed must pin sketch_interpreter v4.0.'
Assert-True -Condition ($tmpl -match 'STYLESHEET:v6') -Message 's63f seed must pin STYLESHEET v6.'
Assert-True -Condition ($tmpl -match 'XDISPLAY_AI_SKETCH_VISION_TIMEOUT_SECONDS=90') -Message 's63f seed must keep 90s sketch vision timeout.'

Assert-True -Condition ((Get-ApprovedBackendRevisionPrefix) -eq 'dd6ab3d50') -Message 'Approved backend tip is dd6ab3d50 / prod/s63f, not HEAD.'
Assert-True -Condition ((Get-ApprovedBackendTag) -eq 'prod/s63f') -Message 'Approved backend tag must be prod/s63f.'
Assert-True `
    -Condition ((Get-ForbiddenS63fAppImageSha256) -eq 'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309') `
    -Message 'The previous 0.1.4 app tar F3EECC91... must be forbidden as an s63f image.'

$retired = @(Get-RetiredBackendEnvKeys)
Assert-True -Condition ($retired -contains 'XDISPLAY_AI_STAGED_DRAFTER_ENABLED') -Message 'Retired staged-drafter key must be listed for explicit migration.'

$defaults = [ordered]@{ APP_HOST_PORT = '18001' }
$existing = [ordered]@{
    APP_HOST_PORT = '18001'
    XDISPLAY_AI_STAGED_DRAFTER_ENABLED = 'true'
    T203_UPGRADE_SENTINEL = 'keep-me'
}
$merged = Merge-EnvEntries -Defaults $defaults -Existing $existing -DropKeys @(Get-RetiredBackendEnvKeys)
Assert-True -Condition (-not $merged.Contains('XDISPLAY_AI_STAGED_DRAFTER_ENABLED')) -Message 'Merge must drop the retired staged-drafter key.'
Assert-True -Condition ($merged['T203_UPGRADE_SENTINEL'] -eq 'keep-me') -Message 'DropKeys must not remove unrelated upgrade sentinels.'

$envRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('s63f-retired-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $envRoot -Force | Out-Null
try {
    $envPath = Join-Path $envRoot 'backend.env'
    [System.IO.File]::WriteAllText($envPath, "XDISPLAY_AI_STAGED_DRAFTER_ENABLED=true`nXDISPLAY_AI_LOG_LEVEL=INFO`n")
    $removed = Remove-RetiredBackendEnvKeys -EnvPath $envPath
    Assert-True -Condition ($removed.Changed -eq $true) -Message 'Remove-RetiredBackendEnvKeys must report a change when the retired key is present.'
    $after = [System.IO.File]::ReadAllText($envPath)
    Assert-True -Condition ($after -notmatch 'XDISPLAY_AI_STAGED_DRAFTER_ENABLED') -Message 'Retired key must be deleted from backend .env.'
    Assert-True -Condition ($after -match 'XDISPLAY_AI_LOG_LEVEL=INFO') -Message 'Unrelated .env keys must remain after staged-drafter deletion.'
}
finally {
    Remove-Item -LiteralPath $envRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$pinPath = Join-Path $PackagingRoot 'manifests\pins\offline-inputs.s63f.json'
Assert-True -Condition (Test-Path -LiteralPath $pinPath) -Message 's63f pin manifest is missing.'
$pins = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
Assert-True -Condition ($pins.backend.requiredRevisionPrefix -eq 'dd6ab3d50') -Message 's63f pin manifest must require dd6ab3d50, not HEAD.'
Assert-True -Condition ($pins.backend.forbiddenAppImageSha256 -eq 'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309') -Message 's63f pin manifest must forbid the previous app tar hash.'
Assert-True -Condition ($pins.client.notAuthorC180MailBytes -eq $true) -Message 'Client pins must be recorded as Word-fix supersets, not literal c180 mail bytes.'
Assert-True -Condition ($pins.client.sha256 -eq '2A80890DB988157371CF28D24CA23685D7933C4E59630E5A2DCD2363B7DB5600') -Message 'Word-fix catalogwrite client SHA must be retained.'
Assert-True -Condition ($pins.converter.sha256 -eq 'F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36') -Message 'Word-fix Converter SHA must be retained.'

$entrypoint = Get-Content -LiteralPath (Join-Path $PackagingRoot 'build-offline-package.ps1') -Raw
Assert-True -Condition ($entrypoint -match 'offline-inputs\.s63f\.json') -Message 'Cached installer rebuild must default to the s63f pin manifest, not the stale F3EECC91 0.1.4 pins.'
Assert-True -Condition ($entrypoint -match 'Assert-S63fBackendInputs' -or $entrypoint -match 'forbiddenAppImageSha256' -or $entrypoint -match 'Assert-ExistingBackendInputs') -Message 'Cached mode must keep s63f source/image gates.'

$prepareInputs = Get-Content -LiteralPath (Join-Path $PackagingRoot 'ci\prepare-inputs.ps1') -Raw
Assert-True -Condition ($prepareInputs -match 'SOURCE_REVISION.txt') -Message 'Backend source snapshot must record SOURCE_REVISION.txt for s63f provenance.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('s63f-inputs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    function Write-EmptyRelative {
        param([string]$Root, [string]$Relative)
        $path = Join-Path $Root $Relative
        $parent = Split-Path -Path $path -Parent
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        [System.IO.File]::WriteAllBytes($path, [byte[]](1, 2, 3, 4))
    }
    foreach ($relative in @(
        'prerequisites/docker-desktop/Docker Desktop Installer.exe',
        'prerequisites/vcredist/VC_redist.x64.exe',
        'prerequisites/wsl/wsl_update_x64.msi',
        'backend/images/orches_orchestration-app_latest.tar',
        'backend/images/orches_embedding-http_latest.tar',
        'backend/images/pgvector_pgvector_pg15.tar',
        'backend/images/redis_7.tar',
        'backend/source/app/main.py',
        'backend/compose/upstream/docker-compose.yml',
        'backend/migrations/0001_init.sql'
    )) {
        Write-EmptyRelative -Root $testRoot -Relative $relative
    }

    $staleRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $pinPath | Out-Null
    }
    catch {
        $staleRejected = $_.Exception.Message -match 'F3EECC91' -or $_.Exception.Message -match 'SOURCE_REVISION' -or $_.Exception.Message -match 's63f'
    }
    Assert-True -Condition $staleRejected -Message 's63f input gate must fail closed without SOURCE_REVISION and without a rebuilt app image.'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_REVISION.txt'), "deadbeef`n")
    $wrongRevRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $pinPath | Out-Null
    }
    catch {
        $wrongRevRejected = $_.Exception.Message -match 'dd6ab3d50'
    }
    Assert-True -Condition $wrongRevRejected -Message 'SOURCE_REVISION that is not dd6ab3d50 must be rejected (no HEAD, no stale snapshot).'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_REVISION.txt'), "dd6ab3d50abcdef`n")
    $appTar = Join-Path $testRoot 'backend\images\orches_orchestration-app_latest.tar'
    $staleBytes = [System.Text.Encoding]::ASCII.GetBytes('not-the-old-gigabyte-tar-but-marked-forbidden')
    [System.IO.File]::WriteAllBytes($appTar, $staleBytes)
    $localForbidden = (Get-FileHash -Path $appTar -Algorithm SHA256).Hash
    $localManifestPath = Join-Path $testRoot 'local-s63f.json'
    $localManifest = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
    $localManifest.backend.forbiddenAppImageSha256 = $localForbidden
    $localManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $localManifestPath
    $forbiddenRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
    }
    catch {
        $forbiddenRejected = $_.Exception.Message -match 'forbidden' -or $_.Exception.Message -match 'F3EECC91' -or $_.Exception.Message -match 'rename'
    }
    Assert-True -Condition $forbiddenRejected -Message 'An app image whose hash is the forbidden previous tar must not be accepted as s63f.'

    [System.IO.File]::WriteAllBytes($appTar, [byte[]](9, 9, 9, 9, 9))
    Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: s63f packaging contract'
exit 0
