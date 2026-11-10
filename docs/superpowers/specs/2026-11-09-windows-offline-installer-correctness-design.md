# Windows 离线安装器正确性设计

日期：2026-11-09

## 问题（独立诊断，基于 t203 密封日志与当前 checkout）

当前仓库 checkout 与已交付的 0.1.3 MSI **不一致**。交付 MSI 在 `InstallFinalize` 之后用 WixQuietExec 调用：

`Bootstrap-InstalledPayload.ps1 -LaunchClient -NoAutoReboot`

密封 `fresh-msi.log` 记录：可选功能需要重启时，bootstrap **抛异常**；WixQuietExec 把非零子进程映射为 MSI 1603；Burn 回滚卸载 payload。重启后没有 `XDisplayAI-ResumeSetup`、没有 `bootstrap-state.json`、没有已安装种子。这不是缺依赖或 Burn 哈希错误。

checkout 的 `Product.wxs` **没有** `-NoAutoReboot`，会在自定义动作里 `shutdown /r`，同样不尊重 Burn `/norestart`，也不是可用的“待重启/可继续”结果。

升级路径：`Initialize-RuntimeEnvironment` 用默认值重建 `runtime.env`，只拷贝四个端口键。t203 在旧 `runtime.env` 写入的非密钥哨兵因此丢失；仅 4/15 旧键保留。HTTP 200 被当成“后端已健康”可跳过本地安装。`APP_HOST_PORT` 在被占用时会静默改到 18002。已有 workspace 只要存在 `Xdisplay.exe`/`app/main.py` 就跳过种子同步。

## 非目标

- 不在本仓库修复 molc/xdisplay 客户端 UI：用户选择 800×480 但图标签显示 720×720。该缺陷仍开放。
- 不在本环境做真实隔离 Windows 验收，也不宣称安装器已被接受。
- 不重启用户主机、不碰 .29/.21、不删除用户数据、不合并 PR。
- 不记录或打包真实 API key。

## 设计

### 1. 重启状态机（MSI 成功 ≠ 后端就绪）

把“文件提交”和“本地后端就绪”分开。

| 条件 | 必须发生 | 禁止 |
|---|---|---|
| 需要重启 + `-NoAutoReboot`（MSI / `/norestart`） | 先写入 `bootstrap-state.json` 并注册交互用户 `AtLogOn` 任务，然后 **exit 0** | throw、Clear-BootstrapState、Unregister-ResumeTask、WixQuietExec 1603、Burn 回滚 |
| 需要重启 + 允许自动重启（启动器） | 同样持久化，再 `shutdown /r /t 5`，exit 0 | 在持久化之前关机 |
| 重启后 `-Resume` | 在交互会话中继续直到本地 18001 就绪 | 仅因 HTTP 200 跳过；把残留 pending-reboot 标记当成新的失败 |
| 重启循环超过上限 | 保留状态与任务，给出可执行错误（MSI 自定义动作仍 exit 0，避免回滚） | 清空恢复状态 |

MSI 自定义动作显式传 `-LaunchClient -NoAutoReboot`。**不要**把 3010 经 WixQuietExec 传回（会被当成失败）。条件改为 `NOT REMOVE="ALL"`，以便 repair/upgrade 仍能进入 bootstrap。设置足够大的 `WixQuietExecCmdTimeout`。从 release bootstrap 移除无关的 RDP/防火墙启用。

### 2. 版本感知 workspace / 配置迁移

同步决策不能是“目标文件在就不做”：

- `create`：目标不存在 → 原子复制种子，写 `workspace-sync.json`（种子指纹 + 包版本）。
- `keep`：上次同步指纹仍等于当前种子指纹 → 保留开发者改动与用户文件。
- `update`/`repair`：种子指纹变化或缺少必需文件 → 先备份，再把种子文件覆盖到目标；**不删除**目标多出来的用户文件；保留 `.env`。

`runtime.env`：默认值 ∪ **全部**已有键（含非端口、非密钥哨兵与提供者设置）。强制 `APP_HOST_PORT=18001` 与当前 `BACKEND_WORKSPACE_PATH`。重写前备份。旧 `runtime.env` 里的 `XDISPLAY_AI_*` 在新建 workspace `.env` 时迁入，且不在日志中打印密钥值。

Docker 命名卷（postgres/redis/app_data/app_logs）不得删除或 prune。

### 3. 真正的本地后端

`127.0.0.1:18001` 的 HTTP 200 **不是**本地成功。成功需要同时满足：

- Docker 引擎是本机 named pipe（`npipe:////./pipe/dockerDesktopLinuxEngine` 或 `docker_engine`），不是远程 TCP context。
- 四个 compose 服务在项目 `xdisplayai` 中运行。
- 应用发布 `127.0.0.1:18001→8000`，监听者为本机 `com.docker.backend` / docker-proxy。
- **没有** `127.0.0.1:18001` 的 portproxy 转发。
- `APP_HOST_PORT` 不得因占用而改到 18002。若 18001 被**本栈**占用则复用；若被转发或无关进程占用则失败并给出可执行说明。辅助端口仍可按排除范围回退。

健康探测必须把 `TimeoutSec` 传给 `Invoke-WebRequest`，等待循环要有次数/剩余时间/最后错误（无密钥）。

### 4. 一命令打包，默认 fail-closed

`build-offline-package.ps1` 必须：钉死并导出输入哈希、检查四个镜像 tar + VC/WSL/Docker Desktop 的**确切文件名**、密钥扫描、完整 SHA256+SHA512 清单、组装后核对 Burn 对相邻 payload 的 SHA512 绑定、跑源码/单元测试。复制到 Downloads **仅**在隔离 Windows 验收证据为 PASS 之后；否则产物目录留下明确的 `NOT_READY` / release-hold。本 Linux 环境只跑源码测试，不冒充 Windows 验收。

客户端 catalogwrite SHA `2A80890D...` 与 Converter `F7C50DB8...` 保持不变，除非有意修复客户端（本变更不做）。包版本升到 **0.1.4**，以便从失败的 0.1.3 候选升级。
