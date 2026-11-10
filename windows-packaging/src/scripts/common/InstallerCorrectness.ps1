Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Join-InstallRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $path = $Root
    foreach ($segment in @($RelativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $path = Join-Path $path $segment
    }
    return $path
}

function Test-IsSecretEnvKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return [bool]($Name -match '(API_KEY|SECRET|TOKEN|PASSWORD|PRIVATE_KEY)')
}

function Get-RedactedEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Test-IsSecretEnvKey -Name $Name) {
        return '***REDACTED***'
    }

    return $Value
}

function Get-OptionalFeatureStateName {
    param(
        [AllowNull()]
        $Feature
    )

    if ($null -eq $Feature) {
        return ''
    }

    if ($Feature.PSObject.Properties.Name -contains 'State') {
        return [string]$Feature.State
    }

    return ''
}

function Test-IsSystemIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IdentityName
    )

    return [string]::Equals(
        $IdentityName,
        'NT AUTHORITY\SYSTEM',
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Get-RequiredComposeServiceNames {
    return @('postgres', 'redis', 'embedding-worker', 'orchestration-app')
}

function Get-RequiredAppHostPort {
    return 18001
}

function Get-PostgresReadyConsecutiveSuccessTarget {
    return 2
}

function Get-PostgresReadyStabilityDelaySeconds {
    return 2
}

function Get-F09ColdPostgresFatalShuttingDownOutput {
    return '2026-11-09 14:38:14.937 UTC [81] FATAL:  the database system is shutting down'
}

function Get-F09ColdPostgresPgIsReadyAcceptingOutput {
    return '/var/run/postgresql:5432 - accepting connections'
}

function Test-IsPostgresTransientUnavailableMessage {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    $text = [string]$Message
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }

    $normalized = $text.ToLowerInvariant()
    $needles = @(
        'the database system is shutting down',
        'the database system is starting up',
        'the database system is not yet accepting connections',
        'the database system is in recovery mode',
        'connection refused',
        'could not connect to server',
        'database "ai_orchestration" does not exist'
    )
    foreach ($needle in $needles) {
        if ($normalized.Contains($needle.ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function ConvertTo-PostgresQueryProbeResult {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Output
    )

    $text = [string]$Output
    $firstDataLine = @(
        $text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                $_ -notmatch '^(psql:|WARNING:|NOTICE:)'
            } |
            Select-Object -First 1
    )
    $ready = ($ExitCode -eq 0) -and ($firstDataLine.Count -eq 1) -and ($firstDataLine[0] -eq '1')
    return [pscustomobject]@{
        Ready = [bool]$ready
        Transient = (-not $ready) -and (Test-IsPostgresTransientUnavailableMessage -Message $text)
        Detail = $text
        ExitCode = $ExitCode
    }
}

function ConvertTo-PostgresHistoryTablePresenceResult {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Output
    )

    $text = [string]$Output
    $firstDataLine = @(
        $text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1
    )
    $present = ($ExitCode -eq 0) -and ($firstDataLine.Count -eq 1) -and ($firstDataLine[0] -eq 'offline_migration_history')
    return [pscustomobject]@{
        Present = [bool]$present
        Transient = (-not $present) -and (Test-IsPostgresTransientUnavailableMessage -Message $text)
        Detail = $text
        ExitCode = $ExitCode
    }
}

function Update-PostgresReadyConsecutiveCount {
    param(
        [int]$CurrentCount = 0,
        [Parameter(Mandatory = $true)]
        [bool]$ProbeReady
    )

    if ($ProbeReady) {
        return ([int]$CurrentCount + 1)
    }

    return 0
}

function Test-PostgresReadyConsecutiveCountMet {
    param(
        [int]$ConsecutiveCount = 0
    )

    return ([int]$ConsecutiveCount -ge (Get-PostgresReadyConsecutiveSuccessTarget))
}

function Test-PostgresReadyProbeSequence {
    param(
        [AllowEmptyCollection()]
        [object[]]$Probes = @()
    )

    $count = 0
    foreach ($probe in @($Probes)) {
        $ready = $false
        if ($null -ne $probe) {
            if ($probe -is [bool]) {
                $ready = [bool]$probe
            }
            elseif ($probe.PSObject.Properties.Name -contains 'Ready') {
                $ready = [bool]$probe.Ready
            }
        }
        $count = Update-PostgresReadyConsecutiveCount -CurrentCount $count -ProbeReady $ready
        if (Test-PostgresReadyConsecutiveCountMet -ConsecutiveCount $count) {
            return $true
        }
    }

    return $false
}

function Select-ComposeContainerId {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output = @()
    )

    # docker compose prints warnings (obsolete `version` attribute, unset variables) on stderr.
    # Under 2>&1 they arrive as ErrorRecords mixed with the id line; joining them into one
    # string produced "time=... level=warning ... <id>" and docker exec failed with No such container.
    foreach ($item in @($Output)) {
        if ($null -eq $item -or $item -is [System.Management.Automation.ErrorRecord]) {
            continue
        }
        $line = ([string]$item).Trim()
        if ($line -match '^[0-9a-f]{12,64}$') {
            return $line
        }
    }
    return ''
}

function Test-PendingFileRenameRequiresReboot {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Entries = @()
    )

    # Windows keeps PendingFileRenameOperations for anything scheduled with MOVEFILE_DELAY_UNTIL_REBOOT:
    # Burn/MSI temp extraction (%TEMP%\DEL*.tmp), Edge updates, profile junk. Treating every entry as
    # "reboot required" forced a reboot on practically every upgrade (dot29: 36 Edge/temp entries, then
    # 8 DEL*.tmp left by the previous uninstall). Only renames touching the virtualization / Docker stack
    # the offline backend depends on are a real reason to reboot before loading images.
    # ponytail: path heuristic; extend the pattern if a prerequisite ever stages files elsewhere.
    $relevant = '(?i)\\(lxss|wsl|vmcompute|vmwp|hvsocket|drivers)\\|\\Program Files\\Docker\\|\\Program Files\\WSL\\|WindowsSubsystemForLinux|VirtualMachinePlatform|\\Hyper-V\\'
    foreach ($entry in @($Entries)) {
        if ([string]::IsNullOrWhiteSpace([string]$entry)) {
            continue
        }
        if ([string]$entry -match $relevant) {
            return $true
        }
    }
    return $false
}

function Get-WorkspacePreserveRelativePaths {
    return @('.env', '.env.local', 'secret.env')
}

function Get-WorkspaceFingerprintRelativePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath
    )

    $paths = @($RequiredRelativePath)
    if ([string]::Equals($RequiredRelativePath, 'Xdisplay.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        # The same Xdisplay.exe can ship different runtime data (0.1.4 replaced the font-bloated keyboard
        # templates with the official 2.4.4 ones). Fingerprint the templates too, otherwise an upgrade
        # from a package with the same exe decides 'keep' and customers never receive the new templates.
        $paths += @(
            'data/keyboard_a/keypage.json',
            'data/keyboard_b/keypage.json',
            'data/keyboard_c/keypage.json',
            'data/keyboard_d/keypage.json',
            'data/keyboard_e/keypage.json',
            'images/launch/logo_tricolor.png'
        )
    }
    return @($paths)
}

function Get-FileSha256Lower {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-FileSha512Lower {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -Path $Path -Algorithm SHA512).Hash.ToLowerInvariant()
}

function Get-PathContentFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string[]]$RelativePaths,
        # ci/Common.ps1 Get-SourceContentFingerprint (which labels the app image at build time) adds an
        # "input\0<path>" row per requested path in addition to the "file\0<path>\0<sha256>" rows. The installer's
        # expected s63f runtime fingerprint must be byte-identical to that payload, otherwise the running image never
        # "matches the package" and every bootstrap run re-imports the offline images instead of taking the
        # health-only skip. Workspace seed fingerprints keep the legacy row set (they are compared against themselves).
        [switch]$IncludeInputRows
    )

    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in @($RelativePaths | Sort-Object -Unique)) {
        $targetPath = Join-InstallRelativePath -Root $Root -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $rows.Add("missing`0$($relativePath.Replace('\', '/'))")
            continue
        }

        if ($IncludeInputRows) {
            $rows.Add("input`0$($relativePath.Replace('\', '/').TrimStart('/'))")
        }
        $fileHash = Get-FileSha256Lower -Path $targetPath
        $rows.Add("file`0$($relativePath.Replace('\', '/'))`0$fileHash")
    }

    $payload = ($rows | Sort-Object) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-WorkspaceSyncDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [Parameter(Mandatory = $true)]
        [string]$RequiredRelativePath,
        [string]$LastSeedFingerprint = '',
        [string]$CurrentSeedFingerprint = ''
    )

    $requiredDestinationPath = Join-InstallRelativePath -Root $Destination -RelativePath $RequiredRelativePath
    if (-not (Test-Path -LiteralPath $Destination)) {
        return 'create'
    }

    if (-not (Test-Path -LiteralPath $requiredDestinationPath)) {
        return 'repair'
    }

    if (
        -not [string]::IsNullOrWhiteSpace($LastSeedFingerprint) -and
        -not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint) -and
        [string]::Equals($LastSeedFingerprint, $CurrentSeedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return 'keep'
    }

    $fingerprintPaths = @(Get-WorkspaceFingerprintRelativePaths -RequiredRelativePath $RequiredRelativePath)
    $destinationFingerprint = Get-PathContentFingerprint -Root $Destination -RelativePaths $fingerprintPaths
    if (
        -not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint) -and
        [string]::Equals($destinationFingerprint, $CurrentSeedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return 'keep'
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentSeedFingerprint)) {
        return 'update'
    }

    $seedFingerprint = Get-PathContentFingerprint -Root $Seed -RelativePaths $fingerprintPaths
    if ([string]::Equals($destinationFingerprint, $seedFingerprint, [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'keep'
    }

    return 'update'
}

function Get-RetiredBackendEnvKeys {
    return @('XDISPLAY_AI_STAGED_DRAFTER_ENABLED')
}

function Get-ApprovedBackendRevisionPrefix {
    return 'dd6ab3d50'
}

function Get-ApprovedBackendRevisionFull {
    return 'dd6ab3d505827a94cbc9d59d7067fcce14db6fbe'
}

function Get-ApprovedBackendTag {
    return 'prod/s63f'
}

function Get-S63fPackagingGitShaLabelName {
    return 'xdisplayai.packaging.git-sha'
}

function Get-S63fPackagingTagLabelName {
    return 'xdisplayai.packaging.tag'
}

function Get-S63fPackagingRuntimeFingerprintLabelName {
    return 'xdisplayai.packaging.runtime-fingerprint'
}

function Get-OrchestrationAppRuntimeFingerprintPaths {
    return @(
        'Dockerfile',
        'pyproject.toml',
        '.dockerignore',
        'external\xdisplay\bin\xd_render_cli\main.cpp',
        'external\xdisplay\bin\xd_render_cli\render_runner.cpp',
        'external\xdisplay\bin\xd_render_cli\render_runner.h',
        'external\xdisplay\bin\xd_render_cli\xd_render_cli.pro',
        'external\xdisplay\bin\xd_render_cli\Makefile'
    )
}

function Get-ObjectPropertyText {
    param(
        $Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return ''
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return [string]$Object[$Name]
        }
        return ''
    }
    if ($Object.PSObject.Properties.Name -contains $Name) {
        return [string]$Object.$Name
    }
    return ''
}

function Test-BackendImageMatchesS63fContract {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$GitSha = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Tag = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RuntimeFingerprint = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExpectedFingerprint = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ImageId = ''
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $gitShaText = [string]$GitSha
    $tagText = [string]$Tag
    $fingerprintText = [string]$RuntimeFingerprint
    $expectedText = [string]$ExpectedFingerprint
    $requiredPrefix = Get-ApprovedBackendRevisionPrefix
    $requiredTag = Get-ApprovedBackendTag

    if ([string]::IsNullOrWhiteSpace($gitShaText) -or -not $gitShaText.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $shown = if ([string]::IsNullOrWhiteSpace($gitShaText)) { 'missing' } else { $gitShaText }
        $imageShown = if ([string]::IsNullOrWhiteSpace($ImageId)) { '' } else { " image=$ImageId" }
        $reasons.Add("orchestration-app git-sha $shown is not s63f $requiredPrefix$imageShown")
    }
    if (-not [string]::Equals($tagText, $requiredTag, [StringComparison]::OrdinalIgnoreCase)) {
        $shown = if ([string]::IsNullOrWhiteSpace($tagText)) { 'missing' } else { $tagText }
        $reasons.Add("orchestration-app tag $shown is not $requiredTag")
    }
    if (-not [string]::IsNullOrWhiteSpace($expectedText)) {
        if (-not [string]::Equals($fingerprintText, $expectedText, [StringComparison]::OrdinalIgnoreCase)) {
            $shown = if ([string]::IsNullOrWhiteSpace($fingerprintText)) { 'missing' } else { $fingerprintText }
            $reasons.Add("orchestration-app runtime-fingerprint $shown does not match package fingerprint")
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($fingerprintText) -and [string]::IsNullOrWhiteSpace($gitShaText)) {
        $reasons.Add('running orchestration-app has no s63f packaging labels')
    }

    return [pscustomobject]@{
        Ok = ($reasons.Count -eq 0)
        Reasons = @($reasons)
    }
}

function Test-BackendPromptContractFromEnvEntries {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$Entries = $null
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Entries) {
        $reasons.Add('backend .env is missing')
        return [pscustomobject]@{
            Ok = $false
            Reasons = @($reasons)
            AgentCount = 0
        }
    }

    foreach ($retired in @(Get-RetiredBackendEnvKeys)) {
        if ($Entries.Contains($retired)) {
            $reasons.Add("retired env key $retired is still present")
        }
    }

    $table = ''
    if ($Entries.Contains('XDISPLAY_AI_PROMPT_VERSIONS')) {
        $table = [string]$Entries['XDISPLAY_AI_PROMPT_VERSIONS']
    }
    $agentCount = 0
    if ([string]::IsNullOrWhiteSpace($table)) {
        $reasons.Add('XDISPLAY_AI_PROMPT_VERSIONS is missing; HTTP 200 does not waive the 31-agent prompt contract')
    }
    else {
        $map = ConvertTo-PromptVersionMap -Value $table
        $agentCount = @($map.Keys).Count
        $problems = @(Get-PromptVersionTableStartupProblems -EffectiveTable $table -DefaultTable (Get-S63fRegisteredPromptVersionTable))
        foreach ($problem in $problems) {
            $reasons.Add([string]$problem)
        }
        $authorPins = ConvertTo-PromptVersionMap -Value (Get-S63fAuthorAgentPromptPins)
        foreach ($agent in @($authorPins.Keys)) {
            if (-not $map.Contains($agent) -or -not [string]::Equals([string]$map[$agent], [string]$authorPins[$agent], [StringComparison]::Ordinal)) {
                $reasons.Add("author pin ${agent}:$($authorPins[$agent]) is missing from the effective prompt table")
            }
        }
        foreach ($alias in @(Get-S63fNonAgentPromptPinNames)) {
            if ($map.Contains($alias)) {
                $reasons.Add("$alias must not appear in XDISPLAY_AI_PROMPT_VERSIONS")
            }
        }
    }

    $pageHtmlKey = 'XDISPLAY_AI_BROWSER_SOLVER_PAGE_HTML_PROMPT_VERSION'
    $stylesheetKey = 'XDISPLAY_AI_BROWSER_SOLVER_ENGINEERING_STYLESHEET_CONTRACT_VERSION'
    $pageHtml = if ($Entries.Contains($pageHtmlKey)) { [string]$Entries[$pageHtmlKey] } else { '' }
    $stylesheet = if ($Entries.Contains($stylesheetKey)) { [string]$Entries[$stylesheetKey] } else { '' }
    if ($pageHtml -ne (Get-S63fBrowserSolverPageHtmlPromptVersion)) {
        $reasons.Add("$pageHtmlKey must be $(Get-S63fBrowserSolverPageHtmlPromptVersion) on its own Settings key")
    }
    if ($stylesheet -ne (Get-S63fBrowserSolverEngineeringStylesheetContractVersion)) {
        $reasons.Add("$stylesheetKey must be $(Get-S63fBrowserSolverEngineeringStylesheetContractVersion) on its own Settings key")
    }

    return [pscustomobject]@{
        Ok = ($reasons.Count -eq 0)
        Reasons = @($reasons)
        AgentCount = $agentCount
    }
}

function Test-LocalBackendSkipAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$HealthReady,
        [AllowNull()]
        $ImageContract = $null,
        [AllowNull()]
        $PromptContract = $null
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $HealthReady) {
        $reasons.Add('local 127.0.0.1:18001 health/origin is not ready')
    }
    $imageOk = $false
    if ($null -ne $ImageContract -and $ImageContract.PSObject.Properties.Name -contains 'Ok') {
        $imageOk = [bool]$ImageContract.Ok
        if (-not $imageOk) {
            foreach ($reason in @($ImageContract.Reasons)) {
                $reasons.Add([string]$reason)
            }
        }
    }
    else {
        $reasons.Add('running app image contract was not evaluated')
    }

    $promptOk = $false
    if ($null -ne $PromptContract -and $PromptContract.PSObject.Properties.Name -contains 'Ok') {
        $promptOk = [bool]$PromptContract.Ok
        if (-not $promptOk) {
            foreach ($reason in @($PromptContract.Reasons)) {
                $reasons.Add([string]$reason)
            }
        }
    }
    else {
        $reasons.Add('prompt contract was not evaluated')
    }

    if ($HealthReady -and -not $imageOk) {
        $reasons.Add('HTTP 200 must not skip offline image load when the running app image is not this package s63f')
    }
    if ($HealthReady -and -not $promptOk) {
        $reasons.Add('HTTP 200 must not skip prompt/config initialization when the s63f prompt contract is stale')
    }

    return [pscustomobject]@{
        Ok = ($HealthReady -and $imageOk -and $promptOk)
        Reasons = @($reasons)
    }
}

function Get-ApprovedXdisplaySubmoduleCommit {
    return '0c657ad3eac7ece814206bd40fea807ec6568f81'
}

function Get-ApprovedS63fSourceArchiveSha256 {
    return '767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84'
}

function Get-ForbiddenS63fAppImageSha256 {
    return 'F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309'
}

function Get-S63fPlaywrightVersion {
    return '1.56.0'
}

function Get-S63fChromiumRevision {
    return '1194'
}

function Get-S63fMigrationFileNames {
    return @(
        '0001_init.sql',
        '0002_rag.sql',
        '0003_orch_runtime.sql'
    )
}

function Get-S63fExportMachOXdRenderCliSha256 {
    return '58618EC212229AC900E48304922AFD50EDFFD0F54CB325DCFA60F34382A606EA'
}

function Get-S63fExportMachOXdRenderCliBytes {
    return [long]50200
}

function ConvertTo-PromptVersionMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $map = [ordered]@{}
    foreach ($rawEntry in $Value.Split(',')) {
        $entry = $rawEntry.Trim()
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }

        $separatorIndex = $entry.IndexOf(':')
        if ($separatorIndex -le 0 -or $separatorIndex -eq ($entry.Length - 1)) {
            throw "Invalid prompt version entry: $entry"
        }

        $agent = $entry.Substring(0, $separatorIndex).Trim()
        $version = $entry.Substring($separatorIndex + 1).Trim()
        if ($map.Contains($agent)) {
            throw "Duplicate prompt agent: $agent"
        }
        $map[$agent] = $version
    }

    return $map
}

function ConvertFrom-PromptVersionMap {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Map
    )

    return @(
        foreach ($agent in @($Map.Keys)) {
            "$agent`:$($Map[$agent])"
        }
    ) -join ','
}

function Get-S63fSettingsDefaultPromptVersionTable {
    # Exact s63f Settings.prompt_versions default (app/config.py at dd6ab3d50).
    return 'planner:v1.2,clarifier:v1.0,diagnoser:v1.0,explainer:v1.0,drafter:v1.0,drafter_dsl:v2.4,sketch_interpreter:v4.0,sketch_interpretation_auditor:v1.0,sketch_layout_auditor:v1.0,auditor_dsl:v1.5,intent_extractor:v2.24,linker_dsl:v1.1,layout_planner:v1.1,component_planner:v1.4,composition_layout_planner:v2.5,component_slot_type_selector:v1.0,component_slot_props_planner:v2.0,page_scene_tweak_planner:v1.0,fixer:v2.2,write_action_declarer:v1.10,nav_declarer:v1.6,engineering_setting_declarer:v1.0,write_action_declarer_link:v1.8,page_set_skeleton_declarer:v1.5,placement_declarer:v1.0,read_display_declarer:v1.15,point_table_column_annotator:v1.1,repeated_series_declarer:v1.2,style_token_declarer:v1.2,strict_region_reader:v1.0,navigation_target_grouping_judge:v1.0'
}

function Get-S63fAuthorAgentPromptPins {
    return 'intent_extractor:v2.24,read_display_declarer:v1.15,write_action_declarer:v1.10,write_action_declarer_link:v1.8,sketch_interpreter:v4.0'
}

function Get-S63fNonAgentPromptPinNames {
    return @('PAGE_HTML', 'STYLESHEET')
}

function Get-S63fRejectedTruncatedPromptVersionPins {
    # Exact a62 native crash table: author-card pins written as the entire XDISPLAY_AI_PROMPT_VERSIONS value.
    return 'intent_extractor:v2.24,PAGE_HTML:v19,read_display_declarer:v1.15,write_action_declarer:v1.10,write_action_declarer_link:v1.8,sketch_interpreter:v4.0,STYLESHEET:v6'
}

function Get-S63fBrowserSolverPageHtmlPromptVersion {
    return 'v19'
}

function Get-S63fBrowserSolverEngineeringStylesheetContractVersion {
    return 'v6'
}

function Get-S63fRegisteredPromptVersionTable {
    $map = ConvertTo-PromptVersionMap -Value (Get-S63fSettingsDefaultPromptVersionTable)
    $authorPins = ConvertTo-PromptVersionMap -Value (Get-S63fAuthorAgentPromptPins)
    $nonAgentNames = @(Get-S63fNonAgentPromptPinNames)
    foreach ($agent in @($authorPins.Keys)) {
        if ($nonAgentNames -contains $agent) {
            continue
        }
        $map[$agent] = $authorPins[$agent]
    }

    return ConvertFrom-PromptVersionMap -Map $map
}

function Get-S63fPromptVersionPins {
    # Compatibility alias: this is the FULL registered-agent table, never the 7-entry author-card replacement.
    return Get-S63fRegisteredPromptVersionTable
}

function Get-PromptVersionTableStartupProblems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectiveTable,
        [Parameter(Mandatory = $true)]
        [string]$DefaultTable,
        [AllowEmptyCollection()]
        [string[]]$RegisteredAgentNames = @()
    )

    $effective = ConvertTo-PromptVersionMap -Value $EffectiveTable
    $defaults = ConvertTo-PromptVersionMap -Value $DefaultTable
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($agent in @($defaults.Keys)) {
        if (-not $effective.Contains($agent)) {
            $problems.Add("missing registered agent $agent")
        }
    }

    $nonAgentNames = @(Get-S63fNonAgentPromptPinNames)
    $registeredSet = @{}
    foreach ($name in @($RegisteredAgentNames)) {
        $registeredSet[$name] = $true
    }

    foreach ($agent in @($effective.Keys)) {
        if ($nonAgentNames -contains $agent) {
            $problems.Add("non-directory agent alias $agent")
            continue
        }
        if ($registeredSet.Count -gt 0 -and -not $registeredSet.ContainsKey($agent)) {
            $problems.Add("unregistered agent $agent")
        }
    }

    return @($problems)
}

function Merge-EnvEntries {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Defaults,
        [AllowNull()]
        [System.Collections.IDictionary]$Existing = $null,
        [AllowNull()]
        [System.Collections.IDictionary]$ForceEntries = $null,
        [AllowEmptyCollection()]
        [string[]]$DropKeys = @()
    )

    $merged = [ordered]@{}
    foreach ($key in @($Defaults.Keys)) {
        $merged[$key] = $Defaults[$key]
    }

    if ($null -ne $Existing) {
        foreach ($key in @($Existing.Keys)) {
            $merged[$key] = $Existing[$key]
        }
    }

    if ($null -ne $ForceEntries) {
        foreach ($key in @($ForceEntries.Keys)) {
            $merged[$key] = $ForceEntries[$key]
        }
    }

    foreach ($dropKey in @($DropKeys)) {
        if ($merged.Contains($dropKey)) {
            $merged.Remove($dropKey)
        }
    }

    return $merged
}

function Remove-RetiredBackendEnvKeys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvPath
    )

    if (-not (Test-Path -LiteralPath $EnvPath -PathType Leaf)) {
        return [pscustomobject]@{
            Changed = $false
            Removed = @()
        }
    }

    $retired = @(Get-RetiredBackendEnvKeys)
    $original = [System.IO.File]::ReadAllText($EnvPath)
    $removed = New-Object System.Collections.Generic.List[string]
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($original -split "`r?`n", [System.StringSplitOptions]::None)) {
        $trimmed = $line.Trim()
        $dropped = $false
        if ($trimmed -and -not $trimmed.StartsWith('#')) {
            $eq = $trimmed.IndexOf('=')
            if ($eq -gt 0) {
                $name = $trimmed.Substring(0, $eq).Trim()
                if ($retired -contains $name) {
                    $removed.Add($name)
                    $dropped = $true
                }
            }
        }
        if (-not $dropped) {
            $kept.Add($line)
        }
    }

    if ($removed.Count -eq 0) {
        return [pscustomobject]@{
            Changed = $false
            Removed = @()
        }
    }

    $updated = ($kept -join "`n")
    if ($original.Contains("`r`n")) {
        $updated = ($kept -join "`r`n")
    }
    [System.IO.File]::WriteAllText($EnvPath, $updated, (New-Object System.Text.UTF8Encoding($false)))
    return [pscustomobject]@{
        Changed = $true
        Removed = @($removed)
    }
}

function Get-LegacyApplicationEnvEntries {
    param(
        [AllowNull()]
        [System.Collections.IDictionary]$RuntimeEntries = $null
    )

    $legacy = [ordered]@{}
    if ($null -eq $RuntimeEntries) {
        return $legacy
    }

    $retired = @(Get-RetiredBackendEnvKeys)
    foreach ($key in @($RuntimeEntries.Keys)) {
        if ($key -like 'XDISPLAY_AI_*' -and $retired -notcontains $key) {
            $legacy[$key] = $RuntimeEntries[$key]
        }
    }

    return $legacy
}

function Get-BootstrapRebootAction {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$RebootRequired,
        [bool]$NoAutoReboot = $false,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$AutomaticRebootCount = 0,
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaximumAutomaticReboots = 2,
        [bool]$InstallerCustomAction = $false
    )

    if (-not $RebootRequired) {
        return [pscustomobject]@{
            Name = 'continue'
            Persist = $false
            RegisterResumeTask = $false
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = $true
            Throw = $false
            NextAutomaticRebootCount = $AutomaticRebootCount
        }
    }

    $nextCount = $AutomaticRebootCount + 1
    $loopExceeded = $nextCount -gt $MaximumAutomaticReboots
    $mustExitZero = $InstallerCustomAction -or $NoAutoReboot -or (-not $loopExceeded)

    if ($loopExceeded) {
        return [pscustomobject]@{
            Name = 'abort-loop'
            Persist = $true
            RegisterResumeTask = $true
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = [bool]$InstallerCustomAction
            Throw = -not $InstallerCustomAction
            NextAutomaticRebootCount = $AutomaticRebootCount
        }
    }

    if ($NoAutoReboot) {
        return [pscustomobject]@{
            Name = 'persist-wait'
            Persist = $true
            RegisterResumeTask = $true
            AutoReboot = $false
            ClearState = $false
            UnregisterResumeTask = $false
            ExitZero = $true
            Throw = $false
            NextAutomaticRebootCount = $nextCount
        }
    }

    return [pscustomobject]@{
        Name = 'persist-reboot'
        Persist = $true
        RegisterResumeTask = $true
        AutoReboot = $true
        ClearState = $false
        UnregisterResumeTask = $false
        ExitZero = $true
        Throw = $false
        NextAutomaticRebootCount = $nextCount
    }
}

function Test-IsLocalDockerEngine {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DockerHost = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ServerOs = '',
        [AllowNull()]
        [AllowEmptyString()]
        [string]$OperatingSystem = ''
    )

    if ([string]::IsNullOrWhiteSpace($DockerHost)) {
        return $false
    }

    $normalizedHost = $DockerHost.Trim()
    if ($normalizedHost -match '^(tcp|http|https)://') {
        if ($normalizedHost -match '://(127\.0\.0\.1|localhost)(:|/|$)') {
            return $false
        }
        return $false
    }

    $localPipes = @(
        'npipe:////./pipe/dockerDesktopLinuxEngine',
        'npipe:////./pipe/docker_engine'
    )
    $isLocalPipe = $false
    foreach ($pipeName in $localPipes) {
        if ([string]::Equals($normalizedHost, $pipeName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $isLocalPipe = $true
            break
        }
    }

    if (-not $isLocalPipe) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ServerOs) -and $ServerOs -ne 'linux') {
        return $false
    }

    if (
        -not [string]::IsNullOrWhiteSpace($OperatingSystem) -and
        ($OperatingSystem -notmatch 'docker[\s-]?desktop')
    ) {
        return $false
    }

    return $true
}

function ConvertTo-PortProxyListenEntries {
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Lines = @()
    )

    $entries = @()
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*(127\.0\.0\.1|localhost)\s+(\d+)\s+(\S+)\s+(\d+)\s*$') {
            $entries += [pscustomobject]@{
                ListenAddress = $Matches[1]
                ListenPort = [int]$Matches[2]
                ConnectAddress = $Matches[3]
                ConnectPort = [int]$Matches[4]
            }
        }
    }
    return @($entries)
}

function Test-AppPortProxyPresent {
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$Entries = @(),
        [int]$Port = 18001
    )

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        if ([int]$entry.ListenPort -eq $Port) {
            return $true
        }
    }
    return $false
}

function Resolve-AppHostPortContract {
    param(
        [int]$RequiredPort = 18001,
        [bool]$LoopbackFree = $true,
        [bool]$OwnedByLocalCompose = $false,
        [bool]$PortProxyPresent = $false,
        [string]$ListenerProcess = ''
    )

    if ($PortProxyPresent) {
        throw "127.0.0.1:$RequiredPort 存在 Windows portproxy 转发，不能当作本机后端。请删除该转发后重试，安装器不会改用其他端口。"
    }

    if ($OwnedByLocalCompose) {
        return $RequiredPort
    }

    if ($LoopbackFree) {
        return $RequiredPort
    }

    $listenerText = if ([string]::IsNullOrWhiteSpace($ListenerProcess)) { '未知进程' } else { $ListenerProcess }
    throw "127.0.0.1:$RequiredPort 被 $listenerText 占用，且不是本机 XDisplay compose 栈。安装器不会把 APP_HOST_PORT 改到 18002 或其他端口。请释放 18001 后重试。"
}

function Test-LocalBackendOrigin {
    param(
        [int]$HealthzStatus = 0,
        [int]$AssistantStatus = 0,
        [string]$PublishedBinding = '',
        [string]$ListenerProcess = '',
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$PortProxyEntries = @(),
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$RunningServices = @(),
        [string]$DockerHost = '',
        [string]$ServerOs = '',
        [string]$OperatingSystem = '',
        [int]$RequiredPort = 18001
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $expectedServices = @(Get-RequiredComposeServiceNames)

    if ($HealthzStatus -ne 200 -or $AssistantStatus -ne 200) {
        $reasons.Add("localhost:$RequiredPort 健康检查不是 200（healthz=$HealthzStatus assistant=$AssistantStatus）")
    }

    $expectedBinding = "127.0.0.1:$RequiredPort"
    if (-not [string]::Equals($PublishedBinding, $expectedBinding, [System.StringComparison]::OrdinalIgnoreCase)) {
        $reasons.Add("应用未发布在 $expectedBinding（实际：$PublishedBinding）")
    }

    if (Test-AppPortProxyPresent -Entries $PortProxyEntries -Port $RequiredPort) {
        $reasons.Add("127.0.0.1:$RequiredPort 存在 portproxy 转发，HTTP 200 不能证明本机后端")
    }

    if (-not (Test-IsLocalDockerEngine -DockerHost $DockerHost -ServerOs $ServerOs -OperatingSystem $OperatingSystem)) {
        $reasons.Add("Docker 引擎不是本机 Docker Desktop Linux named pipe（DockerHost=$DockerHost）")
    }

    $runningSet = @{}
    foreach ($serviceName in @($RunningServices)) {
        if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
            $runningSet[$serviceName] = $true
        }
    }
    foreach ($expectedService in $expectedServices) {
        if (-not $runningSet.ContainsKey($expectedService)) {
            $reasons.Add("缺少本机 compose 服务：$expectedService")
        }
    }

    $listenerOk = $false
    foreach ($allowedListener in @('com.docker.backend', 'com.docker.backend.exe', 'docker-proxy', 'docker-proxy.exe')) {
        if ([string]::Equals($ListenerProcess, $allowedListener, [System.StringComparison]::OrdinalIgnoreCase)) {
            $listenerOk = $true
            break
        }
    }
    if (-not $listenerOk) {
        $reasons.Add("18001 监听进程不是本机 Docker backend（实际：$ListenerProcess）")
    }

    return [pscustomobject]@{
        Ok = ($reasons.Count -eq 0)
        Reasons = @($reasons)
    }
}

function Test-SecretLikeValue {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    $trimmed = $Value.Trim()
    if ($trimmed -like '__SET_ME__*' -or $trimmed -match '^\{\{.+\}\}$') {
        return $false
    }

    if ($trimmed -match '^sk-[A-Za-z0-9]') {
        return $true
    }
    if ($trimmed -match 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY') {
        return $true
    }
    if ($trimmed -match '^(ghp|gho|github_pat)_[A-Za-z0-9_]+') {
        return $true
    }
    if ($trimmed -match '^(xox[baprs]-)[A-Za-z0-9-]+') {
        return $true
    }

    return $false
}

function Get-RequiredOfflineInputRelativePaths {
    return @(
        'prerequisites/docker-desktop/Docker Desktop Installer.exe',
        'prerequisites/vcredist/VC_redist.x64.exe',
        'prerequisites/wsl/wsl_update_x64.msi',
        'backend/images/orches_orchestration-app_latest.tar',
        'backend/images/orches_embedding-http_latest.tar',
        'backend/images/pgvector_pgvector_pg15.tar',
        'backend/images/redis_7.tar'
    )
}

function Get-MissingOfflineInputRelativePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputsRoot,
        [AllowEmptyCollection()]
        [string[]]$RequiredRelativePaths = @()
    )

    $missing = @()
    $paths = if ($RequiredRelativePaths.Count -gt 0) {
        $RequiredRelativePaths
    }
    else {
        @(Get-RequiredOfflineInputRelativePaths)
    }

    foreach ($relativePath in $paths) {
        $absolutePath = Join-InstallRelativePath -Root $InputsRoot -RelativePath $relativePath
        if (-not (Test-Path -LiteralPath $absolutePath)) {
            $missing += $relativePath
        }
    }

    return @($missing)
}

function Convert-ToNormalizedSha512 {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    return $Value.Replace('-', '').Trim().ToUpperInvariant()
}

function Get-BurnManifestExternalPayloads {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Burn manifest.xml 不存在：$ManifestPath"
    }

    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.Load((Resolve-Path -LiteralPath $ManifestPath).Path)
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $namespaceManager.AddNamespace('burn', 'http://wixtoolset.org/schemas/v4/2008/Burn')
    $nodes = $xml.SelectNodes('//burn:Payload[@Packaging="external"]', $namespaceManager)
    if ($null -eq $nodes) {
        return @()
    }

    $payloads = New-Object System.Collections.Generic.List[object]
    foreach ($node in $nodes) {
        $filePath = [string]$node.GetAttribute('FilePath')
        $hash = Convert-ToNormalizedSha512 -Value ([string]$node.GetAttribute('Hash'))
        $sizeText = [string]$node.GetAttribute('FileSize')
        $fileSize = [int64]0
        if (-not [string]::IsNullOrWhiteSpace($sizeText)) {
            $fileSize = [int64]$sizeText
        }
        $payloads.Add([pscustomobject]@{
            Id = [string]$node.GetAttribute('Id')
            FilePath = $filePath
            FileName = [IO.Path]::GetFileName($filePath)
            Hash = $hash
            FileSize = $fileSize
        })
    }
    return @($payloads.ToArray())
}

function Resolve-WixBurnExtractCommand {
    $command = Get-Command wix -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }
    foreach ($candidate in @('C:\WINDOWS\wix.cmd', 'C:\Program Files\WiX Toolset v5.0\bin\wix.exe')) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    throw 'Official WiX burn extract is required to read BurnManifest payload hashes. WiX 5 stores Hash attributes in the compressed UX container; grepping uncompressed EXE bytes is not a Burn binding.'
}

function Export-BurnBundleApplicationManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,
        [string]$OutputDirectory = ''
    )

    if (-not (Test-Path -LiteralPath $BundlePath -PathType Leaf)) {
        throw "Burn bundle 不存在：$BundlePath"
    }

    $wix = Resolve-WixBurnExtractCommand
    $extractRoot = $OutputDirectory
    if ([string]::IsNullOrWhiteSpace($extractRoot)) {
        $tempRoot = [string]$env:XDISPLAYAI_TEMP_ROOT
        if ([string]::IsNullOrWhiteSpace($tempRoot)) {
            $tempRoot = [IO.Path]::GetTempPath()
        }
        $extractRoot = Join-Path $tempRoot ('burn-oba-' + [guid]::NewGuid().ToString('N'))
    }
    $obaDirectory = Join-Path $extractRoot 'oba'
    $intermediateDirectory = Join-Path $extractRoot 'intermediate'
    New-Item -ItemType Directory -Path $obaDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $intermediateDirectory -Force | Out-Null

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $wix burn extract $BundlePath -oba $obaDirectory -intermediateFolder $intermediateDirectory
        $extractExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($extractExitCode -ne 0) {
        throw "wix burn extract failed for $BundlePath (exit $extractExitCode). Official WiX 5.0.2 BA extract is the source of Burn SHA512 bindings."
    }

    $manifestPath = Join-Path $obaDirectory 'manifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $found = @(Get-ChildItem -LiteralPath $obaDirectory -Filter 'manifest.xml' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($found.Count -lt 1) {
            throw "wix burn extract did not produce manifest.xml under $obaDirectory"
        }
        $manifestPath = $found[0].FullName
    }

    return [pscustomobject]@{
        ManifestPath = $manifestPath
        ExtractRoot = $extractRoot
        ObaDirectory = $obaDirectory
    }
}

function Get-BurnPayloadBindingVerdict {
    param(
        [Parameter(Mandatory = $true)]
        $ManifestEntry,
        [Parameter(Mandatory = $true)]
        [string]$PayloadPath
    )

    if ($null -eq $ManifestEntry -or [string]::IsNullOrWhiteSpace([string]$ManifestEntry.Hash)) {
        return 'missing'
    }
    if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) {
        return 'missing-file'
    }

    $actualHash = Convert-ToNormalizedSha512 -Value ((Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA512).Hash)
    $actualSize = [int64](Get-Item -LiteralPath $PayloadPath).Length
    if ($actualHash -eq [string]$ManifestEntry.Hash -and $actualSize -eq [int64]$ManifestEntry.FileSize) {
        return 'match'
    }
    return 'mismatch'
}

function Test-BurnPayloadSha512Binding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,
        [Parameter(Mandatory = $true)]
        [string]$PayloadPath,
        [string]$ManifestXmlPath = ''
    )

    if (-not (Test-Path -LiteralPath $BundlePath)) {
        throw "Burn bundle 不存在：$BundlePath"
    }
    if (-not (Test-Path -LiteralPath $PayloadPath)) {
        throw "Burn 相邻 payload 不存在：$PayloadPath"
    }

    $extractRoot = ''
    try {
        if ([string]::IsNullOrWhiteSpace($ManifestXmlPath)) {
            $exported = Export-BurnBundleApplicationManifest -BundlePath $BundlePath
            $ManifestXmlPath = $exported.ManifestPath
            $extractRoot = [string]$exported.ExtractRoot
        }

        $leaf = [IO.Path]::GetFileName($PayloadPath)
        $entry = @(Get-BurnManifestExternalPayloads -ManifestPath $ManifestXmlPath | Where-Object {
            [string]::Equals([string]$_.FileName, $leaf, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($entry.Count -lt 1) {
            return $false
        }
        return ((Get-BurnPayloadBindingVerdict -ManifestEntry $entry[0] -PayloadPath $PayloadPath) -eq 'match')
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($extractRoot) -and (Test-Path -LiteralPath $extractRoot)) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-WindowsAcceptanceEvidence {
    param(
        [AllowNull()]
        $Evidence
    )

    $failures = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Evidence) {
        $failures.Add('缺少隔离 Windows 验收证据；源码测试通过不能当成安装器已接受。')
        return [pscustomobject]@{
            Ok = $false
            Failures = @($failures)
        }
    }

    $fresh = $null
    $upgrade = $null
    if ($Evidence.PSObject.Properties.Name -contains 'freshOfflineRebootResume') {
        $fresh = $Evidence.freshOfflineRebootResume
    }
    if ($Evidence.PSObject.Properties.Name -contains 'oldVersionPreservation') {
        $upgrade = $Evidence.oldVersionPreservation
    }

    if ($null -eq $fresh -or [string]$fresh.status -ne 'pass') {
        $failures.Add('fresh-offline→reboot-resume→4 local containers/local 18001 验收未 PASS。')
    }
    else {
        if (-not [bool]$fresh.localBackend) {
            $failures.Add('全新安装验收未证明本机后端。')
        }
        if ([int]$fresh.containers -ne 4) {
            $failures.Add("全新安装验收容器数不是 4（实际：$($fresh.containers)）。")
        }
        if ([int]$fresh.appPort -ne 18001) {
            $failures.Add("全新安装验收应用端口不是 18001（实际：$($fresh.appPort)）。")
        }
        if ([string]$fresh.origin -ne 'local') {
            $failures.Add('全新安装验收 origin 不是 local。')
        }
    }

    if ($null -eq $upgrade -or [string]$upgrade.status -ne 'pass') {
        $failures.Add('旧版本配置/项目/数据库保留验收未 PASS。')
    }
    else {
        if (-not [bool]$upgrade.configSentinel) {
            $failures.Add('升级验收未保留配置哨兵。')
        }
        if (-not [bool]$upgrade.projects) {
            $failures.Add('升级验收未保留用户项目。')
        }
        if (-not [bool]$upgrade.dbVolumes) {
            $failures.Add('升级验收未保留数据库卷。')
        }
    }

    return [pscustomobject]@{
        Ok = ($failures.Count -eq 0)
        Failures = @($failures)
    }
}

function New-BoundedWaitStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        [Parameter(Mandatory = $true)]
        [int]$MaxAttempts,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LastError = '',
        [int]$TimeoutSeconds = 0
    )

    $errorText = if ([string]::IsNullOrWhiteSpace($LastError)) { 'none' } else { $LastError }
    if ($errorText.Length -gt 180) {
        $errorText = $errorText.Substring(0, 180)
    }

    $timeoutText = if ($TimeoutSeconds -gt 0) { " timeoutSec=$TimeoutSeconds" } else { '' }
    return "$Stage ($Attempt/$MaxAttempts)$timeoutText lastError=$errorText"
}

function Sync-WorkspaceTreeFromSeed {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Seed,
        [Parameter(Mandatory = $true)]
        [string]$Destination,
        [AllowEmptyCollection()]
        [string[]]$PreserveRelativePaths = @()
    )

    if (-not (Test-Path -LiteralPath $Seed)) {
        throw "安装种子不存在：$Seed"
    }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $preserveSet = @{}
    foreach ($relativePath in @($PreserveRelativePaths)) {
        $preserveSet[$relativePath.Replace('\', '/').Trim('/')] = $true
    }

    $seedFiles = @(Get-ChildItem -LiteralPath $Seed -Recurse -File -Force)
    foreach ($seedFile in $seedFiles) {
        $relativePath = $seedFile.FullName.Substring($Seed.Length).TrimStart('\', '/').Replace('\', '/')
        $destinationPath = Join-InstallRelativePath -Root $Destination -RelativePath $relativePath
        $preserveExisting = $preserveSet.ContainsKey($relativePath) -and (Test-Path -LiteralPath $destinationPath)
        if ($preserveExisting) {
            continue
        }

        $parent = Split-Path -Path $destinationPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $seedFile.FullName -Destination $destinationPath -Force
    }
}
