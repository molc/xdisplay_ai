param(
    [int]$TimeoutMinutes = 30,
    [int]$HealthProbeTimeoutSeconds = 10,
    [switch]$ResumeValidation,
    [switch]$SkipDiagnosticsOnFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')

function Convert-CodePointsToString {
    param(
        [Parameter(Mandatory = $true)]
        [int[]]$CodePoints
    )

    return (-join ($CodePoints | ForEach-Object { [char]$_ }))
}

function Get-ValidationLayout {
    $stateLayout = Get-InstallStateLayout
    return [pscustomobject]@{
        ReportFile = Join-Path $stateLayout.LogsRoot 'backend-startup-validation.json'
        TranscriptFile = Join-Path $stateLayout.LogsRoot 'backend-startup-validation.log'
        TaskName = 'XDisplayAI-BackendStartupValidation'
    }
}

function Get-SelfInvocationArgumentList {
    param(
        [switch]$ResumeMode
    )

    $argumentList = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`"",
        '-HealthProbeTimeoutSeconds',
        $HealthProbeTimeoutSeconds.ToString()
    )

    if ($ResumeMode) {
        $argumentList += '-ResumeValidation'
    }
    else {
        $argumentList += @('-TimeoutMinutes', $TimeoutMinutes.ToString())
    }

    if ($SkipDiagnosticsOnFailure) {
        $argumentList += '-SkipDiagnosticsOnFailure'
    }

    return $argumentList
}

function Invoke-ElevatedSelf {
    param(
        [switch]$ResumeMode
    )

    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (Get-SelfInvocationArgumentList -ResumeMode:$ResumeMode) -Wait -PassThru
    exit $process.ExitCode
}

function Read-ValidationReport {
    $layout = Get-ValidationLayout
    if (-not (Test-Path $layout.ReportFile)) {
        return $null
    }

    return Get-Content -Path $layout.ReportFile -Raw | ConvertFrom-Json
}

function Write-ValidationReport {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report
    )

    $layout = Get-ValidationLayout
    $Report | Add-Member -NotePropertyName updatedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    $Report | ConvertTo-Json -Depth 8 | Set-Content -Path $layout.ReportFile -Encoding utf8
}

function New-ValidationReport {
    $stateLayout = Get-InstallStateLayout
    $startedAtUtc = [DateTime]::UtcNow

    return [pscustomobject]@{
        status = 'running'
        startedAtUtc = $startedAtUtc.ToString('o')
        deadlineUtc = $startedAtUtc.AddMinutes($TimeoutMinutes).ToString('o')
        resumedAfterReboot = $false
        lastError = ''
        diagnosticsArchive = ''
        bootstrapLog = $stateLayout.BootstrapLog
        runtimeEnvFile = $stateLayout.RuntimeEnvFile
        clientLaunchRequested = $true
        clientProcessObserved = $false
        clientProcessId = ''
        clientProcessStartTimeUtc = ''
        observedStages = [ordered]@{}
        health = $null
        composeStatus = ''
        orchestrationAppLogs = ''
    }
}

function Register-ValidationResumeTask {
    $layout = Get-ValidationLayout
    try {
        Unregister-ScheduledTask -TaskName $layout.TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ((Get-SelfInvocationArgumentList -ResumeMode) -join ' ')
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName $layout.TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
}

function Unregister-ValidationResumeTask {
    $layout = Get-ValidationLayout
    try {
        Unregister-ScheduledTask -TaskName $layout.TaskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
    }
}

function Get-BootstrapStageEvidence {
    $stateLayout = Get-InstallStateLayout
    $logPath = $stateLayout.BootstrapLog
    $result = [ordered]@{
        prerequisiteStarted = $false
        prerequisiteCompleted = $false
        rebootScheduled = $false
        resumedAfterReboot = $false
        dockerWaitStarted = $false
        imagesImported = $false
        composeStarted = $false
        migrationsStarted = $false
        healthCheckStarted = $false
    }

    if (-not (Test-Path $logPath)) {
        return $result
    }

    $content = Get-Content -Path $logPath -Raw
    $result.prerequisiteStarted = $content.Contains((Convert-CodePointsToString @(0x68c0, 0x67e5, 0x5e76, 0x5b89, 0x88c5, 0x79bb, 0x7ebf, 0x524d, 0x7f6e, 0x4f9d, 0x8d56, 0x3002)))
    $result.prerequisiteCompleted = $content.Contains((Convert-CodePointsToString @(0x524d, 0x7f6e, 0x4f9d, 0x8d56, 0x9636, 0x6bb5, 0x5b8c, 0x6210, 0x3002)))
    $result.rebootScheduled = $content.Contains((Convert-CodePointsToString @(0x35, 0x20, 0x79d2, 0x540e, 0x81ea, 0x52a8, 0x91cd, 0x542f, 0xff0c, 0x91cd, 0x542f, 0x540e, 0x7ee7, 0x7eed, 0x79bb, 0x7ebf, 0x5b89, 0x88c5, 0x6d41, 0x7a0b, 0x3002)))
    $result.resumedAfterReboot = $content.Contains((Convert-CodePointsToString @(0x7ee7, 0x7eed, 0x6267, 0x884c, 0x91cd, 0x542f, 0x540e, 0x7684, 0x79bb, 0x7ebf, 0x5b89, 0x88c5, 0x6d41, 0x7a0b, 0x3002)))
    $result.dockerWaitStarted = $content.Contains((Convert-CodePointsToString @(0x7b49, 0x5f85, 0x20, 0x44, 0x6f, 0x63, 0x6b, 0x65, 0x72, 0x20, 0x44, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x20, 0x5c31, 0x7eea)))
    $result.imagesImported = $content.Contains((Convert-CodePointsToString @(0x5bfc, 0x5165, 0x79bb, 0x7ebf, 0x20, 0x44, 0x6f, 0x63, 0x6b, 0x65, 0x72, 0x20, 0x955c, 0x50cf, 0x3002)))
    $result.composeStarted = $content.Contains((Convert-CodePointsToString @(0x542f, 0x52a8, 0x79bb, 0x7ebf, 0x540e, 0x7aef, 0x670d, 0x52a1, 0x6808, 0x3002)))
    $result.migrationsStarted = $content.Contains((Convert-CodePointsToString @(0x6267, 0x884c, 0x6570, 0x636e, 0x5e93, 0x8fc1, 0x79fb, 0x3002)))
    $result.healthCheckStarted = $content.Contains((Convert-CodePointsToString @(0x7b49, 0x5f85, 0x5e94, 0x7528, 0x5065, 0x5eb7, 0x68c0, 0x67e5, 0x901a, 0x8fc7, 0x3002)))

    return $result
}

function Invoke-InstalledHealthProbe {
    try {
        $raw = (& (Join-Path $PSScriptRoot '..\health\Test-Health.ps1') -TimeoutSeconds $HealthProbeTimeoutSeconds | Out-String).Trim()
        $details = if ([string]::IsNullOrWhiteSpace($raw)) { $null } else { $raw | ConvertFrom-Json }
        return [pscustomobject]@{
            isHealthy = $true
            details = $details
            error = ''
        }
    }
    catch {
        return [pscustomobject]@{
            isHealthy = $false
            details = $null
            error = $_.Exception.Message
        }
    }
}

function Get-ComposeStatusText {
    try {
        $output = (Invoke-Compose -Arguments @('ps', '-a') | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return ''
        }

        return $output
    }
    catch {
        return ''
    }
}

function Get-OrchestrationAppLogExcerpt {
    try {
        $output = (Invoke-Compose -Arguments @('logs', '--no-color', 'orchestration-app') | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            return ''
        }

        $lines = @($output -split "`r?`n")
        if ($lines.Count -le 60) {
            return $output
        }

        return ($lines[-60..-1] -join "`n")
    }
    catch {
        return ''
    }
}

function Get-TerminalFailureReason {
    $composeStatus = Get-ComposeStatusText
    if ([string]::IsNullOrWhiteSpace($composeStatus)) {
        return ''
    }

    if ($composeStatus -match 'orchestration-app.*Exited') {
        return 'orchestration-app container exited.'
    }

    if ($composeStatus -match 'postgres.*Exited') {
        return 'postgres container exited.'
    }

    return ''
}

function Get-XDisplayClientProcess {
    $stateLayout = Get-InstallStateLayout
    $expectedClientPath = Join-Path $stateLayout.ClientWorkspace 'Xdisplay.exe'
    $processes = @(Get-Process -Name 'Xdisplay' -ErrorAction SilentlyContinue)
    foreach ($process in ($processes | Sort-Object Id)) {
        try {
            if (-not [string]::Equals($process.Path, $expectedClientPath, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
        }
        catch {
            continue
        }

        return $process
    }

    return $null
}

function Wait-For-XDisplayClientLaunch {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$Deadline
    )

    while ([DateTime]::UtcNow -lt $Deadline) {
        $process = Get-XDisplayClientProcess
        if ($null -ne $process) {
            $startedAtUtc = ''
            try {
                $startedAtUtc = $process.StartTime.ToUniversalTime().ToString('o')
            }
            catch {
                $startedAtUtc = ''
            }

            return [pscustomobject]@{
                observed = $true
                processId = [string]$process.Id
                startedAtUtc = $startedAtUtc
            }
        }

        Start-Sleep -Seconds 5
    }

    return [pscustomobject]@{
        observed = $false
        processId = ''
        startedAtUtc = ''
    }
}

function Export-DiagnosticsArchive {
    $pattern = 'xdisplayai-diagnostics-*.zip'
    $before = Get-ChildItem -Path $env:TEMP -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    & (Join-Path $PSScriptRoot '..\diagnostics\Export-Diagnostics.ps1') | Out-Host
    $after = Get-ChildItem -Path $env:TEMP -Filter $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($null -ne $after) {
        return $after.FullName
    }

    if ($null -ne $before) {
        return $before.FullName
    }

    return ''
}

function Get-Deadline {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report
    )

    return [DateTime]::Parse($Report.deadlineUtc)
}

function Wait-For-BackendHealthy {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report
    )

    $deadline = Get-Deadline -Report $Report
    $stateLayout = Get-InstallStateLayout
    $lastError = ''

    while ([DateTime]::UtcNow -lt $deadline) {
        $health = Invoke-InstalledHealthProbe
        if ($health.isHealthy) {
            return $health.details
        }

        $lastError = $health.error
        $resumeTask = Get-ScheduledTask -TaskName $stateLayout.ResumeTaskName -ErrorAction SilentlyContinue
        $resumeTaskState = if ($null -eq $resumeTask) { 'Absent' } else { [string]$resumeTask.State }
        $terminalFailure = Get-TerminalFailureReason

        if (-not [string]::IsNullOrWhiteSpace($terminalFailure) -and $resumeTaskState -ne 'Running') {
            throw $terminalFailure
        }

        Write-Step "Waiting for backend health; resume task state: $resumeTaskState"
        Start-Sleep -Seconds 15
    }

    if ([string]::IsNullOrWhiteSpace($lastError)) {
        throw "Backend did not become healthy within $TimeoutMinutes minutes."
    }

    throw "Backend did not become healthy within $TimeoutMinutes minutes: $lastError"
}

function Finalize-Validation {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Report,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [string]$LastError,
        [object]$HealthDetails,
        [object]$ClientObservation
    )

    $Report.status = $Status
    $Report.lastError = if ($null -eq $LastError) { '' } else { $LastError }
    $Report.health = $HealthDetails
    if ($null -ne $ClientObservation) {
        $Report.clientProcessObserved = [bool]$ClientObservation.observed
        $Report.clientProcessId = [string]$ClientObservation.processId
        $Report.clientProcessStartTimeUtc = [string]$ClientObservation.startedAtUtc
    }
    $Report.observedStages = Get-BootstrapStageEvidence
    $Report.composeStatus = Get-ComposeStatusText
    $Report.orchestrationAppLogs = Get-OrchestrationAppLogExcerpt
    Write-ValidationReport -Report $Report
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf -ResumeMode:$ResumeValidation
}

Initialize-InstallStateDirectories
$validationLayout = Get-ValidationLayout
$report = if ($ResumeValidation) { Read-ValidationReport } else { $null }
if ($null -eq $report) {
    $report = New-ValidationReport
    Write-ValidationReport -Report $report
}

if ($ResumeValidation) {
    $report.resumedAfterReboot = $true
    Write-ValidationReport -Report $report
}

Start-Transcript -Path $validationLayout.TranscriptFile -Append | Out-Null

try {
    Register-ValidationResumeTask

    if (-not $ResumeValidation) {
        Write-Step 'Starting post-install backend startup validation.'
        & (Join-Path $PSScriptRoot '..\\install\\Bootstrap-InstalledPayload.ps1') -LaunchClient
    }
    else {
        Write-Step 'Resuming post-reboot backend startup validation.'
    }

    $healthDetails = Wait-For-BackendHealthy -Report $report
    $clientObservation = Wait-For-XDisplayClientLaunch -Deadline (Get-Deadline -Report $report)
    if (-not $clientObservation.observed) {
        throw 'Xdisplay client process was not observed after bootstrap completed.'
    }

    Finalize-Validation -Report $report -Status 'passed' -HealthDetails $healthDetails -ClientObservation $clientObservation
    Unregister-ValidationResumeTask
    $report | ConvertTo-Json -Depth 8
}
catch {
    $diagnosticsArchive = ''
    if (-not $SkipDiagnosticsOnFailure) {
        try {
            $diagnosticsArchive = Export-DiagnosticsArchive
        }
        catch {
            $diagnosticsArchive = ''
        }
    }

    $report.diagnosticsArchive = $diagnosticsArchive
    Finalize-Validation -Report $report -Status 'failed' -LastError $_.Exception.Message
    Unregister-ValidationResumeTask
    $report | ConvertTo-Json -Depth 8
    exit 1
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
