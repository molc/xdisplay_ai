# Windows Offline Installer Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Windows offline installer survive expected reboot-required/no-restart, resume to a genuinely local 18001 backend, and preserve old configuration/workspace data; keep packaging fail-closed.

**Architecture:** Extract pure decision helpers in `InstallerCorrectness.ps1`, wire them into bootstrap/MSI/health/backend install, and extend the one-command packager with pin/export, secrets scan, SHA256/SHA512, Burn bindings, and Windows-acceptance publish gates.

**Tech Stack:** Windows PowerShell 5.1, WiX v4 Burn/MSI, Docker Desktop named pipe, Pester-less Assert scripts.

## Global Constraints

- Do not reboot the user host, touch .29/.21, erase user data, or merge PRs.
- Never log or package real API keys.
- Keep catalogwrite client SHA `2A80890D...` and Converter `F7C50DB8...` unless a deliberate client fix is required.
- Distinguish source/unit tests from isolated Windows acceptance; do not claim accepted without a real Windows rerun.
- molc/xdisplay 800×480 vs 720×720 label bug remains open and out of this repo.

### Task 1: Durable reboot continuation

- [x] Add `Get-BootstrapRebootAction` and MSI `-LaunchClient -NoAutoReboot` with exit 0 on reboot-required
- [x] Persist `bootstrap-state.json` + `XDisplayAI-ResumeSetup` before returning
- [x] Source tests in `tests/Test-InstallerCorrectness.ps1`

### Task 2: Version-aware config/workspace migration

- [x] `Merge-EnvEntries` keeps all existing keys; force APP_HOST_PORT=18001
- [x] Workspace sync by seed fingerprint, not one-file existence
- [x] Preserve `.env`, extra user files, and Docker volumes

### Task 3: Local 18001 origin

- [x] `Test-LocalBackendOrigin` rejects HTTP 200 + portproxy + remote docker + 18002 drift
- [x] Health probes pass `-TimeoutSec` and bounded wait logs

### Task 4: One-command fail-closed packaging

- [x] Pin/export inputs, secrets scan, SHA256+SHA512 manifest, Burn SHA512 bindings
- [x] `built_not_ready` / `NOT_READY.txt` until Windows evidence PASS
- [x] Version 0.1.4 rebuild instructions in `ONE_CLICK_PACKAGING_GUIDE.md`
