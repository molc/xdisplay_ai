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
Assert-True -Condition ($tmpl -match 'XDISPLAY_AI_PROMPT_VERSIONS=') -Message 'Seed backend.env must pin approved-card prompt versions.'
$promptLineMatch = [regex]::Match($tmpl, '(?m)^XDISPLAY_AI_PROMPT_VERSIONS=(?<value>[^\r\n]*)\s*$')
Assert-True -Condition $promptLineMatch.Success -Message 'Seed backend.env must have a single XDISPLAY_AI_PROMPT_VERSIONS assignment.'
$generatedPromptTable = [string]$promptLineMatch.Groups['value'].Value
Assert-True -Condition ($generatedPromptTable -eq (Get-S63fRegisteredPromptVersionTable)) -Message 'Seed XDISPLAY_AI_PROMPT_VERSIONS must be the full approved-card registered-agent table with author version overlays.'
Assert-True -Condition ($generatedPromptTable -ne (Get-S63fRejectedTruncatedPromptVersionPins)) -Message 'Seed must not ship the truncated seven-entry author-card table that crashed native a62.'
$generatedPromptProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable $generatedPromptTable -DefaultTable (Get-S63fSettingsDefaultPromptVersionTable))
Assert-True -Condition ($generatedPromptProblems.Count -eq 0) -Message ('Generated prompt table must pass registry-shape checks: ' + ($generatedPromptProblems -join '; '))
Assert-True -Condition ($generatedPromptTable -match 'intent_extractor:v2.24') -Message 'approved-card seed must pin intent_extractor v2.24.'
Assert-True -Condition ($generatedPromptTable -match 'read_display_declarer:v1.15') -Message 'approved-card seed must pin read_display_declarer v1.15.'
Assert-True -Condition ($generatedPromptTable -match 'write_action_declarer:v1.10') -Message 'approved-card seed must pin write_action_declarer v1.10.'
Assert-True -Condition ($generatedPromptTable -match 'write_action_declarer_link:v1.10') -Message 'approved-card seed must pin write_action_declarer_link v1.10.'
Assert-True -Condition ($generatedPromptTable -match 'sketch_interpreter:v4.0') -Message 'approved-card seed must pin sketch_interpreter v4.0.'
Assert-True -Condition ($generatedPromptTable -match 'planner:v1.2') -Message 'approved-card seed must keep planner in the registered-agent map.'
Assert-True -Condition ($generatedPromptTable -match 'navigation_target_grouping_judge:v1.0') -Message 'approved-card seed must keep navigation_target_grouping_judge in the registered-agent map.'
Assert-True -Condition ($generatedPromptTable -notmatch 'PAGE_HTML') -Message 'PAGE_HTML is not a prompt_versions agent; it must not appear in XDISPLAY_AI_PROMPT_VERSIONS.'
Assert-True -Condition ($generatedPromptTable -notmatch 'STYLESHEET') -Message 'STYLESHEET is not a prompt_versions agent; it must not appear in XDISPLAY_AI_PROMPT_VERSIONS.'
Assert-True -Condition ($tmpl -match '(?m)^XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION=v20\s*$') -Message 'approved-card seed must pin PAGE_HTML v20 on XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION.'
Assert-True -Condition ($tmpl -match '(?m)^XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION=v6\s*$') -Message 'approved-card seed must pin STYLESHEET v6 on XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION.'
Assert-True -Condition ($tmpl -match 'XDISPLAY_AI_SKETCH_VISION_TIMEOUT_SECONDS=90') -Message 'approved-card seed must keep 90s sketch vision timeout.'
$truncatedProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable (Get-S63fRejectedTruncatedPromptVersionPins) -DefaultTable (Get-S63fSettingsDefaultPromptVersionTable))
Assert-True -Condition ($truncatedProblems.Count -ge 28) -Message 'The a62 crash table must still fail registry-shape checks (missing 26 agents plus PAGE_HTML/STYLESHEET aliases).'
Assert-True -Condition (($truncatedProblems -join ' ') -match 'PAGE_HTML') -Message 'Registry-shape checks must reject PAGE_HTML as a non-directory agent alias.'
Assert-True -Condition (($truncatedProblems -join ' ') -match 'STYLESHEET') -Message 'Registry-shape checks must reject STYLESHEET as a non-directory agent alias.'

Assert-True -Condition ((Get-ApprovedBackendRevisionPrefix) -eq '623b07232') -Message 'Approved backend tip is 623b07232 / prod/s63i-hf2, not HEAD.'
Assert-True -Condition ((Get-ApprovedBackendRevisionFull) -eq '623b072320d2e8c68059ec5e7e33958267203a9c') -Message 'Approved backend full revision is 623b072320d2e8c68059ec5e7e33958267203a9c.'
Assert-True -Condition ((Get-ApprovedBackendTag) -eq 'prod/s63i-hf2') -Message 'Approved backend Git tag must be prod/s63i-hf2 (card name s63i-hf2b is not a Git tag).'
Assert-True -Condition ((Get-ApprovedBackendTag) -ne 'prod/s63i-hf2b') -Message 'Must not accept invented Git tag prod/s63i-hf2b.'
Assert-True -Condition ((Get-ApprovedXdisplaySubmoduleCommit) -eq '0c657ad3eac7ece814206bd40fea807ec6568f81') -Message 'xd_render_cli submodule source is 0c657ad3; Linux ELF is built in qt_builder.'
Assert-True -Condition ((Get-S63fPlaywrightVersion) -eq '1.56.0') -Message 'approved-card runtime image pins playwright 1.56.0.'
Assert-True -Condition ((Get-S63fChromiumRevision) -eq '1194') -Message 'approved-card runtime image pins Chromium 1194.'
Assert-True -Condition ((Get-S63fExportMachOXdRenderCliBytes) -eq 0) -Message 'Mach-O leftover identity is pending until the sanitized source archive exists; it must not be a required Linux ELF pin.'
Assert-True `
    -Condition ([string]::IsNullOrWhiteSpace((Get-S63fExportMachOXdRenderCliSha256))) `
    -Message 'Mach-O leftover SHA is pending; do not invent or require a cached Linux ELF pin.'
Assert-True `
    -Condition ((Get-ForbiddenS63fAppImageSha256) -eq 'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309') `
    -Message 'The previous 0.1.4 app tar F3EECC91... must be forbidden as an s63f image.'
Assert-True `
    -Condition ((((Get-S63fMigrationFileNames) -join ',') -eq '0001_init.sql,0002_rag.sql,0003_orch_runtime.sql')) `
    -Message 'approved card ships migrations 0001-0003 only; no new data migration.'

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

$pinPath = Join-Path $PackagingRoot 'manifests\pins\offline-inputs.s63i-hf2b.json'
Assert-True -Condition (Test-Path -LiteralPath $pinPath) -Message 's63i-hf2b pin manifest is missing.'
$pins = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
Assert-True -Condition ($pins.backend.requiredRevisionPrefix -eq '623b07232') -Message 's63i-hf2b pin manifest must require 623b07232, not HEAD.'
Assert-True -Condition ($pins.backend.requiredTag -eq 'prod/s63i-hf2') -Message 'Pin manifest requiredTag must be verified Git tag prod/s63i-hf2, not an invented hf2b tag.'
Assert-True -Condition ($pins.backend.sourceArchiveSha256 -eq '68B6E331A6942A9CBDE6FDDFA7579E1AD8227B57C1D05E0D6C724F32A8317278') -Message 'Pin manifest must record verified sanitized source archive SHA.'
Assert-True -Condition ($pins.backend.runtimeFingerprintInputs -contains 'docker/strict-ocr/fetch_models.py') -Message 'Pin manifest fingerprint inputs must include strict-ocr fetch_models.py.'
Assert-True -Condition ($pins.backend.forbiddenAppImageSha256 -eq 'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309') -Message 's63i-hf2b pin manifest must forbid the previous app tar hash.'
Assert-True -Condition ($pins.promptPins -eq (Get-S63fRegisteredPromptVersionTable)) -Message 's63i-hf2b pin manifest promptPins must be the full registered-agent table, not the truncated author-card replacement.'
Assert-True -Condition ($pins.rejectedTruncatedPromptPins -eq (Get-S63fRejectedTruncatedPromptVersionPins)) -Message 's63i-hf2b pin manifest must record the a62 crash table as rejected.'
Assert-True -Condition ($pins.browserSolverPageHtmlPromptVersion -eq 'v20') -Message 's63i-hf2b pin manifest must pin PAGE_HTML v20 on the browser-solver Settings field.'
Assert-True -Condition ($pins.browserSolverEngineeringStylesheetContractVersion -eq 'v6') -Message 's63i-hf2b pin manifest must pin STYLESHEET on the engineering stylesheet Settings field.'
Assert-True -Condition ($pins.client.notAuthorC180MailBytes -eq $true) -Message 'Client pins must be recorded as Word-fix supersets, not literal c180 mail bytes.'
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$pins.client.sha256)) -Message 'Windows c186 client SHA must remain pending until the real Windows release hash exists.'
Assert-True -Condition ($pins.converter.sha256 -eq 'F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36') -Message 'Word-fix Converter SHA must be retained.'
Assert-True -Condition ($pins.backend.linuxRenderCli.exportBinary.required -eq $false) -Message 'Mach-O leftover must not be a required Linux ELF pin.'
Assert-True -Condition ($pins.backend.runtimeImage.playwright -eq '1.56.0') -Message 'Pin manifest must record playwright 1.56.0.'
Assert-True -Condition ($pins.backend.skipBackendImageBuild -match 'invalid') -Message 'Pin manifest must record SkipBackendImageBuild as invalid from-source.'

$pendingPinsRejected = $false
try {
    Assert-ApprovedCardPinsReady -PinManifestPath $pinPath
}
catch {
    $pendingPinsRejected = $_.Exception.Message -match 'pending' -or $_.Exception.Message -match 'incomplete'
}
Assert-True -Condition $pendingPinsRejected -Message 'Assert-ApprovedCardPinsReady must fail closed while Windows c186 / image hashes are pending.'
Assert-True -Condition ((Get-PinnedClientTag) -eq 'client/c-186') -Message 'Pinned client tag must be client/c-186.'
Assert-True -Condition ((Get-PinnedClientGitCommit) -eq '1898d30cc036241f5af5283c4dc9d7f95dbb8887') -Message 'Pinned client commit must be c-186 1898d30c.'
Assert-True -Condition ((Get-ForbiddenMacClientSha256) -eq 'AFDE40DBC47A1680A053FA9AD63E0532CD4A893824BB58E162FCDC2AD905E71F') -Message 'Mac c186 SHA must be recorded as forbidden for Windows pins.'

$entrypoint = Get-Content -LiteralPath (Join-Path $PackagingRoot 'build-offline-package.ps1') -Raw
Assert-True -Condition ($entrypoint -match 'offline-inputs\.s63i-hf2b\.json') -Message 'Cached installer rebuild must default to the s63i-hf2b pin manifest, not the stale F3EECC91 / s63f pins.'
Assert-True -Condition ($entrypoint -match 'Assert-S63fBackendInputs' -or $entrypoint -match 'forbiddenAppImageSha256' -or $entrypoint -match 'Assert-ExistingBackendInputs') -Message 'Cached mode must keep approved-card source/image gates.'

$prepareInputs = Get-Content -LiteralPath (Join-Path $PackagingRoot 'ci\prepare-inputs.ps1') -Raw
Assert-True -Condition ($prepareInputs -match 'SOURCE_REVISION.txt') -Message 'Backend source snapshot must record SOURCE_REVISION.txt for approved-card provenance.'
Assert-True -Condition ($prepareInputs -match 'Get-ApprovedBackendCardName' -or $prepareInputs -match 'SkipBackendImageBuild is invalid') -Message 'prepare-inputs must refuse unproven SkipBackendImageBuild instead of tagging an old runtime-cache.'
Assert-True -Condition ($entrypoint -match 'Assert-SkipBackendImageBuildFromSource') -Message 'Cached entrypoint must refuse SkipBackendImageBuild unless UseExistingBackendInputs follows a sanctioned rebuild.'

$fingerprintPaths = @(Get-OrchestrationAppRuntimeFingerprintPaths)
foreach ($legacyPath in @(Get-ForbiddenLegacyOrchestrationRuntimeFingerprintPaths)) {
    Assert-True -Condition ($fingerprintPaths -notcontains $legacyPath) -Message "Runtime fingerprint must not require nonexistent $legacyPath"
}
Assert-True -Condition ($fingerprintPaths -contains 'Dockerfile') -Message 'Fingerprint must include Dockerfile (Qt6/pip/playwright pins).'
Assert-True -Condition ($fingerprintPaths -contains 'pyproject.toml') -Message 'Fingerprint must include pyproject.toml.'
Assert-True -Condition ($fingerprintPaths -contains '.dockerignore') -Message 'Fingerprint must include .dockerignore (uv.lock ignored).'
Assert-True -Condition ($fingerprintPaths -contains 'external\xdisplay\bin\xd_render_cli\main.cpp') -Message 'Fingerprint must include xd_render_cli source, not a cached ELF.'
Assert-True -Condition ($fingerprintPaths -contains 'docker\strict-ocr\fetch_models.py') -Message 'Fingerprint must include docker/strict-ocr fetch_models.py for prod/s63i-hf2.'
Assert-True -Condition ($fingerprintPaths -contains 'docker\strict-ocr\model-manifest.json') -Message 'Fingerprint must include docker/strict-ocr model-manifest.json.'
Assert-True -Condition ($fingerprintPaths -contains 'docker\strict-ocr\LICENSE-APACHE-2.0.txt') -Message 'Fingerprint must include docker/strict-ocr LICENSE.'
Assert-True -Condition ($fingerprintPaths -contains 'docker\strict-ocr\NOTICE.md') -Message 'Fingerprint must include docker/strict-ocr NOTICE.'
Assert-True -Condition ((@(Get-ForbiddenLegacyOrchestrationRuntimeFingerprintPaths) -notcontains 'docker\strict-ocr')) -Message 'docker/strict-ocr must not be listed as a forbidden legacy fingerprint path.'
Assert-True -Condition ((Get-ApprovedS63fSourceArchiveSha256) -eq '68B6E331A6942A9CBDE6FDDFA7579E1AD8227B57C1D05E0D6C724F32A8317278') -Message 'Verified sanitized source archive SHA must be pinned.'
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
Assert-True -Condition $skipFromSourceRejected -Message 'From-source SkipBackendImageBuild must fail closed for the approved card.'
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
        $strict = Join-Path $SourceRoot 'docker\strict-ocr'
        New-Item -ItemType Directory -Path $strict -Force | Out-Null
        foreach ($name in @('LICENSE-APACHE-2.0.txt', 'NOTICE.md', 'fetch_models.py', 'model-manifest.json')) {
            [System.IO.File]::WriteAllText((Join-Path $strict $name), $name)
        }
    }

    $staleRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $pinPath | Out-Null
    }
    catch {
        $staleRejected = $_.Exception.Message -match 'F3EECC91' -or $_.Exception.Message -match 'SOURCE_REVISION' -or $_.Exception.Message -match 's63i-hf2b' -or $_.Exception.Message -match 's63f'
    }
    Assert-True -Condition $staleRejected -Message 'approved-card input gate must fail closed without SOURCE_REVISION and without a rebuilt app image.'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_REVISION.txt'), "deadbeef`n")
    $wrongRevRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $pinPath | Out-Null
    }
    catch {
        $wrongRevRejected = $_.Exception.Message -match '623b07232'
    }
    Assert-True -Condition $wrongRevRejected -Message 'SOURCE_REVISION that is not 623b07232 must be rejected (no HEAD, no stale snapshot).'

    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_REVISION.txt'), "623b072320d2e8c68059ec5e7e33958267203a9c`n")
    [System.IO.File]::WriteAllText((Join-Path $testRoot 'backend\source\SOURCE_TAG.txt'), "prod/s63i-hf2`n")
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
    $localManifestPath = Join-Path $testRoot 'local-s63i-hf2b.json'
    $localManifest = Get-Content -LiteralPath $pinPath -Raw | ConvertFrom-Json
    $localManifest.backend.forbiddenAppImageSha256 = $localForbidden
    # Fixture stubs are 4-byte placeholders; this unit covers SOURCE_REVISION/inspect gates, not prereq byte pins.
    foreach ($entry in @($localManifest.files)) {
        if ($null -eq $entry) { continue }
        $entry | Add-Member -NotePropertyName assertSha256 -NotePropertyValue $false -Force
    }
    $localManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $localManifestPath
    $forbiddenRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
    }
    catch {
        $forbiddenRejected = $_.Exception.Message -match 'forbidden' -or $_.Exception.Message -match 'F3EECC91' -or $_.Exception.Message -match 'rename'
    }
    Assert-True -Condition $forbiddenRejected -Message 'An app image whose hash is the forbidden previous tar must not be accepted as s63i-hf2b.'

    [System.IO.File]::WriteAllBytes($appTar, [byte[]](9, 9, 9, 9, 9))
    $missingInspectRejected = $false
    try {
        Assert-ExistingBackendInputs -InputsRoot $testRoot -PinManifestPath $localManifestPath | Out-Null
    }
    catch {
        $missingInspectRejected = $_.Exception.Message -match 'inspect'
    }
    Assert-True -Condition $missingInspectRejected -Message 'approved-card app tar requires companion docker inspect JSON; renaming a tar is not proof.'

    $fingerprint = Get-SourceContentFingerprint -Root $sourceRoot -RelativePaths @(Get-OrchestrationAppRuntimeFingerprintPaths)
    $inspectObject = [pscustomobject]@{
        Id = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        RepoTags = @('orches/orchestration-app:s63i-hf2b-623b07232', 'orches/orchestration-app:latest')
        Config = [pscustomobject]@{
            Labels = [pscustomobject]@{
                'xdisplayai.packaging.git-sha' = '623b072320d2e8c68059ec5e7e33958267203a9c'
                'xdisplayai.packaging.tag' = 'prod/s63i-hf2'
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

Write-Output 'PASS: s63i-hf2b packaging contract'
exit 0
