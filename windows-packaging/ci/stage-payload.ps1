param(
    [string]$Channel = 'dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Common.ps1')

function Copy-ClientReleaseTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "客户端发布目录不存在：$Source"
    }

    Ensure-Directory -Path $Destination

    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        $rawName = $_.Name
        $relativeSegments = @($rawName -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($relativeSegments.Count -eq 0) {
            return
        }

        $targetPath = $Destination
        foreach ($relativeSegment in $relativeSegments) {
            $targetPath = Join-Path $targetPath $relativeSegment
        }

        if ($_.PSIsContainer -or $rawName.EndsWith('\') -or $rawName.EndsWith('/')) {
            Ensure-Directory -Path $targetPath
            if ($_.PSIsContainer) {
                Copy-Tree -Source $_.FullName -Destination $targetPath
            }
            return
        }

        $targetParent = Split-Path -Path $targetPath -Parent
        Ensure-Directory -Path $targetParent
        Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
    }
}

& (Join-Path $PSScriptRoot 'validate.ps1') -Channel $Channel -RequirePayloads

$bundleManifest = Get-BundleManifest
$channelManifest = Get-ChannelManifest -Channel $Channel
$portsManifest = Get-PortsManifest
$inputLayout = Get-InputLayout
$stagingLayout = Get-StagingLayout -Channel $Channel

Write-Step "渲染离线 payload：channel=$Channel"

Reset-Directory -Path $stagingLayout.Root
Ensure-Directory -Path $stagingLayout.Payload
Ensure-Directory -Path $stagingLayout.WxsGenerated
Ensure-Directory -Path $stagingLayout.Dist

$payloadRoot = $stagingLayout.Payload

Copy-ClientReleaseTree -Source $inputLayout.ClientReleaseDir -Destination (Join-Path $payloadRoot 'seed/client')
Copy-Tree -Source $inputLayout.BackendSourceDir -Destination (Join-Path $payloadRoot 'seed/backend')
Copy-Tree -Source $inputLayout.BackendImagesDir -Destination (Join-Path $payloadRoot 'docker/images')
Copy-Tree -Source $inputLayout.BackendMigrationDir -Destination (Join-Path $payloadRoot 'docker/migrations')
Copy-Tree -Source (Join-FromRoot 'src/scripts') -Destination (Join-Path $payloadRoot 'scripts')

Ensure-Directory -Path (Join-Path $payloadRoot 'docker/compose')
Ensure-Directory -Path (Join-Path $payloadRoot 'docker/env')
Ensure-Directory -Path (Join-Path $payloadRoot 'launchers')
Ensure-Directory -Path (Join-Path $payloadRoot 'metadata')

Copy-Item -Path $inputLayout.BackendComposeBase -Destination (Join-Path $payloadRoot 'docker/compose/docker-compose.yml') -Force
Copy-Item -Path (Join-FromRoot 'manifests/bundle.json') -Destination (Join-Path $payloadRoot 'metadata/bundle.json') -Force
Copy-Item -Path (Join-FromRoot "manifests/channels/$Channel.json") -Destination (Join-Path $payloadRoot "metadata/$Channel.json") -Force

Render-Template `
    -TemplatePath (Join-FromRoot 'src/templates/compose/compose.windows.yml.tmpl') `
    -DestinationPath (Join-Path $payloadRoot 'docker/compose/compose.windows.yml')

Render-Template `
    -TemplatePath (Join-FromRoot 'src/templates/env/runtime.env.tmpl') `
    -DestinationPath (Join-Path $payloadRoot 'docker/env/runtime.defaults.env') `
    -Tokens @{
        APP_HOST_PORT = $portsManifest.ports.app
        POSTGRES_HOST_PORT = $portsManifest.ports.postgres
        REDIS_HOST_PORT = $portsManifest.ports.redis
        EMBEDDING_HOST_PORT = $portsManifest.ports.embedding
    }

Render-Template `
    -TemplatePath (Join-FromRoot 'src/templates/env/backend.env.tmpl') `
    -DestinationPath (Join-Path $payloadRoot 'seed/backend/.env') `
    -Tokens @{
        ENVIRONMENT = $channelManifest.name
        LOG_LEVEL = $channelManifest.logLevel
        APP_HOST_PORT = $portsManifest.ports.app
        RAG_BACKEND = $bundleManifest.runtime.rag.backend
        RAG_ACTIVE_INDEX_VERSION = $bundleManifest.runtime.rag.activeIndexVersion
        RAG_EMBEDDING_VERSION = $bundleManifest.runtime.rag.embeddingVersion
        LLM_PROVIDER = $bundleManifest.runtime.llm.provider
        LLM_BASE_URL = $bundleManifest.runtime.llm.baseUrl
        LLM_MODEL_DEFAULT = $bundleManifest.runtime.llm.modelDefault
    }

Render-Template `
    -TemplatePath (Join-FromRoot 'src/templates/launcher/Launch-XDisplay.cmd.tmpl') `
    -DestinationPath (Join-Path $payloadRoot 'launchers/Launch-XDisplay.cmd') `
    -Tokens @{
        APP_HOST_PORT = $portsManifest.ports.app
    }

Render-Template `
    -TemplatePath (Join-FromRoot 'src/templates/launcher/Complete-Offline-Setup.cmd.tmpl') `
    -DestinationPath (Join-Path $payloadRoot 'launchers/Complete-Offline-Setup.cmd')

Write-Step "payload 已输出到：$payloadRoot"
