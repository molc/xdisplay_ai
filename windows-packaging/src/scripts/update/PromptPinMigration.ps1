Set-StrictMode -Version Latest

function Get-UpdatedBackendDefaultPromptVersions {
    $dockerCommand = Get-DockerCommand
    $dockerLayout = Get-DockerLayout
    $pythonCode = "from app.config import Settings; print(Settings.model_fields['prompt_versions'].default)"
    $composeArguments = @(
        'compose',
        '--project-name',
        $dockerLayout.ProjectName,
        '--env-file',
        $dockerLayout.EnvFile,
        '-f',
        $dockerLayout.BaseCompose,
        '-f',
        $dockerLayout.OverlayCompose,
        'run',
        '--rm',
        '--no-deps',
        '--entrypoint',
        'python',
        'orchestration-app',
        '-c',
        $pythonCode
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $dockerCommand @composeArguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "Failed to read updated backend default prompt_versions; docker exit code: $exitCode`n$details"
    }

    $candidate = @(
        $output |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -match '^[A-Za-z0-9_]+:v[^,]+(,[A-Za-z0-9_]+:v[^,]+)+$' }
    ) | Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
        $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "Updated backend did not return recognizable default prompt_versions:`n$details"
    }
    return [string]$candidate
}

function ConvertTo-PromptVersionEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $entries = [ordered]@{}
    foreach ($rawEntry in $Value.Split(',')) {
        $entry = $rawEntry.Trim()
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $separatorIndex = $entry.IndexOf(':')
        if ($separatorIndex -le 0 -or $separatorIndex -eq ($entry.Length - 1)) {
            throw "$Label contains an invalid prompt version entry: $entry"
        }

        $agent = $entry.Substring(0, $separatorIndex).Trim()
        $version = $entry.Substring($separatorIndex + 1).Trim()
        if ($entries.Contains($agent)) {
            throw "$Label contains a duplicate prompt agent: $agent"
        }
        $entries[$agent] = $version
    }
    return $entries
}

function Update-BackendPromptVersionPins {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvPath,
        [Parameter(Mandatory = $true)]
        [string]$DefaultPromptVersions
    )

    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
        throw "Backend .env does not exist: $EnvPath"
    }

    $content = [System.IO.File]::ReadAllText($EnvPath)
    $assignmentPattern = '(?m)^(?!\s*#)\s*XDISPLAY_AI_PROMPT_VERSIONS=(?<value>[^\r\n]*)\s*$'
    $assignmentMatches = [regex]::Matches($content, $assignmentPattern)
    if ($assignmentMatches.Count -eq 0) {
        # A .env written by an older package (0.1.3) has no XDISPLAY_AI_PROMPT_VERSIONS at all. Returning
        # "nothing to do" left upgraded machines permanently outside the s63f prompt contract, so every
        # client launch re-ran the full backend refresh. Seed the complete agent table instead.
        $seedEntries = ConvertTo-PromptVersionEntries `
            -Value $DefaultPromptVersions `
            -Label 'Updated backend default prompt_versions'
        $seedNonAgentNames = @('PAGE_HTML', 'STYLESHEET')
        if (Get-Command Get-S63fNonAgentPromptPinNames -ErrorAction SilentlyContinue) {
            $seedNonAgentNames = @(Get-S63fNonAgentPromptPinNames)
        }
        $seedAdded = New-Object System.Collections.Generic.List[string]
        $seedPairs = @(
            foreach ($agent in $seedEntries.Keys) {
                if ($seedNonAgentNames -contains $agent) {
                    continue
                }
                $seedAdded.Add([string]$agent)
                "$agent`:$($seedEntries[$agent])"
            }
        )
        $seedBackupPath = "$EnvPath.bak-prompt-pins-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))"
        Copy-Item -LiteralPath $EnvPath -Destination $seedBackupPath -Force
        $seedLine = "XDISPLAY_AI_PROMPT_VERSIONS=$($seedPairs -join ',')"
        $seedContent = if ($content.Length -eq 0 -or $content.EndsWith("`n")) { $content + $seedLine + "`n" } else { $content + "`n" + $seedLine + "`n" }
        [System.IO.File]::WriteAllText($EnvPath, $seedContent, (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{
            Changed = $true
            Added = @($seedAdded)
            Removed = @()
            BackupPath = $seedBackupPath
        }
    }
    if ($assignmentMatches.Count -ne 1) {
        throw 'Backend .env must contain at most one active XDISPLAY_AI_PROMPT_VERSIONS assignment.'
    }

    $existingEntries = ConvertTo-PromptVersionEntries `
        -Value $assignmentMatches[0].Groups['value'].Value `
        -Label 'Existing XDISPLAY_AI_PROMPT_VERSIONS'
    $defaultEntries = ConvertTo-PromptVersionEntries `
        -Value $DefaultPromptVersions `
        -Label 'Updated backend default prompt_versions'
    $nonAgentNames = @('PAGE_HTML', 'STYLESHEET')
    if (Get-Command Get-S63fNonAgentPromptPinNames -ErrorAction SilentlyContinue) {
        $nonAgentNames = @(Get-S63fNonAgentPromptPinNames)
    }
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($agent in @($existingEntries.Keys)) {
        if ($nonAgentNames -contains $agent) {
            $existingEntries.Remove($agent) | Out-Null
            $removed.Add([string]$agent)
        }
    }

    $added = New-Object System.Collections.Generic.List[string]
    foreach ($agent in $defaultEntries.Keys) {
        if ($nonAgentNames -contains $agent) {
            continue
        }
        if (-not $existingEntries.Contains($agent)) {
            $existingEntries[$agent] = $defaultEntries[$agent]
            $added.Add([string]$agent)
        }
    }

    if ($added.Count -eq 0 -and $removed.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Added = @()
            Removed = @()
            BackupPath = ''
        }
    }

    $backupPath = "$EnvPath.bak-prompt-pins-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))"
    Copy-Item -LiteralPath $EnvPath -Destination $backupPath -Force
    $mergedValue = @(
        foreach ($agent in $existingEntries.Keys) {
            "$agent`:$($existingEntries[$agent])"
        }
    ) -join ','
    $replacement = "XDISPLAY_AI_PROMPT_VERSIONS=$mergedValue"
    $match = $assignmentMatches[0]
    $updatedContent = $content.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
    [System.IO.File]::WriteAllText(
        $EnvPath,
        $updatedContent,
        (New-Object System.Text.UTF8Encoding($false))
    )

    return [pscustomobject]@{
        Changed = $true
        Added = @($added)
        Removed = @($removed)
        BackupPath = $backupPath
    }
}

function Ensure-BackendBrowserSolverPromptPins {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvPath
    )

    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
        throw "Backend .env does not exist: $EnvPath"
    }

    $pageHtmlVersion = 'v19'
    $stylesheetVersion = 'v6'
    if (Get-Command Get-S63fBrowserSolverPageHtmlPromptVersion -ErrorAction SilentlyContinue) {
        $pageHtmlVersion = [string](Get-S63fBrowserSolverPageHtmlPromptVersion)
    }
    if (Get-Command Get-S63fBrowserSolverEngineeringStylesheetContractVersion -ErrorAction SilentlyContinue) {
        $stylesheetVersion = [string](Get-S63fBrowserSolverEngineeringStylesheetContractVersion)
    }

    $required = [ordered]@{
        XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION = $pageHtmlVersion
        XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION = $stylesheetVersion
    }

    $content = [System.IO.File]::ReadAllText($EnvPath)
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($required.Keys)) {
        $pattern = '(?m)^(?!\s*#)\s*' + [regex]::Escape($key) + '='
        if ([regex]::IsMatch($content, $pattern)) {
            continue
        }

        $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) {
            $content += $newline
        }
        $content += "$key=$($required[$key])$newline"
        $added.Add([string]$key)
    }

    if ($added.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Added = @()
        }
    }

    [System.IO.File]::WriteAllText($EnvPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Changed = $true
        Added = @($added)
    }
}
