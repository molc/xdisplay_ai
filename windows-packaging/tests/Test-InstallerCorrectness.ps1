param(
    [string]$PackagingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$failed = 0
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Condition) {
        $script:passed++
        return
    }

    $script:failed++
    Write-Host "FAIL: $Message" -ForegroundColor Red
}

function Assert-Equal {
    param(
        $Expected,
        $Actual,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $equal = $false
    if ($null -eq $Expected -and $null -eq $Actual) {
        $equal = $true
    }
    elseif ($null -ne $Expected -and $null -ne $Actual) {
        $equal = [string]$Expected -eq [string]$Actual
    }

    Assert-True -Condition $equal -Message "$Message Expected=[$Expected] Actual=[$Actual]"
}

$commonScript = Join-Path $PackagingRoot 'src\scripts\common\Common.ps1'
$correctnessScript = Join-Path $PackagingRoot 'src\scripts\common\InstallerCorrectness.ps1'
Assert-True -Condition (Test-Path $correctnessScript) -Message 'InstallerCorrectness.ps1 must exist.'
. $correctnessScript
if (Test-Path $commonScript) {
    . $commonScript
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xdisplayai-correctness-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
    $noAutoReboot = Get-BootstrapRebootAction -RebootRequired $true -NoAutoReboot:$true -AutomaticRebootCount 0 -InstallerCustomAction:$true
    Assert-Equal -Expected 'persist-wait' -Actual $noAutoReboot.Name -Message 'MSI /norestart reboot-required must persist and wait.'
    Assert-True -Condition $noAutoReboot.Persist -Message 'NoAutoReboot must persist bootstrap state.'
    Assert-True -Condition $noAutoReboot.RegisterResumeTask -Message 'NoAutoReboot must register the resume task before returning.'
    Assert-True -Condition (-not $noAutoReboot.Throw) -Message 'NoAutoReboot must not throw; WixQuietExec maps throw to MSI 1603/Burn rollback.'
    Assert-True -Condition $noAutoReboot.ExitZero -Message 'NoAutoReboot must exit 0 so InstallFinalize stays committed.'
    Assert-True -Condition (-not $noAutoReboot.ClearState) -Message 'NoAutoReboot must not clear recovery state.'
    Assert-True -Condition (-not $noAutoReboot.UnregisterResumeTask) -Message 'NoAutoReboot must not unregister continuation.'
    Assert-True -Condition (-not $noAutoReboot.AutoReboot) -Message 'NoAutoReboot must not call shutdown.'
    Assert-Equal -Expected 1 -Actual $noAutoReboot.NextAutomaticRebootCount -Message 'Persist-wait must count the pending reboot so resume can ignore stale markers.'

    $autoReboot = Get-BootstrapRebootAction -RebootRequired $true -NoAutoReboot:$false -AutomaticRebootCount 0
    Assert-Equal -Expected 'persist-reboot' -Actual $autoReboot.Name -Message 'Launcher reboot-required must persist then automatically reboot.'
    Assert-True -Condition $autoReboot.AutoReboot -Message 'Launcher path may reboot only after durable continuation is saved.'
    Assert-True -Condition $autoReboot.ExitZero -Message 'Automatic reboot path must still exit 0 from the custom action/script.'

    $continueAction = Get-BootstrapRebootAction -RebootRequired $false
    Assert-Equal -Expected 'continue' -Actual $continueAction.Name -Message 'No reboot required must continue through local readiness.'

    $loopAction = Get-BootstrapRebootAction -RebootRequired $true -AutomaticRebootCount 2 -MaximumAutomaticReboots 2 -InstallerCustomAction:$true
    Assert-Equal -Expected 'abort-loop' -Actual $loopAction.Name -Message 'Reboot loop from MSI must not throw/rollback.'
    Assert-True -Condition $loopAction.Persist -Message 'Reboot loop must keep durable state for manual recovery.'
    Assert-True -Condition $loopAction.ExitZero -Message 'MSI custom action reboot-loop must exit 0 to keep payload installed.'
    Assert-True -Condition (-not $loopAction.Throw) -Message 'MSI custom action reboot-loop must not throw.'

    $feature = [pscustomobject]@{ Name = 'VirtualMachinePlatform' }
    Assert-Equal -Expected '' -Actual (Get-OptionalFeatureStateName -Feature $feature) -Message 'Optional feature objects without State must not throw under StrictMode.'
    $enabledFeature = [pscustomobject]@{ State = 'EnablePending' }
    Assert-Equal -Expected 'EnablePending' -Actual (Get-OptionalFeatureStateName -Feature $enabledFeature) -Message 'EnablePending must be readable as reboot-required, not as failure.'

    Assert-True -Condition (Test-IsSystemIdentity -IdentityName 'NT AUTHORITY\SYSTEM') -Message 'SYSTEM identity uses a single backslash.'
    Assert-True -Condition (-not (Test-IsSystemIdentity -IdentityName 'NT AUTHORITY\\SYSTEM')) -Message 'The two-backslash SYSTEM string must not match a Windows identity.'
    Assert-True -Condition (-not (Test-IsSystemIdentity -IdentityName 'DESKTOP-V8DI44I\molc')) -Message 'Interactive users are not SYSTEM.'

    $defaults = [ordered]@{
        APP_HOST_PORT = '18001'
        POSTGRES_HOST_PORT = '55432'
        REDIS_HOST_PORT = '56379'
        EMBEDDING_HOST_PORT = '18090'
        BACKEND_WORKSPACE_PATH = 'placeholder'
    }
    $existing = [ordered]@{
        APP_HOST_PORT = '18002'
        POSTGRES_HOST_PORT = '55432'
        REDIS_HOST_PORT = '56379'
        EMBEDDING_HOST_PORT = '18090'
        XDISPLAY_AI_LLM_PROVIDER = 'openai_compatible'
        XDISPLAY_AI_LLM_BASE_URL = 'https://example.invalid/v1'
        XDISPLAY_AI_LLM_MODEL_DEFAULT = 'kept-model'
        XDISPLAY_AI_ENVIRONMENT = 'prod'
        XDISPLAY_AI_LOG_LEVEL = 'INFO'
        XDISPLAY_AI_RAG_BACKEND = 'pgvector'
        XDISPLAY_AI_RAG_ACTIVE_INDEX_VERSION = 'v7'
        XDISPLAY_AI_RAG_EMBEDDING_VERSION = 'bge-m3@1.5'
        XDISPLAY_AI_SERVER_BASE_URL = 'http://127.0.0.1:18001'
        XDISPLAY_AI_LLM_API_KEY = 'should-not-be-logged'
        T203_UPGRADE_SENTINEL = 't203-offline-upgrade-20261109'
    }
    $merged = Merge-EnvEntries -Defaults $defaults -Existing $existing -ForceEntries @{
        APP_HOST_PORT = '18001'
        BACKEND_WORKSPACE_PATH = 'C:/ProgramData/XDisplayAI/workspace/backend'
    }
    Assert-Equal -Expected 't203-offline-upgrade-20261109' -Actual $merged['T203_UPGRADE_SENTINEL'] -Message 'Unknown nonsecret runtime keys must be preserved.'
    Assert-Equal -Expected 'should-not-be-logged' -Actual $merged['XDISPLAY_AI_LLM_API_KEY'] -Message 'Provider/secret keys must be preserved privately, not dropped.'
    Assert-Equal -Expected 'kept-model' -Actual $merged['XDISPLAY_AI_LLM_MODEL_DEFAULT'] -Message 'Old model setting must be preserved.'
    Assert-Equal -Expected '18001' -Actual $merged['APP_HOST_PORT'] -Message 'APP_HOST_PORT must be forced back to 18001 rather than keeping 18002 drift.'
    Assert-Equal -Expected 'C:/ProgramData/XDisplayAI/workspace/backend' -Actual $merged['BACKEND_WORKSPACE_PATH'] -Message 'Workspace path must be forced to the current layout.'
    foreach ($oldKey in @($existing.Keys)) {
        Assert-True -Condition $merged.Contains($oldKey) -Message "Merged runtime.env must retain old key $oldKey."
    }
    Assert-Equal -Expected '***REDACTED***' -Actual (Get-RedactedEnvValue -Name 'XDISPLAY_AI_LLM_API_KEY' -Value $merged['XDISPLAY_AI_LLM_API_KEY']) -Message 'Secret values must never be logged.'
    Assert-Equal -Expected 't203-offline-upgrade-20261109' -Actual (Get-RedactedEnvValue -Name 'T203_UPGRADE_SENTINEL' -Value $merged['T203_UPGRADE_SENTINEL']) -Message 'Nonsecret sentinels may be logged by name/value because they are not keys.'

    $legacyApp = Get-LegacyApplicationEnvEntries -RuntimeEntries $existing
    Assert-True -Condition $legacyApp.Contains('XDISPLAY_AI_LLM_PROVIDER') -Message 'Legacy XDISPLAY_AI_* keys must migrate into backend.env.'
    Assert-True -Condition (-not $legacyApp.Contains('T203_UPGRADE_SENTINEL')) -Message 'Compose-only sentinel stays in runtime.env; backend migration copies application keys.'
    Assert-True -Condition (-not $legacyApp.Contains('APP_HOST_PORT')) -Message 'Port keys are not application env keys.'

    $seedRoot = Join-Path $testRoot 'seed-client'
    $destRoot = Join-Path $testRoot 'workspace-client'
    $userProject = Join-InstallRelativePath -Root $destRoot -RelativePath 'user-projects/keep-me.txt'
    $seedExe = Join-InstallRelativePath -Root $seedRoot -RelativePath 'Xdisplay.exe'
    $destExe = Join-InstallRelativePath -Root $destRoot -RelativePath 'Xdisplay.exe'
    New-Item -ItemType Directory -Path (Split-Path $seedExe -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($seedExe, 'seed-v2')
    New-Item -ItemType Directory -Path (Split-Path $destExe -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($destExe, 'old-v1')
    New-Item -ItemType Directory -Path (Split-Path $userProject -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($userProject, 'user-bytes')
    $seedFp = Get-PathContentFingerprint -Root $seedRoot -RelativePaths @('Xdisplay.exe')
    $createDecision = Get-WorkspaceSyncDecision -Seed $seedRoot -Destination (Join-Path $testRoot 'missing-client') -RequiredRelativePath 'Xdisplay.exe' -CurrentSeedFingerprint $seedFp
    Assert-Equal -Expected 'create' -Actual $createDecision -Message 'Missing workspace must be created from seed.'
    $updateDecision = Get-WorkspaceSyncDecision -Seed $seedRoot -Destination $destRoot -RequiredRelativePath 'Xdisplay.exe' -LastSeedFingerprint 'old' -CurrentSeedFingerprint $seedFp
    Assert-Equal -Expected 'update' -Actual $updateDecision -Message 'Changed seed fingerprint must update shipped binaries instead of skipping because Xdisplay.exe exists.'
    $keepDecision = Get-WorkspaceSyncDecision -Seed $seedRoot -Destination $destRoot -RequiredRelativePath 'Xdisplay.exe' -LastSeedFingerprint $seedFp -CurrentSeedFingerprint $seedFp
    Assert-Equal -Expected 'keep' -Actual $keepDecision -Message 'Matching last-sync seed fingerprint must keep developer/user workspace files.'
    $incompleteRoot = Join-Path $testRoot 'incomplete-client'
    New-Item -ItemType Directory -Path $incompleteRoot -Force | Out-Null
    $repairDecision = Get-WorkspaceSyncDecision -Seed $seedRoot -Destination $incompleteRoot -RequiredRelativePath 'Xdisplay.exe' -CurrentSeedFingerprint $seedFp
    Assert-Equal -Expected 'repair' -Actual $repairDecision -Message 'Incomplete workspace missing the required file must repair from seed, not throw-and-stop.'

    Sync-WorkspaceTreeFromSeed -Seed $seedRoot -Destination $destRoot -PreserveRelativePaths @(Get-WorkspacePreserveRelativePaths)
    Assert-Equal -Expected 'seed-v2' -Actual ([System.IO.File]::ReadAllText($destExe)) -Message 'Update must replace stale shipped Xdisplay.exe from seed.'
    Assert-Equal -Expected 'user-bytes' -Actual ([System.IO.File]::ReadAllText($userProject)) -Message 'Update must preserve extra user project files.'

    $backendSeed = Join-Path $testRoot 'seed-backend'
    $backendDest = Join-Path $testRoot 'workspace-backend'
    $seedMain = Join-InstallRelativePath -Root $backendSeed -RelativePath 'app/main.py'
    $seedEnv = Join-InstallRelativePath -Root $backendSeed -RelativePath '.env'
    $destMain = Join-InstallRelativePath -Root $backendDest -RelativePath 'app/main.py'
    $destEnv = Join-InstallRelativePath -Root $backendDest -RelativePath '.env'
    New-Item -ItemType Directory -Path (Split-Path $seedMain -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($seedMain, 'new-main')
    [System.IO.File]::WriteAllText($seedEnv, 'XDISPLAY_AI_ENVIRONMENT=dev')
    New-Item -ItemType Directory -Path (Split-Path $destMain -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($destMain, 'old-main')
    [System.IO.File]::WriteAllText($destEnv, "XDISPLAY_AI_ENVIRONMENT=prod`nXDISPLAY_AI_LLM_API_KEY=keep-private")
    Sync-WorkspaceTreeFromSeed -Seed $backendSeed -Destination $backendDest -PreserveRelativePaths @(Get-WorkspacePreserveRelativePaths)
    Assert-Equal -Expected 'new-main' -Actual ([System.IO.File]::ReadAllText($destMain).Trim()) -Message 'Backend shipped source must update from seed when hashes differ.'
    Assert-True -Condition ([System.IO.File]::ReadAllText($destEnv) -match 'keep-private') -Message 'Existing backend .env must be preserved during seed sync.'

    $proxyEntries = ConvertTo-PortProxyListenEntries -Lines @(
        'Listen on ipv4:             Connect to ipv4:',
        '',
        'Address         Port        Address         Port',
        '--------------- ----------  --------------- ----------',
        '127.0.0.1       18001       172.19.103.18   18001'
    )
    Assert-True -Condition (Test-AppPortProxyPresent -Entries $proxyEntries -Port 18001) -Message 'Portproxy listen 18001 must be detected.'
    $httpOnly = Test-LocalBackendOrigin -HealthzStatus 200 -AssistantStatus 200 -PublishedBinding '127.0.0.1:18001' -ListenerProcess 'svchost' -PortProxyEntries $proxyEntries -RunningServices @() -DockerHost 'tcp://172.19.103.18:2375'
    Assert-True -Condition (-not $httpOnly.Ok) -Message 'HTTP 200 through a forward must not count as local backend success.'
    Assert-True -Condition ($httpOnly.Reasons.Count -ge 2) -Message 'False-local diagnosis must be actionable and mention more than one missing local proof.'

    $localOk = Test-LocalBackendOrigin `
        -HealthzStatus 200 `
        -AssistantStatus 200 `
        -PublishedBinding '127.0.0.1:18001' `
        -ListenerProcess 'com.docker.backend' `
        -PortProxyEntries @() `
        -RunningServices @(Get-RequiredComposeServiceNames) `
        -DockerHost 'npipe:////./pipe/dockerDesktopLinuxEngine' `
        -ServerOs 'linux' `
        -OperatingSystem 'Docker Desktop'
    Assert-True -Condition $localOk.Ok -Message 'Named-pipe Docker Desktop owning 18001 with four local services is local success.'

    Assert-True -Condition (Test-IsLocalDockerEngine -DockerHost 'npipe:////./pipe/dockerDesktopLinuxEngine' -ServerOs 'linux' -OperatingSystem 'Docker Desktop') -Message 'Docker Desktop Linux engine pipe is local.'
    Assert-True -Condition (-not (Test-IsLocalDockerEngine -DockerHost 'tcp://172.19.103.18:2375')) -Message 'Remote Docker host is not local.'

    $reused = Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree:$false -OwnedByLocalCompose:$true -PortProxyPresent:$false -ListenerProcess 'com.docker.backend'
    Assert-Equal -Expected 18001 -Actual $reused -Message 'Own compose stack may reuse 18001.'
    $freePort = Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree:$true -OwnedByLocalCompose:$false -PortProxyPresent:$false
    Assert-Equal -Expected 18001 -Actual $freePort -Message 'Free 18001 must stay 18001.'

    $foreignRejected = $false
    try {
        Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree:$false -OwnedByLocalCompose:$false -PortProxyPresent:$false -ListenerProcess 'python' | Out-Null
    }
    catch {
        $foreignRejected = $_.Exception.Message -match '18002' -and $_.Exception.Message -match 'python'
    }
    Assert-True -Condition $foreignRejected -Message 'Foreign occupier of 18001 must fail closed and mention that 18002 will not be used.'

    $proxyRejected = $false
    try {
        Resolve-AppHostPortContract -RequiredPort 18001 -LoopbackFree:$false -OwnedByLocalCompose:$false -PortProxyPresent:$true | Out-Null
    }
    catch {
        $proxyRejected = $_.Exception.Message -match 'portproxy'
    }
    Assert-True -Condition $proxyRejected -Message 'Portproxy on 18001 must fail closed.'

    $waitStatus = New-BoundedWaitStatus -Stage '等待 Docker Desktop 就绪' -Attempt 3 -MaxAttempts 12 -LastError 'named pipe not ready' -TimeoutSeconds 60
    Assert-True -Condition ($waitStatus -match '3/12' -and $waitStatus -match 'named pipe not ready' -and $waitStatus -match 'timeoutSec=60') -Message 'Bounded waits must log attempt, timeout and last error.'

    $inputsRoot = Join-Path $testRoot 'inputs'
    $missing = @(Get-MissingOfflineInputRelativePaths -InputsRoot $inputsRoot)
    Assert-True -Condition ($missing -contains 'prerequisites/docker-desktop/Docker Desktop Installer.exe') -Message 'Missing Docker Desktop installer must be reported by exact filename.'
    Assert-True -Condition ($missing -contains 'backend/images/orches_orchestration-app_latest.tar') -Message 'Missing orchestration image archive must be reported by exact filename.'
    Assert-Equal -Expected 7 -Actual $missing.Count -Message 'All four image archives plus VC/WSL/Docker Desktop are required.'

    $payload = Join-Path $testRoot 'VC_redist.x64.exe'
    [System.IO.File]::WriteAllText($payload, 'payload-bytes')
    $payloadHash = Convert-ToNormalizedSha512 -Value ((Get-FileHash -LiteralPath $payload -Algorithm SHA512).Hash)
    $payloadSize = [int64](Get-Item -LiteralPath $payload).Length
    $boundBundle = Join-Path $testRoot 'bound-bundle.exe'
    $unboundBundle = Join-Path $testRoot 'unbound-bundle.exe'
    [System.IO.File]::WriteAllText($boundBundle, "hdr$payloadHash tail")
    [System.IO.File]::WriteAllText($unboundBundle, 'hdr NOHASH tail')
    $boundManifest = Join-Path $testRoot 'bound-manifest.xml'
    $unboundManifest = Join-Path $testRoot 'unbound-manifest.xml'
    $boundXml = @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">
  <Payload Id="VcRedist" FilePath="VC_redist.x64.exe" FileSize="$payloadSize" Hash="$payloadHash" Packaging="external" SourcePath="VC_redist.x64.exe" />
</BurnManifest>
"@
    $unboundXml = @"
<?xml version="1.0" encoding="utf-8"?>
<BurnManifest xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">
  <Payload Id="UxTheme" FilePath="thm.xml" SourcePath="u0" />
</BurnManifest>
"@
    [System.IO.File]::WriteAllText($boundManifest, $boundXml)
    [System.IO.File]::WriteAllText($unboundManifest, $unboundXml)
    Assert-True -Condition (Test-BurnPayloadSha512Binding -BundlePath $boundBundle -PayloadPath $payload -ManifestXmlPath $boundManifest) -Message 'Burn binding check must accept a WiX 5 BurnManifest Hash that matches the adjacent payload.'
    Assert-True -Condition (-not (Test-BurnPayloadSha512Binding -BundlePath $unboundBundle -PayloadPath $payload -ManifestXmlPath $unboundManifest)) -Message 'Burn binding check must fail closed when BurnManifest has no external payload Hash.'
    Assert-True -Condition (-not (Test-BurnPayloadSha512Binding -BundlePath $boundBundle -PayloadPath $payload -ManifestXmlPath $unboundManifest)) -Message 'A raw EXE containing SHA512 hex is not a Burn binding without BurnManifest Hash attributes.'

    $secretHit = Test-SecretLikeValue -Value 'sk-live-examplekey'
    $placeholderMiss = Test-SecretLikeValue -Value '{{LLM_API_KEY}}'
    $emptyMiss = Test-SecretLikeValue -Value ''
    Assert-True -Condition $secretHit -Message 'Live-looking API keys must fail the secrets scan.'
    Assert-True -Condition (-not $placeholderMiss) -Message 'Template placeholders are not secrets.'
    Assert-True -Condition (-not $emptyMiss) -Message 'Empty values are not secrets.'

    $installedFixtureRoot = Join-Path $testRoot 'installed-layout'
    $installedDataRoot = Join-Path $testRoot 'program-data'
    $seedMain = Join-InstallRelativePath -Root $installedFixtureRoot -RelativePath 'seed/backend/app/main.py'
    $seedEnv = Join-InstallRelativePath -Root $installedFixtureRoot -RelativePath 'seed/backend/.env'
    $seedClient = Join-InstallRelativePath -Root $installedFixtureRoot -RelativePath 'seed/client/Xdisplay.exe'
    $runtimeDefaultsPath = Join-InstallRelativePath -Root $installedFixtureRoot -RelativePath 'docker/env/runtime.defaults.env'
    New-Item -ItemType Directory -Path (Split-Path $seedMain -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $seedClient -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $runtimeDefaultsPath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($seedMain, 'old-main')
    [System.IO.File]::WriteAllText($seedEnv, 'XDISPLAY_AI_ENVIRONMENT=dev')
    [System.IO.File]::WriteAllText($seedClient, 'client-v1')
    [System.IO.File]::WriteAllText($runtimeDefaultsPath, "APP_HOST_PORT=18001`nPOSTGRES_HOST_PORT=55432`nREDIS_HOST_PORT=56379`nEMBEDDING_HOST_PORT=18090`nBACKEND_WORKSPACE_PATH=placeholder`n")
    $installedMetadata = [pscustomobject]@{
        bundle = [pscustomobject]@{ version = '0.1.4' }
        runtime = [pscustomobject]@{
            projectName = 'xdisplayai-test'
            dataRoot = $installedDataRoot
        }
    }
    $installedMetadataPath = Join-InstallRelativePath -Root $installedFixtureRoot -RelativePath 'metadata/bundle.json'
    New-Item -ItemType Directory -Path (Split-Path $installedMetadataPath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($installedMetadataPath, ($installedMetadata | ConvertTo-Json -Depth 4))

    $originalInstallRoot = $script:InstallRoot
    $originalBundleMetadataCache = $script:BundleMetadataCache
    try {
        $script:InstallRoot = $installedFixtureRoot
        $script:BundleMetadataCache = $null
        $runtimeState = Initialize-RuntimeEnvironment
        $workspaceMainPath = Join-InstallRelativePath -Root $runtimeState.BackendWorkspace -RelativePath 'app/main.py'
        $userProjectPath = Join-InstallRelativePath -Root $runtimeState.BackendWorkspace -RelativePath 'user-projects/keep-me.txt'
        New-Item -ItemType Directory -Path (Split-Path $userProjectPath -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($userProjectPath, 'user-bytes')
        [System.IO.File]::WriteAllText($workspaceMainPath, 'developer-update')
        Initialize-DevelopmentWorkspace | Out-Null
        Assert-Equal -Expected 'developer-update' -Actual ([System.IO.File]::ReadAllText($workspaceMainPath)) -Message 'Same-seed relaunch must keep developer backend edits.'
        [System.IO.File]::WriteAllText($seedMain, 'new-seed')
        [System.IO.File]::WriteAllText($runtimeState.RuntimeEnvFile, (([System.IO.File]::ReadAllText($runtimeState.RuntimeEnvFile).TrimEnd()) + "`nT203_UPGRADE_SENTINEL=t203-offline-upgrade-20261109`nXDISPLAY_AI_LLM_MODEL_DEFAULT=kept-model`n"))
        $script:BundleMetadataCache = $null
        Initialize-RuntimeEnvironment | Out-Null
        Assert-Equal -Expected 'new-seed' -Actual ([System.IO.File]::ReadAllText($workspaceMainPath).Trim()) -Message 'Changed seed fingerprint must update shipped backend source.'
        Assert-Equal -Expected 'user-bytes' -Actual ([System.IO.File]::ReadAllText($userProjectPath)) -Message 'Seed update must keep extra user project files.'
        $runtimeAfter = Get-Content -Path $runtimeState.RuntimeEnvFile -Raw
        Assert-True -Condition ($runtimeAfter -match 'T203_UPGRADE_SENTINEL=t203-offline-upgrade-20261109') -Message 'Initialize-RuntimeEnvironment must preserve the upgrade sentinel.'
        Assert-True -Condition ($runtimeAfter -match 'XDISPLAY_AI_LLM_MODEL_DEFAULT=kept-model') -Message 'Initialize-RuntimeEnvironment must preserve provider/model settings.'
        Assert-True -Condition ($runtimeAfter -match 'APP_HOST_PORT=18001') -Message 'Initialize-RuntimeEnvironment must keep APP_HOST_PORT at 18001.'
    }
    finally {
        $script:InstallRoot = $originalInstallRoot
        $script:BundleMetadataCache = $originalBundleMetadataCache
    }

    $upgradeDataRoot = Join-Path $testRoot 'upgrade-010-data'
    $upgradeInstallRoot = Join-Path $testRoot 'upgrade-010-install'
    foreach ($relativePath in @('seed/backend/app/main.py', 'seed/backend/.env', 'seed/client/Xdisplay.exe', 'docker/env/runtime.defaults.env', 'metadata/bundle.json')) {
        $path = Join-InstallRelativePath -Root $upgradeInstallRoot -RelativePath $relativePath
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        if ($relativePath -eq 'seed/backend/.env') {
            [System.IO.File]::WriteAllText($path, "XDISPLAY_AI_ENVIRONMENT=dev`nXDISPLAY_AI_LLM_MODEL_DEFAULT=template-model`n")
        }
        elseif ($relativePath -eq 'docker/env/runtime.defaults.env') {
            [System.IO.File]::WriteAllText($path, "APP_HOST_PORT=18001`nBACKEND_WORKSPACE_PATH=placeholder`n")
        }
        elseif ($relativePath -eq 'metadata/bundle.json') {
            [System.IO.File]::WriteAllText($path, (@{ bundle = @{ version = '0.1.4' }; runtime = @{ projectName = 'xdisplayai-test'; dataRoot = $upgradeDataRoot } } | ConvertTo-Json -Depth 5))
        }
        else {
            [System.IO.File]::WriteAllText($path, 'seed')
        }
    }
    $oldRuntimePath = Join-InstallRelativePath -Root $upgradeDataRoot -RelativePath 'config/runtime.env'
    New-Item -ItemType Directory -Path (Split-Path $oldRuntimePath -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($oldRuntimePath, "APP_HOST_PORT=18001`nT203_UPGRADE_SENTINEL=t203-offline-upgrade-20261109`nXDISPLAY_AI_LLM_MODEL_DEFAULT=old-machine-model`n")
    $previousInstallRoot = $script:InstallRoot
    $previousBundleMetadataCache = $script:BundleMetadataCache
    try {
        $script:InstallRoot = $upgradeInstallRoot
        $script:BundleMetadataCache = $null
        $upgradeState = Initialize-RuntimeEnvironment
        $upgradeRuntime = Get-Content -Path $upgradeState.RuntimeEnvFile -Raw
        $upgradeBackend = Get-Content -Path (Join-InstallRelativePath -Root $upgradeState.BackendWorkspace -RelativePath '.env') -Raw
        Assert-True -Condition ($upgradeRuntime -match 'T203_UPGRADE_SENTINEL=t203-offline-upgrade-20261109') -Message '0.1.0-style runtime.env sentinel must survive first workspace create.'
        Assert-True -Condition ($upgradeBackend -match 'XDISPLAY_AI_LLM_MODEL_DEFAULT=old-machine-model') -Message 'Old runtime application settings must overlay seed backend.env when no previous workspace existed.'
    }
    finally {
        $script:InstallRoot = $previousInstallRoot
        $script:BundleMetadataCache = $previousBundleMetadataCache
    }

    $healDataRoot = Join-Path $testRoot 'heal-truncated-data'
    $healInstallRoot = Join-Path $testRoot 'heal-truncated-install'
    foreach ($relativePath in @('seed/backend/app/main.py', 'seed/backend/.env', 'seed/client/Xdisplay.exe', 'docker/env/runtime.defaults.env', 'metadata/bundle.json')) {
        $path = Join-InstallRelativePath -Root $healInstallRoot -RelativePath $relativePath
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        if ($relativePath -eq 'seed/backend/.env') {
            [System.IO.File]::WriteAllText($path, "XDISPLAY_AI_ENVIRONMENT=dev`nXDISPLAY_AI_PROMPT_VERSIONS=$(Get-S63fRegisteredPromptVersionTable)`n")
        }
        elseif ($relativePath -eq 'docker/env/runtime.defaults.env') {
            [System.IO.File]::WriteAllText($path, "APP_HOST_PORT=18001`nBACKEND_WORKSPACE_PATH=placeholder`n")
        }
        elseif ($relativePath -eq 'metadata/bundle.json') {
            [System.IO.File]::WriteAllText($path, (@{ bundle = @{ version = '0.1.4' }; runtime = @{ projectName = 'xdisplayai-test'; dataRoot = $healDataRoot } } | ConvertTo-Json -Depth 5))
        }
        else {
            [System.IO.File]::WriteAllText($path, 'seed')
        }
    }
    $healWorkspaceEnv = Join-InstallRelativePath -Root $healDataRoot -RelativePath 'workspace/backend/.env'
    $healWorkspaceMain = Join-InstallRelativePath -Root $healDataRoot -RelativePath 'workspace/backend/app/main.py'
    New-Item -ItemType Directory -Path (Split-Path $healWorkspaceEnv -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $healWorkspaceMain -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($healWorkspaceMain, 'seed')
    [System.IO.File]::WriteAllText(
        $healWorkspaceEnv,
        "T014_UPGRADE_SENTINEL=keep-t014`nXDISPLAY_AI_PROMPT_VERSIONS=$(Get-S63fRejectedTruncatedPromptVersionPins)`nXDISPLAY_AI_LOG_LEVEL=DEBUG`n"
    )
    $healPreviousInstallRoot = $script:InstallRoot
    $healPreviousBundleMetadataCache = $script:BundleMetadataCache
    try {
        $script:InstallRoot = $healInstallRoot
        $script:BundleMetadataCache = $null
        $healState = Initialize-RuntimeEnvironment
        $healedBackend = Get-Content -Path (Join-InstallRelativePath -Root $healState.BackendWorkspace -RelativePath '.env') -Raw
        Assert-True -Condition ($healedBackend -match 'T014_UPGRADE_SENTINEL=keep-t014') -Message 'Healing leftover truncated prompt_versions must preserve T014_UPGRADE_SENTINEL.'
        Assert-True -Condition ($healedBackend -match 'XDISPLAY_AI_LOG_LEVEL=DEBUG') -Message 'Healing leftover truncated prompt_versions must preserve unrelated user keys.'
        $healedTable = [regex]::Match($healedBackend, '(?m)^XDISPLAY_AI_PROMPT_VERSIONS=(?<value>[^\r\n]*)\s*$').Groups['value'].Value
        $healProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable $healedTable -DefaultTable (Get-S63fRegisteredPromptVersionTable))
        Assert-True -Condition ($healProblems.Count -eq 0) -Message ('Leftover a62 crash table must be healed before stack start: ' + ($healProblems -join '; '))
        Assert-True -Condition ($healedTable -notmatch 'PAGE_HTML') -Message 'Healed leftover env must drop PAGE_HTML from prompt_versions.'
        Assert-True -Condition ($healedBackend -match '(?m)^XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION=v19\s*$') -Message 'Healed leftover env must gain the PAGE_HTML Settings key when missing.'
        Assert-True -Condition ($healedBackend -match '(?m)^XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION=v6\s*$') -Message 'Healed leftover env must gain the STYLESHEET Settings key when missing.'
    }
    finally {
        $script:InstallRoot = $healPreviousInstallRoot
        $script:BundleMetadataCache = $healPreviousBundleMetadataCache
    }

    $hold = Test-WindowsAcceptanceEvidence -Evidence $null
    Assert-True -Condition (-not $hold.Ok) -Message 'Missing Windows evidence must fail closed and must not be treated as accepted.'
    $passEvidence = [pscustomobject]@{
        freshOfflineRebootResume = [pscustomobject]@{
            status = 'pass'
            localBackend = $true
            containers = 4
            appPort = 18001
            origin = 'local'
        }
        oldVersionPreservation = [pscustomobject]@{
            status = 'pass'
            configSentinel = $true
            projects = $true
            dbVolumes = $true
        }
    }
    $accepted = Test-WindowsAcceptanceEvidence -Evidence $passEvidence
    Assert-True -Condition $accepted.Ok -Message 'Complete Windows evidence may unlock Downloads publish.'
    $badPort = [pscustomobject]@{
        freshOfflineRebootResume = [pscustomobject]@{
            status = 'pass'
            localBackend = $true
            containers = 4
            appPort = 18002
            origin = 'local'
        }
        oldVersionPreservation = $passEvidence.oldVersionPreservation
    }
    $portHold = Test-WindowsAcceptanceEvidence -Evidence $badPort
    Assert-True -Condition (-not $portHold.Ok) -Message 'Windows evidence with 18002 drift must not publish.'

    $productWxs = Get-Content -Path (Join-Path $PackagingRoot 'src\wix\msi\Product.wxs') -Raw
    Assert-True -Condition ($productWxs -match '-LaunchClient -NoAutoReboot') -Message 'MSI custom action must pass -NoAutoReboot so /norestart is honored.'
    Assert-True -Condition ($productWxs -match 'WixQuietExecCmdTimeout') -Message 'QuietExec must have an explicit bounded timeout.'
    Assert-True -Condition ($productWxs -match 'NOT REMOVE=') -Message 'Bootstrap custom action must run on install/repair/upgrade, not only first-install NOT Installed.'

    $bootstrapContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\install\Bootstrap-InstalledPayload.ps1') -Raw
    Assert-True -Condition ($bootstrapContent -match 'NoAutoReboot') -Message 'Bootstrap must expose -NoAutoReboot.'
    Assert-True -Condition ($bootstrapContent -match 'Get-BootstrapRebootAction') -Message 'Bootstrap must use the durable reboot decision helper.'
    Assert-True -Condition ($bootstrapContent -notmatch 'Enable-RemoteDesktopAccess') -Message 'Release bootstrap must not enable RDP/firewall as a side effect.'
    Assert-True -Condition ($bootstrapContent -match 'Test-LocalBackendOrigin|Test-LocalBackendFullyReady') -Message 'Healthy-backend skip must require local origin, not HTTP 200 alone.'
    Assert-True -Condition ($bootstrapContent -match 'Test-LocalBackendSkipAllowed') -Message 'Healthy-backend skip must also require this package s63f image and prompt contract.'
    Assert-True -Condition ($bootstrapContent -match 'Test-InstalledBackendMatchesPackage') -Message 'Upgrade from a healthy older backend must inspect running image labels and prompt env before skipping payload apply.'

    $commonContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\common\Common.ps1') -Raw
    Assert-True -Condition ($commonContent -match 'Merge-EnvEntries') -Message 'Runtime env initialization must merge all existing keys.'
    Assert-True -Condition ($commonContent -match 'Get-WorkspaceSyncDecision') -Message 'Workspace initialization must be version/hash aware.'
    Assert-True -Condition ($commonContent -match 'Update-BackendPromptVersionPins') -Message 'Runtime init must heal leftover truncated XDISPLAY_AI_PROMPT_VERSIONS against the full s63f registry table.'
    Assert-True -Condition ($commonContent -match 'Ensure-BackendBrowserSolverPromptPins') -Message 'Runtime init must seed PAGE_HTML/STYLESHEET on their Settings keys, not as prompt_versions agents.'

    $healthContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\health\Test-Health.ps1') -Raw
    Assert-True -Condition ($healthContent -match '-TimeoutSec') -Message 'Health probes must pass TimeoutSec to Invoke-WebRequest.'
    Assert-True -Condition ($healthContent -match 'Test-LocalBackendOrigin') -Message 'Health success must include local origin proof.'

    $backendInstallContent = Get-Content -Path (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1') -Raw
    Assert-True -Condition ($backendInstallContent -match 'Resolve-AppHostPortContract') -Message 'Backend install must enforce the 18001 contract.'
    Assert-True -Condition ($backendInstallContent -match "NT AUTHORITY\\SYSTEM" -or $backendInstallContent -match 'Test-IsSystemIdentity') -Message 'SYSTEM identity comparison must use the real Windows account name.'
    Assert-True -Condition ($backendInstallContent -notmatch "NT AUTHORITY\\\\SYSTEM") -Message 'Install-BackendPayload must not compare against a two-backslash SYSTEM string.'
    Assert-True -Condition ($backendInstallContent -notmatch 'pg_isready -U') -Message 'Migration readiness must not invoke pg_isready as the docker-entrypoint temp-server false positive.'
    Assert-True -Condition ($backendInstallContent -match 'ConvertTo-PostgresQueryProbeResult') -Message 'Postgres wait must require a successful SELECT 1 against ai_orchestration.'
    Assert-True -Condition ($backendInstallContent -match 'to_regclass') -Message 'offline_migration_history init must verify the table exists after CREATE.'
    Assert-True -Condition ($backendInstallContent -match 'Test-IsPostgresTransientUnavailableMessage') -Message 'History-table init must retry only transient cold-start/shutdown errors, not skip the gate.'

    $bundleJson = Get-Content -Path (Join-Path $PackagingRoot 'manifests\bundle.json') -Raw | ConvertFrom-Json
    Assert-Equal -Expected '0.1.4' -Actual $bundleJson.bundle.version -Message 'Correctness rebuild must increment the package version above the failed 0.1.3 candidate.'

    $buildScript = Get-Content -Path (Join-Path $PackagingRoot 'build-offline-package.ps1') -Raw
    Assert-True -Condition ($buildScript -match 'Invoke-SecretsScan|Assert-SecretsScan') -Message 'One-command packaging must scan for secrets.'
    Assert-True -Condition ($buildScript -match 'SHA512|sha512') -Message 'One-command packaging must emit SHA512 as well as SHA256.'
    Assert-True -Condition ($buildScript -match 'Test-BurnPayloadSha512Binding|Assert-BurnExternalPayloadBindings') -Message 'One-command packaging must verify Burn SHA512 bindings.'
    Assert-True -Condition ($buildScript -match 'VerifyExistingOutputsOnly') -Message 'One-command packaging must support re-verifying an already generated dist tree without rebuilding MSI/CAB/Burn.'
    Assert-True -Condition ($buildScript -match 'Test-WindowsAcceptanceEvidence|Assert-WindowsAcceptanceEvidence') -Message 'One-command packaging must fail closed without Windows acceptance evidence.'
    Assert-True -Condition ($buildScript -match 'NOT_READY|built_not_ready') -Message 'Downloads publish must stay blocked with an unmistakable NOT_READY result until Windows gates pass.'
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Installer correctness checks passed=$passed failed=$failed"
if ($failed -gt 0) {
    throw "Installer correctness tests failed: $failed"
}

exit 0
