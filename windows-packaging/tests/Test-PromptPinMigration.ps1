param(
    [string]$MigrationScriptPath = (Join-Path $PSScriptRoot '..\src\scripts\update\PromptPinMigration.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Expected -ne $Actual) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

$correctnessScript = Join-Path $PSScriptRoot '..\src\scripts\common\InstallerCorrectness.ps1'
if (-not (Test-Path -LiteralPath $MigrationScriptPath -PathType Leaf)) {
    throw "Prompt pin migration script is missing: $MigrationScriptPath"
}
if (-not (Test-Path -LiteralPath $correctnessScript -PathType Leaf)) {
    throw "Installer correctness script is missing: $correctnessScript"
}
. $correctnessScript
. $MigrationScriptPath

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xdisplayai-prompt-pin-test-' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $envPath = Join-Path $testRoot 'backend.env'
    $initialContent = @(
        '# keep this comment',
        'XDISPLAY_AI_PROMPT_VERSIONS=planner:v1.1,existing:v7.2',
        'XDISPLAY_AI_LOG_LEVEL=DEBUG'
    ) -join "`r`n"
    [IO.File]::WriteAllText($envPath, $initialContent + "`r`n", (New-Object Text.UTF8Encoding($false)))

    $result = Update-BackendPromptVersionPins `
        -EnvPath $envPath `
        -DefaultPromptVersions 'planner:v1.2,existing:v8.0,new_agent:v1.0,second_agent:v2.3'
    Assert-Equal -Expected $true -Actual $result.Changed -Message 'Missing prompt pins must trigger a migration.'
    Assert-Equal -Expected 'new_agent,second_agent' -Actual ($result.Added -join ',') -Message 'Only missing pins may be added.'
    if (-not (Test-Path -LiteralPath $result.BackupPath -PathType Leaf)) {
        throw 'Prompt pin migration must create a backup before changing .env.'
    }
    Assert-Equal -Expected ($initialContent + "`r`n") -Actual ([IO.File]::ReadAllText($result.BackupPath)) -Message 'The backup must preserve the original file.'

    $updatedContent = [IO.File]::ReadAllText($envPath)
    if (-not $updatedContent.Contains('# keep this comment')) { throw 'Comments must be preserved.' }
    if (-not $updatedContent.Contains('XDISPLAY_AI_LOG_LEVEL=DEBUG')) { throw 'Unrelated settings must be preserved.' }
    if (-not $updatedContent.Contains('XDISPLAY_AI_PROMPT_VERSIONS=planner:v1.1,existing:v7.2,new_agent:v1.0,second_agent:v2.3')) {
        throw 'Existing prompt versions must remain pinned while missing defaults are appended.'
    }

    $hashBeforeSecondRun = (Get-FileHash $envPath -Algorithm SHA256).Hash
    $secondResult = Update-BackendPromptVersionPins `
        -EnvPath $envPath `
        -DefaultPromptVersions 'planner:v1.2,existing:v8.0,new_agent:v1.0,second_agent:v2.3'
    Assert-Equal -Expected $false -Actual $secondResult.Changed -Message 'Prompt pin migration must be idempotent.'
    Assert-Equal -Expected $hashBeforeSecondRun -Actual (Get-FileHash $envPath -Algorithm SHA256).Hash -Message 'An idempotent run must not rewrite .env.'

    $defaultOnlyPath = Join-Path $testRoot 'default-only.env'
    [IO.File]::WriteAllText($defaultOnlyPath, "XDISPLAY_AI_LOG_LEVEL=INFO`r`n", (New-Object Text.UTF8Encoding($false)))
    $defaultOnlyResult = Update-BackendPromptVersionPins `
        -EnvPath $defaultOnlyPath `
        -DefaultPromptVersions 'planner:v1.2'
    Assert-Equal -Expected $true -Actual $defaultOnlyResult.Changed -Message 'An env without an explicit prompt table must be seeded; the package contract (Test-BackendPromptContractFromEnvEntries) requires the explicit 31-agent table and an upgraded 0.1.3 .env has none.'
    Assert-Equal -Expected 'planner' -Actual ($defaultOnlyResult.Added -join ',') -Message 'Seeding must report every agent it wrote.'

    $crashPath = Join-Path $testRoot 'a62-crash.env'
    $crashTable = Get-S63fRejectedTruncatedPromptVersionPins
    $fullTable = Get-S63fRegisteredPromptVersionTable
    [IO.File]::WriteAllText(
        $crashPath,
        "T014_UPGRADE_SENTINEL=keep-t014`r`nXDISPLAY_AI_PROMPT_VERSIONS=$crashTable`r`nXDISPLAY_AI_LOG_LEVEL=DEBUG`r`n",
        (New-Object Text.UTF8Encoding($false))
    )
    $crashResult = Update-BackendPromptVersionPins `
        -EnvPath $crashPath `
        -DefaultPromptVersions $fullTable
    Assert-Equal -Expected $true -Actual $crashResult.Changed -Message 'The a62 truncated table must be expanded to the full registered-agent map.'
    if (($crashResult.Removed -join ',') -notmatch 'PAGE_HTML') { throw 'PAGE_HTML must be dropped from prompt_versions.' }
    if (($crashResult.Removed -join ',') -notmatch 'STYLESHEET') { throw 'STYLESHEET must be dropped from prompt_versions.' }
    if (@($crashResult.Added).Count -lt 26) { throw 'Migration must append the 26 registered agents missing from the a62 crash table.' }
    $healed = [IO.File]::ReadAllText($crashPath)
    if ($healed -notmatch 'T014_UPGRADE_SENTINEL=keep-t014') { throw 'Prompt pin migration must preserve upgrade sentinels.' }
    if ($healed -notmatch 'XDISPLAY_AI_LOG_LEVEL=DEBUG') { throw 'Prompt pin migration must preserve unrelated settings.' }
    $healedTable = [regex]::Match($healed, '(?m)^XDISPLAY_AI_PROMPT_VERSIONS=(?<value>[^\r\n]*)\s*$').Groups['value'].Value
    $healedProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable $healedTable -DefaultTable $fullTable)
    if ($healedProblems.Count -ne 0) { throw "Healed table still fails registry-shape checks: $($healedProblems -join '; ')" }
    if ($healedTable -match 'PAGE_HTML' -or $healedTable -match 'STYLESHEET') { throw 'Healed table must not keep PAGE_HTML/STYLESHEET as agents.' }

    $browserPath = Join-Path $testRoot 'browser-pins.env'
    [IO.File]::WriteAllText($browserPath, "XDISPLAY_AI_LOG_LEVEL=INFO`r`n", (New-Object Text.UTF8Encoding($false)))
    $browserResult = Ensure-BackendBrowserSolverPromptPins -EnvPath $browserPath
    Assert-Equal -Expected $true -Actual $browserResult.Changed -Message 'Missing browser-solver PAGE_HTML/STYLESHEET keys must be added.'
    $browserContent = [IO.File]::ReadAllText($browserPath)
    if ($browserContent -notmatch 'XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION=v20') { throw 'PAGE_HTML must be seeded as XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION.' }
    if ($browserContent -notmatch 'XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION=v6') { throw 'STYLESHEET must be seeded as XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION.' }

    Write-Host 'Prompt pin migration tests passed.'
    exit 0

    # 0.1.3 upgrade: the preserved .env has no XDISPLAY_AI_PROMPT_VERSIONS line at all.
    $legacyEnvPath = Join-Path $testRoot 'legacy-backend.env'
    [IO.File]::WriteAllText($legacyEnvPath, "XDISPLAY_AI_LOG_LEVEL=DEBUG`r`nXDISPLAY_AI_STAGED_DRAFTER_ENABLED=true`r`n", (New-Object Text.UTF8Encoding($false)))
    $seeded = Update-BackendPromptVersionPins -EnvPath $legacyEnvPath -DefaultPromptVersions 'planner:v1.2,intent_extractor:v2.24,PAGE_HTML:v19,STYLESHEET:v6'
    Assert-Equal -Expected $true -Actual $seeded.Changed -Message 'A .env without XDISPLAY_AI_PROMPT_VERSIONS must be seeded (dot29: 0.1.3 -> 0.1.4 upgrade stayed outside the prompt contract).'
    Assert-Equal -Expected 'planner,intent_extractor' -Actual ($seeded.Added -join ',') -Message 'Seeding must add every agent pin and skip PAGE_HTML/STYLESHEET aliases.'
    $seededContent = [IO.File]::ReadAllText($legacyEnvPath)
    if ($seededContent -notmatch '(?m)^XDISPLAY_AI_PROMPT_VERSIONS=planner:v1\.2,intent_extractor:v2\.24\s*$') {
        throw "Seeded .env must contain the full agent table: $seededContent"
    }
    if ($seededContent -notmatch '(?m)^XDISPLAY_AI_LOG_LEVEL=DEBUG') {
        throw 'Seeding must keep the existing keys.'
    }
    if (-not (Test-Path -LiteralPath $seeded.BackupPath -PathType Leaf)) {
        throw 'Seeding must back up the original .env.'
    }
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
