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

$utf8Bom = [byte[]](0xEF, 0xBB, 0xBF)
$scriptFiles = @(Get-ChildItem -LiteralPath $PackagingRoot -Filter '*.ps1' -File -Recurse | Where-Object {
    $_.FullName -notmatch '[\\/](cache|dist|staging|logs|inputs)[\\/]'
})
Assert-True -Condition ($scriptFiles.Count -gt 0) -Message 'No PowerShell scripts were found under windows-packaging.'

$missingBom = New-Object System.Collections.Generic.List[string]
foreach ($scriptFile in $scriptFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($scriptFile.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq $utf8Bom[0] -and $bytes[1] -eq $utf8Bom[1] -and $bytes[2] -eq $utf8Bom[2])
    if (-not $hasBom) {
        $relative = $scriptFile.FullName.Substring($PackagingRoot.Length).TrimStart('\', '/')
        $missingBom.Add($relative)
    }
}

Assert-True `
    -Condition ($missingBom.Count -eq 0) `
    -Message ("Windows PowerShell 5.1 (CP936) requires a UTF-8 BOM on every packaging .ps1. Missing BOM: " + ($missingBom -join ', '))

$correctnessPath = Join-Path $PackagingRoot 'src\scripts\common\InstallerCorrectness.ps1'
Assert-True -Condition (Test-Path -LiteralPath $correctnessPath) -Message 'InstallerCorrectness.ps1 is missing.'

$correctnessBytes = [System.IO.File]::ReadAllBytes($correctnessPath)
$payloadBytes = $correctnessBytes[3..($correctnessBytes.Length - 1)]
$utf8 = New-Object System.Text.UTF8Encoding $false
$utf8Text = $utf8.GetString($payloadBytes)
Assert-True `
    -Condition ($utf8Text -match '127\.0\.0\.1:\$RequiredPort' -and $utf8Text -match 'APP_HOST_PORT') `
    -Message 'InstallerCorrectness.ps1 must keep the APP_HOST_PORT fail-closed throw text.'

$codePagesAvailable = $false
try {
    Add-Type -AssemblyName System.Text.Encoding.CodePages -ErrorAction Stop | Out-Null
    [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    $codePagesAvailable = $true
}
catch {
    $codePagesAvailable = $false
}

if ($codePagesAvailable) {
    $systemAnsi = [System.Text.Encoding]::GetEncoding(936)
    $misdecoded = $systemAnsi.GetString($payloadBytes)
    Assert-True `
        -Condition ($misdecoded -ne $utf8Text) `
        -Message 'CP936 must not be able to decode the UTF-8 payload as the same script text; that is the native 5.1 failure mode without a BOM.'
    $failClosedPhrase = [string]::Concat([char]0x4E0D, [char]0x4F1A, [char]0x628A, ' APP_HOST_PORT')
    Assert-True `
        -Condition ($misdecoded -notmatch [regex]::Escape($failClosedPhrase)) `
        -Message 'A CP936 misdecode must not preserve the Chinese fail-closed throw, matching the native ParseFile 44-error report.'
}

Write-Output 'PASS: native Windows PowerShell 5.1 UTF-8 BOM encoding checks'
exit 0
