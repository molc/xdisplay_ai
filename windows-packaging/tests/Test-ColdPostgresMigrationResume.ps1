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

$pgIsReady = ConvertTo-PostgresQueryProbeResult -ExitCode 0 -Output (Get-F09ColdPostgresPgIsReadyAcceptingOutput)
Assert-True -Condition (-not $pgIsReady.Ready) -Message 'pg_isready "accepting connections" must not count as migration-ready; that is the f09 cold-init false positive.'
Assert-True -Condition (-not $pgIsReady.Transient) -Message 'pg_isready success text is not a transient SQL error; it is the wrong probe.'

$shuttingDown = ConvertTo-PostgresQueryProbeResult -ExitCode 2 -Output (Get-F09ColdPostgresFatalShuttingDownOutput)
Assert-True -Condition (-not $shuttingDown.Ready) -Message 'FATAL shutting down during docker-entrypoint temp-server stop must not be migration-ready.'
Assert-True -Condition $shuttingDown.Transient -Message 'FATAL shutting down must be classified as a transient cold-start error so wait/retry can continue fail-closed.'

$missingDb = ConvertTo-PostgresQueryProbeResult -ExitCode 2 -Output 'psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: FATAL:  database "ai_orchestration" does not exist'
Assert-True -Condition (-not $missingDb.Ready) -Message 'ai_orchestration missing during initdb CREATE DATABASE must not be migration-ready.'
Assert-True -Condition $missingDb.Transient -Message 'Missing ai_orchestration during cold init must be retried, not treated as a permanent failure.'

$queryOk = ConvertTo-PostgresQueryProbeResult -ExitCode 0 -Output "1`n"
Assert-True -Condition $queryOk.Ready -Message 'psql -t -A SELECT 1 must be the migration-ready signal.'

$permanent = ConvertTo-PostgresQueryProbeResult -ExitCode 2 -Output 'ERROR:  permission denied for schema public'
Assert-True -Condition (-not $permanent.Ready) -Message 'Non-transient SQL errors must not look ready.'
Assert-True -Condition (-not $permanent.Transient) -Message 'Permission errors must fail closed instead of being retried as cold-start noise.'

$composeWarning = New-Object System.Management.Automation.ErrorRecord (New-Object System.Exception 'time="2026-11-10T12:06:46+08:00" level=warning msg="C:\\Program Files\\XDisplayAI\\docker\\compose\\docker-compose.yml: the attribute `version` is obsolete, it will be ignored, please remove it to avoid potential confusion"'), 'NativeCommandError', 'FromStdErr', $null
$composeId = '28966287ed3b2efc4d975de4107b3de3e74b8ba10fad3a33500db26bbf683f55'
Assert-True -Condition ((Select-ComposeContainerId -Output @($composeWarning, $composeWarning, $composeId)) -eq $composeId) -Message 'compose stderr warnings merged by 2>&1 must not pollute the container id (dot29 reboot-resume regression: docker exec "time=... level=warning ..." -> No such container).'
Assert-True -Condition ((Select-ComposeContainerId -Output @('time="x" level=warning msg="The FOO variable is not set"', "$composeId`r`n")) -eq $composeId) -Message 'String-form warning lines and trailing CRLF must be ignored too.'
Assert-True -Condition ((Select-ComposeContainerId -Output @()) -eq '') -Message 'No container id must stay an empty string so the wait loop keeps polling.'
Assert-True -Condition ((Select-ComposeContainerId -Output $null) -eq '') -Message 'Null compose output must stay an empty string.'

$tempRenames = @('\??\C:\Users\admin\AppData\Local\Temp\DEL22B5.tmp', '', '\??\C:\Program Files (x86)\Microsoft\Edge\Application\142.0.3595.65\old_chrome.exe', '!\??\C:\Users\admin\AppData\Local\Temp\DELFD32.tmp')
Assert-True -Condition (-not (Test-PendingFileRenameRequiresReboot -Entries $tempRenames)) -Message 'Temp-file / Edge PendingFileRenameOperations must not force a reboot (dot29: every upgrade demanded a reboot because of %TEMP%\DEL*.tmp left by the previous uninstall).'
Assert-True -Condition (-not (Test-PendingFileRenameRequiresReboot -Entries $null)) -Message 'Null PendingFileRenameOperations must not force a reboot.'
Assert-True -Condition (Test-PendingFileRenameRequiresReboot -Entries @('\??\C:\Windows\System32\drivers\vmbus.sys')) -Message 'Driver replacement pending must still force a reboot.'
Assert-True -Condition (Test-PendingFileRenameRequiresReboot -Entries @('\??\C:\Users\admin\AppData\Local\Temp\DEL1.tmp', '\??\C:\Program Files\Docker\Docker\resources\bin\docker.exe')) -Message 'A pending Docker Desktop file replacement must force a reboot even when mixed with temp entries.'
Assert-True -Condition (Test-PendingFileRenameRequiresReboot -Entries @('\??\C:\Program Files\WSL\wsl.exe')) -Message 'A pending WSL file replacement must force a reboot.'

$absentHistory = ConvertTo-PostgresHistoryTablePresenceResult -ExitCode 0 -Output ''
Assert-True -Condition (-not $absentHistory.Present) -Message 'Empty to_regclass result is the measured f09 SELECT-only failure: table absent.'
$presentHistory = ConvertTo-PostgresHistoryTablePresenceResult -ExitCode 0 -Output "offline_migration_history`n"
Assert-True -Condition $presentHistory.Present -Message 'to_regclass must confirm public.offline_migration_history before migrations run.'

$oldPgIsReadyOnlySequence = @(
    $pgIsReady
)
Assert-True -Condition (-not (Test-PostgresReadyProbeSequence -Probes $oldPgIsReadyOnlySequence)) -Message 'The f09 pg_isready-only wait would have returned ready during the temp server; that sequence must stay NOT ready.'

$actualF09Sequence = @(
    $pgIsReady,
    $missingDb,
    $shuttingDown,
    $queryOk
)
Assert-True -Condition (-not (Test-PostgresReadyProbeSequence -Probes $actualF09Sequence)) -Message 'A single SELECT 1 after the shutdown FATAL is not enough; docker-entrypoint can still bounce the temp server.'

$recoveredSequence = @(
    $pgIsReady,
    $missingDb,
    $shuttingDown,
    $queryOk,
    $queryOk
)
Assert-True -Condition (Test-PostgresReadyProbeSequence -Probes $recoveredSequence) -Message 'Two consecutive SELECT 1 successes after the temp-server shutdown window must become ready.'

$interruptedSequence = @(
    $queryOk,
    $shuttingDown,
    $queryOk
)
Assert-True -Condition (-not (Test-PostgresReadyProbeSequence -Probes $interruptedSequence)) -Message 'A shutting-down probe must reset the consecutive-success counter.'

$backendInstall = Get-Content -LiteralPath (Join-Path $PackagingRoot 'src\scripts\install\Install-BackendPayload.ps1') -Raw
Assert-True -Condition ($backendInstall -notmatch 'pg_isready -U') -Message 'Install-BackendPayload must not call pg_isready for migration readiness.'
Assert-True -Condition ($backendInstall -match "SELECT 1;") -Message 'Wait-For-PostgresReady must probe with SELECT 1 against ai_orchestration.'
Assert-True -Condition ($backendInstall -match 'to_regclass\(''public.offline_migration_history''\)') -Message 'Ensure-MigrationHistoryTable must SELECT to_regclass after CREATE, not trust CREATE exit alone.'
Assert-True -Condition ($backendInstall -match '初始化 offline_migration_history 失败') -Message 'The history-table gate must remain fail-closed.'
Assert-True -Condition ($backendInstall -match 'Test-IsPostgresTransientUnavailableMessage') -Message 'CREATE TABLE retries must be limited to transient cold-start errors.'

Write-Output 'PASS: cold Postgres / reboot-resume migration-history readiness'
exit 0
