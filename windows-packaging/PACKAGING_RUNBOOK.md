# XDisplay AI Windows 打包 Runbook
更新时间：2026-08-25

> 第一次使用 Windows 或 PowerShell，请先看面向打包人员的
> [一键打包新手手册](ONE_CLICK_PACKAGING_GUIDE.md)。本文主要保留 builder 运维、排障和恢复细节。

> 当前为开发版可变载荷模式：Docker 镜像只承担依赖运行环境，后端源码、后端 `.env` 和
> XDisplay release 均部署到 `C:\ProgramData\XDisplayAI\workspace`。普通代码更新不需要重新
> 制作镜像或安装包。发布版取消源码挂载、后端二进制化不在本 Runbook 范围内。

## 1. 目的
这份文档用于固定当前已经验证可用的 Windows 打包流程，目标是让新的 agent 不需要重新摸索以下问题：

- 现在哪台机器负责打包
- 打包脚本分别做什么
- 后端源码、`xdisplay` 源码、客户端发布目录、前置依赖如何进入 builder
- 如何触发构建
- 如何判断构建成功
- 如何从 builder 回收最终安装包

这份文档关注的是 `xdisplay_ai/windows-packaging` 的打包闭环，同时记录 Windows builder 内“从源码直接出离线安装目录”的入口脚本与前置条件；它不展开后端业务开发细节。

## 2. 结论先行
当前标准流程是“复制两份只读源码快照到 Windows builder，然后运行一条脚本”。在
**已安装 Qt / MinGW / WiX / Docker 的 `win11-wsl2-builder`** 内执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\xdisplay_ai\windows-packaging\build-offline-package.ps1
```

默认输入和输出如下：

- 后端源码副本：`C:\work\backend`
- `xdisplay` 源码副本：`C:\work\xdisplay`
- 离线前置依赖：`C:\xdisplay_ai\windows-packaging\inputs\prerequisites`
- 交付目录：`C:\xdisplay_ai\windows-packaging\dist\dev`
- JSON 结果、完整 transcript 和子命令日志：`C:\xdisplay_ai\windows-packaging\logs`

入口脚本顺序完成环境预检、客户端源码构建、后端基础镜像校验与 bind-mount smoke test、后端
源码 seed 准备、离线镜像导出、
WiX MSI/Bundle 构建、发布清单生成，以及最终 EXE/MSI/CAB/前置依赖的大小和 SHA256 一致性校验。
任何一步退出非零时，脚本整体失败并在 JSON 报告中记录错误，不会把残缺目录报告为成功。

源码同步不属于 Windows 打包脚本的职责：控制端先将下列目录复制为快照，脚本只操作 builder
中的副本，不应对原始目录执行构建或写操作：

- `/Users/molc/Documents/tricolor_work/ai-orchestration-page-engineering-unified`
- `/Users/molc/Documents/tricolor_work/xdisplay`

复制必须是递归且 submodule-aware 的完整目录复制。后端依赖
`external/xdisplay/bin/xd_render_cli` 中的原生 renderer 源码；单独执行 `git archive` 不会包含
submodule 工作树，会产出不完整快照。复制后至少确认下面的文件存在：

```text
C:\work\backend\external\xdisplay\bin\xd_render_cli\xd_render_cli.pro
```

入口脚本的 preflight 会主动拒绝缺少该文件的快照。

推荐在每份副本根目录写入 `SOURCE_REVISION.txt`，内容为复制时的 Git commit。入口脚本会把它写入
构建报告，从而可以追溯安装包使用的确切源码。

必须区分三层环境：

1. 控制端：当前通常是本地开发机，用来准备输入、同步文件、回收产物
2. libvirt 宿主机：负责管理 Windows builder VM，也负责离线挂盘注入文件
3. Windows builder VM：执行 `build-offline-package.ps1`，输出完整离线交付目录

当前仓库中的脚本现在已经能：

- 从 `xdisplay` 源码构建 Windows 客户端发布目录
- 会准备 inputs
- 会做 payload staging
- 会调用 WiX 生成安装包
- 会生成产物清单
- 会记录源码 revision、工具路径、运行日志和最终状态
- 会验证产物清单中的文件大小与 SHA256，并拒绝未列入清单的多余文件

后端采用“运行时依赖缓存 + 宿主机源码 bind mount”模型。安装包把当前后端源码作为 seed，首次
安装后初始化到 `C:\ProgramData\XDisplayAI\workspace\backend`，Compose 将它挂载到两个 Python
服务的 `/app`。日常只改 `app`、`data`、prompt、配置或其他 Python 源码时，直接同步 workspace
并重启服务，不再重新打包。

`Dockerfile`、`Dockerfile.embedding` 或 `external/xdisplay/bin/xd_render_cli` 等运行依赖发生变化
时，指纹改变，才需要刷新 runtime cache。当前缓存标签是：

- `orches/orchestration-app:xdisplayai-runtime-cache`
- `orches/embedding-http:xdisplayai-runtime-cache`

运行时依赖变化时，需要先让 builder 能联网完成一次依赖镜像刷新，或从可信环境导入与新指纹
匹配的缓存镜像。普通后端源码更新使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Program Files\XDisplayAI\scripts\update\Update-BackendSource.ps1" `
  -SourcePath C:\path\to\backend-copy
```

脚本保留目标机现有 `.env`，同步其余源码，重启 `embedding-worker` 和 `orchestration-app`，并等待
健康检查通过。输入目录只读，不会被脚本修改。

普通 XDisplay 更新先准备完整 release 目录，再执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "C:\Program Files\XDisplayAI\scripts\update\Update-XDisplayClient.ps1" `
  -ReleasePath C:\path\to\xdisplay-release
```

脚本先校验 `Xdisplay.exe`、Qt platform plugin 和 QML 目录，再停止 workspace 中的旧客户端、原子
替换完整 release 并重新启动。安装后的可变路径为：

- 后端：`C:\ProgramData\XDisplayAI\workspace\backend`
- 后端配置：`C:\ProgramData\XDisplayAI\workspace\backend\.env`
- 客户端：`C:\ProgramData\XDisplayAI\workspace\client`

但不会：

- 自动把源码上传到 Windows builder
- 自动把客户端发布目录上传到 Windows builder
- 自动把前置依赖上传到 Windows builder

这些“输入同步”步骤需要额外执行。日常更新优先使用正常的 Windows 文件复制、共享目录或 SMB；
离线挂载 builder 系统盘只适合恢复/引导场景，因为它可能触发 Windows 下一次启动时的磁盘检查。

## 3. 当前已验证环境
### 3.1 控制端
当前会话里实际使用的是本地开发机，关键路径如下：

- 打包仓：`/Users/molc/Documents/tricolor_work/xdisplay_ai/windows-packaging`
- 当前最终产物目录：`/Users/molc/Downloads/XDisplayAI-0.1.2-dev-offline-20260825`

控制端至少需要：

- `ssh`
- `scp`
- `tar`
- `python3`

### 3.2 libvirt 宿主机
当前已验证宿主机：

- 主机：`172.19.103.18`
- SSH 用户：`root`

宿主机上至少需要：

- `virsh`
- `qemu-nbd`
- `ntfsfix`
- `ntfs-3g`

### 3.3 Windows builder VM
当前已验证 builder：

- VM 名称：`win11-wsl2-builder`
- VM 磁盘：`/var/lib/libvirt/images/win11-wsl2-builder/win11-wsl2-builder.qcow2`
- Windows 仓库目录：`C:\xdisplay_ai\windows-packaging`

Builder 内必须具备：

- PowerShell
- Git
- Qt 5.15.x（含 `qmake`、`windeployqt`）
- MinGW 8.1.0（含 `mingw32-make`）
- WiX Toolset
- Docker Desktop
- qemu guest agent

完整构建必须在已登录的普通 Windows 用户会话中运行。Docker Desktop/WSL2 不支持从
`NT AUTHORITY\SYSTEM` 会话启动；若用任务计划程序自动触发，应选择交互用户并使用最高权限，
不能把任务主体改为 SYSTEM。

### 3.4 历史导出目录
以下目录是旧流程留下的历史样例，不应作为当前修正版交付物：

- 宿主机：`/var/lib/libvirt/images/winpkg-dev-export-20260818-qtfix`
- 本地：`/Users/molc/Downloads/winpkg-dev-export-20260818-qtfix`

历史安装包路径：

- `/Users/molc/Downloads/winpkg-dev-export-20260818-qtfix/dev/XDisplayAI-0.1.0-dev.exe`

### 3.5 2026-08-25 最终 0.1.2 构建与独立 Win11 验收证据

完整一键构建在 `win11-wsl2-builder` 的交互用户 `molc` 会话中执行。修复重启续装状态后，源码、
客户端 release 和后端镜像均未变化，因此只重新执行 installer/publish 阶段生成 `0.1.2`。结果如下：

- 构建状态：`succeeded`，任务退出码 `0`
- 后端源码 revision：`c5b49da147ac89cce26c0e324256f9a5905432ed`
- XDisplay 源码 revision：`e7565392db0f6f116c8e711b897b7848dd9da3d7`
- 交付文件：15 个清单文件和 `artifacts-dev.json`，其中 9 个外部 CAB
- Bundle SHA256：`ea5661ed4e79ab024aa968025cd6f1d1a783552727defc341ac57de408de57ab`
- `artifacts-dev.json` SHA256：`60a6b79950e525778f3e44eba0172f9346051795829d9f2b28f277f58ba45e69`
- 构建机回归测试：`PASS: build-offline-package preflight behavior`，退出码 `0`

最终 `0.1.2` 产物通过独立 ISO 送到 `win11-wsl2-offline-verify`，逐个校验 15 个清单文件，
`BAD=0`。该 VM 先前已完成旧版的干净离线安装，因此本次对最终包执行的是 `0.1.1 -> 0.1.2`
真实升级验证，不把它误写成 `0.1.2` 干净安装。最终验收结果：

- 离线 Bundle 升级退出码 `0`，卸载注册表中的两个相关条目均为 `0.1.2`
- `/healthz` 和 `/api/v1/assistant/health` 均返回 `200`
- PostgreSQL、Redis、embedding-worker、orchestration-app 共 4 个服务运行
- orchestration-app 和 embedding-worker 的 `/app` 均为
  `C:\ProgramData\XDisplayAI\workspace\backend` 的可写 bind mount
- XDisplay 客户端从 ProgramData workspace 启动
- 人工注入可识别的待重启标记后，安装流程只自动重启 1 次；重启后 `-Resume` 自动执行
- 含中文重启原因的 UTF-8 JSON 状态可正常解析；持久待重启标记被识别为残留标记并继续，没有
  `ConvertFrom-Json` 错误或循环重启
- 续装后两个健康接口恢复为 `200`，状态文件和续装任务自动删除
- `.env` SHA256 在重启测试前后保持
  `8944A64DC5E7A62862F6F20A12F131236F25DFE72C6BDF16C11CF0266EC943AD`
- 本次 `0.1.2` 日志中没有旧的“缺少服务端 LLM API key”警告

这组证据验证的是本节记录的最终产物，不是历史安装包。

## 4. 仓库内脚本职责
### 4.1 `ci/prepare-inputs.ps1`
路径：`windows-packaging/ci/prepare-inputs.ps1`

作用：

- 接收 `BackendRepoPath`
- 接收 `ClientReleaseDir`
- 接收 `XdisplayRepoPath`
- 接收 `PrerequisitesSourceRoot`
- 同步 compose、migration、client release、prerequisites 到 `inputs`
- 将后端源码副本过滤后同步到 `inputs/backend/source`，不复制 `.env`、`.git`、`.venv` 或缓存
- 必要时调用客户端源码构建脚本生成 `ClientReleaseDir`
- 按依赖指纹刷新或复用后端基础镜像
- 将当前后端源码 bind mount 到 `/app` 后 smoke test 基础镜像
- 导出镜像 tar 到 `inputs/backend/images`

关键限制：

- 只处理“运行它的那台机器上的本地路径”
- 不负责跨机器传输
- 运行它的那台机器必须具备 PowerShell 和 Docker

补充说明：

- `prepare-inputs.ps1` 不要求必须在 Windows builder 本机运行
- 但无论在哪台机器运行，生成的结果最终都必须进入 builder 仓库下的 `inputs`
### 4.2 `ci/build-xdisplay-from-source.ps1`
路径：`windows-packaging/ci/build-xdisplay-from-source.ps1`

作用：

- 接收 `XdisplayRepoPath`
- 执行 `src/Service_PB/compile_all_proto.bat`
- 调 `qmake` + `mingw32-make` 编译 `Xdisplay.exe`
- 复制 `caesium.dll` 与 `UpdateUnpack.exe` 到发布目录
- 调 `windeployqt` 生成标准 Windows 客户端发布目录
- 补齐 `qt.conf`
- 校验关键 Qt DLL / plugin / QML 文件是否齐全

关键限制：

- 必须在装了 Qt + MinGW 的 Windows 环境运行
- 默认走 shadow build，但最终二进制仍来自 `xdisplay/bin/Xdisplay.exe`

### 4.3 `ci/validate.ps1`
路径：`windows-packaging/ci/validate.ps1`

作用：

- 校验 manifest
- 校验 compose / migration
- 校验前置依赖
- 校验客户端关键文件
- 校验离线镜像 tar

当前强校验的客户端关键文件包括：

- `Xdisplay.exe`
- `caesium.dll`
- `UpdateUnpack.exe`
- `qt.conf`
- `Qt5Core.dll`
- `Qt5Gui.dll`
- `Qt5Widgets.dll`
- `plugins/platforms/qwindows.dll`
- `qml/QtQuick/Controls.2/Action.qml`

### 4.4 `ci/stage-payload.ps1`
路径：`windows-packaging/ci/stage-payload.ps1`

作用：

- 将 `inputs` 渲染到 `staging/<channel>/payload`
- 把客户端发布目录复制到 `payload/seed/client`
- 把过滤后的后端源码复制到 `payload/seed/backend`
- 在后端 seed 中渲染不含服务端 LLM key 的 `.env`
- 对“伪路径文件名”做目录规范化

关键点：

如果客户端输入里存在类似：

- `plugins\platforms\qwindows.dll`
- `qml\QtQuick\Controls.2\Action.qml`

这种带反斜杠的扁平文件名，`stage-payload.ps1` 会把它们还原成真实目录结构。

### 4.5 `ci/build-installer.ps1`
路径：`windows-packaging/ci/build-installer.ps1`

作用：

- 调 `stage-payload.ps1`
- 生成 WiX payload authoring
- 构建 MSI
- 构建 Burn bundle EXE
- 生成外部 CAB

关键限制：

- 必须在装了 WiX 的 Windows 环境运行

### 4.6 `ci/publish.ps1`
路径：`windows-packaging/ci/publish.ps1`

作用：

- 校验 `dist/<channel>` 下已有 `.msi` 和 `.exe`
- 枚举所有产物
- 生成 `artifacts-<channel>.json`

### 4.7 `ci/build-package-from-source.ps1`
路径：`windows-packaging/ci/build-package-from-source.ps1`

作用：

- 作为 Windows builder 内的一条命令入口
- 顺序执行 `prepare-inputs.ps1`
- 顺序执行 `build-installer.ps1`
- 顺序执行 `publish.ps1`
- 最终校验 `dist/<channel>/artifacts-<channel>.json` 已生成

适用场景：

- Builder 本机已具备后端源码、`xdisplay` 源码、前置依赖
- 希望避免手工准备 `inputs/client/xdisplay-win64`
- 希望让客户端发布目录直接在 NTFS 上生成，避免伪路径文件名问题

### 4.8 `build-offline-package.ps1`
路径：`windows-packaging/build-offline-package.ps1`

这是日常使用的唯一顶层入口。它在调用 4.7 的内部流水线之前做源码、前置依赖、Qt/MinGW、
Docker 和 WiX 预检；构建后再验证完整交付目录并写 JSON 报告。除非排查某个内部阶段，后续打包
不应再手工逐个调用 `prepare-inputs.ps1`、`build-installer.ps1` 和 `publish.ps1`。

## 5. 当前目录约定
### 5.1 Builder VM 内目录
- 仓库：`C:\xdisplay_ai\windows-packaging`
- 一键入口：`C:\xdisplay_ai\windows-packaging\build-offline-package.ps1`
- 后端源码副本：`C:\work\backend`
- `xdisplay` 源码副本：`C:\work\xdisplay`
- 构建报告和日志：`C:\xdisplay_ai\windows-packaging\logs`

### 5.2 仓库内输入目录
- `inputs/backend/compose/upstream`
- `inputs/backend/migrations`
- `inputs/backend/images`
- `inputs/backend/source`
- `inputs/client/xdisplay-win64`
- `inputs/prerequisites`

### 5.3 仓库内输出目录
- `staging/dev/payload`
- `dist/dev`

## 6. 历史流程（禁止作为日常入口）

本节及后续旧流程仅保留排障背景，不再作为操作步骤。日常打包以第 2 节的一条
`build-offline-package.ps1` 命令为准；不要再使用 `rebuild-xdisplayai.cmd`，也不要为了同步日常源码
而离线挂载 Windows 系统盘。正常源码复制应递归写入 `C:\work\backend` 和
`C:\work\xdisplay`，完整构建必须由交互 Windows 用户执行。

### 6.1 什么时候需要 Windows builder
如果只是修改文档、PowerShell 脚本、manifest，不一定要立刻开 builder。

但只要你要做下面任何一件事，就必须有可用的 Windows builder：

- 生成新的 `.msi`
- 生成新的 `.exe`
- 验证 Burn bundle 输出
- 验证 CAB 布局

更准确的说法是：

- 不一定必须是“专门的 Windows 11 VM”
- 但必须有一台“具备 WiX + Docker Desktop + PowerShell 的 Windows 打包环境”
- 当前已经验证可用的是 `win11-wsl2-builder`

除非另一个 agent 明确知道另一台 Windows 打包环境同样可用，否则默认继续使用 `win11-wsl2-builder`

## 7. 输入来源的两种模式
### 7.1 模式 A：输入已经在 Windows builder 本机
如果后端源码、`xdisplay` 源码、客户端发布目录或前置依赖都已经在 Windows builder 里，可以直接在 VM 内运行。

如果希望从源码直接出离线安装目录，优先使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\xdisplay_ai\windows-packaging\build-offline-package.ps1
```

只有输入不在默认位置或要打非 `dev` channel 时才传参数，例如：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File C:\xdisplay_ai\windows-packaging\build-offline-package.ps1 `
  -BackendRepoPath C:\work\backend `
  -XdisplayRepoPath C:\work\xdisplay `
  -PrerequisitesSourceRoot C:\work\prerequisites `
  -Channel test
```

如果客户端发布目录已经提前准备好，也可以继续沿用旧方式只运行 `prepare-inputs.ps1` / `build-installer.ps1` / `publish.ps1`。

```powershell
Set-Location C:\xdisplay_ai\windows-packaging

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ci\prepare-inputs.ps1 `
  -BackendRepoPath C:\path\to\backend `
  -ClientReleaseDir C:\path\to\client-release `
  -PrerequisitesSourceRoot C:\path\to\prerequisites

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ci\validate.ps1 -Channel dev -RequirePayloads
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ci\build-installer.ps1 -Channel dev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ci\publish.ps1 -Channel dev
```

这是脚本设计上的“直觉模式”，但它要求：

- 你能把源码或发布目录先放到 builder VM
- builder 内 Docker Desktop 能用于镜像构建

当前建议在 builder VM 内使用固定路径：

- 后端源码：`C:\work\backend`
- `xdisplay` 源码：`C:\work\xdisplay`
- 前置依赖目录：默认复用仓库的 `inputs\prerequisites`

### 7.2 把原始后端仓 / 客户端发布目录 / 前置依赖送上 builder
当前仓库没有现成的“上传到 Windows builder”的自动脚本。

如果另一个 agent 需要把新的后端代码或客户端发布目录送上 builder，有两条路：

1. 日常方式：通过 VNC、共享目录、SMB 或其他正常文件复制，把目录放到 `C:\work\...`
2. 恢复方式：builder 无法正常接收文件时，才通过宿主机离线挂盘注入

第二种方式会直接写系统盘，并可能触发 Windows 磁盘检查，因此不能作为日常首选。

#### 7.2.1 控制端打包 raw 输入目录
在控制端先把三个目录分别打包并上传到宿主机：

```bash
tar -C /path/to/backend-root -cf /tmp/backend-src.tar .
tar -C /path/to/client-release -cf /tmp/client-release.tar .
tar -C /path/to/prerequisites -cf /tmp/prerequisites.tar .

scp /tmp/backend-src.tar root@172.19.103.18:/tmp/backend-src.tar
scp /tmp/client-release.tar root@172.19.103.18:/tmp/client-release.tar
scp /tmp/prerequisites.tar root@172.19.103.18:/tmp/prerequisites.tar
```

如果客户端发布目录来自 Mac / Linux，并且文件名里含有反斜杠伪路径，不要直接打 `client-release.tar`，而是先按 8.4 做规范化，再上传规范化结果。

#### 7.2.2 离线挂盘并把 raw 目录解到 builder
先确保 builder VM 已关机，然后在宿主机执行挂盘：

```bash
ssh root@172.19.103.18 '
NBD=/dev/nbd0
IMG=/var/lib/libvirt/images/win11-wsl2-builder/win11-wsl2-builder.qcow2
MNT=/mnt/win11-builder

umount "$MNT" >/dev/null 2>&1 || true
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
mkdir -p "$MNT"
qemu-nbd --connect="$NBD" "$IMG"
sleep 2
ntfsfix ${NBD}p3
mount -t ntfs-3g ${NBD}p3 "$MNT"
'
```

把目录解到建议位置：

```bash
ssh root@172.19.103.18 '
mkdir -p /mnt/win11-builder/work/backend
mkdir -p /mnt/win11-builder/work/client-release
mkdir -p /mnt/win11-builder/work/prerequisites

tar -xf /tmp/backend-src.tar -C /mnt/win11-builder/work/backend
tar -xf /tmp/client-release.tar -C /mnt/win11-builder/work/client-release
tar -xf /tmp/prerequisites.tar -C /mnt/win11-builder/work/prerequisites
'
```

卸载：

```bash
ssh root@172.19.103.18 '
umount /mnt/win11-builder
qemu-nbd --disconnect /dev/nbd0
'
```

#### 7.2.3 在 builder 内执行 `prepare-inputs.ps1`
目录就位后，启动 builder VM，再运行：

```powershell
Set-Location C:\xdisplay_ai\windows-packaging

powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ci\prepare-inputs.ps1 `
  -BackendRepoPath C:\work\backend `
  -ClientReleaseDir C:\work\client-release `
  -PrerequisitesSourceRoot C:\work\prerequisites
```

如果不想手工登录 Windows，可以复用 8.9 / 8.10 的 qemu guest agent 调用模式，把 8.10 中执行的命令换成上面的 PowerShell 命令。

### 7.3 模式 B：控制端 + libvirt 宿主机 + 离线注盘（仅恢复）
这是历史恢复手段，不是日常推荐方式。能够正常复制文件时，应优先把两份源码副本写入
`C:\work\backend`、`C:\work\xdisplay`，再运行顶层一键脚本。

适用场景：

- 控制端是本地 Mac / Linux
- 你有宿主机 SSH 权限
- 不想依赖在 Windows 里手工登录拷贝文件
- 需要用离线方式把打包仓或 inputs 注入 builder

后文第 8 节就是这个模式的完整步骤

## 8. 历史恢复闭环（禁止作为日常入口）
### 8.1 总体思路
本节只用于 builder 无法通过正常 Windows 文件复制、共享目录或 SMB 接收输入时的恢复操作。
日常流程以第 2 节为准。

完整闭环拆成 6 个阶段：

1. 在控制端准备要同步的文件
2. 通过 `scp` 传到 libvirt 宿主机
3. 关闭 builder VM，离线挂盘并注入文件
4. 启动 builder VM，用 qemu guest agent 触发构建
5. 构建结束后关闭 VM，再次离线挂盘回收产物
6. 从宿主机把交付目录拉回本地

### 8.2 构建前必须确认的条件
执行前至少确认：

- 能 `ssh root@172.19.103.18`
- `virsh list --all` 能看到 `win11-wsl2-builder`
- builder VM 安装了 qemu guest agent
- builder VM 里已有 `C:\xdisplay_ai\windows-packaging`
- 你本地拥有新的 `windows-packaging` 脚本改动，或者拥有新的 client / backend inputs

### 8.3 同步打包脚本到 builder
如果本次改动的是：

- `ci/`
- `src/`
- `manifests/`

建议先在控制端打一个小 tar：

```bash
tar -C /Users/molc/Documents/tricolor_work/xdisplay_ai/windows-packaging \
  -cf /tmp/windows-packaging-sync.tar \
  ci src manifests

scp /tmp/windows-packaging-sync.tar root@172.19.103.18:/tmp/windows-packaging-sync.tar
```

### 8.3.1 如果本次变更包含新的后端输入
如果后端代码发生变化，而你不准备把 raw backend 仓放进 builder 再跑 `prepare-inputs.ps1`，那么至少需要把新的 `inputs/backend` 注入 builder。

最少要更新这三块：

- `inputs/backend/compose/upstream/docker-compose.yml`
- `inputs/backend/migrations`
- `inputs/backend/images/*.tar`

其中镜像 tar 名称必须符合当前脚本约定，对应：

- `orches/orchestration-app:latest` -> `orches_orchestration-app_latest.tar`
- `orches/embedding-http:latest` -> `orches_embedding-http_latest.tar`
- `pgvector/pgvector:pg15` -> `pgvector_pgvector_pg15.tar`
- `redis:7` -> `redis_7.tar`

如果你是在别处准备好整个 `inputs/backend`，也可以直接把它整体打包后注入 builder：

```bash
tar -C /path/to/windows-packaging/inputs -cf /tmp/backend-inputs.tar backend
scp /tmp/backend-inputs.tar root@172.19.103.18:/tmp/backend-inputs.tar
```

然后在 8.6 的挂盘阶段解到：

```bash
ssh root@172.19.103.18 '
tar -xf /tmp/backend-inputs.tar -C /mnt/win11-builder/xdisplay_ai/windows-packaging/inputs
'
```

### 8.3.2 如果本次变更包含新的前置依赖
同理，如果前置依赖要更新，也可以整体打包并注入：

```bash
tar -C /path/to/windows-packaging/inputs -cf /tmp/prereq-inputs.tar prerequisites
scp /tmp/prereq-inputs.tar root@172.19.103.18:/tmp/prereq-inputs.tar
```

挂盘后解到：

```bash
ssh root@172.19.103.18 '
tar -xf /tmp/prereq-inputs.tar -C /mnt/win11-builder/xdisplay_ai/windows-packaging/inputs
'
```

### 8.4 如果客户端输入包含“伪路径文件名”
这是当前流程里最容易让新 agent 摔坑的点。

如果你的客户端输入目录是在 Mac / Linux 上得到的，里面可能存在这种文件名：

- `plugins\platforms\qwindows.dll`
- `qml\QtQuick\Controls.2\Action.qml`
- `qml\QtQuick\...`

这种输入在 Mac / Linux 文件系统上能存在，但在 Windows NTFS 上不能以“文件名带反斜杠”的形式保留。

因此：

- 不要把这类原始扁平输入直接拷到 Windows builder 的 `inputs/client/xdisplay-win64`
- 应先在控制端把它们规范化成真实目录结构，再注入 builder

当前已验证可用的控制端规范化脚本如下：

```bash
python3 - <<'PY'
import os, shutil
src_root='/Users/molc/Documents/tricolor_work/xdisplay_ai/windows-packaging/inputs/client/xdisplay-win64'
stage='/tmp/xdisplay-client-pseudopath-normalized'
if os.path.exists(stage):
    shutil.rmtree(stage)
os.makedirs(stage, exist_ok=True)
for entry in os.scandir(src_root):
    raw=entry.name
    if '\\' not in raw and '/' not in raw:
        continue
    rel=[seg for seg in raw.replace('\\','/').split('/') if seg]
    if not rel:
        continue
    dst=os.path.join(stage, *rel)
    if entry.is_dir(follow_symlinks=False) or raw.endswith('\\') or raw.endswith('/'):
        os.makedirs(dst, exist_ok=True)
        continue
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(entry.path, dst)
PY

cd /tmp && tar -czf /tmp/xdisplay-client-pseudopath-normalized.tar.gz xdisplay-client-pseudopath-normalized
scp /tmp/xdisplay-client-pseudopath-normalized.tar.gz root@172.19.103.18:/tmp/xdisplay-client-pseudopath-normalized.tar.gz
```

这一步的目标不是直接生成安装包，而是生成一个“可以安全放进 NTFS 的规范化客户端补丁”。

### 8.5 关闭 builder VM
注盘前必须确保 builder VM 处于关机状态：

```bash
ssh root@172.19.103.18 'virsh domstate win11-wsl2-builder'
```

如果不是 `shut off`，先关机。

### 8.6 挂盘并注入文件
当前已验证的 Windows 分区路径：

- qcow2：`/var/lib/libvirt/images/win11-wsl2-builder/win11-wsl2-builder.qcow2`
- nbd 设备：`/dev/nbd0`
- Windows 分区：`/dev/nbd0p3`
- 挂载点：`/mnt/win11-builder`

标准离线挂盘步骤：

```bash
ssh root@172.19.103.18 '
NBD=/dev/nbd0
IMG=/var/lib/libvirt/images/win11-wsl2-builder/win11-wsl2-builder.qcow2
MNT=/mnt/win11-builder

umount "$MNT" >/dev/null 2>&1 || true
qemu-nbd --disconnect "$NBD" >/dev/null 2>&1 || true
mkdir -p "$MNT"
qemu-nbd --connect="$NBD" "$IMG"
sleep 2
ntfsfix ${NBD}p3
mount -t ntfs-3g ${NBD}p3 "$MNT"
'
```

注入打包脚本：

```bash
ssh root@172.19.103.18 '
tar -xf /tmp/windows-packaging-sync.tar -C /mnt/win11-builder/xdisplay_ai/windows-packaging
'
```

注入规范化客户端补丁：

```bash
ssh root@172.19.103.18 '
tar -xzf /tmp/xdisplay-client-pseudopath-normalized.tar.gz \
  -C /mnt/win11-builder/xdisplay_ai/windows-packaging/inputs/client/xdisplay-win64 \
  --strip-components=1
'
```

清理旧标记和旧输出：

```bash
ssh root@172.19.103.18 '
rm -f /mnt/win11-builder/xdisplay_ai/REBUILD_START.txt \
      /mnt/win11-builder/xdisplay_ai/BUILD_DONE.txt \
      /mnt/win11-builder/xdisplay_ai/build-installer.log \
      /mnt/win11-builder/xdisplay_ai/publish.log
rm -rf /mnt/win11-builder/xdisplay_ai/windows-packaging/dist/dev \
       /mnt/win11-builder/xdisplay_ai/windows-packaging/staging/dev
'
```

卸载：

```bash
ssh root@172.19.103.18 '
umount /mnt/win11-builder
qemu-nbd --disconnect /dev/nbd0
'
```

### 8.7 `rebuild-xdisplayai.cmd`
Builder 内应存在如下脚本：

```batch
@echo off
if exist "%~f0" del "%~f0"
set REPO=C:\xdisplay_ai\windows-packaging
echo STARTED> C:\xdisplay_ai\REBUILD_START.txt
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO%\ci\build-installer.ps1" -Channel dev *> C:\xdisplay_ai\build-installer.log
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%REPO%\ci\publish.ps1" -Channel dev *> C:\xdisplay_ai\publish.log
if errorlevel 1 exit /b 1
echo DONE> C:\xdisplay_ai\BUILD_DONE.txt
```

如果缺失，可以在离线挂盘时重建该文件。

### 8.8 启动 builder VM
```bash
ssh root@172.19.103.18 'virsh start win11-wsl2-builder'
```

### 8.9 等待 qemu guest agent 就绪
当前已验证的可用探测方式：

```bash
python3 - <<'PY'
import subprocess, json, shlex, time
host='root@172.19.103.18'
req=json.dumps({'execute':'guest-ping'}, separators=(',',':'))
remote='virsh qemu-agent-command win11-wsl2-builder ' + shlex.quote(req)
for i in range(1,25):
    p=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=15',host,remote], text=True, capture_output=True)
    if p.returncode == 0:
        print(f'guest-agent-ready:{i}')
        print(p.stdout.strip())
        break
    time.sleep(5)
else:
    raise SystemExit('guest-agent-timeout')
PY
```

### 8.10 通过 guest agent 触发构建
当前已验证可用的方式是直接在 VM 里运行：

- `cmd.exe /c C:\xdisplay_ai\rebuild-xdisplayai.cmd`

控制端示例：

```bash
python3 - <<'PY'
import subprocess, json, shlex, time
host='root@172.19.103.18'
start_req={
    'execute':'guest-exec',
    'arguments':{
        'path':'cmd.exe',
        'arg':['/c', r'C:\xdisplay_ai\rebuild-xdisplayai.cmd'],
        'capture-output':True,
    }
}
start_remote='virsh qemu-agent-command win11-wsl2-builder ' + shlex.quote(json.dumps(start_req, separators=(',',':')))
start_resp=subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=15',host,start_remote], text=True)
pid=json.loads(start_resp)['return']['pid']
print(f'guest-exec-pid={pid}', flush=True)
status_req=lambda pid: 'virsh qemu-agent-command win11-wsl2-builder ' + shlex.quote(json.dumps({'execute':'guest-exec-status','arguments':{'pid':pid}}, separators=(',',':')))
for i in range(1,181):
    status_resp=subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=15',host,status_req(pid)], text=True)
    status=json.loads(status_resp)['return']
    exited=status.get('exited', False)
    exitcode=status.get('exitcode')
    print(f'poll={i} exited={exited} exitcode={exitcode}', flush=True)
    if exited:
        break
    time.sleep(10)
else:
    raise SystemExit('build-timeout')
PY
```

判定标准：

- `exitcode=0`：构建脚本执行成功
- 非 0：立即去读 `C:\xdisplay_ai\build-installer.log`

### 8.11 构建成功后的关机
```bash
python3 - <<'PY'
import subprocess, json, shlex
host='root@172.19.103.18'
req={'execute':'guest-exec','arguments':{'path':'shutdown.exe','arg':['/s','/t','0'],'capture-output':True}}
remote='virsh qemu-agent-command win11-wsl2-builder ' + shlex.quote(json.dumps(req, separators=(',',':')))
print(subprocess.check_output(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=15',host,remote], text=True).strip())
PY
```

### 8.12 再次离线挂盘，验证并回收产物
再次离线挂盘后，至少验证：

- `staging/dev/payload/seed/client/plugins/platforms/qwindows.dll`
- `staging/dev/payload/seed/client/qml/QtQuick/Controls.2/Action.qml`

只有这两个都存在，才能确认 Qt 修复已真正进入新包。

当前已验证的回收方式是：

1. 离线挂盘
2. 从 VM 磁盘拷贝 `dist/dev` 到宿主机导出目录
3. 同时拷贝 `build-installer.log`、`publish.log`

宿主机导出目录示例：

- `/var/lib/libvirt/images/winpkg-dev-export-20260818-qtfix`

### 8.13 从宿主机回收到控制端
当前已验证可用：

```bash
scp -r root@172.19.103.18:/var/lib/libvirt/images/winpkg-dev-export-20260825-0.1.2/dev \
  /Users/molc/Downloads/XDisplayAI-0.1.2-dev-offline-20260825
```

## 9. 构建成功的判断标准
最少满足以下条件：

1. `build-offline-package.ps1` 退出码为 `0`
2. 构建 JSON 报告的 `status` 为 `succeeded`
3. `staging/dev/payload/seed/client/plugins/platforms/qwindows.dll` 存在
4. `staging/dev/payload/seed/client/qml/QtQuick/Controls.2/Action.qml` 存在
5. `staging/dev/payload/seed/backend/app/main.py` 和 `.env` 存在
6. 后端 `.env`、runtime env 与 Compose 中均不存在 `XDISPLAY_AI_LLM_API_KEY`
7. `dist/dev` 至少包含：
   - `XDisplayAI-0.1.2-dev.exe`（或当前 `bundle.version` 对应的文件名）
   - `XDisplayAI-0.1.2-dev.msi`（或当前 `bundle.version` 对应的文件名）
   - `artifacts-dev.json`
   - 所有 `xdp*.cab`
   - `Docker Desktop Installer.exe`
   - `VC_redist.x64.exe`
   - `wsl_update_x64.msi`
8. `artifacts-dev.json` 中列出的大小和 SHA256 全部匹配，且交付目录没有未列入清单的多余文件

## 10. 当前最容易踩坑的点
### 10.1 文档只写“运行 prepare-inputs/build/publish”是不够的
因为这些脚本默认假设：

- 输入已经在 builder 上
- builder 已经有 WiX
- builder 已经有 Docker Desktop

如果不补“如何把输入送上 builder”，新 agent 会卡住。

### 10.2 Mac/Linux 上的扁平客户端输入不能原样放进 Windows NTFS
这是本次会话里最关键的经验之一。

如果客户端输入里有：

- `qml\QtQuick\...`
- `plugins\platforms\...`

这种文件名，Windows NTFS 不能保留。

处理方式：

- 在控制端先规范化
- 再注入 builder

### 10.3 `prepare-inputs.ps1` 并不负责跨机器上传
它只对本地路径工作。

所以“换代码并重打包”的完整闭环，必须额外补：

- 上传后端源码 / 客户端发布目录 / 前置依赖
或者
- 在控制端先准备好 inputs，再离线注入 builder

### 10.4 不要只交付 `XDisplayAI-0.1.2-dev.exe`
离线安装依赖同目录下的：

- 外部 CAB
- Docker Desktop 安装器
- VC 运行库
- WSL 安装器

交付时必须交付整个 `dist/dev`

### 10.5 发布新安装包时必须递增版本

Windows Installer 依靠 `manifests/bundle.json` 中的 `bundle.version` 判断升级关系。安装逻辑、seed、
基础镜像或首次安装内容变化并需要重新交付 EXE 时，必须把三段版本号递增；不要用同一个版本号
覆盖旧包，否则目标机可能跳过新 payload。普通后端源码和 XDisplay release 更新走已安装的 update
脚本，不需要重新发布安装包。

### 10.6 自动重启后不要再次手工运行安装包

如果 WSL/Windows 可选功能要求重启，bootstrap 会保存 UTF-8 状态并注册登录续装任务。登录原用户后
等待 `-Resume` 自动完成即可。脚本会把重启后仍存在的同一待重启标记视为残留标记继续执行，并在
完成后删除状态和任务，避免循环重启。

## 11. 推荐给下一个 agent 的优先级
### 11.1 如果只是继续当前体系打包
默认继续使用：

- 宿主机：`172.19.103.18`
- builder：`win11-wsl2-builder`
- 第 2 节的一键入口；源码通过正常 Windows 文件复制进入 `C:\work`

只有正常传输不可用时，才使用第 8 节的离线注盘恢复流程。

### 11.2 如果要更新后端或客户端
已安装开发版的普通更新不需要 builder，也不需要重新生成安装包：

- 后端使用 `Update-BackendSource.ps1` 同步源码并重启两个 Python 服务
- 客户端使用 `Update-XDisplayClient.ps1` 原子替换完整 XDisplay release

只有要生成新的首次安装 seed、更新基础镜像/前置依赖或制作新的交付版本时，才重新打包。

### 11.3 如果只是改 `windows-packaging` 脚本
只需同步：

- `ci/`
- `src/`
- `manifests/`

不需要每次都完整覆盖整个 `inputs`

## 12. 当前文档的定位
这份文档的定位不是“泛化到任何环境的包装说明”，而是：

**基于当前已验证环境，给后续 agent 的可直接执行版打包 runbook。**

只要：

- 宿主机 `172.19.103.18` 仍可用
- `win11-wsl2-builder` 仍可用
- builder 中的 `C:\xdisplay_ai\windows-packaging` 仍在

后续 agent 就不需要重新摸索整条链路。
