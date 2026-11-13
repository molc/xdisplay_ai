# s63i-hf2b offline backend packaging export (metadata / scripts)

This is the packaging-export-only snapshot for the **s63i-hf2b** Windows offline installer card.
It belongs on `molc/xdisplay_ai` (`packaging-export/s63i-hf2b-623b07232/`), not in `molc/ai_orchestration`.
This is not a product-code change, not a `.21` deploy, and it contains no user API keys and no multi-GB docker-save tarballs.

**Status: NOT BUILT / NOT ACCEPTED.** Required hashes below are intentionally pending. Pack and qualification scripts must refuse until parent supplies them.

## Authoritative source pin

- Author card: `s63i-hf2b`
- Tag (installer gate): `prod/s63i-hf2`
- `SOURCE_REVISION` (do **not** use any packaging-export branch HEAD): `623b072320d2e8c68059ec5e7e33958267203a9c` (prefix `623b07232`)
- Source archive: `ai_orchestration-s63i-hf2b-623b07232.sanitized.tar.gz` — **3205603** bytes, SHA256 `68B6E331A6942A9CBDE6FDDFA7579E1AD8227B57C1D05E0D6C724F32A8317278` (do not commit the tarball).

## Final Windows-packaged app image (pending)

| Item | Value |
|---|---|
| Packaged app image id | **PENDING** |
| Packaged app image tar SHA256 / bytes | **PENDING** |
| runtime-fingerprint | **PENDING** |
| git-sha / tag | `623b072320d2e8c68059ec5e7e33958267203a9c` / `prod/s63i-hf2` |

### Forbidden identities (never relabel as this card)

| Item | Value |
|---|---|
| Previous non-s63f app tar | `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` |
| s63f builder-packaged app tar | `514ACD60DF0D7D6FAB00684116F9F863A6A58F161A4C9BAF73CFAD76E0B83A24` |
| s63f cloud recipe docker-save | `35E5F27EEB4623B816120020116995216CBF2E601CD357ACC676A4384BE9E638` |
| s63f packaged image id / fingerprint | `050efd06…` / `5f1b3896…` |
| Old `orches/orchestration-app:latest` | `a001031bb9b0…` |

Do not commit multi-gigabyte docker-save tarballs or any file >50MB.

## Companion images

embedding / pgvector / redis: **unproven for this card** until parent provides four Linux amd64 image tars with inspect records. Historical prereq pins for Docker Desktop / VC / WSL remain valid (see `offline-inputs.s63i-hf2b.json`).

## Client pins

- Target: tag `client/c-186`, commit `1898d30cc036241f5af5283c4dc9d7f95dbb8887`, branch `codex/int-6001`
- Windows `Xdisplay.exe` SHA256 / bytes: **PENDING**
- Mac package SHA1 `50ba545e…` / SHA256 `afde40db…` are Mac bytes only — **MUST NOT** be used as the Windows client pin
- Converter: retain Word-fix `F7C50DB87D082DE31A154A123B05FA3D327A4117F7CE5FCD2F5E51CF3D595D36` until parent says otherwise

## Prompt contract

`XDISPLAY_AI_PROMPT_VERSIONS` must be the full registered map of **31** agents, with five agent version overlays. `PAGE_HTML` **v20** and `STYLESHEET` **v6** belong on their own Settings keys, not in the agent map. Retired `XDISPLAY_AI_STAGED_DRAFTER_ENABLED` must be absent.

Agent overlays: intent_extractor v2.24, read_display_declarer v1.15, write_action v1.10, link **v1.10**, sketch v4.0. No new SQL migrations (0001–0003 only) unless the source tree proves otherwise.

Windows bind-mount remains `C:\ProgramData\XDisplayAI\workspace\backend` → `/app`. The backend must run on the installation machine; the client connects to `127.0.0.1:18001` only (no tunnel/portproxy, no 18002 fallback).

## Rebuild

```bash
# After parent places the verified source archive next to this script:
S63I_HF2B_SOURCE_TAR=/path/to/ai_orchestration-s63i-hf2b-623b07232.tar.gz \
  ./rebuild-orches-app-image.sh
```

Rebuild requires this verified source SHA. Do not invent a fingerprint value; compute after this contract with Common.ps1 + strict-ocr inputs.
