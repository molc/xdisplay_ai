Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SecretScanTextExtensions {
    return @('.json', '.env', '.yml', '.yaml', '.ps1', '.cmd', '.txt', '.tmpl', '.xml', '.wxs', '.md', '.log', '.cfg', '.ini')
}

function Invoke-SecretsScan {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [AllowEmptyCollection()]
        [string[]]$ExcludeDirectoryNames = @('.git', 'cache', 'logs')
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        throw "Secrets scan root does not exist: $Root"
    }

    $hits = New-Object System.Collections.Generic.List[string]
    $textExtensions = @(Get-SecretScanTextExtensions)
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $directoryNames = @($_.DirectoryName.Split([IO.Path]::DirectorySeparatorChar))
        $excluded = $false
        foreach ($name in $ExcludeDirectoryNames) {
            if ($directoryNames -contains $name) {
                $excluded = $true
                break
            }
        }
        -not $excluded
    })

    foreach ($file in $files) {
        if ([string]::Equals($file.Name, 'secret.env', [StringComparison]::OrdinalIgnoreCase)) {
            if ($file.Length -gt 0) {
                $hits.Add($file.FullName + ': secret.env must not be packaged')
            }
            continue
        }

        if ($textExtensions -notcontains $file.Extension.ToLowerInvariant()) {
            continue
        }

        $lines = @(Get-Content -LiteralPath $file.FullName)
        $lineNumber = 0
        foreach ($line in $lines) {
            $lineNumber++
            if ($line -match '^\s*#' ) {
                continue
            }

            $value = $line
            if ($line -match '^[A-Za-z_][A-Za-z0-9_]*=(.*)$') {
                $keyName = ($line -split '=', 2)[0]
                $value = $Matches[1]
                if (-not (Test-IsSecretEnvKey -Name $keyName) -and -not (Test-SecretLikeValue -Value $value)) {
                    continue
                }
                if (Test-IsSecretEnvKey -Name $keyName -and -not (Test-SecretLikeValue -Value $value) -and [string]::IsNullOrWhiteSpace($value)) {
                    continue
                }
            }

            if (Test-SecretLikeValue -Value $value) {
                $hits.Add("$($file.Name):$lineNumber")
            }
        }
    }

    if ($hits.Count -gt 0) {
        throw "Secrets scan failed (values not printed). Locations: $($hits -join ', ')"
    }

    return [pscustomobject]@{
        ok = $true
        scannedRoot = $Root
        hitCount = 0
    }
}

function Export-InputPins {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputsRoot,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $missing = @(Get-MissingOfflineInputRelativePaths -InputsRoot $InputsRoot)
    if ($missing.Count -gt 0) {
        throw "离线输入不完整，缺少确切文件：$($missing -join ', ')"
    }

    $pins = @()
    foreach ($relativePath in @(Get-RequiredOfflineInputRelativePaths)) {
        $absolutePath = Join-InstallRelativePath -Root $InputsRoot -RelativePath $relativePath
        $item = Get-Item -LiteralPath $absolutePath
        $pins += [pscustomobject]@{
            relativePath = $relativePath
            sizeBytes = $item.Length
            sha256 = (Get-FileHash -Path $absolutePath -Algorithm SHA256).Hash.ToLowerInvariant()
            sha512 = (Get-FileHash -Path $absolutePath -Algorithm SHA512).Hash.ToLowerInvariant()
        }
    }

    $payload = [pscustomobject]@{
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        inputsRoot = $InputsRoot
        files = $pins
    }
    Write-TextFileUtf8NoBom -Path $OutputPath -Content ($payload | ConvertTo-Json -Depth 6)
    return $payload
}

function Assert-BurnExternalPayloadBindings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath,
        [Parameter(Mandatory = $true)]
        [string[]]$PayloadPaths
    )

    $missing = @()
    foreach ($payloadPath in $PayloadPaths) {
        if (-not (Test-Path -LiteralPath $payloadPath)) {
            $missing += Split-Path -Path $payloadPath -Leaf
            continue
        }
        if (-not (Test-BurnPayloadSha512Binding -BundlePath $BundlePath -PayloadPath $payloadPath)) {
            $missing += Split-Path -Path $payloadPath -Leaf
        }
    }

    if ($missing.Count -gt 0) {
        throw "Burn SHA512 绑定校验失败，未在 bundle 中找到这些相邻 payload 的哈希：$($missing -join ', ')"
    }
}

function Assert-WindowsAcceptanceEvidence {
    param(
        [AllowEmptyString()]
        [string]$EvidencePath = ''
    )

    if ([string]::IsNullOrWhiteSpace($EvidencePath) -or -not (Test-Path -LiteralPath $EvidencePath)) {
        return Test-WindowsAcceptanceEvidence -Evidence $null
    }

    $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    return Test-WindowsAcceptanceEvidence -Evidence $evidence
}

function Write-ReleaseHold {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DistDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [AllowEmptyCollection()]
        [string[]]$Failures = @()
    )

    $holdPath = Join-Path $DistDirectory 'NOT_READY.txt'
    $statusPath = Join-Path $DistDirectory 'release-status.json'
    $payload = [pscustomobject]@{
        status = $Status
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        windowsAcceptance = $Status
        failures = @($Failures)
        note = 'Source/unit tests are not Windows acceptance. Do not publish Downloads until fresh-offline reboot-resume and old-version preservation actually PASS.'
    }
    Write-TextFileUtf8NoBom -Path $statusPath -Content ($payload | ConvertTo-Json -Depth 6)

    if ($Status -ne 'pass') {
        $lines = @(
            'RELEASE HOLD / NOT_READY',
            'This directory is a rebuilt candidate, not an accepted installer.',
            'Windows isolated acceptance was not PASS.'
        ) + @($Failures)
        Write-TextFileUtf8NoBom -Path $holdPath -Content (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
    }
    elseif (Test-Path -LiteralPath $holdPath) {
        Remove-Item -LiteralPath $holdPath -Force
    }

    return $statusPath
}
