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
    $matches = [regex]::Matches($content, $assignmentPattern)
    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Added = @()
            BackupPath = ''
        }
    }
    if ($matches.Count -ne 1) {
        throw 'Backend .env must contain at most one active XDISPLAY_AI_PROMPT_VERSIONS assignment.'
    }

    $existingEntries = ConvertTo-PromptVersionEntries `
        -Value $matches[0].Groups['value'].Value `
        -Label 'Existing XDISPLAY_AI_PROMPT_VERSIONS'
    $defaultEntries = ConvertTo-PromptVersionEntries `
        -Value $DefaultPromptVersions `
        -Label 'Updated backend default prompt_versions'
    $added = New-Object System.Collections.Generic.List[string]
    foreach ($agent in $defaultEntries.Keys) {
        if (-not $existingEntries.Contains($agent)) {
            $existingEntries[$agent] = $defaultEntries[$agent]
            $added.Add([string]$agent)
        }
    }

    if ($added.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Added = @()
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
    $match = $matches[0]
    $updatedContent = $content.Remove($match.Index, $match.Length).Insert($match.Index, $replacement)
    [System.IO.File]::WriteAllText(
        $EnvPath,
        $updatedContent,
        (New-Object System.Text.UTF8Encoding($false))
    )

    return [pscustomobject]@{
        Changed = $true
        Added = @($added)
        BackupPath = $backupPath
    }
}
