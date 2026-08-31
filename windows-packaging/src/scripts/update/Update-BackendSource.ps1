param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\common\Common.ps1')
. (Join-Path $PSScriptRoot 'PromptPinMigration.ps1')

function Invoke-ElevatedSelf {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        "`"$PSCommandPath`"",
        '-SourcePath',
        "`"$SourcePath`""
    )
    $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $process.ExitCode
}

function Get-NormalizedPathValue {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath((Resolve-Path $Path).Path).TrimEnd('\', '/')
}

if (-not (Test-IsAdministrator)) {
    Invoke-ElevatedSelf
}

if (-not (Test-Path $SourcePath -PathType Container)) {
    throw "后端源码目录不存在：$SourcePath"
}

$resolvedSource = (Resolve-Path $SourcePath).Path
if (-not (Test-Path (Join-Path $resolvedSource 'app\main.py') -PathType Leaf)) {
    throw "后端源码目录缺少 app\main.py：$resolvedSource"
}

$layout = Initialize-DevelopmentWorkspace
if ([string]::Equals(
        (Get-NormalizedPathValue -Path $resolvedSource),
        (Get-NormalizedPathValue -Path $layout.BackendWorkspace),
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw '后端更新源目录不能是当前 workspace 本身。'
}

$logPath = Join-Path $layout.LogsRoot 'backend-update.log'
Start-Transcript -Path $logPath -Append | Out-Null
try {
    Write-Step "同步后端源码：$resolvedSource -> $($layout.BackendWorkspace)"
    $robocopyArguments = @(
        $resolvedSource,
        $layout.BackendWorkspace,
        '/MIR',
        '/R:2',
        '/W:1',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS',
        '/NP',
        '/XF',
        '.env',
        '.DS_Store',
        '/XD',
        '.git',
        '.venv',
        '.mypy_cache',
        '.pytest_cache',
        '.ruff_cache',
        '__pycache__',
        'node_modules',
        'scratchpad-logs',
        'render_debug'
    )
    & robocopy.exe @robocopyArguments | Out-Host
    $robocopyExitCode = $LASTEXITCODE
    if ($robocopyExitCode -ge 8) {
        throw "后端源码同步失败，robocopy exit code: $robocopyExitCode"
    }

    if (-not (Test-Path $layout.BackendEnvFile -PathType Leaf)) {
        throw "后端 workspace 缺少本机配置文件：$($layout.BackendEnvFile)"
    }

    Initialize-RuntimeEnvironment | Out-Null
    Assert-Command -Name 'docker'
    Write-Step '检查新后端所需的 prompt 版本钉扎。'
    $defaultPromptVersions = Get-UpdatedBackendDefaultPromptVersions
    $promptMigration = Update-BackendPromptVersionPins `
        -EnvPath $layout.BackendEnvFile `
        -DefaultPromptVersions $defaultPromptVersions
    if ($promptMigration.Changed) {
        Write-Step "已补充 prompt 版本钉扎：$($promptMigration.Added -join ', ')"
        Write-Step "原 .env 已备份：$($promptMigration.BackupPath)"
    }
    Write-Step '重启 embedding-worker 和 orchestration-app。'
    Invoke-Compose -Arguments @('restart', 'embedding-worker', 'orchestration-app')
    & (Join-Path $PSScriptRoot '..\health\Test-Health.ps1') -TimeoutSeconds 300
    Write-Step '后端源码更新完成。'
}
finally {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
