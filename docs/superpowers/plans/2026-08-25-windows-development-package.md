# Windows Development Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify a Windows development installer whose backend source, backend `.env`, and XDisplay release are replaceable under `C:\ProgramData\XDisplayAI\workspace` without rebuilding the installer.

**Architecture:** The installer carries dependency-only Docker images plus backend/client seed snapshots. First bootstrap atomically initializes mutable workspace directories, Compose bind-mounts the backend workspace into both Python services, and launch/update scripts always use workspace paths. Image refresh is keyed only by dependency inputs; ordinary source updates use host-file synchronization and service restart.

**Tech Stack:** Windows PowerShell 5.1, Docker Desktop/Compose V2, Qt 5/MinGW, WiX Toolset, MSI/Burn.

**Spec:** `docs/superpowers/specs/2026-08-25-windows-development-package-design.md`

## Global Constraints

- Never write to `/Users/molc/Documents/tricolor_work/ai-orchestration-page-engineering-unified` or `/Users/molc/Documents/tricolor_work/xdisplay`; Windows builds consume copies only.
- Mutable payload root is exactly `C:\ProgramData\XDisplayAI\workspace`.
- No server-side LLM API key prerequisite, persistence, or missing-key warning.
- Release-stage binary packaging is outside this plan.
- Completion requires a clean offline Windows 11 install, runtime behavior checks, log inspection, and update-flow verification.

---

### Task 1: Stage Dependency Images and Mutable Seed Snapshots

**Files:**
- Modify: `windows-packaging/manifests/bundle.json`
- Modify: `windows-packaging/ci/Common.ps1`
- Modify: `windows-packaging/ci/prepare-inputs.ps1`
- Modify: `windows-packaging/ci/stage-payload.ps1`
- Modify: `windows-packaging/tests/Test-BuildOfflinePackage.ps1`

**Interfaces:**
- Produces: `inputs/backend/source`, `payload/seed/backend`, and `payload/seed/client`.
- Produces: `orches/orchestration-app:latest` and `orches/embedding-http:latest` as dependency-only images.
- Consumes: copied backend repo and XDisplay release paths passed to `prepare-inputs.ps1`.

- [ ] **Step 1: Write failing packaging assertions**

Add assertions that `bundle.json` defines `backendSourceDir`, staging copies backend to `seed/backend` and client to `seed/client`, and `prepare-inputs.ps1` does not call `Build-BackendSourceOverlay` or `Add-OrchestrationAppDataLayer`.

```powershell
Assert-True -Condition ($bundleManifest.paths.backendSourceDir -eq 'inputs/backend/source') -Message 'Backend source input path is missing.'
Assert-True -Condition ($stageContent -match "seed/backend" -and $stageContent -match "seed/client") -Message 'Mutable seeds are not staged.'
Assert-True -Condition ($prepareContent -notmatch 'Build-BackendSourceOverlay|Add-OrchestrationAppDataLayer') -Message 'Development images must not bake current source.'
```

- [ ] **Step 2: Run the Windows test and confirm RED**

Run on `win11-wsl2-builder`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\xdisplay_ai\windows-packaging\tests\Test-BuildOfflinePackage.ps1
```

Expected: failure stating the backend source input or seed paths are missing.

- [ ] **Step 3: Implement sanitized source snapshot and base-image tagging**

Add `BackendSourceDir` to `Get-InputLayout`. Mirror the copied backend repo into this directory while excluding `.git`, `.venv`, caches, logs, and an input `.env`; never change the source. Refresh runtime-cache images only when dependency fingerprints differ, then tag those caches as the exported `:latest` images.

```powershell
& docker image tag $imageBuild.RuntimeImageRef $imageBuild.ImageRef
if ($LASTEXITCODE -ne 0) { throw "标记后端基础镜像失败：$($imageBuild.ImageRef)" }
```

Smoke-test the current source through a bind mount:

```powershell
& docker run --rm --mount "type=bind,source=$BackendRepoPath,target=/app" `
    'orches/orchestration-app:latest' python -c 'import app.main'
```

- [ ] **Step 4: Stage seeds and confirm GREEN**

Stage backend and client under `payload/seed`, keep images/compose/scripts under their existing immutable paths, then rerun the Windows test. Expected: `PASS: build-offline-package preflight behavior`.

### Task 2: Initialize and Run the Mutable Development Workspace

**Files:**
- Modify: `windows-packaging/src/scripts/common/Common.ps1`
- Modify: `windows-packaging/src/scripts/install/Install-BackendPayload.ps1`
- Modify: `windows-packaging/src/scripts/install/Bootstrap-InstalledPayload.ps1`
- Modify: `windows-packaging/src/templates/compose/compose.windows.yml.tmpl`
- Modify: `windows-packaging/src/templates/env/runtime.env.tmpl`
- Create: `windows-packaging/src/templates/env/backend.env.tmpl`
- Modify: `windows-packaging/ci/stage-payload.ps1`
- Modify: `windows-packaging/src/scripts/tests/Test-BackendStartupFlow.ps1`
- Modify: `windows-packaging/tests/Test-BuildOfflinePackage.ps1`

**Interfaces:**
- Produces: `Get-InstallStateLayout().BackendWorkspace`, `.ClientWorkspace`, `.BackendSeed`, `.ClientSeed`.
- Produces: `Initialize-DevelopmentWorkspace` with first-install-only seed initialization.
- Consumes: Task 1 seed paths.

- [ ] **Step 1: Write failing workspace-layout assertions**

Assert that Common defines exact ProgramData workspace paths, Compose mounts `${BACKEND_WORKSPACE_PATH}:/app` for both application services, bootstrap launches `ClientWorkspace\Xdisplay.exe`, and no install script refers to `HasApiKey`, `ApiKeySource`, or the old warning.

```powershell
Assert-True -Condition ($commonContent -match "WorkspaceRoot = Join-Path \$dataRoot 'workspace'") -Message 'Workspace root is missing.'
Assert-True -Condition ($composeContent -match 'BACKEND_WORKSPACE_PATH.*:/app') -Message 'Backend bind mount is missing.'
Assert-True -Condition ($installContent -notmatch 'HasApiKey|ApiKeySource|未发现可用的 LLM API key') -Message 'Server-side key warning remains.'
```

- [ ] **Step 2: Run the Windows test and confirm RED**

Run the same packaging test. Expected: failure on workspace layout or bind-mount assertion.

- [ ] **Step 3: Implement atomic first-install workspace initialization**

Extend `Get-InstallStateLayout` and create a helper that copies a seed into a sibling temporary directory, validates a required file, and renames it to the destination only when the destination is absent. Generate `backend/.env` from the staged key-free template only on first initialization.

```powershell
Initialize-WorkspaceDirectory -Seed $layout.BackendSeed -Destination $layout.BackendWorkspace -RequiredRelativePath 'app\main.py'
Initialize-WorkspaceDirectory -Seed $layout.ClientSeed -Destination $layout.ClientWorkspace -RequiredRelativePath 'Xdisplay.exe'
```

Set `BACKEND_WORKSPACE_PATH` in Compose runtime env using forward slashes. Remove all server-side API-key persistence and reporting from runtime initialization.

- [ ] **Step 4: Bind both Python services and launch workspace client**

Add the same backend bind mount to `orchestration-app` and `embedding-worker`. Keep fixed database/Redis/embedding URLs and data paths in Compose; place other application defaults in `backend/.env`. Change bootstrap and the installed validator to resolve XDisplay from `ClientWorkspace`.

- [ ] **Step 5: Run packaging tests and confirm GREEN**

Expected: test exits 0 and all workspace, bind-mount, single-instance, and no-key-warning assertions pass.

### Task 3: Add Explicit Backend and Client Update Entrypoints

**Files:**
- Create: `windows-packaging/src/scripts/update/Update-BackendSource.ps1`
- Create: `windows-packaging/src/scripts/update/Update-XDisplayClient.ps1`
- Modify: `windows-packaging/tests/Test-BuildOfflinePackage.ps1`
- Modify: `windows-packaging/PACKAGING_RUNBOOK.md`

**Interfaces:**
- Produces: `Update-BackendSource.ps1 -SourcePath <directory>`.
- Produces: `Update-XDisplayClient.ps1 -ReleasePath <directory>`.
- Consumes: Task 2 workspace layout and Compose functions.

- [ ] **Step 1: Write failing update-contract assertions**

Assert both scripts exist, never write to their source arguments, backend sync preserves `.env`, backend restarts `embedding-worker` and `orchestration-app`, and client validation requires `Xdisplay.exe`, `plugins\platforms\qwindows.dll`, and `qml`.

- [ ] **Step 2: Run the Windows test and confirm RED**

Expected: failure because the update scripts are absent.

- [ ] **Step 3: Implement backend update**

Require elevation, validate `app\main.py`, mirror with `robocopy /MIR` while excluding `.env`, `.git`, `.venv`, caches, and logs, accept robocopy exit codes 0 through 7, restart both Python services, and run `Test-Health.ps1`.

```powershell
& robocopy $resolvedSource $layout.BackendWorkspace /MIR /XF .env /XD .git .venv __pycache__ .pytest_cache .mypy_cache .ruff_cache
if ($LASTEXITCODE -ge 8) { throw "后端源码同步失败，robocopy exit code: $LASTEXITCODE" }
Invoke-Compose -Arguments @('restart', 'embedding-worker', 'orchestration-app')
```

- [ ] **Step 4: Implement client update**

Require elevation, validate the release, stop only XDisplay processes whose executable path equals the workspace executable, mirror the release, then invoke bootstrap with `-LaunchClient`. Return nonzero on validation, copy, launch, or health failure.

- [ ] **Step 5: Run tests and update the runbook**

Document the initial one-click command, exact mutable directories, the two update commands, image-refresh conditions, and the release-stage boundary. Expected test result: PASS.

### Task 4: Build and Verify on Independent Offline Windows 11

**Files:**
- Modify: `windows-packaging/PACKAGING_RUNBOOK.md`
- Evidence: `windows-packaging/logs/*.json`, builder `dist/dev`, validation-machine reports.

**Interfaces:**
- Consumes: Tasks 1-3.
- Produces: final package hash, clean-install report, runtime report, and update-flow report.

- [ ] **Step 1: Run the full one-click build**

On `win11-wsl2-builder`, run the existing scheduled one-click build against `C:\Work\backend`, `C:\Work\xdisplay`, and prerequisites. Require report status `succeeded`, manifest coverage of every delivery file, and SHA-256 hashes.

- [ ] **Step 2: Transfer without enabling validation-machine networking**

Move the package using the existing transfer disk. Confirm the physical network adapter count remains zero and verify hashes against the builder manifest before installation.

- [ ] **Step 3: Perform a clean install and runtime checks**

Remove only the prior XDisplayAI product/data on the dedicated validation VM, install the new bundle, then require: Burn exit 0, four services running, both health endpoints 200, XDisplay running from ProgramData workspace, no traceback, and no missing-key warning.

- [ ] **Step 4: Verify bind-mount and backend update behavior**

Create a temporary marker in the host backend workspace, assert it is immediately visible at `/app/<marker>` inside both Python containers, remove it, execute `Update-BackendSource.ps1` using a copied backend snapshot, and require health 200 after restart.

- [ ] **Step 5: Verify client replacement and idempotency**

Execute `Update-XDisplayClient.ps1` using the packaged seed release, require the new client process path under ProgramData, run bootstrap again, and assert the healthy existing PID is reused rather than creating another instance.

- [ ] **Step 6: Inspect logs and record final evidence**

Inspect bootstrap, Compose, and application logs for fatal errors/tracebacks; record package sizes/hashes and all pass/fail results in the runbook. Clean temporary VM tasks, transfer disk, transient DNS configuration, and exact temporary files without touching source repositories.
