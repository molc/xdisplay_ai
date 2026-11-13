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

$staleImage = Test-BackendImageMatchesS63fContract `
    -GitSha '' `
    -Tag '' `
    -RuntimeFingerprint '' `
    -ExpectedFingerprint '5f1b3896deadbeef' `
    -ImageId 'sha256:a001031bb9b0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Assert-True -Condition (-not $staleImage.Ok) -Message 'Unlabeled 0.1.3 orchestration-app:latest a001031bb9b0 must not match the approved-card image contract.'
Assert-True -Condition (($staleImage.Reasons -join ' ') -match '623b07232') -Message 'Stale image reasons must name the required approved-card revision prefix.'

$s63fImage = Test-BackendImageMatchesS63fContract `
    -GitSha (Get-ApprovedBackendRevisionFull) `
    -Tag (Get-ApprovedBackendTag) `
    -RuntimeFingerprint '5f1b3896aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
    -ExpectedFingerprint '5f1b3896aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' `
    -ImageId 'sha256:s63f'
Assert-True -Condition $s63fImage.Ok -Message 'Labeled approved-card git-sha/tag/fingerprint must match the package image contract.'

$wrongFingerprint = Test-BackendImageMatchesS63fContract `
    -GitSha (Get-ApprovedBackendRevisionFull) `
    -Tag (Get-ApprovedBackendTag) `
    -RuntimeFingerprint 'not-the-package-fingerprint' `
    -ExpectedFingerprint '5f1b3896aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
Assert-True -Condition (-not $wrongFingerprint.Ok) -Message 'A later HTTP 200 on a retagged old image must still fail the fingerprint contract.'

$oldEnv = [ordered]@{
    XDISPLAY_AI_ENVIRONMENT = 'dev'
    XDISPLAY_AI_STAGED_DRAFTER_ENABLED = 'true'
    XDISPLAY_AI_LLM_API_KEY = 'do-not-print'
}
$stalePrompt = Test-BackendPromptContractFromEnvEntries -Entries $oldEnv
Assert-True -Condition (-not $stalePrompt.Ok) -Message 'Healthy 0.1.3 env without the 31-agent map must fail the prompt contract.'
Assert-True -Condition ($stalePrompt.AgentCount -eq 0) -Message 'The .29 prompt failure was agentCount=0; that case must stay a contract miss.'
Assert-True -Condition (($stalePrompt.Reasons -join ' ') -match 'XDISPLAY_AI_STAGED_DRAFTER_ENABLED') -Message 'Retired staged-drafter key must keep the prompt contract FAIL.'
Assert-True -Condition (($stalePrompt.Reasons -join ' ') -notmatch 'do-not-print') -Message 'Prompt contract reasons must not include secret values.'

$goodEnv = [ordered]@{
    XDISPLAY_AI_PROMPT_VERSIONS = (Get-S63fRegisteredPromptVersionTable)
    XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION = (Get-S63fBrowserSolverPageHtmlPromptVersion)
    XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION = (Get-S63fBrowserSolverEngineeringStylesheetContractVersion)
}
$goodPrompt = Test-BackendPromptContractFromEnvEntries -Entries $goodEnv
Assert-True -Condition $goodPrompt.Ok -Message 'Full 31-agent table plus v20/v6 Settings keys must satisfy the prompt contract.'
Assert-True -Condition ($goodPrompt.AgentCount -eq 31) -Message 'Prompt contract must count all 31 registered agents.'

$dot29Skip = Test-LocalBackendSkipAllowed -HealthReady $true -ImageContract $staleImage -PromptContract $stalePrompt
Assert-True -Condition (-not $dot29Skip.Ok) -Message 'Upgrade-from-healthy-0.1.3 must NOT skip offline image load or prompt initialization.'
Assert-True -Condition (($dot29Skip.Reasons -join ' ') -match 'HTTP 200') -Message 'Skip denial must state that HTTP 200 does not waive a stale image or prompt contract.'

$matchingSkip = Test-LocalBackendSkipAllowed -HealthReady $true -ImageContract $s63fImage -PromptContract $goodPrompt
Assert-True -Condition $matchingSkip.Ok -Message 'A healthy local backend that already matches this package may skip re-initialization.'

$healthOnly = Test-LocalBackendSkipAllowed -HealthReady $true -ImageContract $null -PromptContract $null
Assert-True -Condition (-not $healthOnly.Ok) -Message 'Health-only Test-LocalBackendFullyReady must not be enough to skip payload apply.'

$bootstrap = Get-Content -LiteralPath (Join-Path $PackagingRoot 'src\scripts\install\Bootstrap-InstalledPayload.ps1') -Raw
Assert-True -Condition ($bootstrap -match 'Test-LocalBackendSkipAllowed') -Message 'Bootstrap skip must go through Test-LocalBackendSkipAllowed.'
Assert-True -Condition ($bootstrap -match 'Test-InstalledBackendMatchesPackage') -Message 'Bootstrap skip must evaluate the installed image/prompt package contract.'
Assert-True -Condition ($bootstrap -notmatch 'Enable-RemoteDesktopAccess') -Message 'Release bootstrap must not enable RDP/firewall as a side effect.'
Assert-True `
    -Condition ($bootstrap -notmatch '(?s)if \(-not \$Resume -and \(Test-LocalBackendFullyReady\)\)') `
    -Message 'Bootstrap must not skip payload apply on health-only Test-LocalBackendFullyReady.'

$backendInstall = Get-Content -LiteralPath (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1') -Raw
Assert-True -Condition ($backendInstall -match 'Sync-StaleAppContainersToLoadedImages') -Message 'After docker load, stale running app/embedding containers must be force-recreated.'
Assert-True -Condition ($backendInstall -match '--force-recreate') -Message 'Stale app image refresh must use compose force-recreate, not health-only up -d.'
Assert-True -Condition ($backendInstall -match 'postgres') -Message 'Postgres service path must remain for the cold-start wait.'
Assert-True -Condition ($backendInstall -match 'ConvertTo-PostgresQueryProbeResult') -Message 'Cold-PG two-consecutive SELECT 1 wait must not regress.'
Assert-True -Condition ($backendInstall -match 'to_regclass\(''public.offline_migration_history''\)') -Message 'offline_migration_history to_regclass gate must not regress.'
Assert-True -Condition ($backendInstall -notmatch 'force-recreate.*postgres') -Message 'Do not force-recreate postgres when refreshing a stale app image.'

Write-Output 'PASS: upgrade-from-healthy-older-backend must refresh approved-card image and prompt contract'
exit 0
