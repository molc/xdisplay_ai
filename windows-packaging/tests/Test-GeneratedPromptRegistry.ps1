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

function Resolve-PythonExecutable {
    foreach ($name in @('python3', 'python')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & $command --version 2>&1
            if ($LASTEXITCODE -eq 0 -and ("$output" -match 'Python 3')) {
                return $command.Source
            }
        }
        catch {
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    return $null
}

function Resolve-S63fBackendSource {
    param([string]$PackagingRoot)

    $candidates = @(
        $env:S63F_BACKEND_SOURCE,
        (Join-Path $PackagingRoot 'inputs\backend\source'),
        '/tmp/s63f-src/ai_orchestration-s63f-dd6ab3d50',
        '/opt/cursor/artifacts/ai_orchestration-s63f-dd6ab3d50'
    )
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }
        $registryPath = Join-Path $candidate 'app/prompts/registry.py'
        $configPath = Join-Path $candidate 'app/config.py'
        if ((Test-Path -LiteralPath $registryPath -PathType Leaf) -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
            return [string]$candidate
        }
    }
    return $null
}

. (Join-Path $PackagingRoot 'src\scripts\common\InstallerCorrectness.ps1')

$tmplPath = Join-Path $PackagingRoot 'src\templates\env\backend.env.tmpl'
$tmpl = [System.IO.File]::ReadAllText($tmplPath)
$generated = $tmpl.
    Replace('{{ENVIRONMENT}}', 'dev').
    Replace('{{LOG_LEVEL}}', 'INFO').
    Replace('{{APP_HOST_PORT}}', '18001').
    Replace('{{RAG_BACKEND}}', 'pgvector').
    Replace('{{RAG_ACTIVE_INDEX_VERSION}}', 'v7').
    Replace('{{RAG_EMBEDDING_VERSION}}', 'bge-m3@1.5').
    Replace('{{LLM_PROVIDER}}', 'openrouter').
    Replace('{{LLM_BASE_URL}}', 'https://openrouter.ai/api/v1').
    Replace('{{LLM_MODEL_DEFAULT}}', 'qwen/qwen3-235b-a22b-2507')

Assert-True -Condition ($generated -notmatch '\{\{') -Message 'Generated backend.env from tmpl still contains unrendered tokens.'
$promptLine = [regex]::Match($generated, '(?m)^XDISPLAY_AI_PROMPT_VERSIONS=(?<value>[^\r\n]*)\s*$')
Assert-True -Condition $promptLine.Success -Message 'Generated env must contain XDISPLAY_AI_PROMPT_VERSIONS.'
$generatedTable = [string]$promptLine.Groups['value'].Value
Assert-True -Condition ($generatedTable -eq (Get-S63fRegisteredPromptVersionTable)) -Message 'Generated env prompt table must equal the packaged full s63f registry map.'
Assert-True -Condition ($generatedTable -ne (Get-S63fRejectedTruncatedPromptVersionPins)) -Message 'Matching the seven author-card pin strings is not a valid generated table.'
$shapeProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable $generatedTable -DefaultTable (Get-S63fSettingsDefaultPromptVersionTable))
Assert-True -Condition ($shapeProblems.Count -eq 0) -Message ('Generated table failed registry-shape checks: ' + ($shapeProblems -join '; '))
$crashProblems = @(Get-PromptVersionTableStartupProblems -EffectiveTable (Get-S63fRejectedTruncatedPromptVersionPins) -DefaultTable (Get-S63fSettingsDefaultPromptVersionTable))
Assert-True -Condition ($crashProblems.Count -ge 28) -Message 'The exact a62 crash table must still fail the registry-shape gate.'

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('xdisplayai-prompt-registry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $generatedEnvPath = Join-Path $testRoot 'generated.backend.env'
    $crashEnvPath = Join-Path $testRoot 'a62-crash.backend.env'
    [System.IO.File]::WriteAllText($generatedEnvPath, $generated, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText(
        $crashEnvPath,
        "XDISPLAY_AI_PROMPT_VERSIONS=$(Get-S63fRejectedTruncatedPromptVersionPins)`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    $python = Resolve-PythonExecutable
    if ([string]::IsNullOrWhiteSpace([string]$python)) {
        if ($env:OS -eq 'Windows_NT') {
            Write-Host 'SKIP: Python 3 is not available for validate_prompt_version_pins exec on this Windows host; PowerShell registry-shape checks passed.'
            Write-Output 'PASS: generated prompt registry (PowerShell shape checks; Python exec skipped)'
            exit 0
        }
        throw 'python3 is required to execute s63f validate_prompt_version_pins against a generated env.'
    }

    $helper = Join-Path $PackagingRoot 'tests\helpers\validate_generated_prompt_env.py'
    $fixtureRegistry = Join-Path $PackagingRoot 'tests\fixtures\s63f-prompt-registry\registry.py'
    Assert-True -Condition (Test-Path -LiteralPath $helper -PathType Leaf) -Message 'Missing tests/helpers/validate_generated_prompt_env.py'
    Assert-True -Condition (Test-Path -LiteralPath $fixtureRegistry -PathType Leaf) -Message 'Missing vendored s63f registry.py fixture'

    $syntheticPass = & $python $helper `
        --env $generatedEnvPath `
        --expect pass `
        --synthetic `
        --registry-py $fixtureRegistry `
        --default-table (Get-S63fRegisteredPromptVersionTable)
    if ($LASTEXITCODE -ne 0) {
        throw "s63f validate_prompt_version_pins rejected the generated installer env.`n$syntheticPass"
    }

    $syntheticFail = & $python $helper `
        --env $crashEnvPath `
        --expect fail `
        --synthetic `
        --registry-py $fixtureRegistry `
        --default-table (Get-S63fRegisteredPromptVersionTable)
    if ($LASTEXITCODE -ne 0) {
        throw "s63f validate_prompt_version_pins must reject the exact a62 truncated table.`n$syntheticFail"
    }

    $backendSource = Resolve-S63fBackendSource -PackagingRoot $PackagingRoot
    if (-not [string]::IsNullOrWhiteSpace([string]$backendSource)) {
        $sourceRegistry = Join-Path $backendSource 'app/prompts/registry.py'
        $fixtureHash = (Get-FileHash -LiteralPath $fixtureRegistry -Algorithm SHA256).Hash.ToLowerInvariant()
        $sourceHash = (Get-FileHash -LiteralPath $sourceRegistry -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-True -Condition ($fixtureHash -eq $sourceHash) -Message 'Vendored registry.py fixture must stay byte-identical to s63f app/prompts/registry.py.'

        $realPass = & $python $helper `
            --env $generatedEnvPath `
            --expect pass `
            --backend-source $backendSource
        if ($LASTEXITCODE -ne 0) {
            throw "Real s63f registry.py rejected the generated installer env, including prompt file digest checks.`n$realPass"
        }

        $realFail = & $python $helper `
            --env $crashEnvPath `
            --expect fail `
            --backend-source $backendSource
        if ($LASTEXITCODE -ne 0) {
            throw "Real s63f registry.py must reject the exact a62 truncated table.`n$realFail"
        }
        Write-Host "PASS: real s63f source at $backendSource accepted generated env and rejected the a62 crash table."
    }
    else {
        Write-Host 'NOTE: s63f backend source was not found; ran validate_prompt_version_pins against the vendored registry.py and a synthetic prompt tree.'
    }
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'PASS: generated prompt registry / strict startup validation'
exit 0
