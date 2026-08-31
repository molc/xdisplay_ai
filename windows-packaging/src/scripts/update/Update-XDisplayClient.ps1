param(
    [Parameter(Mandatory = $true)]
    [string]$ReleasePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')

function Invoke-ElevatedSelf {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`"",
        '-ReleasePath',
        "`"$ReleasePath`""
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Assert-ClientRelease {
    param([Parameter(Mandatory = $true)][string]$Path)

    foreach ($requiredRelativePath in @(
        'Xdisplay.exe',
        'plugins\platforms\qwindows.dll',
        'data\keyboard_a\keypage.json',
        'data\keyboard_b\keypage.json',
        'data\keyboard_c\keypage.json',
        'data\keyboard_d\keypage.json',
        'data\keyboard_e\keypage.json'
    )) {
        $requiredPath = Join-Path $Path $requiredRelativePath
        if (-not (Test-Path $requiredPath -PathType Leaf)) {
            throw "XDisplay release 缺少：$requiredRelativePath"
        }
    }

    $qmlPath = Join-Path $Path 'qml'
    if (-not (Test-Path $qmlPath -PathType Container)) {
        throw 'XDisplay release 缺少 qml 目录。'
    }
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
}

if (-not (Test-Path $ReleasePath -PathType Container)) {
    throw "XDisplay release 目录不存在：$ReleasePath"
}

$resolvedRelease = Resolve-XDisplayFileSystemPath -Path $ReleasePath
Assert-ClientRelease -Path $resolvedRelease
$layout = Initialize-DevelopmentWorkspace
$workspaceExecutable = Join-Path $layout.ClientWorkspace 'Xdisplay.exe'
$stagingDirectory = Join-Path $layout.WorkspaceRoot ('.client-update-' + [System.Guid]::NewGuid().ToString('N'))
$backupDirectory = Join-Path $layout.WorkspaceRoot ('.client-backup-' + [System.Guid]::NewGuid().ToString('N'))
$logPath = Join-Path $layout.LogsRoot 'client-update.log'

Start-Transcript -Path $logPath -Append | Out-Null
try {
    Write-Step "校验并暂存 XDisplay release：$resolvedRelease"
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    & robocopy.exe $resolvedRelease $stagingDirectory /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Host
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "XDisplay release 同步失败，robocopy exit code: $robocopyExitCode"
    }
    Assert-ClientRelease -Path $stagingDirectory

    foreach ($process in @(Get-Process -Name 'Xdisplay' -ErrorAction SilentlyContinue)) {
        try {
            if ([string]::Equals($process.Path, $workspaceExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-Process -Id $process.Id -Force
                $process.WaitForExit(10000) | Out-Null
            }
        }
        catch {
        }
    }

    Move-Item -Path $layout.ClientWorkspace -Destination $backupDirectory
    Move-Item -Path $stagingDirectory -Destination $layout.ClientWorkspace
    try {
        & (Join-Path $PSScriptRoot '..\install\Bootstrap-InstalledPayload.ps1') -LaunchClient
        if (-not $?) {
            throw '更新后的 XDisplay 启动失败。'
        }
    }
    catch {
        if (Test-Path $layout.ClientWorkspace) {
            Remove-Item -Path $layout.ClientWorkspace -Recurse -Force
        }
        Move-Item -Path $backupDirectory -Destination $layout.ClientWorkspace
        throw
    }

    Remove-Item -Path $backupDirectory -Recurse -Force
    Write-Step 'XDisplay release 更新完成。'
}
finally {
    foreach ($temporaryPath in @($stagingDirectory, $backupDirectory)) {
        if (Test-Path $temporaryPath) {
            Remove-Item -Path $temporaryPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
