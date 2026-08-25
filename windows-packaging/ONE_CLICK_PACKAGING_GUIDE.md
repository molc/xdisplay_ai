# How to：在 Windows 中执行 XDisplay AI 一键打包

这份手册写给第一次使用 Windows、PowerShell 和 Windows builder 的人。照着本文操作，可以把一份
后端源码副本和一份 XDisplay 源码副本制作成完整的 Windows 离线安装目录。

## 先说结论

是的，builder 环境已经准备好以后，下一次打包的日常流程就是：

1. 把最新后端源码**副本**放到 `C:\work\backend`。
2. 把最新 XDisplay 源码**副本**放到 `C:\work\xdisplay`。
3. 在 Windows 中打开管理员 PowerShell。
4. 先执行预检命令。
5. 再执行正式打包命令。
6. 从 `C:\xdisplay_ai\windows-packaging\dist\dev` 取走**整个目录**。

正式打包只需要复制下面这一行命令并按回车：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1"
```

但是不要跳过前面的源码准备和预检。下面是从头到尾的完整步骤。

不要在文件资源管理器中双击 `.ps1` 文件。双击后窗口可能立即关闭，你看不到进度和错误。正确方法
是先打开 PowerShell，再把本文给出的完整命令粘贴进去。命令中的 `-ExecutionPolicy Bypass` 只对
这一次启动的 PowerShell 进程生效，不会永久修改 Windows 的执行策略。

## 你正在操作什么

整个流程只有四个位置：

```text
Mac 上的原始源码（只读，不修改）
                |
                | 完整复制
                v
Windows builder 上的源码副本
  C:\work\backend
  C:\work\xdisplay
                |
                | 执行 build-offline-package.ps1
                v
Windows builder 上的完整安装目录
  C:\xdisplay_ai\windows-packaging\dist\dev
```

原始源码位置是：

```text
/Users/molc/Documents/tricolor_work/ai-orchestration-page-engineering-unified
/Users/molc/Documents/tricolor_work/xdisplay
```

打包时只把它们复制到 Windows builder。打包脚本只操作 Windows 中的副本，不操作 Mac 上的原始
目录。

## 一、只需要确认一次的 builder 环境

当前已经验证可用的 Windows 虚拟机叫：

```text
win11-wsl2-builder
```

这台 builder 中已经准备了打包需要的工具：

- PowerShell
- Qt 5.15、qmake 和 windeployqt
- MinGW 和 mingw32-make
- WiX Toolset
- Docker Desktop 和 WSL2
- XDisplay AI 打包脚本
- Docker Desktop、VC 运行库和 WSL 的离线安装文件

只有更换 builder 或重装 Windows 时，才需要重新准备这些工具。正常换后端和 XDisplay 源码时，
不用重新安装。

请用普通 Windows 用户登录 builder。可以使用管理员 PowerShell，但不能从
`NT AUTHORITY\SYSTEM` 会话运行完整构建，因为 Docker Desktop 需要已登录的桌面用户会话。

## 二、每次打包都要做的步骤

### 第 0 步：启动并登录 Windows builder

如果 `win11-wsl2-builder` 已经运行，直接用现有的虚拟机控制台或 VNC 打开它，并登录 Windows。

如果它还没有启动，可以在 Mac 的“终端”中先检查状态：

```bash
ssh root@172.19.103.18 'virsh domstate win11-wsl2-builder'
```

输出 `shut off` 表示已经关机。执行下面命令启动：

```bash
ssh root@172.19.103.18 'virsh start win11-wsl2-builder'
```

看到 `Domain 'win11-wsl2-builder' started` 后，用现有虚拟机控制台或 VNC 登录 Windows。完整构建
必须在登录后的 Windows 桌面用户会话中执行。

### 第 1 步：准备两份完整源码副本

先把 Mac 上的两个原始源码目录完整复制出来。可以使用共享目录、SMB、移动硬盘或其他正常文件
复制方式把副本送进 Windows builder。

复制后，Windows 中必须形成下面两个目录：

```text
C:\work\backend
C:\work\xdisplay
```

在 Windows 中可以这样准备目录：

1. 按 `Win + E` 打开文件资源管理器。
2. 单击地址栏，输入 `C:\`，然后按回车。
3. 如果没有 `work` 文件夹，在空白位置单击右键，选择“新建” -> “文件夹”，命名为 `work`。
4. 如果 `C:\work` 中已经有上次使用的 `backend` 和 `xdisplay`，先确认没有构建正在运行，再把
   它们改名为备份目录或移走。
5. 把后端源码副本复制进 `C:\work`，并把该目录命名为 `backend`。
6. 把 XDisplay 源码副本复制进 `C:\work`，并把该目录命名为 `xdisplay`。

复制的是两个目录里面的完整内容，不是快捷方式，也不是只复制几个改过的文件。

不要直接在 Mac 原始目录里构建。Windows 中这两份副本是可丢弃的构建输入，脚本可以在副本中
生成中间文件。

后端目录必须是包含 submodule 工作树的完整副本。不要只用 `git archive`，因为它不会包含
`external\xdisplay` submodule 的实际文件。

### 第 2 步：检查目录有没有多套一层

按键盘上的 `Win + E` 打开“文件资源管理器”，然后单击上方地址栏，粘贴：

```text
C:\work\backend
```

按回车后，应该能直接看到 `Dockerfile`、`Dockerfile.embedding`、`app`、`data`、`db` 和
`external` 等内容。

正确目录：

```text
C:\work\backend\Dockerfile
C:\work\backend\app\main.py
```

错误目录，多套了一层：

```text
C:\work\backend\ai-orchestration-page-engineering-unified\Dockerfile
```

再在地址栏粘贴：

```text
C:\work\xdisplay
```

应该能直接看到 `src` 目录，并且下面这个文件存在：

```text
C:\work\xdisplay\src\Xdisplay_V2.pro
```

### 第 3 步：打开管理员 PowerShell

1. 按一下键盘上的 `Win` 键，或者单击任务栏上的 Windows 图标。
2. 输入 `PowerShell`。
3. 在“Windows PowerShell”上单击鼠标右键。
4. 单击“以管理员身份运行”。
5. Windows 弹出确认窗口时，单击“是”。

打开后，窗口标题通常会显示“管理员: Windows PowerShell”。后面的所有命令都粘贴到这个窗口中。

粘贴方法：在 PowerShell 窗口中单击鼠标右键，或者按 `Ctrl + V`，然后按回车。

### 第 4 步：用 PowerShell 检查三个关键路径

依次复制并执行下面三行命令：

```powershell
Test-Path "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1"
Test-Path "C:\work\backend\external\xdisplay\bin\xd_render_cli\xd_render_cli.pro"
Test-Path "C:\work\xdisplay\src\Xdisplay_V2.pro"
```

三行都应该输出：

```text
True
```

只要有一行输出 `False`，就先不要打包。检查是否复制到了错误目录、是否多套了一层目录，或者后端
源码是否缺少 submodule 内容。

### 第 5 步：先运行预检

如果这次要生成一个可以覆盖旧安装的新安装包，先打开：

```text
C:\xdisplay_ai\windows-packaging\manifests\bundle.json
```

把 `bundle.version` 改成一个比旧包大的三段版本号，例如当前已验证版本是 `0.1.2`，下一版可用
`0.1.3`。同一个版本号不要重复发布，否则 Windows 可能把新包当成已经安装过的旧包。只改普通后端
源码或 XDisplay release、并通过第四节的更新脚本部署时，不需要改安装包版本。

把下面一整行复制到管理员 PowerShell，然后按回车：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1" -PreflightOnly
```

预检只检查源码、离线依赖和打包工具，不执行完整编译。正常时最后会看到类似：

```text
[one-click-build] Preflight passed. Report: C:\xdisplay_ai\windows-packaging\logs\build-dev-日期时间.json
```

如果出现红色错误，先按本文“常见问题”处理。不要在预检失败时继续正式打包。

### 第 6 步：执行正式一键打包

预检通过后，把下面一整行复制到同一个管理员 PowerShell，然后按回车：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1"
```

脚本会自动完成：

1. 再次检查输入和工具。
2. 启动或等待 Docker Desktop。
3. 编译 XDisplay Windows 客户端。
4. 准备或复用后端运行时基础镜像。
5. 使用当前后端源码挂载 `/app` 做导入和运行 smoke test。
6. 准备后端源码 seed 和 XDisplay 客户端 seed。
7. 导出离线 Docker 镜像。
8. 构建 MSI、Bundle EXE 和外部 CAB。
9. 生成 `artifacts-dev.json`。
10. 重新校验全部交付文件的大小和 SHA256。

构建可能需要约 30 分钟。Docker 首次冷启动或需要刷新运行时镜像时可能更久。期间：

- 不要关闭 PowerShell 窗口。
- 不要关闭 Windows builder。
- 不要退出当前 Windows 用户。
- 如果 Docker Desktop 弹出窗口，让它继续启动。

成功时最后会看到类似：

```text
[one-click-build] Build succeeded. Delivery directory: C:\xdisplay_ai\windows-packaging\dist\dev
[one-click-build] Installer: C:\xdisplay_ai\windows-packaging\dist\dev\XDisplayAI-0.1.2-dev.exe
[one-click-build] Report: C:\xdisplay_ai\windows-packaging\logs\build-dev-日期时间.json
```

然后再执行：

```powershell
$LASTEXITCODE
```

应该输出：

```text
0
```

看到 `Build succeeded`、报告状态为 `succeeded` 且退出码为 `0`，才算本次打包成功。仅仅看到
`dist\dev` 中存在旧文件不代表本次构建成功。

### 第 7 步：打开安装包目录

在同一个 PowerShell 窗口中执行：

```powershell
explorer.exe "C:\xdisplay_ai\windows-packaging\dist\dev"
```

Windows 会用文件资源管理器打开交付目录。目录中至少应该包含：

```text
XDisplayAI-0.1.2-dev.exe
XDisplayAI-0.1.2-dev.msi
artifacts-dev.json
xdp1.cab、xdp2.cab 等所有 xdp*.cab
Docker Desktop Installer.exe
VC_redist.x64.exe
wsl_update_x64.msi
```

### 第 8 步：复制整个 `dev` 目录

把下面这个目录整体复制到移动硬盘、共享目录或要安装的 Windows 物理机：

```text
C:\xdisplay_ai\windows-packaging\dist\dev
```

不能只复制 `XDisplayAI-0.1.2-dev.exe`。这个 EXE 会使用同目录中的 CAB、Docker Desktop、VC 运行
库和 WSL 安装文件。少任何一个文件都可能导致离线安装失败。

物理机上应先把完整 `dev` 目录复制到本地磁盘，然后右键单击
`XDisplayAI-0.1.2-dev.exe`，选择“以管理员身份运行”。以后版本号变化时，选择目录里版本号最大的
`XDisplayAI-<版本>-dev.exe`。

如果安装过程中 Windows 自动重启：

1. 不要再次双击安装包。
2. 正常登录原来的 Windows 用户。
3. 等待自动续装任务启动 Docker、导入离线镜像并拉起后端；首次导入大镜像可能需要几分钟。
4. 续装完成后，临时任务和状态文件会自动删除，XDisplay 客户端会启动。

安装脚本会识别重启后仍存在的残留“待重启”标记并继续，不会因为同一个标记循环重启。

## 三、如果源码不在默认路径

新手优先使用默认目录：

```text
C:\work\backend
C:\work\xdisplay
```

如果确实要使用其他 Windows 目录，可以显式传入路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1" -BackendRepoPath "D:\sources\backend" -XdisplayRepoPath "D:\sources\xdisplay"
```

路径中有空格时必须保留双引号。

## 四、什么情况下不需要重新打安装包

已经安装开发版以后，普通后端 Python 源码变化不需要重新打包。把新的后端源码副本放到目标机，
然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XDisplayAI\scripts\update\Update-BackendSource.ps1" -SourcePath "C:\path\to\backend-copy"
```

这个命令会：

- 保留目标机现有的 `C:\ProgramData\XDisplayAI\workspace\backend\.env`。
- 更新其余后端源码。
- 重启主后端和 embedding-worker。
- 等待健康检查通过。

如果只是 XDisplay 客户端变了，先准备完整的 Windows release 目录，然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\XDisplayAI\scripts\update\Update-XDisplayClient.ps1" -ReleasePath "C:\path\to\xdisplay-release"
```

这个命令会校验 release、原子替换客户端并重新启动 XDisplay。

## 五、什么情况下需要重新打安装包

下面情况需要回到 builder 执行完整打包：

- 要给一台新电脑提供包含最新首次安装内容的安装包。
- 要生成新的 EXE、MSI 或 CAB 交付物。
- `Dockerfile` 或 `Dockerfile.embedding` 发生变化。
- `external\xdisplay\bin\xd_render_cli` 等后端原生运行依赖发生变化。
- Docker Desktop、WSL、VC 运行库等离线前置依赖发生变化。
- Windows 打包脚本、安装逻辑或 WiX 配置发生变化。
- 要制作一个新的正式交付版本。

下面变化通常不需要重新打安装包：

- 已安装机器上的 `app`、`data`、prompt 或普通 Python 源码变化。
- 已安装机器只需要换一份新的 XDisplay Windows release。
- 后端 `.env` 中的运行配置变化。
- 客户端配置的 LLM key 变化。

## 六、构建日志在哪里

所有顶层构建报告和 transcript 位于：

```text
C:\xdisplay_ai\windows-packaging\logs
```

每次构建都会生成带时间戳的文件，例如：

```text
build-dev-20260825-012801.json
build-dev-20260825-012801.log
```

JSON 中最重要的字段是：

- `status`：成功时是 `succeeded`。
- `error`：失败原因。
- `sources`：本次使用的两份源码路径和 revision。
- `output.directory`：交付目录。
- `output.bundle`：Bundle EXE 路径。
- `output.fileCount` 和 `output.cabCount`：交付文件数量。

失败时把最新的 `.json` 和同名 `.log` 一起保存，方便分析。

## 七、常见问题

### `BackendRepoPath does not exist`

原因：`C:\work\backend` 不存在，或者源码复制到了其他位置。

处理：用文件资源管理器检查路径。也可以使用 `-BackendRepoPath` 显式指定正确目录。

### `Backend source is incomplete`

原因：后端源码复制不完整，或者缺少 submodule 内容。

重点检查：

```text
C:\work\backend\external\xdisplay\bin\xd_render_cli\xd_render_cli.pro
C:\work\backend\data\chunks\component_capabilities_v1.jsonl
```

不要使用不含 submodule 工作树的 `git archive` 作为后端输入。

### `Xdisplay source is incomplete`

重点检查：

```text
C:\work\xdisplay\src\Xdisplay_V2.pro
C:\work\xdisplay\src\Service_PB\compile_all_proto.bat
C:\work\xdisplay\src\Service_Caesium\caesium\caesium.dll
C:\work\xdisplay\src\Service_PackL\res\UpdateUnpack.exe
```

### `Required build tool was not found`

原因：当前不是已准备好的 `win11-wsl2-builder`，或者 Qt、MinGW、WiX、Docker 的安装路径发生了
变化。

处理：确认虚拟机名称和工具安装。不要在普通物理机或另一台未准备的 Windows 上直接执行打包
脚本。

### `Docker daemon did not become ready`

处理顺序：

1. 确认当前已登录 Windows 桌面。
2. 手工打开 Docker Desktop。
3. 等 Docker Desktop 显示 Engine 正常运行。
4. 重新运行一键脚本。

不要用 `NT AUTHORITY\SYSTEM` 身份启动完整构建。

### PowerShell 显示红色错误

脚本任一阶段失败都会返回非零退出码并写入最新的 JSON 和 log。不要只看屏幕最后一行；到
`C:\xdisplay_ai\windows-packaging\logs` 找到本次构建对应的文件。

### 物理机安装时提示找不到 CAB 或依赖

原因通常是只复制了 EXE。

处理：重新复制整个 `C:\xdisplay_ai\windows-packaging\dist\dev` 目录，保持 EXE、CAB 和离线依赖
在同一目录。

## 八、最快操作卡片

如果已经熟悉流程，每次只需确认下面这些内容：

```text
1. 后端完整副本 -> C:\work\backend
2. XDisplay 完整副本 -> C:\work\xdisplay
3. 三个 Test-Path 都是 True
4. 执行 -PreflightOnly，看到 Preflight passed
5. 执行正式打包命令，看到 Build succeeded
6. $LASTEXITCODE 输出 0
7. 复制整个 C:\xdisplay_ai\windows-packaging\dist\dev
```

预检命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1" -PreflightOnly
```

正式打包命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\xdisplay_ai\windows-packaging\build-offline-package.ps1"
```

更底层的 builder 运维、恢复注盘和 qemu guest agent 操作，请看
[PACKAGING_RUNBOOK.md](PACKAGING_RUNBOOK.md)。
