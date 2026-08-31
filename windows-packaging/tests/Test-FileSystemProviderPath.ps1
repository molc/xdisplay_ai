param(
    [Parameter(Mandatory = $true)]
    [string]$CommonScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. $CommonScriptPath

$resolvedPath = Resolve-XDisplayFileSystemPath -Path $FixturePath

if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
    throw "Resolved path is not an existing directory: $resolvedPath"
}

if ($resolvedPath.Contains('::')) {
    throw "Resolved path must not contain a PowerShell provider qualifier: $resolvedPath"
}

if ($FixturePath.StartsWith('\\') -and -not $resolvedPath.StartsWith('\\')) {
    throw "Resolved UNC path must remain UNC: $resolvedPath"
}

Write-Host '[windows-packaging-test] FileSystem provider path normalization passed.'
