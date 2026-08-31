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

if (-not (Test-Path -LiteralPath $MigrationScriptPath -PathType Leaf)) {
    throw "Prompt pin migration script is missing: $MigrationScriptPath"
}
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
    Assert-Equal -Expected $false -Actual $defaultOnlyResult.Changed -Message 'An env without an explicit prompt table must keep using code defaults.'

    Write-Host 'Prompt pin migration tests passed.'
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
