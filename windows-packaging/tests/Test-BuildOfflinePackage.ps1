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

function Write-EmptyFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, '')
}

function New-SourceFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $backendRoot = Join-Path $Root 'backend'
    $xdisplayRoot = Join-Path $Root 'xdisplay'
    $prerequisitesRoot = Join-Path $Root 'prerequisites'

    foreach ($relativePath in @(
        'Dockerfile',
        'Dockerfile.embedding',
        'docker-compose.yml',
        'db/migrations/0001_init.sql',
        'data/chunks/component_capabilities_v1.jsonl',
        'external/xdisplay/bin/xd_render_cli/xd_render_cli.pro'
    )) {
        Write-EmptyFile -Path (Join-Path $backendRoot $relativePath)
    }

    foreach ($relativePath in @(
        'src/Xdisplay_V2.pro',
        'src/Service_PB/compile_all_proto.bat',
        'src/Service_Caesium/caesium/caesium.dll',
        'src/Service_PackL/res/UpdateUnpack.exe'
    )) {
        Write-EmptyFile -Path (Join-Path $xdisplayRoot $relativePath)
    }

    foreach ($relativePath in @(
        'docker-desktop/Docker Desktop Installer.exe',
        'vcredist/VC_redist.x64.exe',
        'wsl/wsl_update_x64.msi'
    )) {
        Write-EmptyFile -Path (Join-Path $prerequisitesRoot $relativePath)
    }

    return [pscustomobject]@{
        BackendRoot = $backendRoot
        XdisplayRoot = $xdisplayRoot
        PrerequisitesRoot = $prerequisitesRoot
    }
}

function Invoke-Preflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Fixture,
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScriptPath `
            -BackendRepoPath $Fixture.BackendRoot `
            -XdisplayRepoPath $Fixture.XdisplayRoot `
            -PrerequisitesSourceRoot $Fixture.PrerequisitesRoot `
            -ReportPath $ReportPath `
            -PreflightOnly 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $output
    }
}

$scriptPath = Join-Path $PackagingRoot 'build-offline-package.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xdisplayai-build-script-test-' + [System.Guid]::NewGuid().ToString('N'))

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    . (Join-Path $PackagingRoot 'ci\Common.ps1')

    $bundleManifest = Get-BundleManifest
    Assert-True `
        -Condition ($bundleManifest.paths.backendSourceDir -eq 'inputs/backend/source') `
        -Message 'The development package manifest must define inputs/backend/source.'

    $inputLayout = Get-InputLayout
    Assert-True `
        -Condition ($inputLayout.BackendSourceDir.EndsWith('inputs\backend\source')) `
        -Message 'The input layout must expose the backend source snapshot directory.'

    $runtimeFingerprintFixture = Join-Path $testRoot 'runtime-fingerprint'
    Write-EmptyFile -Path (Join-Path $runtimeFingerprintFixture 'Dockerfile')
    Write-EmptyFile -Path (Join-Path $runtimeFingerprintFixture 'external\xdisplay\bin\xd_render_cli\renderer.cpp')
    Write-EmptyFile -Path (Join-Path $runtimeFingerprintFixture 'app\main.py')
    $runtimeFingerprintBefore = Get-SourceContentFingerprint `
        -Root $runtimeFingerprintFixture `
        -RelativePaths @('Dockerfile', 'external\xdisplay\bin\xd_render_cli')
    [System.IO.File]::WriteAllText((Join-Path $runtimeFingerprintFixture 'app\main.py'), 'source-only change')
    $runtimeFingerprintAfterAppChange = Get-SourceContentFingerprint `
        -Root $runtimeFingerprintFixture `
        -RelativePaths @('Dockerfile', 'external\xdisplay\bin\xd_render_cli')
    Assert-True `
        -Condition ($runtimeFingerprintBefore -eq $runtimeFingerprintAfterAppChange) `
        -Message 'Application-only changes must not invalidate the backend runtime dependency cache.'
    [System.IO.File]::WriteAllText(
        (Join-Path $runtimeFingerprintFixture 'external\xdisplay\bin\xd_render_cli\renderer.cpp'),
        'runtime dependency change'
    )
    $runtimeFingerprintAfterRuntimeChange = Get-SourceContentFingerprint `
        -Root $runtimeFingerprintFixture `
        -RelativePaths @('Dockerfile', 'external\xdisplay\bin\xd_render_cli')
    Assert-True `
        -Condition ($runtimeFingerprintBefore -ne $runtimeFingerprintAfterRuntimeChange) `
        -Message 'Native renderer changes must invalidate the backend runtime dependency cache.'

    $matchingCacheDecision = Get-BackendRuntimeCacheDecision `
        -ImageExists $true `
        -ExpectedFingerprint $runtimeFingerprintBefore `
        -CachedFingerprint $runtimeFingerprintBefore
    Assert-True -Condition ($matchingCacheDecision -eq 'reuse') -Message 'A runtime image with the exact dependency fingerprint must be reused.'
    $mismatchedCacheDecision = Get-BackendRuntimeCacheDecision `
        -ImageExists $true `
        -ExpectedFingerprint $runtimeFingerprintBefore `
        -CachedFingerprint $runtimeFingerprintAfterRuntimeChange
    Assert-True -Condition ($mismatchedCacheDecision -eq 'refresh') -Message 'A stale runtime dependency image must trigger a full refresh.'
    $missingCacheDecision = Get-BackendRuntimeCacheDecision `
        -ImageExists $false `
        -ExpectedFingerprint $runtimeFingerprintBefore `
        -CachedFingerprint ''
    Assert-True -Condition ($missingCacheDecision -eq 'refresh') -Message 'A missing runtime dependency image must trigger a full refresh.'

    $jsonArrayFixturePath = Join-Path $testRoot 'json-array-fixture.json'
    [System.IO.File]::WriteAllText(
        $jsonArrayFixturePath,
        '[{"relativePath":"first.cab"},{"relativePath":"second.cab"}]'
    )
    $jsonArrayEntries = @(Read-JsonArrayFile -Path $jsonArrayFixturePath)
    Assert-True -Condition ($jsonArrayEntries.Count -eq 2) -Message 'A top-level JSON array must expand into individual manifest entries on Windows PowerShell 5.'
    Assert-True -Condition ($jsonArrayEntries[0].relativePath -eq 'first.cab') -Message 'The first expanded JSON manifest entry is incorrect.'
    Assert-True -Condition ($jsonArrayEntries[1].relativePath -eq 'second.cab') -Message 'The second expanded JSON manifest entry is incorrect.'
    $failingDockerProbe = Join-Path $testRoot 'docker-not-ready.cmd'
    [System.IO.File]::WriteAllText(
        $failingDockerProbe,
        "@echo off`r`necho docker daemon not ready 1>&2`r`nexit /b 1`r`n"
    )
    $probeThrew = $false
    try {
        $dockerReady = Test-DockerDaemonReady -DockerPath $failingDockerProbe
    }
    catch {
        $probeThrew = $true
        $dockerReady = $false
    }
    Assert-True -Condition (-not $probeThrew) -Message 'Docker readiness probe must not throw when docker info writes to stderr.'
    Assert-True -Condition (-not $dockerReady) -Message 'Docker readiness probe must return false for a non-zero docker info exit code.'

    $warningTool = Join-Path $testRoot 'warning-success.cmd'
    [System.IO.File]::WriteAllText($warningTool, "@echo off`r`necho compiler warning 1>&2`r`nexit /b 0`r`n")
    $warningCommandThrew = $false
    $warningToolLog = Join-Path $testRoot 'warning-success.log'
    try {
        Invoke-CheckedNativeCommand `
            -FilePath $warningTool `
            -LogPath $warningToolLog `
            -FailureMessage 'Warning-only command failed.'
    }
    catch {
        $warningCommandThrew = $true
    }
    Assert-True -Condition (-not $warningCommandThrew) -Message 'A native command that writes to stderr but exits 0 must succeed.'
    Assert-True -Condition ((Get-Content $warningToolLog -Raw) -match 'compiler warning') -Message 'Native stderr was not preserved in the command log.'

    $failingTool = Join-Path $testRoot 'checked-command-failure.cmd'
    [System.IO.File]::WriteAllText($failingTool, "@echo off`r`nexit /b 7`r`n")
    $nonzeroCommandRejected = $false
    try {
        Invoke-CheckedNativeCommand -FilePath $failingTool -FailureMessage 'Expected checked failure.'
    }
    catch {
        $nonzeroCommandRejected = $_.Exception.Message -match 'Expected checked failure.*exit code 7'
    }
    Assert-True -Condition $nonzeroCommandRejected -Message 'A native command with a non-zero exit code must fail with the exact exit code.'

    $systemSessionRejected = $false
    try {
        Assert-CanStartDockerDesktop -IdentityName 'NT AUTHORITY\SYSTEM'
    }
    catch {
        $systemSessionRejected = $_.Exception.Message -match 'interactive Windows user session'
    }
    Assert-True -Condition $systemSessionRejected -Message 'SYSTEM must be rejected when Docker Desktop needs an interactive session.'
    Assert-CanStartDockerDesktop -IdentityName 'WORKGROUP\molc'

    $displayLabel = [string]::Concat(
        [char]0x4F4D,
        [char]0x7F6E,
        [char]0xFF1A
    )
    $batchContentForUnattendedRun = "@echo off`necho ${displayLabel}src\Service_PB\proto_generated\`nprotoc.exe input.proto`npause`nexit /b 1`n"
    $unattendedBatchContent = Convert-BatchContentForUnattendedRun -Content $batchContentForUnattendedRun
    Assert-True -Condition ($unattendedBatchContent -match 'echo src\\Service_PB\\proto_generated\\') -Message 'Non-ASCII display text should be removed from the temporary batch copy.'
    Assert-True -Condition ($unattendedBatchContent -match '(?m)^protoc\.exe input\.proto\r?$') -Message 'Executable batch commands must be preserved.'
    Assert-True -Condition ($unattendedBatchContent -notmatch '(?im)^\s*pause\s*$') -Message 'Interactive pause must be disabled in the temporary batch copy.'
    Assert-True -Condition ($unattendedBatchContent -match '(?m)^exit /b 1\r?$') -Message 'Explicit failure exits must be preserved.'

    $lfBatchPath = Join-Path $testRoot 'utf8-lf-source.bat'
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $lfBatchContent = "@echo off`nchcp 65001 >nul`necho proto build complete`necho location: src\\Service_PB\\proto_generated\\`nexit /b 0`n"
    [System.IO.File]::WriteAllText($lfBatchPath, $lfBatchContent, $utf8NoBom)
    $batchExitCode = Invoke-NormalizedBatchFile -BatchPath $lfBatchPath -WorkingDirectory $testRoot
    Assert-True -Condition ($batchExitCode -eq 0) -Message "Expected normalized LF batch file to exit 0, got: $batchExitCode"

    $pathToolDirectory = Join-Path $testRoot 'path-tool-bin'
    New-Item -ItemType Directory -Path $pathToolDirectory -Force | Out-Null
    $pathOnlyTool = Join-Path $pathToolDirectory 'path-only-tool.cmd'
    [System.IO.File]::WriteAllText($pathOnlyTool, "@echo off`r`nexit /b 0`r`n")
    $pathDependentBatch = Join-Path $testRoot 'path-dependent-source.bat'
    [System.IO.File]::WriteAllText($pathDependentBatch, "@echo off`r`npath-only-tool.cmd`r`nexit /b %errorlevel%`r`n")
    $pathBeforeBatch = $env:Path
    $pathDependentExitCode = Invoke-NormalizedBatchFile `
        -BatchPath $pathDependentBatch `
        -WorkingDirectory $testRoot `
        -PathPrefixDirectory $pathToolDirectory
    Assert-True -Condition ($pathDependentExitCode -eq 0) -Message "Expected batch dependency to resolve from the temporary PATH prefix, got: $pathDependentExitCode"
    Assert-True -Condition ($env:Path -eq $pathBeforeBatch) -Message 'PATH was not restored after the normalized batch completed.'

    $secondPathToolDirectory = Join-Path $testRoot 'second-path-tool-bin'
    New-Item -ItemType Directory -Path $secondPathToolDirectory -Force | Out-Null
    $secondPathOnlyTool = Join-Path $secondPathToolDirectory 'second-path-only-tool.cmd'
    [System.IO.File]::WriteAllText($secondPathOnlyTool, "@echo off`r`nexit /b 0`r`n")
    $pathBeforeMultiPrefix = $env:Path
    Invoke-CheckedNativeCommand `
        -FilePath 'cmd.exe' `
        -ArgumentList @('/d', '/c', 'second-path-only-tool.cmd') `
        -PathPrefixDirectory "$pathToolDirectory;$secondPathToolDirectory" `
        -FailureMessage 'Multiple PATH prefix entries were not applied.'
    Assert-True -Condition ($env:Path -eq $pathBeforeMultiPrefix) -Message 'PATH was not restored after using multiple PATH prefix entries.'

    $qtQmlFixture = Join-Path $testRoot 'qt-qml-source'
    $qmlReleaseFixture = Join-Path $testRoot 'qml-release'
    Write-EmptyFile -Path (Join-Path $qtQmlFixture 'QtQuick\qmldir')
    Write-EmptyFile -Path (Join-Path $qmlReleaseFixture 'QtQuick\Controls.2\Action.qml')
    Write-EmptyFile -Path (Join-Path $qmlReleaseFixture 'platforms\qwindows.dll')
    Move-WinDeployQtQmlModules `
        -ReleaseDirectory $qmlReleaseFixture `
        -QtQmlSourceDirectory $qtQmlFixture
    Assert-True `
        -Condition (Test-Path (Join-Path $qmlReleaseFixture 'qml\QtQuick\Controls.2\Action.qml')) `
        -Message 'windeployqt QML modules must be moved under the release qml directory.'
    Assert-True `
        -Condition (-not (Test-Path (Join-Path $qmlReleaseFixture 'QtQuick'))) `
        -Message 'The top-level windeployqt QML module directory must not remain after normalization.'
    Assert-True `
        -Condition (Test-Path (Join-Path $qmlReleaseFixture 'platforms\qwindows.dll')) `
        -Message 'QML normalization must not move unrelated plugin directories.'

    $qtPluginsFixture = Join-Path $testRoot 'qt-plugins-source'
    Write-EmptyFile -Path (Join-Path $qtPluginsFixture 'platforms\qwindows.dll')
    Write-EmptyFile -Path (Join-Path $qmlReleaseFixture 'translations\qtbase_en.qm')
    Move-WinDeployQtPluginDirectories `
        -ReleaseDirectory $qmlReleaseFixture `
        -QtPluginsSourceDirectory $qtPluginsFixture
    Assert-True `
        -Condition (Test-Path (Join-Path $qmlReleaseFixture 'plugins\platforms\qwindows.dll')) `
        -Message 'windeployqt plugin directories must be moved under the release plugins directory.'
    Assert-True `
        -Condition (-not (Test-Path (Join-Path $qmlReleaseFixture 'platforms'))) `
        -Message 'The top-level windeployqt platform plugin directory must not remain after normalization.'
    Assert-True `
        -Condition (Test-Path (Join-Path $qmlReleaseFixture 'translations\qtbase_en.qm')) `
        -Message 'Plugin normalization must not move unrelated deployment directories.'

    $clientBuildScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'ci\build-xdisplay-from-source.ps1') -Raw
    Assert-True `
        -Condition ($clientBuildScriptContent -match "-ArgumentList @\('-f', 'Makefile\.Release', '-j'") `
        -Message 'Windows client compilation must use Makefile.Release to avoid the qmake regeneration loop.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'Remove-Item -Path \$sourceBinaryPath -Force') `
        -Message 'The stale source-tree Xdisplay.exe must be removed before compiling.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'Copy-Item -Path \$caesiumLinkSourcePath -Destination \$caesiumLinkDestinationPath -Force') `
        -Message 'The tracked caesium.dll must be staged into the source-copy bin directory before linking.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match '\$deploymentPathPrefix = "\$qmakeBinDirectory;\$mingwBinDirectory"') `
        -Message 'windeployqt must receive both the Qt and MinGW bin directories on PATH.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match '(?s)-FilePath \$resolvedWinDeployQtPath.*?-PathPrefixDirectory \$deploymentPathPrefix') `
        -Message 'The windeployqt invocation must use the deployment PATH prefix.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'Unable to find the platform plugin') `
        -Message 'The known Qt 5.15 plugin misclassification must have an exact-match fallback.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match "-ArgumentList @\('--debug', '--compiler-runtime'") `
        -Message 'The known windeployqt plugin misclassification fallback must retry debug matching.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'Move-WinDeployQtPluginDirectories') `
        -Message 'The client build must normalize windeployqt plugin directories.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'Plugins = plugins' -and $clientBuildScriptContent -match 'Qml2Imports = qml') `
        -Message 'qt.conf must explicitly point Qt at the normalized plugins and qml directories.'

    $prepareInputsScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'ci\prepare-inputs.ps1') -Raw
    Assert-True `
        -Condition ($prepareInputsScriptContent -match '--mount.*type=bind,source=\$BackendRepoPath,target=/app') `
        -Message 'The main backend smoke test must import current source through the development bind mount.'
    Assert-True `
        -Condition ($prepareInputsScriptContent -notmatch 'Build-BackendSourceOverlay|Add-OrchestrationAppDataLayer') `
        -Message 'Development backend images must not bake the current app/data source into an overlay layer.'
    Assert-True `
        -Condition ($prepareInputsScriptContent -match 'docker image tag.*RuntimeImageRef.*ImageRef') `
        -Message 'Dependency-only runtime-cache images must be tagged as the exported development images.'
    Assert-True `
        -Condition ($prepareInputsScriptContent -match 'inputs/backend/source' -and $prepareInputsScriptContent -match 'Sync-BackendSourceSnapshot') `
        -Message 'prepare-inputs must synchronize a backend source snapshot.'

    $stagePayloadScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'ci\stage-payload.ps1') -Raw
    Assert-True `
        -Condition ($stagePayloadScriptContent -match "seed[/\\]backend" -and $stagePayloadScriptContent -match "seed[/\\]client") `
        -Message 'The MSI payload must stage backend and client snapshots as mutable workspace seeds.'

    $commonInstallScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\common\Common.ps1') -Raw
    Assert-True `
        -Condition ($commonInstallScriptContent -match 'WorkspaceRoot\s*=\s*Join-Path\s+\$dataRoot\s+''workspace''') `
        -Message 'The installed state layout must define C:\ProgramData\XDisplayAI\workspace.'
    Assert-True `
        -Condition ($commonInstallScriptContent -match 'BackendWorkspace' -and $commonInstallScriptContent -match 'ClientWorkspace') `
        -Message 'The installed state layout must expose backend and client workspace directories.'
    Assert-True `
        -Condition ($commonInstallScriptContent -match 'Initialize-DevelopmentWorkspace') `
        -Message 'First bootstrap must initialize the mutable development workspace from immutable seeds.'

    $composeTemplateContent = Get-Content -Path (Join-Path $PackagingRoot 'src\templates\compose\compose.windows.yml.tmpl') -Raw
    Assert-True `
        -Condition (([regex]::Matches($composeTemplateContent, '\$\{BACKEND_WORKSPACE_PATH\}:/app')).Count -eq 2) `
        -Message 'Both Python services must bind-mount the backend workspace at /app.'
    Assert-True `
        -Condition ($composeTemplateContent -notmatch 'XDISPLAY_AI_LLM_API_KEY') `
        -Message 'Compose must not inject a server-side LLM API key.'

    $bootstrapScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\install\Bootstrap-InstalledPayload.ps1') -Raw
    Assert-True `
        -Condition ($bootstrapScriptContent -notmatch 'UseShellExecute\s*=\s*\$false') `
        -Message 'The client launcher must not let Xdisplay inherit the WiX QuietExec pipe handles.'
    Assert-True `
        -Condition ($bootstrapScriptContent -match '(?s)\$env:XDISPLAY_AI_BASE_URL\s*=\s*\$baseUrl.*?Start-Process.*?-FilePath\s+\$clientPath.*?finally\s*\{.*?\$env:XDISPLAY_AI_BASE_URL') `
        -Message 'The client must be launched with Start-Process and temporary inherited environment variables must be restored.'
    Assert-True `
        -Condition ($bootstrapScriptContent -match "Get-Process\s+-Name\s+'Xdisplay'" -and $bootstrapScriptContent -match 'XDisplay client is already running') `
        -Message 'The installed bootstrap must reuse an already-running single-instance XDisplay client.'
    Assert-True `
        -Condition ($bootstrapScriptContent -match '\$stateLayout\.ClientWorkspace') `
        -Message 'The bootstrap must launch XDisplay from the mutable ProgramData workspace.'

    $backendStartupTestContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\tests\Test-BackendStartupFlow.ps1') -Raw
    Assert-True `
        -Condition ($backendStartupTestContent -notmatch 'ExistingProcessIds') `
        -Message 'The post-install validator must accept a healthy existing XDisplay process after idempotent bootstrap.'
    Assert-True `
        -Condition ($backendStartupTestContent -match '\$stateLayout\.ClientWorkspace') `
        -Message 'The post-install validator must observe XDisplay in the mutable ProgramData workspace.'

    $backendInstallScriptContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1') -Raw
    Assert-True `
        -Condition ($backendInstallScriptContent -notmatch 'HasApiKey|ApiKeySource|未发现可用的 LLM API key') `
        -Message 'The installer must not warn about a missing server-side LLM key because the key is configured by the client.'

    $backendUpdateScriptPath = Join-Path $PackagingRoot 'src\scripts\update\Update-BackendSource.ps1'
    $clientUpdateScriptPath = Join-Path $PackagingRoot 'src\scripts\update\Update-XDisplayClient.ps1'
    Assert-True -Condition (Test-Path $backendUpdateScriptPath) -Message 'The backend source update entrypoint is missing.'
    Assert-True -Condition (Test-Path $clientUpdateScriptPath) -Message 'The XDisplay release update entrypoint is missing.'
    $backendUpdateScriptContent = Get-Content -Path $backendUpdateScriptPath -Raw
    Assert-True `
        -Condition ($backendUpdateScriptContent -match '(?s)/XF.*?\.env' -and $backendUpdateScriptContent -match "restart.*embedding-worker.*orchestration-app") `
        -Message 'Backend update must preserve .env and restart both Python services.'
    $clientUpdateScriptContent = Get-Content -Path $clientUpdateScriptPath -Raw
    Assert-True `
        -Condition ($clientUpdateScriptContent -match 'plugins\\platforms\\qwindows\.dll' -and $clientUpdateScriptContent -match "Join-Path.*'qml'") `
        -Message 'Client update must validate the complete Qt release before replacement.'

    $installedFixtureRoot = Join-Path $testRoot 'installed-development-layout'
    $installedDataRoot = Join-Path $testRoot 'program-data'
    Write-EmptyFile -Path (Join-Path $installedFixtureRoot 'seed\backend\app\main.py')
    [System.IO.File]::WriteAllText((Join-Path $installedFixtureRoot 'seed\backend\.env'), 'XDISPLAY_AI_ENVIRONMENT=dev')
    Write-EmptyFile -Path (Join-Path $installedFixtureRoot 'seed\client\Xdisplay.exe')
    $runtimeDefaultsFixturePath = Join-Path $installedFixtureRoot 'docker\env\runtime.defaults.env'
    Write-EmptyFile -Path $runtimeDefaultsFixturePath
    [System.IO.File]::WriteAllText(
        $runtimeDefaultsFixturePath,
        "APP_HOST_PORT=18001`r`nBACKEND_WORKSPACE_PATH=placeholder`r`n"
    )
    $installedMetadata = [pscustomobject]@{
        runtime = [pscustomobject]@{
            projectName = 'xdisplayai-test'
            dataRoot = $installedDataRoot
        }
    }
    $installedMetadataJson = $installedMetadata | ConvertTo-Json -Depth 4
    $installedMetadataPath = Join-Path $installedFixtureRoot 'metadata\bundle.json'
    New-Item -ItemType Directory -Path (Split-Path $installedMetadataPath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($installedMetadataPath, $installedMetadataJson)

    . (Join-Path $PackagingRoot 'src\scripts\common\Common.ps1')
    $originalInstallRoot = $script:InstallRoot
    $originalBundleMetadataCache = $script:BundleMetadataCache
    try {
        $script:InstallRoot = $installedFixtureRoot
        $script:BundleMetadataCache = $null
        $runtimeState = Initialize-RuntimeEnvironment
        Assert-True -Condition (Test-Path (Join-Path $runtimeState.BackendWorkspace 'app\main.py')) -Message 'Backend seed was not initialized into ProgramData workspace.'
        Assert-True -Condition (Test-Path (Join-Path $runtimeState.ClientWorkspace 'Xdisplay.exe')) -Message 'Client seed was not initialized into ProgramData workspace.'
        Assert-True -Condition (Test-Path (Join-Path $runtimeState.BackendWorkspace '.env')) -Message 'Backend .env was not initialized with the backend seed.'
        $runtimeEnvContent = Get-Content -Path $runtimeState.RuntimeEnvFile -Raw
        Assert-True -Condition ($runtimeEnvContent -match 'BACKEND_WORKSPACE_PATH=.*workspace/backend') -Message 'Compose runtime env does not use a forward-slash ProgramData backend path.'
        Assert-True -Condition ($runtimeEnvContent -notmatch 'LLM_API_KEY') -Message 'Compose runtime env unexpectedly contains a server-side LLM key setting.'

        $workspaceMainPath = Join-Path $runtimeState.BackendWorkspace 'app\main.py'
        [System.IO.File]::WriteAllText($workspaceMainPath, 'developer-update')
        [System.IO.File]::WriteAllText((Join-Path $installedFixtureRoot 'seed\backend\app\main.py'), 'new-seed')
        Initialize-DevelopmentWorkspace | Out-Null
        Assert-True -Condition ((Get-Content $workspaceMainPath -Raw) -eq 'developer-update') -Message 'Repeated bootstrap overwrote the mutable backend workspace.'
    }
    finally {
        $script:InstallRoot = $originalInstallRoot
        $script:BundleMetadataCache = $originalBundleMetadataCache
    }

    $windowsCompatibilityHeader = Join-Path $PackagingRoot 'compat\xdisplay-windows-posix-compat.h'
    Assert-True -Condition (Test-Path $windowsCompatibilityHeader) -Message 'Windows xdisplay compatibility header is missing.'
    Assert-True `
        -Condition ($clientBuildScriptContent -match 'QMAKE_CXXFLAGS\+=-include') `
        -Message 'qmake must force-include the Windows compatibility header.'
    $compatibilityProbeSource = Join-Path $testRoot 'windows-posix-compat-probe.cpp'
    $compatibilityProbeObject = Join-Path $testRoot 'windows-posix-compat-probe.o'
    [System.IO.File]::WriteAllText($compatibilityProbeSource, "int use_fsync(int descriptor) { return ::fsync(descriptor); }`r`n")
    Invoke-CheckedNativeCommand `
        -FilePath 'C:\Qt\Tools\mingw810_64\bin\g++.exe' `
        -ArgumentList @('-std=c++17', '-include', $windowsCompatibilityHeader, '-c', $compatibilityProbeSource, '-o', $compatibilityProbeObject) `
        -PathPrefixDirectory 'C:\Qt\Tools\mingw810_64\bin' `
        -FailureMessage 'Windows POSIX compatibility probe failed.'
    Assert-True -Condition (Test-Path $compatibilityProbeObject) -Message 'Windows POSIX compatibility probe did not create an object file.'

    $unicodeBatchPath = Join-Path $testRoot 'utf8-chinese-output.bat'
    $unicodeLocationLabel = [string]::Concat(
        [char]0x4F4D,
        [char]0x7F6E,
        [char]0xFF1A
    )
    $unicodeBatchContent = "@echo off`nchcp 65001 >nul`necho proto build complete`necho ${unicodeLocationLabel}src\Service_PB\proto_generated\`npause`n"
    [System.IO.File]::WriteAllText($unicodeBatchPath, $unicodeBatchContent, $utf8NoBom)
    $unicodeBatchExitCode = Invoke-NormalizedBatchFile -BatchPath $unicodeBatchPath -WorkingDirectory $testRoot
    Assert-True -Condition ($unicodeBatchExitCode -eq 0) -Message "Expected UTF-8 display text and terminal pause not to cause a false batch failure, got: $unicodeBatchExitCode"

    $temporaryBatchFiles = @(Get-ChildItem -Path $testRoot -Filter '.xdisplayai-*.cmd' -File -ErrorAction SilentlyContinue)
    Assert-True -Condition ($temporaryBatchFiles.Count -eq 0) -Message 'Normalized temporary batch file was not cleaned up.'

    $validFixture = New-SourceFixture -Root (Join-Path $testRoot 'valid')
    $validReportPath = Join-Path $testRoot 'valid-report.json'
    $validResult = Invoke-Preflight -ScriptPath $scriptPath -Fixture $validFixture -ReportPath $validReportPath

    Assert-True -Condition ($validResult.ExitCode -eq 0) -Message "Expected valid preflight to succeed. Output: $($validResult.Output)"
    Assert-True -Condition (Test-Path $validReportPath) -Message 'Expected valid preflight to create a JSON report.'

    $validReport = Get-Content -Path $validReportPath -Raw | ConvertFrom-Json
    Assert-True -Condition ($validReport.status -eq 'preflight_passed') -Message "Expected preflight_passed status, got: $($validReport.status)"
    Assert-True -Condition ($validReport.sources.backend.path -eq $validFixture.BackendRoot) -Message 'Backend source path was not recorded in the report.'
    Assert-True -Condition ($validReport.sources.xdisplay.path -eq $validFixture.XdisplayRoot) -Message 'Xdisplay source path was not recorded in the report.'

    $missingCorpusFixture = New-SourceFixture -Root (Join-Path $testRoot 'missing-corpus')
    Remove-Item -Path (Join-Path $missingCorpusFixture.BackendRoot 'data\chunks\component_capabilities_v1.jsonl') -Force
    $missingCorpusReportPath = Join-Path $testRoot 'missing-corpus-report.json'
    $missingCorpusResult = Invoke-Preflight -ScriptPath $scriptPath -Fixture $missingCorpusFixture -ReportPath $missingCorpusReportPath
    Assert-True -Condition ($missingCorpusResult.ExitCode -ne 0) -Message 'Expected backend source without component capability corpus to fail preflight.'
    $missingCorpusReport = Get-Content -Path $missingCorpusReportPath -Raw | ConvertFrom-Json
    Assert-True `
        -Condition ($missingCorpusReport.error -match 'component_capabilities_v1\.jsonl') `
        -Message "Expected missing component capability corpus in report error. Error: $($missingCorpusReport.error)"

    $invalidFixture = New-SourceFixture -Root (Join-Path $testRoot 'invalid')
    Remove-Item -Path (Join-Path $invalidFixture.BackendRoot 'Dockerfile.embedding') -Force
    $invalidReportPath = Join-Path $testRoot 'invalid-report.json'
    $invalidResult = Invoke-Preflight -ScriptPath $scriptPath -Fixture $invalidFixture -ReportPath $invalidReportPath

    Assert-True -Condition ($invalidResult.ExitCode -ne 0) -Message 'Expected incomplete backend source to fail preflight.'
    Assert-True -Condition (Test-Path $invalidReportPath) -Message 'Expected failed preflight to create a JSON report.'
    $invalidReport = Get-Content -Path $invalidReportPath -Raw | ConvertFrom-Json
    Assert-True -Condition ($invalidReport.status -eq 'failed') -Message "Expected failed status, got: $($invalidReport.status)"
    Assert-True -Condition ($invalidReport.error -match 'Dockerfile\.embedding') -Message "Expected missing Dockerfile.embedding in report error. Error: $($invalidReport.error)"

    Write-Host 'PASS: build-offline-package preflight behavior'
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force
    }
}

exit 0
