param(
    [string]$Channel = 'dev',
    [string]$PayloadRoot,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

$stagingLayout = Get-StagingLayout -Channel $Channel
if ([string]::IsNullOrWhiteSpace($PayloadRoot)) {
    $PayloadRoot = $stagingLayout.Payload
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = $stagingLayout.GeneratedPayloadWxs
}

if (-not (Test-Path $PayloadRoot)) {
    throw "未找到 payload 目录：$PayloadRoot"
}

$payloadRootResolved = (Resolve-Path $PayloadRoot).Path
$directories = Get-ChildItem -Path $payloadRootResolved -Directory -Recurse | Sort-Object FullName
$files = Get-ChildItem -Path $payloadRootResolved -File -Recurse | Sort-Object FullName

if (-not $files) {
    throw "payload 目录为空：$payloadRootResolved"
}

function New-WixId {
    param(
        [string]$Prefix,
        [string]$Value
    )

    $hash = (Get-RelativeContentHash -Value $Value).Substring(0, 10)
    $sanitized = ($Value -replace '[^A-Za-z0-9_\.]', '_')
    if ([string]::IsNullOrWhiteSpace($sanitized)) {
        $sanitized = 'root'
    }
    if ($sanitized -notmatch '^[A-Za-z_]') {
        $sanitized = "_$sanitized"
    }
    $candidate = "${Prefix}_${sanitized}"
    if ($candidate.Length -gt 52) {
        $candidate = $candidate.Substring(0, 52)
    }
    return "${candidate}_${hash}"
}

function New-DeterministicGuid {
    param(
        [string]$Value
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    }
    finally {
        $md5.Dispose()
    }

    $hex = ([BitConverter]::ToString($bytes)).Replace('-', '')
    return '{0}-{1}-{2}-{3}-{4}' -f $hex.Substring(0, 8), $hex.Substring(8, 4), $hex.Substring(12, 4), $hex.Substring(16, 4), $hex.Substring(20, 12)
}

function Escape-Xml {
    param(
        [AllowNull()]
        [string]$Value
    )

    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-RelativePathValue {
    param(
        [string]$BasePath,
        [string]$FullPath
    )
    $baseUri = New-Object System.Uri(([System.IO.Path]::GetFullPath((Join-Path $BasePath '.')) + [System.IO.Path]::DirectorySeparatorChar))
    $fullUri = New-Object System.Uri([System.IO.Path]::GetFullPath($FullPath))
    $relativePath = [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString())
    if ($relativePath -eq '.' -or [string]::IsNullOrWhiteSpace($relativePath)) {
        return ''
    }
    return $relativePath.Replace('/', '\')
}

$directoryByRelativePath = @{}
$directoryByRelativePath[''] = 'INSTALLROOTDIR'

$directoryChildren = @{}
$directoryChildren[''] = New-Object System.Collections.ArrayList

foreach ($directory in $directories) {
    $relativePath = Get-RelativePathValue -BasePath $payloadRootResolved -FullPath $directory.FullName
    $parentRelativePath = Split-Path -Path $relativePath -Parent
    if ($parentRelativePath -eq '.' -or $null -eq $parentRelativePath) {
        $parentRelativePath = ''
    }

    $directoryId = New-WixId -Prefix 'DIR' -Value $relativePath
    $directoryByRelativePath[$relativePath] = $directoryId

    if (-not $directoryChildren.ContainsKey($parentRelativePath)) {
        $directoryChildren[$parentRelativePath] = New-Object System.Collections.ArrayList
    }
    if (-not $directoryChildren.ContainsKey($relativePath)) {
        $directoryChildren[$relativePath] = New-Object System.Collections.ArrayList
    }

    [void]$directoryChildren[$parentRelativePath].Add([pscustomobject]@{
        RelativePath = $relativePath
        DirectoryId = $directoryId
        Name = $directory.Name
    })
}

$componentRows = New-Object System.Collections.ArrayList
foreach ($file in $files) {
    $relativePath = Get-RelativePathValue -BasePath $payloadRootResolved -FullPath $file.FullName
    $directoryRelativePath = Split-Path -Path $relativePath -Parent
    if ($directoryRelativePath -eq '.' -or $null -eq $directoryRelativePath) {
        $directoryRelativePath = ''
    }

    $directoryId = $directoryByRelativePath[$directoryRelativePath]
    $componentId = New-WixId -Prefix 'CMP' -Value $relativePath
    $fileId = New-WixId -Prefix 'FILE' -Value $relativePath
    $guid = New-DeterministicGuid -Value $relativePath

    [void]$componentRows.Add([pscustomobject]@{
        ComponentId = $componentId
        DirectoryId = $directoryId
        FileId = $fileId
        Guid = $guid
        Source = $file.FullName
    })
}

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine('<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs">')
[void]$builder.AppendLine('  <Fragment>')
[void]$builder.AppendLine('    <DirectoryRef Id="INSTALLROOTDIR">')

function Add-DirectoryXml {
    param(
        [string]$ParentRelativePath,
        [int]$Depth
    )

    if (-not $directoryChildren.ContainsKey($ParentRelativePath)) {
        return
    }

    $indent = '  ' * $Depth
    foreach ($child in ($directoryChildren[$ParentRelativePath] | Sort-Object RelativePath)) {
        [void]$builder.AppendLine("$indent<Directory Id=""$($child.DirectoryId)"" Name=""$(Escape-Xml $child.Name)"">")
        Add-DirectoryXml -ParentRelativePath $child.RelativePath -Depth ($Depth + 1)
        [void]$builder.AppendLine("$indent</Directory>")
    }
}

Add-DirectoryXml -ParentRelativePath '' -Depth 3

[void]$builder.AppendLine('    </DirectoryRef>')
[void]$builder.AppendLine('  </Fragment>')
[void]$builder.AppendLine('  <Fragment>')
[void]$builder.AppendLine('    <ComponentGroup Id="PayloadComponents">')

foreach ($row in $componentRows) {
    [void]$builder.AppendLine("      <Component Id=""$($row.ComponentId)"" Directory=""$($row.DirectoryId)"" Guid=""$($row.Guid)"" Bitness=""always64"">")
    [void]$builder.AppendLine("        <File Id=""$($row.FileId)"" Source=""$(Escape-Xml $row.Source)"" KeyPath=""yes"" />")
    [void]$builder.AppendLine('      </Component>')
}

[void]$builder.AppendLine('    </ComponentGroup>')
[void]$builder.AppendLine('  </Fragment>')
[void]$builder.AppendLine('</Wix>')

$outputDirectory = Split-Path -Path $OutputPath -Parent
Ensure-Directory -Path $outputDirectory
Write-TextFileUtf8NoBom -Path $OutputPath -Content $builder.ToString()

Write-Step "已生成 payload authoring：$OutputPath"
