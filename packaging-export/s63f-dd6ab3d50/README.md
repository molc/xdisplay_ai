# s63f offline backend packaging export

This is the packaging-export-only snapshot for Windows offline installer 0.1.4.
It belongs on `molc/xdisplay_ai` (`packaging-export/s63f-dd6ab3d50/`), not in `molc/ai_orchestration`.
This is not a product-code change, not a `.21` deploy, and it contains no user API keys and no multi-GB docker-save tarballs.

## Authoritative source pin

- Tag: `prod/s63f`
- `SOURCE_REVISION` (do **not** use any packaging-export branch HEAD): `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe`
- Source archive: `ai_orchestration-s63f-dd6ab3d50.tar.gz`
  - 2890098 bytes
  - SHA256 `767E9305A7C9C6B57CE9220A971C9F1BE0F8102E46F9A8C67444203253B76A84`
- Build-handoff archive: `s63f-build-handoff.tar.gz`
  - 74378 bytes
  - SHA256 `20BF8758E10BF23D7E90CD2851938AAE6420ED02B1866907B023D166CEB7E044`
- These two tarballs are byte-identical to the packaging-export in `molc/ai_orchestration` PR #13 (`baa7c86759a4d47979829fa4b719d766b71eeb4a`). Do not merge that PR into `ai_orchestration`.

## Final Windows-packaged app image (use this)

The image actually used in the later Windows package is a metadata-only derivation. Do **not** call the older tarballs the final packaged image.

| Item | Value |
|---|---|
| Packaged app image id | `sha256:050efd063552087d4cad4dd6d24408e2d8d114face233e6a2f44a2a65b59d71b` |
| Packaged app image tar | 1910111744 bytes |
| Packaged app image tar SHA256 | `514acd60df0d7d6fab00684116f9f863a6a58f161a4c9baf73cfad76e0b83a24` |
| runtime-fingerprint | `5f1b3896315250c1a62ee3cba769909ffbf6c5f3984f6479cccf6d0e6e168233` |
| git-sha / tag | `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe` / `prod/s63f` |

## Earlier hashes (do not relabel as the final packaged image)

| Item | Value | Meaning |
|---|---|---|
| Cloud VM recipe-built docker-save | `35E5F27EEB4623B816120020116995216CBF2E601CD357ACC676A4384BE9E638` (1910100992 bytes) | Built on the export VM from the s63f Dockerfile; recorded in `image-build/`. Not the later Windows-packaged tar. |
| Forbidden old app tar | `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` | Never label this as s63f. |

Do not commit the multi-gigabyte docker-save or its 24MiB parts.

## Companion official load IDs (not rebuilt in the export PR)

- embedding `27cfc156…`
- pgvector `ddb77949…`
- redis `54fc9bbc…`

## Client pins (unchanged)

- CatalogWrite `Xdisplay.exe` SHA256 `2A80890DB988157371CF28D24CA23685D7933C4E59630E5A2DCD2363B7DB5600`
- Converter SHA256 `F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36`

## Prompt contract

`XDISPLAY_AI_PROMPT_VERSIONS` must be the full s63f default map of 31 registered agents, with five real agent version overlays. `PAGE_HTML` v19 and `STYLESHEET` v6 belong on their own keys, not in the agent map. Retired `XDISPLAY_AI_STAGED_DRAFTER_ENABLED` must be absent. Agent overlays: intent_extractor v2.24, read_display_declarer v1.15, write_action v1.10, link v1.8, sketch v4.0. No new SQL migrations (0001–0003 only).

Windows bind-mount remains `C:\ProgramData\XDisplayAI\workspace\backend` → `/app`. The backend must run on the installation machine; the client connects to `127.0.0.1:18001`.
