# Windows 开发版一键安装包设计

日期：2026-08-25

## 目标

开发阶段的一键安装包负责可靠部署 Windows 运行环境、Docker 基础镜像、当前后端源码快照和当前 XDisplay 编译产物。安装后，后端源码、后端 `.env` 和客户端编译目录均位于宿主机可变目录；日常代码更新不再重建 Docker 镜像或安装包。

本设计不实现发布版的后端二进制封装。发布阶段再取消源码挂载并单独设计不可变制品。

## 安装后目录

- `C:\Program Files\XDisplayAI`：MSI 管理的安装脚本、Compose 文件、基础镜像 tar 和只读种子载荷。
- `C:\ProgramData\XDisplayAI\workspace\backend`：完整后端源码及应用 `.env`，挂载到容器 `/app`。
- `C:\ProgramData\XDisplayAI\workspace\client`：XDisplay 完整编译结果，客户端从这里启动。
- `C:\ProgramData\XDisplayAI\config`：Compose 端口等宿主机运行配置。
- `C:\ProgramData\XDisplayAI\data`、`logs`：持久化数据与日志。

首次安装从安装包中的种子载荷初始化 `workspace`。已有 workspace 默认不被修复或重装覆盖，以保护开发者直接更新后的内容；需要部署新快照时使用显式更新脚本。

## 后端运行方式

主应用镜像只提供 Python、依赖、原生渲染组件和启动环境。Compose 将 `workspace\backend` 整目录绑定到 `/app`，与 `.21` 的 `/mnt/ai_orchestration:/app` 模式保持一致。PostgreSQL、Redis、embedding worker 等离线依赖镜像仍随安装包交付。

后端应用配置由 `/app/.env` 读取。安装脚本生成不含 LLM API key 的开发模板；LLM key 由客户端配置和传递，因此安装阶段不检查或警告服务端 key。Compose 只注入容器内固定路径和数据库、Redis、embedding 等本机基础连接配置，避免覆盖 `/app/.env` 的应用配置。

只有 Python/系统依赖、基础镜像 Dockerfile、原生渲染组件或 embedding 运行依赖改变时才刷新基础镜像。普通 `app`、配置、prompt、数据语料等源码变化只同步到宿主机 workspace，并重启主应用容器。

## 客户端运行方式

构建阶段仍从 XDisplay 源码生成完整 release 目录，但 MSI 只把它作为种子载荷。首次安装复制到 `workspace\client`，启动器始终运行该目录中的 `Xdisplay.exe`。

普通客户端更新只需停止 XDisplay、用新 release 目录覆盖 `workspace\client`、校验 `Xdisplay.exe` 和 Qt 运行目录存在，然后重新启动。无需重新制作 MSI。

## 操作入口

- 一键打包入口：复制两份源码到 `win11-wsl2-builder` 后运行现有 `build-offline-package.ps1`。
- 后端更新入口：接收一个后端源码副本路径，同步到 workspace，保留本机 `.env`，然后重启并健康检查。
- 客户端更新入口：接收一个 XDisplay release 路径，停止旧进程、同步完整 release、校验后启动。
- 安装/恢复入口：导入缺失的基础镜像、初始化缺失的 workspace、启动服务并启动客户端；重复执行必须幂等。

更新脚本只写 `C:\ProgramData\XDisplayAI`，不会修改作为输入的源码目录。

## 失败处理

- 基础镜像、后端种子或客户端种子缺失时，打包立即失败。
- workspace 初始化使用临时目录完成后再切换，避免半复制状态。
- 后端更新前保留本机 `.env`；同步或健康检查失败时返回非零并保留日志。
- 客户端更新在校验新 release 通过后才重启；失败时返回非零，不报告成功。
- 安装日志和诊断包不得输出 `.env` 中的 key、token 或 secret 值。

## 验收标准

1. 在 `win11-wsl2-builder` 从复制的后端与 XDisplay 源码一键生成完整离线安装目录。
2. 独立、断网的 Windows 11 能从零完成安装。
3. `docker inspect` 证明主应用 `/app` 来自 `C:\ProgramData\XDisplayAI\workspace\backend` 的 bind mount。
4. PostgreSQL、Redis、embedding worker 和主应用全部运行，后端健康接口返回 200，日志无启动 traceback。
5. XDisplay 从 `workspace\client\Xdisplay.exe` 启动，并且重复 bootstrap 不创建第二个实例。
6. 在宿主机创建 mount 探针后容器 `/app` 立即可见，证明普通后端源码变更无需重建镜像；重启主应用后仍健康。
7. 用相同 release 执行一次客户端替换流程后，客户端重新启动且后端仍健康。
8. 安装日志不再出现缺少服务端 LLM API key 的警告。
9. 两个原始源码目录的 Git 状态和内容不因打包、安装或更新流程发生改变。
