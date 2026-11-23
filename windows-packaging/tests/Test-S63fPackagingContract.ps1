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
foreach ($retiredKey in @(Get-RetiredBackendEnvKeys)) {
    Assert-True -Condition ($tmpl -notmatch ('(?m)^' + [regex]::Escape($retiredKey) + '=')) -Message "Seed backend.env must not override behaviour key $retiredKey; s70 behaviour comes from the code defaults (24-869)."
}
Assert-True -Condition ($tmpl -match '(?m)^XDISPLAY_AI_STRICT_DESIGN_ASSEMBLY_BINDING_ENABLED=true\s*$') -Message 'Seed backend.env must enable strict design assembly binding like production.'
Assert-True -Condition ($tmpl -match '(?m)^XDISPLAY_AI_STRICT_VISION_UPSTREAM=bailian\s*$') -Message 'Seed backend.env must route strict vision to bailian like production.'
Assert-True -Condition ((Get-RetiredBackendEnvKeys) -contains 'XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION') -Message 'PAGE_HTML override must be retired (v19 is not a valid s70 value).'
$truncatedProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable (Get-S63fRejectedTruncatedPromptVersionPins) -DefaultTable (Get-S63fSettingsDefaultPromptVersionTable))
Assert-True -Condition ($truncatedProblems.Count -ge 12) -Message 'The a62 crash table must still fail registry-shape checks (missing 26 agents plus PAGE_HTML/STYLESHEET aliases).'
Assert-True -Condition (($truncatedProblems -join ' ') -match 'PAGE_HTML') -Message 'Registry-shape checks must reject PAGE_HTML as a non-directory agent alias.'
Assert-True -Condition (($truncatedProblems -join ' ') -match 'STYLESHEET') -Message 'Registry-shape checks must reject STYLESHEET as a non-directory agent alias.'

Assert-True -Condition ((Get-ApprovedBackendRevisionPrefix) -eq '61d37700a') -Message 'Approved backend tip is dd6ab3d50 / prod/s70, not HEAD.'
Assert-True -Condition ((Get-ApprovedBackendRevisionFull) -eq '61d37700ac224e675b2d55ee62acd21c813e15e3') -Message 'Approved backend full revision is 61d37700ac224e675b2d55ee62acd21c813e15e3.'
Assert-True -Condition ((Get-ApprovedBackendTag) -eq 'prod/s70') -Message 'Approved backend tag must be prod/s70.'
Assert-True -Condition ((Get-ApprovedXdisplaySubmoduleCommit) -eq '0c657ad3eac7ece814206bd40fea807ec6568f81') -Message 'xd_render_cli submodule source is 0c657ad3; Linux ELF is built in qt_builder.'
Assert-True -Condition ((Get-S63fPlaywrightVersion) -eq '1.56.0') -Message 's63f runtime image pins playwright 1.56.0.'
Assert-True -Condition ((Get-S63fChromiumRevision) -eq '1194') -Message 's63f runtime image pins Chromium 1194.'
Assert-True -Condition ((Get-S63fExportMachOXdRenderCliBytes) -eq 50200) -Message 'Sanctioned export Mach-O leftover is 50200 bytes, not a required Linux ELF.'
Assert-True `
    -Condition ((Get-S63fExportMachOXdRenderCliSha256) -eq '58618EC212229AC900E48304922AFD50EDFFD0F54CB325DCFA60F34382A606EA') `
    -Message 'Sanctioned export Mach-O leftover hash is 58618EC2..., not a cached Linux ELF pin.'
Assert-True `
    -Condition ((Get-ForbiddenS63fAppImageSha256) -eq '514ACD60DF0D7D6FAB00684116F9F863A6A58F161A4C9BAF73CFAD76E0B83A24') `
    -Message 'The previous 0.1.4 app tar F3EECC91... must be forbidden as an s63f image.'
Assert-True `
    -Condition ((((Get-S63fMigrationFileNames) -join ',') -eq '0001_init.sql,0002_rag.sql,0003_orch_runtime.sql')) `
    -Message 's63f ships migrations 0001-0003 only; no new data migration.'

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
Assert-True -Condition ($pins.backend.requiredRevisionPrefix -eq '61d37700a') -Message 's63f pin manifest must require dd6ab3d50, not HEAD.'
Assert-True -Condition ($pins.backend.forbiddenAppImageSha256 -eq '514ACD60DF0D7D6FAB00684116F9F863A6A58F161A4C9BAF73CFAD76E0B83A24') -Message 's63f pin manifest must forbid the previous app tar hash.'
Assert-True -Condition ($pins.promptPins -eq (Get-S63fRegisteredPromptVersionTable)) -Message 's63f pin manifest promptPins must be the full registered-agent table, not the truncated author-card replacement.'
Assert-True -Condition ($pins.rejectedTruncatedPromptPins -eq (Get-S63fRejectedTruncatedPromptVersionPins)) -Message 's63f pin manifest must record the a62 crash table as rejected.'
Assert-True -Condition ($pins.browserSolverPageHtmlPromptVersion -eq 'v22') -Message 's63f pin manifest must pin PAGE_HTML on the browser-solver Settings field.'
Assert-True -Condition ($pins.browserSolverEngineeringStylesheetContractVersion -eq 'v7') -Message 's63f pin manifest must pin STYLESHEET on the engineering stylesheet Settings field.'
Assert-True -Condition ($pins.client.notAuthorC180MailBytes -eq $true) -Message 'Client pins must be recorded as Word-fix supersets, not literal c180 mail bytes.'
Assert-True -Condition ($pins.client.sha256 -eq (Get-PinnedCatalogwriteClientSha256)) -Message 'Word-fix catalogwrite client SHA must be retained.'
Assert-True -Condition ($pins.converter.sha256 -eq 'F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36') -Message 'Word-fix Converter SHA must be retained.'
Assert-True -Condition ($pins.backend.linuxRenderCli.exportBinary.required -eq $false) -Message 'Mach-O leftover must not be a required Linux ELF pin.'
Assert-True -Condition ($pins.backend.runtimeImage.playwright -eq '1.56.0') -Message 'Pin manifest must record playwright 1.56.0.'
Assert-True -Condition ($pins.backend.skipBackendImageBuild -match 'invalid') -Message 'Pin manifest must record SkipBackendImageBuild as invalid from-source.'

$entrypoint = Get-Content -LiteralPath (Join-Path $PackagingRoot 'build-offline-package.ps1') -Raw
Assert-True -Condition ($entrypoint -match 'offline-inputs\.s63f\.json') -Message 'Cached installer rebuild must default to the s63f pin manifest, not the stale F3EECC91 0.1.4 pins.'
Assert-True -Condition ($entrypoint -match 'Assert-S63fBackendInputs' -or $entrypoint -match 'forbiddenAppImageSha256' -or $entrypoint -match 'Assert-ExistingBackendInputs') -Message 'Cached mode must keep s63f source/image gates.'

$prepareInputs = Get-Content -LiteralPath (Join-Path $PackagingRoot 'ci\prepare-inputs.ps1') -Raw
Assert-True -Condition ($prepareInputs -match 'SOURCE_REVISION.txt') -Message 'Backend source snapshot must record SOURCE_REVISION.txt for s63f provenance.'
Assert-True -Condition ($prepareInputs -match 'SkipBackendImageBuild is invalid for s63f') -Message 'prepare-inputs must refuse unproven SkipBackendImageBuild instead of tagging an old runtime-cache.'
Assert-True -Condition ($entrypoint -match 'Assert-SkipBackendImageBuildFromSource') -Message 'Cached entrypoint must refuse SkipBackendImageBuild unless UseExistingBackendInputs follows a sanctioned rebuild.'

$fingerprintPaths = @(Get-OrchestrationAppRuntimeFingerprintPaths)
foreach ($legacyPath in @(Get-ForbiddenLegacyOrchestrationRuntimeFingerprintPaths)) {
    Assert-True -Condition ($fingerprintPaths -notcontains $legacyPath) -Message "Runtime fingerprint must not require nonexistent $legacyPath"
}
Assert-True -Condition ($fingerprintPaths -contains 'Dockerfile') -Message 'Fingerprint must include Dockerfile (Qt6/pip/playwright pins).'
Assert-True -Condition ($fingerprintPaths -contains 'pyproject.toml') -Message 'Fingerprint must include pyproject.toml.'
Assert-True -Condition ($fingerprintPaths -contains '.dockerignore') -Message 'Fingerprint must include .dockerignore (uv.lock ignored).'
Assert-True -Condition ($fingerprintPaths -contains 'external\xdisplay\bin\xd_render_cli\main.cpp') -Message 'Fingerprint must include xd_render_cli source, not a cached ELF.'
Assert-True -Condition ($fingerprintPaths -notcontains 'external\xdisplay\bin\xd_render_cli') -Message 'Fingerprint hashes source files, not the Mach-O leftover binary path.'
Assert-True -Condition ($fingerprintPaths -notcontains 'uv.lock') -Message 'uv.lock must not be a runtime fingerprint input.'
Assert-True -Condition ((Get-EmbeddingRuntimeFingerprintPaths) -contains 'scripts\embedding_http_service.py') -Message 'Embedding fingerprint must include the copied service script.'

$skipFromSourceRejected = $false
try {
    Assert-SkipBackendImageBuildFromSource -SkipBackendImageBuild $true -UseExistingBackendInputs $false
}
catch {
    $skipFromSourceRejected = $_.Exception.Message -match 'SkipBackendImageBuild is invalid'
}
Assert-True -Condition $skipFromSourceRejected -Message 'From-source SkipBackendImageBuild must fail closed for s63f.'
Assert-SkipBackendImageBuildFromSource -SkipBackendImageBuild $false -UseExistingBackendInputs $false
Assert-SkipBackendImageBuildFromSource -SkipBackendImageBuild $true -UseExistingBackendInputs $true

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
        'backend/migrations/0001_init.sql',
        'backend/migrations/0002_rag.sql',
        'backend/migrations/0003_orch_runtime.sql'
    )) {
        Write-EmptyRelative -Root $testRoot -Relative $relative
    }

    function Write-S63fSourceContractFiles {
        param([string]$SourceRoot)
        $dockerfile = @(
            'FROM python:3.11-slim-bookworm AS qt_builder',
            'RUN apt-get update && apt-get install -y qt6-base-dev qmake6 libgl-dev',
            'COPY external/xdisplay/bin/xd_render_cli /src/xd_render_cli',
            'RUN rm -f xd_render_cli && qmake6 xd_render_cli.pro && make',
            'COPY app ./app',
            'COPY pyproject.toml ./pyproject.toml',
            'ARG PLAYWRIGHT_VERSION=1.56.0',
            'ARG CHROMIUM_REVISION=1194'
        ) -join "`n"
        [System.IO.File]::WriteAllText((Join-Path $SourceRoot 'Dockerfile'), $dockerfile + "`n")
        [System.IO.File]::WriteAllText((Join-Path $SourceRoot 'pyproject.toml'), "name = `"ai_orchestration`"`n")
        [System.IO.File]::WriteAllText((Join-Path $SourceRoot '.dockerignore'), "uv.lock`n")
        [System.IO.File]::WriteAllText((Join-Path $SourceRoot 'uv.lock'), 'ignored')
        $cli = Join-Path $SourceRoot 'external\xdisplay\bin\xd_render_cli'
        New-Item -ItemType Directory -Path $cli -Force | Out-Null
        foreach ($name in @('main.cpp', 'render_runner.cpp', 'render_runner.h', 'xd_render_cli.pro', 'Makefile')) {
            [System.IO.File]::WriteAllText((Join-Path $cli $name), $name)
        }
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
        $wrongRevRejected = $_.Exception.Message -match '61d37700a'
    }
    Assert-True -Condition $wrongRevRejected -Message 'SOURCE_REVISION that is not dd6ab3d50 must be rejected (no HEAD, no stale snapshot).'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_REVISION.txt'), "61d37700ac224e675b2d55ee62acd21c813e15e3`n")
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_TAG.txt'), "prod/s70`n")
    [System.IO.File]::WriteAllText(
        (Join-Path $testRoot 'backend\source\SOURCE_SUBMODULE.txt'),
        "commit=0c657ad3eac7ece814206bd40fea807ec6568f81`n"
    )
    $sourceRoot = Join-Path $testRoot 'backend\source'
    Write-S63fSourceContractFiles -SourceRoot $sourceRoot

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
    $missingInspectRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
    }
    catch {
        $missingInspectRejected = $_.Exception.Message -match 'inspect'
    }
    Assert-True -Condition $missingInspectRejected -Message 's63f app tar requires companion docker inspect JSON; renaming a tar is not proof.'

    $fingerprint = Get-SourceContentFingerprint -Root $sourceRoot -RelativePaths @(Get-OrchestrationAppRuntimeFingerprintPaths)
    $inspectObject = [pscustomobject]@{
        Id = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        RepoTags = @('orches/orchestration-app:s70-61d37700a', 'orches/orchestration-app:latest')
        Config = [pscustomobject]@{
            Labels = [pscustomobject]@{
                'xdisplayai.packaging.git-sha' = '61d37700ac224e675b2d55ee62acd21c813e15e3'
                'xdisplayai.packaging.tag' = 'prod/s70'
                'xdisplayai.packaging.runtime-fingerprint' = $fingerprint
            }
        }
    }
    @( $inspectObject ) | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $testRoot 'backend\images\orches_orchestration-app_latest.inspect.json') -Encoding utf8
    Assert-S63fXdRenderCliSourcePresent -SourceRoot $sourceRoot
    Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null

    $cliBinary = Join-Path $sourceRoot 'external\xdisplay\bin\xd_render_cli\xd_render_cli'
    [System.IO.File]::WriteAllBytes($cliBinary, [byte[]](0xFE, 0xED, 0xFA, 0xCF) + [byte[]](1..20))
    $fingerprintWithMachO = Get-SourceContentFingerprint -Root $sourceRoot -RelativePaths @(Get-OrchestrationAppRuntimeFingerprintPaths)
    Assert-True -Condition ($fingerprintWithMachO -eq $fingerprint) -Message 'Adding the Mach-O leftover must not change the runtime fingerprint or require a cached Linux ELF.'
    Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'PASS: s63f packaging contract'
exit 0
