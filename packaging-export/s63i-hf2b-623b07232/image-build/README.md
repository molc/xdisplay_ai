# s63i-hf2b `orches/orchestration-app` image build records

**PENDING.** No docker-save was produced in this packaging-source PR.

When parent builds:

- Record inspect JSON next to the tar (never commit the multi-GB tar).
- Labels: git-sha=`623b072320d2e8c68059ec5e7e33958267203a9c`, tag=`prod/s63i-hf2`, runtime-fingerprint=<computed>.
- Companion tags: `orches/orchestration-app:s63i-hf2b-623b07232`, `orches/orchestration-app:latest`.
- Refuse if tar SHA equals any forbidden identity listed in `../provenance.json`.
