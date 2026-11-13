# s63i-hf2b + client/c-186 packaging contracts

日期：2026-11-13

## 目标

在 `molc/xdisplay_ai` 内更新离线安装器**源码合同**，使后续 Windows offline pack 能按提测卡 `s63i-hf2b`（`623b07232…`）与客户端 `client/c-186`（`1898d30c…`）构建。本变更**不**构建、不验收、不部署 `.21`。

## 非目标

- 不发明 Windows 客户端 SHA/size、app image id、docker-save SHA、runtime fingerprint
- 不提交 >50MB 产物或真实密钥
- 不改 `molc/ai_orchestration` / 不碰 PR #13
- 不跑 `.29` 验收；不宣称 800×480 预览标签已修

## 设计

1. 新增 `packaging-export/s63i-hf2b-623b07232/`（镜像 s63f 导出布局的 metadata/scripts；无源码 tar / 无 docker-save）与 `manifests/pins/offline-inputs.s63i-hf2b.json`（缺哈希字段标 PENDING）。
2. 批准修订：`Get-ApprovedBackendRevision*` / tag `prod/s63i-hf2b`；companion `orches/orchestration-app:s63i-hf2b-623b07232`；prompt 31 代理 + PAGE_HTML **v20**（独立键）+ link **v1.10**；迁移仍仅 0001–0003；STAGED_DRAFTER 仍退役。
3. `Assert-ApprovedCardPinsReady` 在打包入口失败关闭；禁止把 Mac c186 / 旧 s63f 镜像身份抄进本卡钉。
4. 用户可见日志从误导性 “s63f” 改为当前卡名，不削弱任何门禁。
5. `.29` 模板常量更新为新卡；指纹与 Windows 客户端 SHA 用 `__PENDING_*__` 占位。

## 父流程下一步

提供 Windows c186 release 哈希，以及四个 Linux amd64 image tar + inspect；填齐 pin 后再在 builder 上全新 WorkRoot 打包。
