# Dockerfile 运行时基座 vs Windows 安装器 bind-mount（s63i-hf2b）

与已验证的 Windows 包装合同一致：镜像烤运行时依赖；`app/` `data/` prompts / `.env` 由 bind-mount `/app` 覆盖。

## 必须同时交付

1. 新 `orches/orchestration-app` 镜像（本卡 git-sha / tag / runtime-fingerprint）
2. 本修订源码快照（含 migrations 0001–0003，除非父机证明另有）

只换源码挂旧镜像、或只换镜像不换源码，都不能标 s63i-hf2b。

## 本机端口政策

- 客户端只连 `127.0.0.1:18001`
- 无 tunnel / portproxy
- 无 `18002` 回退

## 退役键

安装器种子与升级路径不得出现 `XDISPLAY_AI_STAGED_DRAFTER_ENABLED`。
