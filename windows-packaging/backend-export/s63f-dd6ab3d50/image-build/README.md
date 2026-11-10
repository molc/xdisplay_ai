# s63f `orches/orchestration-app` 已构建镜像

本云 VM **已经用官方 apt 装上 Docker 29.1.3 并完成 linux/amd64 构建**。Dockerfile 未改。

| 项 | 值 |
|---|---|
| image id | `sha256:d820003319943337a16430b0ea094b81087f8290ec06e81c18d2ce48cb377175` |
| tags | `orches/orchestration-app:latest` 与 `orches/orchestration-app:s63f-dd6ab3d50` 与 `orches/orchestration-app:s63f-dd6ab3d505827a94cbc9d59d7067fcce14db6fbe` |
| git-sha label | `dd6ab3d505827a94cbc9d59d7067fcce14db6fbe` |
| docker save SHA256 | `35E5F27EEB4623B816120020116995216CBF2E601CD357ACC676A4384BE9E638` |
| docker save size | 1910100992 |
| 不是 | `F3EECC91AB386DE950F175329AB7CCF078435FF9E863E55708F60485BFFC2309` |

整包 1.91GB **不能** 写入 `/cursor/stores`（`cp: failed to close ... Invalid argument`，留下 0 字节）。24MiB 分片 **可以**。

分片目录：`/cursor/stores/self/artifacts/s63f-app-image/`（76 个 `*.part000`–`*.part075` + `SHA256SUMS.parts.txt` + 整包 sha256）。

```bash
cd /cursor/stores/self/artifacts/s63f-app-image
cat orches_orchestration-app_latest.tar.part??? > orches_orchestration-app_latest.tar
sha256sum -c orches_orchestration-app_latest.tar.sha256
docker load -i orches_orchestration-app_latest.tar
```

构建日志：`05-docker-build.log.gz`（exit 0，`Successfully tagged` 三标签）。Playwright Chromium 141.0.7390.37 / build 1194 断言通过。`xd_render_cli --help` 在镜像内可用。
