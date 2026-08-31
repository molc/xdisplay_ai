# Windows Packaging 交接文档
更新时间：2026-08-14

## 目标与范围
当前工作目标是继续完善 `windows-packaging`，让 Windows 11 上的离线一键安装/部署流程稳定完成：
- `xdisplay` 客户端安装
- 后端离线镜像导入
- `docker compose up`
- 数据库迁移
- 应用健康检查
- 安装后自动化验证

本轮工作严格限制在 `windows-packaging` 内，不修改 `xdisplay` 和 `ai_orchestration` 源码仓。

## 硬约束
- 只能改 `xdisplay_ai/windows-packaging`
- 不能改 `xdisplay` 源码
- 不能改 `ai_orchestration` 源码
- 当前 builder 验证环境是 `172.19.103.18` 宿主机上的 `win11-wsl2-builder`
- 远端后端参考环境在 `172.19.103.21`

## 本轮已完成的关键修复

### 1. 修复安装后验证脚本在 WinPS 5.1 下的解析失败
文件：
- `windows-packaging/src/scripts/tests/Test-BackendStartupFlow.ps1`

问题：
- 脚本里的中文字面量在 Windows PowerShell 5.1 下触发 `ParserError`
- 现象是计划任务看似执行了，但没有生成 `backend-startup-validation.json` / `.log`

处理：
- 把阶段识别相关的非 ASCII 字面量改成 ASCII 安全表达
- 调整少量错误文本为 ASCII 形式，避免 WinPS 5.1 编码/解析问题

结果：
- 该脚本现在能稳定运行并生成：
  - `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.json`
  - `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.log`

### 2. 修复数据库迁移阶段的空值异常
文件：
- `windows-packaging/src/scripts/install/Install-BackendPayload.ps1`

问题：
- `Test-MigrationApplied` 在 `psql` 查询无结果时，对 `$null` 调用 `.Trim()`
- 这会在“尚未应用某条迁移”时直接把安装流程打断

处理：
- 改为：
  - `| Out-String).Trim()`
  - 并增加 `$LASTEXITCODE` 检查

结果：
- 迁移已能完整执行：
  - `0001_init.sql`
  - `0002_rag.sql`
  - `0003_orch_runtime.sql`

### 3. 修复离线镜像准备逻辑，避免导出陈旧本地镜像
文件：
- `windows-packaging/ci/prepare-inputs.ps1`

新增：
- `-SkipBackendImageBuild`
- `Build-BackendImagesFromSource`

处理：
- 默认先从 `BackendRepoPath` 对以下镜像做构建：
  - `orches/orchestration-app:latest`
  - `orches/embedding-http:latest`
- 构建完成后再执行 `docker save` 导出到 `inputs/backend/images`

目的：
- 避免继续把某台机器上“已经存在但版本未知”的 `latest` 镜像直接打进安装包

## 当前验证状态
最新一次真实用户态验证任务已经完整生成报告和日志：

- `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.json`
- `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.log`
- `C:\ProgramData\XDisplayAI\logs\bootstrap.log`
- 诊断包：
  - `C:\Users\molc\AppData\Local\Temp\xdisplayai-diagnostics-20260814-112924.zip`

最新 JSON 结果：
- `status = failed`
- `lastError = 应用健康检查失败：无法连接到远程服务器`

注意：
- 这个 `lastError` 只是表层现象，不是最终根因

## 已确认的真实根因
健康检查失败的直接表现是：
- `Test-Health.ps1` 访问 `http://127.0.0.1:18001/healthz`
- 以及 `http://127.0.0.1:18001/api/v1/assistant/health`
- 返回“无法连接到远程服务器”

真实原因是：
- `orchestration-app` 容器启动后立即崩溃
- 所以本地 `18001` 没有服务监听

关键崩溃栈已经在诊断包和验证报告中稳定收敛到：
- `/app/app/main.py`, line 35
- `/app/app/services/autofix_compile.py`, line 42
- `/app/app/page_dsl/layout_hint_classifier.py`, line 64
- `AssertionError: CAP-19 taxonomy contains non-creatable types`

## 已确认的边界
以下链路已验证通过，当前不是主要问题：
- WSL 前置依赖
- Docker Desktop 已安装/可用
- `docker compose up`
- PostgreSQL
- Redis
- embedding worker
- 数据库迁移
- Windows 本机网络
- 健康检查脚本本身

也就是说，当前阻塞点已经收敛到：
- `orchestration-app` 离线镜像内容与当前可运行源码状态不一致

## 关键差异结论

### builder VM 中失败的离线镜像
builder VM 上失败容器使用的镜像：
- `orches/orchestration-app:latest`
- image id：
  - `sha256:be35701b6f5b73e7f47eab61f2bee12e669d8dc830fbc8198f549b6d8873bdc5`
- created：
  - `2026-08-12T20:41:35.872375003-07:00`

### 172.19.103.21 上参考环境
`172.19.103.21` 上当前运行中的 `ai_orches_app`：
- image id：
  - `sha256:724f9232179de85879e278c877c39a32123b4f2e5472599af41fa8803c0d1d5c`
- created：
  - `2026-08-13T16:13:53.706946783Z`

更关键的是，该容器不是纯镜像运行，而是依赖源码挂载：
- `/mnt/ai_orchestration:/app`

这意味着：
- 远端“能跑”的实际基础是源码目录状态
- 不是单纯 `orches/orchestration-app:latest` 这层镜像本身

### 已做过的关键验证

#### 验证 1：纯镜像导入测试
在 `172.19.103.21` 上执行：

```bash
docker run --rm orches/orchestration-app:latest python -c 'from app.page_dsl.layout_hint_classifier import apply_layout_classification; print("IMPORT_OK")'
```

结果：
- 直接失败
- 报同样的：
  - `AssertionError: CAP-19 taxonomy contains non-creatable types`

结论：
- 远端现有 `orches/orchestration-app:latest` 纯镜像本身也不能脱离源码挂载独立启动

#### 验证 2：源码快照固化进临时镜像
在 `172.19.103.21` 上把当前运行源码目录 `/mnt/ai_orchestration` 固化进临时镜像：
- `orches/orchestration-app:packaging-b32b674`

随后执行同样的导入测试，结果：
- `IMPORT_OK`

结论：
- 当前可运行的是“源码快照状态”
- 不是当前 `latest` 纯镜像

## 当前最大结论
当前问题的本质不是安装脚本崩溃，而是：

1. `windows-packaging` 之前导出的 `orches/orchestration-app:latest` 是陈旧/不一致的本地镜像
2. 当前离线包里使用的 app 镜像不等于当前可运行源码状态
3. 必须确保离线打包导出的 app 镜像来自指定后端源码，而不是机器里已经存在的 `latest`

## 最新验证覆盖情况
最新 `backend-startup-validation.json` 中已确认：
- `prerequisiteStarted = true`
- `prerequisiteCompleted = true`
- `imagesImported = true`
- `composeStarted = true`
- `migrationsStarted = true`
- `healthCheckStarted = true`

另：
- `rebootScheduled = false`
- `resumedAfterReboot = false`

这说明：
- 当前验证已经推进到最终应用启动失败点
- 安装闭环本身已经基本打通

## 下一个 session 建议优先顺序

### 1. 刷新离线 app 镜像输入
优先目标：
- 更新 `inputs/backend/images/orches_orchestration-app_latest.tar`

首选方案：
- 使用更新后的 `windows-packaging/ci/prepare-inputs.ps1`
- 让它从正确的 `BackendRepoPath` 构建并导出镜像

注意：
- 远端 `172.19.103.21` 缺少 `python:3.11-slim-bookworm`
- 直接在那台机子上按 `Dockerfile` 做离线 rebuild 会失败

### 2. 必要时走临时替代路径
如果当前构建环境拿不到 Docker Hub 基础镜像，可以使用已验证可行的替代方案：
- 把 `/mnt/ai_orchestration` 当前源码快照固化为临时镜像
- 再把这个镜像导出成 tar
- 用它替换 `inputs/backend/images/orches_orchestration-app_latest.tar`

这条路径已经验证过 `IMPORT_OK`

### 3. 更新 builder VM 上的离线镜像并重跑验证
更新后需要：
- `docker load` 新 tar
- 重新执行安装后验证脚本

关键验收目标：
- `orchestration-app` 不再因 CAP-19 assertion 启动即崩
- `backend-startup-validation.json` 最终变为通过
- `healthz` 和 `assistant/health` 返回 200

## 如果下一位要直接接手，最值得先看的文件
- `windows-packaging/ci/prepare-inputs.ps1`
- `windows-packaging/src/scripts/install/Install-BackendPayload.ps1`
- `windows-packaging/src/scripts/tests/Test-BackendStartupFlow.ps1`

以及这些验证产物：
- `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.json`
- `C:\ProgramData\XDisplayAI\logs\backend-startup-validation.log`
- `C:\ProgramData\XDisplayAI\logs\bootstrap.log`
- `C:\Users\molc\AppData\Local\Temp\xdisplayai-diagnostics-20260814-112924.zip`

## 当前计划文档
- plan id：
  - `767fe334-b923-4ac9-a58c-1efed8a81cb5`

## 一句话接力结论
下一个 session 最优先做的事是：

**刷新 `orchestration-app` 的离线镜像输入，使其与当前可运行源码快照一致，然后在 builder VM 上重新导入镜像并重跑安装后验证。**
