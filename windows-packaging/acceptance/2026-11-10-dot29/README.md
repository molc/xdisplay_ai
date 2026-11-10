# 0.1.4 (s63f) 在 .29 上的安装 / 升级验收记录

## 结论（2026-11-10 23:15）

**放行版本：r11，包装源码 `bf74d56d`（builder 上构建时的提交；推送前把本地 main 变基到 `origin/main` 后，同一改动的提交号为 `d203e24`，打包脚本内容相同），安装包 `XDisplayAI-0.1.4-dev.exe` SHA256 `df92a8e4e8c654bb32facf92d72b2bfe638e36a4eab07409238a109b4bdc6e86`。** 交付目录 `~/Downloads/XDisplayAI-0.1.4-dev-s63f/`（20 个文件，2,022,868,870 B：bundle、MSI、10 个 cab、Docker Desktop / VC / WSL 三个前置、4 个 json 清单；本机逐文件与 `artifacts-dev.json` 核对 19/19 一致，`release-status.json` = `pass`，`NOT_READY.txt` 已由 builder 的放行门自己移除）。

| 场景 | 结果 | 要点 |
|---|---|---|
| 一：全清后全新安装（`fresh-r11-state.json`） | **17/17 门通过** | 安装 263 s、exit 0、不要求重启；4 个容器本机 Docker、18001 仅本机监听、s63f 镜像、31 个 prompt 钉、迁移执行、客户端拉起 |
| 二：已装 0.1.3 直接升级（`upgrade-r11-state.json`） | **19/19 门通过** | 升级 244 s、exit 0、**不要求重启**；只剩 0.1.4 注册；旧镜像 `a001031b…` → s63f `f65e76a3…`；pg 卷、工程、用户自定义配置行全保留；`.env` 进 s63f 合同 |
| 二次启动（桌面图标路径，`steady-r11*.json`） | **3.1 s** 走"健康即跳过" | r10 同一检查 195 s 全量重刷（指纹缺陷，r11 修） |
| 莫工 Word 16 项 | 全部通过 | 第 4 项在官方 c-184 模板上复核（ID 300 220×240 / ID 301 550×300），其余与 r6 同一客户端二进制 |
| 提测卡 | 24-902 / 空调键盘链在 r6 完成（后端镜像与 r11 相同） | 480×800 竖屏需客户端支持（产品侧）；`write_action_declare` 绑定未确认（后端侧） |

今天修进包里的缺陷（按发现顺序）：compose stderr 污染容器 id（`b6cd88cd`）、任何待删除项都要求重启（`58f4c5cf`）、客户端缺官方键盘模板与三张图（`50038034`）、升级后 `.env` 永不入合同（`08738ccb`）、缺 `Simulator.exe`（`1c65d842`）、**安装器运行时指纹与镜像标签算法不一致导致每次启动全量重刷（`bf74d56d`）**。

未改、需产品/后端侧决定：卸载不停后端容器；升级后 Docker Desktop 仪表盘弹到前台；辅助端口因 Hyper-V 保留区回退（有日志、APP 固定 18001）；builder VM 时钟比时区慢 8 小时，`release-status.json` / 清单里的 UTC 时间戳偏早。测试机 .29 现在处于 r11 全新安装状态。

日期：2026-11-10。目标机：`172.19.103.29` = DESKTOP-LLRKFC6，Dell Vostro 3890 物理机，Windows 11 IoT 企业版 LTSC 26100，静态 IP，无自动登录。
候选包：`XDisplayAI-0.1.4-dev.exe` SHA256 `DA39C672…`，由 `win11-wsl2-builder` 上 `T:\work\014-s63f-48f75880-r5\dist\dev` 构建（打包提交 48f75880，与 `main` b6f21509 树完全一致；app 镜像 tar `514ACD60…`，git-sha dd6ab3d50，runtime-fingerprint 5f1b3896…）。

## 场景二：已安装机器直接升级（0.1.3 → 0.1.4）

起点：.29 上先卸掉上一轮会话留下的 0.1.4-r4 候选（Burn 卸载 exit 0），再安装 2026-11-08 交付的 0.1.3 完整包（Burn exit 0，41 s，注册 0.1.3 ×2，本机 18001 健康），在 `runtime.env` / `workspace\backend\.env` 各写入一个哨兵键，记录 16 个用户工程目录（283 个文件）的 SHA256 与 `xdisplayai_postgres_data` 卷身份。

升级：`XDisplayAI-0.1.4-dev.exe /install /quiet /norestart`，66 s，**exit 0**，注册仅剩 0.1.4 ×2，启动时间不变。bootstrap 日志：

1. 正确拒绝"仅凭 HTTP 200 跳过"：列出 git-sha / tag / fingerprint 缺失、`XDISPLAY_AI_STAGED_DRAFTER_ENABLED` 残留、`XDISPLAY_AI_PROMPT_VERSIONS` 缺失、v19/v6 键缺失，然后"继续导入离线镜像并刷新配置"。
2. 前置依赖阶段检测到系统待重启标记（`PendingFileRenameOperations` 36 条，全是 Edge 更新与 `%TEMP%\DEL*.tmp`；CBS / WU 标记均不存在），按 0.1.4 设计写入 `bootstrap-state.json`（Phase reboot-pending）、注册 `XDisplayAI-ResumeSetup`（admin / Interactive / Highest / AtLogOn），MSI 自定义动作以 0 退出，**没有 1603，没有回滚**。
3. 重启 .29（上次开机 11-05，约 40 s 回到 RDP），以 admin 通过 RDP 登录 → Resume 任务自动运行：按种子指纹同步工作目录（update）、启动 Docker Desktop、导入离线镜像、重建 app / embedding 容器、健康检查、拉起客户端。

**r5 结果：续跑失败。** 登录后续跑任务同步了工作目录、导入了镜像、重建了容器（后端随后 200 健康），但在"等待 PostgreSQL 接受迁移查询"阶段 120 次全部失败，360 s 后抛错退出，`bootstrap-state.json` 与 `XDisplayAI-ResumeSetup` 任务残留（每次登录都会再跑一次并再失败；桌面图标启动客户端时同样会走到这一步：实测桌面图标 → UAC → bootstrap 重新导入镜像后以『127.0.0.1:18001 被 com.docker.backend 占用，且不是本机 XDisplay compose 栈』终止，客户端没有拉起）。错误文本：`No such container: time=2026-11-10T12:09:35+08:00 level=warning msg=C:\\Program`。

根因（已修，见 `b6cd88cd`）：.29 上 Docker Desktop 29.7.2 自带 Compose v5.3.1，对 compose 文件里过时的 `version:` 属性在 stderr 打两行 warning；`Common.ps1` 的 `Get-ComposeServiceContainerId` 用 `2>&1` 合流后整体 `[string]` 化，容器 ID 变成 "warning 文本 + ID"。修复：只取形如 12–64 位十六进制的那一行，忽略 ErrorRecord / warning 行（`Select-ComposeContainerId`，附单元测试）。同一函数也被"健康旧后端是否可跳过"检查使用，所以 r5 在这类机器上永远判定"不是本包 s63f 镜像"而重复导入镜像。

**r6（打包提交 `b6cd88cd`）场景二结果（16:19 重启 → 16:20 登录续跑 → 17:17 门禁）**：卸 r5 exit 0（23 s）→ 装 0.1.3 exit 0（42 s）→ 升级 r6 exit 0（62 s）；升级再次被待重启标记拦下（这次是前一步卸载留下的 8 条 `%TEMP%\DEL*.tmp`，见"发现"）；重启登录后续跑任务：导镜像、判定"运行中的 orchestration-app 不是本包 s63f 镜像"并强制重建 app/embedding、**PostgreSQL 等待通过**、迁移 3 条跳过已执行、健康 200、客户端拉起，续跑任务与状态文件清除。门禁 25 项：24 真（含哨兵保留、16 个工程 283 文件哈希不变、postgres 卷同一、迁移表 3 行、app 容器重建且镜像标签 = s63f、工作目录 SOURCE_REVISION = dd6ab3d50、四个 exe 钉、本机 18001 由 com.docker.backend 监听、无 portproxy），1 假：`promptContract`——升级保留下来的 0.1.3 `.env` 没有 `XDISPLAY_AI_PROMPT_VERSIONS`、还带退役键 `XDISPLAY_AI_STAGED_DRAFTER_ENABLED`。根因与修复见"发现"（r9）。记录：`postresume-r6-state.json`、`postresume-r6-bootstrap.log`。

## 场景一：全清后全新安装

- **22:38 全清（r11 前）**：`Wipe-29.ps1` 28 步，释放 15.4 GB；校验：注册项 0、`Program Files\XDisplayAI` / `ProgramData\XDisplayAI` 不存在、项目容器 / 卷 / orches 镜像为空、计划任务 0、18001 无监听、Package Cache 无 XDisplayAI、Docker Desktop 保留（前置依赖不属于产品状态）。验收脚本两个缺陷顺手修掉：产品卸载脚本的 compose stderr 警告（`version` 属性过时）被当成致命错误；`@($null).Count -eq 1` 让"注册项为空"被判成"仍有注册"。
- **22:42 r11 全新安装第一轮**：安装 exit 0（无 3010）、健康即通过；17 门中 16 通过：只剩 0.1.4 注册、导入 4 镜像、prompt 合同 31 钉、本机 Docker 监听 18001 / 无 portproxy / 显式本机 Linux 引擎、4 服务运行、双健康 200、s63f 镜像、4 个 exe 钉、迁移历史有行、工作目录种子指纹已记录、无残留 bootstrap 状态、客户端已拉起。失败的 `bootstrapNoError` 是脚本误判：全新机器上安装器第一次 5 秒就绪探测必然失败并被安装器捕获（"应用健康检查失败…无法连接到远程服务器"），但 PowerShell 转录仍记为 `PS>TerminatingError`。门已改为忽略这段已处理的探测块、继续检查真实错误；随后再次全清重跑取干净证据（`fresh-r11-state.run1.json` 保留）。
- **22:49 第二轮**：全清 WIPE_CLEAN；安装 260.6 s、exit 0、健康 0.1 s；仍只有 `bootstrapNoError` 失败——这次是 PowerShell `-match` 不区分大小写，把安装器已处理的 PostgreSQL 冷启动重试行（`等待 PostgreSQL 接受迁移查询 (1/120) … lastError=psql: error: connection to server on socket … No such file`）里的小写 `error:` 当成错误；升级场景里 pg 卷已存在、首查即成功，所以没出现这行。门改为 `-cmatch` 并排除 `lastError=` 重试行（`fresh-r11-state.run2.json` 保留），第三轮全清重跑。
- **22:56–23:02 第三轮（出货证据）**：全清 WIPE_CLEAN → r11 全新安装 `installExit 0`、262.9 s、健康即通过、未要求重启；**17/17 门通过**（只剩 0.1.4 注册、导入 4 镜像、无真实错误、prompt 31 钉、本机 Docker 监听 18001 / 无 portproxy / 显式本机 Linux 引擎、4 服务运行、双健康 200、s63f 镜像、4 个 exe 钉、迁移历史有行、种子指纹已记录、无残留 bootstrap 状态、客户端已拉起）。随后再跑一次 bootstrap：**3.1 s**，"本机后端已在 127.0.0.1:18001 就绪，且为本包 s63f 镜像与 prompt 合同，无需重复初始化"。证据：`fresh-r11-state.json`、`fresh-r11-bootstrap.log`、`steady-r11.json`、`wipe-state.json`。
- 两场景证据汇总为 `windows-pass-dot29.json`（fresh pass / oldVersionPreservation pass / steadyStateHealthOnlySkip pass，bundle SHA `df92a8e4…6e86`），交给 builder 的 `build-offline-package.ps1 -VerifyExistingOutputsOnly -AcceptanceEvidencePath` 复核放行。

待填。

## Word 反馈（莫工 16 项）与提测卡复测

### 预检（r5 后端 + 同一客户端 2A80890D，r6 构建期间，14:20–14:40）

- .29 出厂没有任何 LLM 密钥（后端 `.env` 无 `XDISPLAY_AI_LLM_API_KEY`，容器内 `/data/provider_key.json` 不存在）——这是打包要求（密钥扫描禁止入包）。用户提供了一个**仅供测试**的百炼 key，经 `POST 127.0.0.1:18001/api/v1/assistant/provider-key`（provider=bailian，baseUrl 显式给 `https://dashscope.aliyuncs.com/compatible-mode/v1`）注入，落在 `xdisplayai_app_data` 卷里；不进包、不进仓库、不进日志。注意：该端点在 `baseUrl` 为空时会回落到 `.env` 的 `XDISPLAY_AI_LLM_BASE_URL`（OpenRouter），百炼 key 必须显式带 baseUrl。
- AI 链路端到端可用：24-902 原话在"800*480 + 旋转 90°"工程上 42 s 出稿（DashScope 全 200，作者 glm-5.2，声明器 qwen3.8-max），一件 statictext、一行、告示「…按一行画（72px→42px）」、无读数件、应用成功。
- **发现（后端/客户端，非安装器）**：客户端新建工程与工程属性的分辨率都是固定下拉列表，没有 480*800；竖屏只能用 800*480 + 旋转 90°（页面 W480 H800）。后端披露"工程分辨率是 800×480，页面按它生成，没有沿用当前页的 480×800"，应用后页面被改成 800×480。提测卡里"480×800 工程"的 26px/宽 468 预期在这个客户端构建上无法复现，只能得到 800×480 的 42px 版本。
- 这一步已顺带确认 Word 第 1 项（分辨率下拉）、第 3 项（XD 图标）、第 4 项（数字键盘/全键盘页）、第 5 项（第一次新建即有画布）、第 7 项（工程属性显示当前分辨率 800*480 / 旋转 90°）。

### r6 上的正式走查（17:18–17:38，客户端 2A80890D，与 r9 相同；仅键盘模板在 r9 换成官方版）

| # | Word 项 | 结果 | 证据 |
|---|---|---|---|
| 1 | 新建工程分辨率应为下拉 | 通过 | 固定列表 320*240 … 1920*1080（17 项），工程属性同样 |
| 2 | 窗口最小化/最大化/关闭 | 通过 | 标题栏三键存在且可用（word-r6/26-minimized） |
| 3 | XD 相关图标 | 通过 | 工具栏 18 个控件图标、标题 logo（images/bartitle 来自官方包） |
| 4 | 键盘页 300/301 | 通过 | r6（旧缓存模板）：ID 300 440×480 / ID 301 1000×600；**r10 复核（21:57，升级后同步到的官方 c-184 模板）**：新建 800×480 工程自带"数字键盘"ID 300 220×240 与"全键盘"ID 301 550×300（截图 s29-kb300 / s29-kb301） |
| 5 | 第一次新建即有画布、可拖控件 | 通过 | 08-static-text-dragged：静态文本拖入 (218,185) |
| 6 | 界面清晰度 | 通过（主观） | 1600×900 下文字清晰 |
| 7 | 工程属性同步分辨率 | 通过 | 显示 800*480 / 旋转 0°，改 854*480 后页面随之 854×480 |
| 8 | 图片库有系统图 | 通过 | r6：系统图库 4 张（同一客户端二进制）。r10：文件级复核——`workspace\client\images` 596 个文件与种子同步，`images/launch/logo_tricolor.png`、`images/base/scale_*_hover.png`、`titlelogo.png` 齐备；图片选择器 UI 在驱动脚本下未能再次打开，未重复截图 |
| 9 | 字体库 / 常用字 | 通过 | 三个字体（OPPO Sans 4.0 / fangsong_GB2312 / 思源黑体）；字体裁剪常用字 7000、拼音文件 52.85 KB |
| 10 | 指令工具可用 | 通过 | 对话框打开，协议格式/变量浏览/发送区正常 |
| 11 | 转换工具 | 通过 | 转换工具窗口：音频/视频/字符转换 |
| 12 | LUA 编辑器 | 通过 | ZeroBrane Studio 打开工程 private\main.lua |
| 13 | 帮助文档 | 通过 | Edge 打开 workspace\client\doc\Xdisplay使用手册V2.4.4.pdf（179 页） |
| 14 | 关于：淳信二维码 | 通过 | V2.4.4，二维码 + "进入官网" |
| 15 | AI 工作区清晰度 | 通过（主观） | 23-ai-workspace |
| 16 | 配置/总览图标提示词 | 通过 | 悬停分别显示"配置"、"总览" |

提测卡：
- 24-902 原话（800*480 + 旋转 90°，见预检）：一件 statictext、一行、告示「按一行画（72px→42px）」、无读数件、应用成功；但后端按工程分辨率 800×480 出页（客户端无法建 480×800 工程，见上）。
- 键盘两轮链（854×480，原话「做一个房间空调控制页…」）：**单轮** 81 s 出稿，应用成功：7 个控件、自动创建用户变量 设定温度(0000)/当前室温(0001)、页面改名"房间空调控制页"、"点击设定"按钮在。没有出现"先供键盘页再续发"的两轮——这个工程由官方模板创建，已自带 数字键盘/全键盘 页，后端无需供页；日志 `write_action_declare` 对 set_temperature_input 的写绑定 needed 1 / resolved 0（writes_bound 0），即"点击设定 → 键盘页输入同一变量"这条链在本次没有绑上，需后端/客户端同事看（与安装器无关，s63f 行为）。记录：`ac-ai/*.png`、`applog2.json`。

## 客户端来源核对（2026-11-10 17:45）

交接要求"从 `client/c-185` 取码打 Windows 包"。核对客户端仓：钉死的缓存客户端 `P:\catalogwrite-9aa152b7\client`（Xdisplay.exe SHA `2A80890D…`）构建自 9aa152b7 = `fix(c-183)`，它是 `client/c-185`（d4a3d2d）的祖先，且 `git diff 9aa152b7 client/c-185 -- src Tool_Converter simulator Tool_Encrypt` 为空——两者代码完全相同，差别只有 c-184 的运行时资源入仓与两份测试夹具。因此 r9 的 Xdisplay.exe 就是 c-185 代码（含 c-181 莫工 Word 7 项、c-182 背景 PNG 校验、c-183 图库临时文件），Converter.exe 钉的是 10b7a3d（转换工具白窗修复）构建；运行时资源按 c-184 官方版覆盖。未重新编译客户端，不需要。

## 发现

- **r11 场景二（22:27–22:36，`df92a8e4…6e86`）**：前置卸载 r10 15 s → 移除项目容器、清掉 8 条卸载遗留的 `%TEMP%\*.tmp` 待删除项（验收脚本步骤，未重启）→ 0.1.3 基线 232 s（真正的旧镜像 `a001031b…`）→ 升级到 r11 244 s、exit 0、`bootUnchanged`；**19/19 门通过**（`appContainerRecreated`：`a001031b…` → `f65e76a3…` s63f；prompt 31 钉、退役键删除；pg 卷相同；工程与哨兵行保留；三个辅助端口按设计回退、APP 固定 18001）。升级后再跑一次 `Bootstrap-InstalledPayload.ps1 -NoAutoReboot`：**3.1 s**，日志"本机后端已在 127.0.0.1:18001 就绪，且为本包 s63f 镜像与 prompt 合同，无需重复初始化"（r10 同一检查 195 s 全量重刷）。证据：`upgrade-r11-state.json`、`upgrade-r11-bootstrap.log`、`steady-r11-after-upgrade.json`。
- **安装器运行时指纹与镜像标签永远不等（r11，`bf74d56d`，阻断级）**：r10 场景二重跑的日志里，对一个**已经是 s63f 镜像且健康**的栈，安装器仍打印"orchestration-app runtime-fingerprint 5f1b3896… does not match package fingerprint … 继续导入离线镜像并刷新配置"并强制重建 app/embedding-worker。原因：`Get-ExpectedS63fRuntimeFingerprintFromSeed` 用工作目录种子那套行格式（只有 `file\0路径\0sha256` 行）对 8 个 Dockerfile/渲染器输入做哈希，而构建期给镜像打 `xdisplayai.packaging.runtime-fingerprint` 标签的 `ci/Common.ps1 Get-SourceContentFingerprint` 每个输入还多一行 `input\0路径`。在 builder 上用 r10 的 staging 种子逐字节验证：安装侧 `0826653f…`，ci 侧 `5f1b3896…`（= 镜像标签）。后果是 `Test-InstalledBackendMatchesPackage` 永远为假，桌面图标每次启动客户端（走 `Bootstrap-InstalledPayload.ps1`）都重新 `docker load` 2.3 GB 并重建容器，约 4–5 分钟——r9 修掉的 `.env` 合同问题只是这个症状的一半。修复：`Get-PathContentFingerprint -IncludeInputRows`（仅 s63f 运行时指纹使用；工作目录同步指纹保持旧行集，自己与自己比较不受影响），单测把 ci 函数文本抽出来与安装侧在同一临时树上比较（130 项通过，r10 为 126 项）。r11 重新构建，验收时加"升级后再跑一次 bootstrap 必须走跳过路径"的计时门。实测（21:52，r10 升级后的健康栈上再跑一次 `Bootstrap-InstalledPayload.ps1 -NoAutoReboot`）：**195 秒**，日志完整重复了"不是本包 s63f 合同 → 导入 4 个镜像 → 重建 app/embedding → 迁移 → 等健康"，这就是客户每次点桌面图标要等的时间。
- **r10 场景二第一轮（21:19–21:28）**：0.1.3 装 285 s / 升级到 r10 290 s，升级**未要求重启**（exit 0、`bootUnchanged`），只剩 0.1.4 注册项，`.env` 进入 s63f 合同（31 个显式钉、退役键已删）、后端 s63f 镜像健康、pg 卷与工程与哨兵行全保留。19 个门里有 2 个判失败，查明都是验收脚本自身的缺陷而非包：(1) `bootstrapRefusedHealthOnlySkip`——脚本用文件字节数做"升级前日志长度"，再用字符偏移截尾，日志含中文导致截到空串；实际日志第 979 行就是"本机 18001 健康，但不是本包 s63f 合同 … image=sha256:a001031bb9b0"后接完整刷新（导镜像、删退役键、补 31 钉、迁移均已执行、重建容器、健康）；(2) `configLiteralsPreserved`——`POSTGRES/REDIS/EMBEDDING_HOST_PORT` 三个辅助端口被当成用户字面量，而安装器的"选择可用的本机发布端口"是有日志的设计行为（55432→55662、56379→56380、18090→18091，`APP_HOST_PORT 仍固定为 18001`；0.1.3 自己首装时同样把 55432 换成了 55661，应是 Windows 的 Hyper-V/WSL 动态端口保留区所致）。脚本已修（按字符计长、三端口键归入安装器管理项），并加了仅验收用的"清掉卸载遗留的 `%TEMP%\*.tmp` 待删除项"步骤以免为 0.1.3 基线再重启，随后重跑。
  同一轮的工作目录核对：五个 `keypage.json` 工作目录与种子哈希一致（keyboard_a 36,524 B，官方模板已随升级同步到位），`Simulator.exe`（13,540,972 B）、`logo_tricolor.png`、`scale_less_hover.png`、`titlelogo.png`、使用手册、`qrcode_about.jpg` 在种子与工作目录都存在；`workspace-sync.json` 记录了 0.1.4 的客户端/后端种子指纹。升级后 Docker Desktop 的仪表盘窗口会弹到前台（安装器启动 Docker Desktop 时未最小化），体验瑕疵，未改。
- **0.1.3 基线的"待重启即回滚"（复测 0.1.3 时必须知道）**：重启 .29 后第二次回装 0.1.3，MSI 退出 1603、Burn 回滚（`upgrade-r10-v013-install-burn.log`：Exit code 0x643）。0.1.3 的 `Bootstrap-InstalledPayload.ps1` 在前置依赖阶段打印"检测到系统待重启，将在重启后继续执行"后退出非 0，MSI 把它当失败——正是 `41fe120` 在 0.1.4 里修掉的行为；触发它的只是前一步卸载留下的 `%TEMP%\DEL*.tmp` 待删除项（0.1.3 的 `Test-PendingReboot` 对任何 `PendingFileRenameOperations` 都算待重启，0.1.4 已在 `58f4c5cf` 收窄）。所以在 .29 上铺 0.1.3 基线的顺序必须是：卸载 → 重启（清掉待删除项）→ 安装 0.1.3，中间不能再有卸载动作。
- **测试机事故（.29，20:10–21:05，与产品无关）**：r9 场景二在"回装 0.1.3 基线"一步超时（45 分钟）。0.1.3 的 MSI 本体 40 秒装完（`InstallFinalize` 返回 1），卡在它的安装后自定义动作 `RunBootstrapAfterInstall` → `Bootstrap-InstalledPayload.ps1` 的 `Enable-RemoteDesktopAccess`（日志停在"启用 Windows 远程桌面访问"），进程 12 线程、1 秒 CPU、无子进程；同一时刻从另一个进程查防火墙规则 / CIM / TermService 都正常。这个步骤只存在于 0.1.3（`41fe120` 已删除），而且同一 0.1.3 包在当天 15:50 的 r6 场景中正常装完，差别是 20:03 这台机器刚经历一次桌面会话崩溃（见下一条）。处理：21:02 重启 .29，把 r10 的场景二脚本改成"先卸掉任何已注册的 bundle（含半装的 0.1.3）再回装基线"，r9 不再单独验证。
  会话崩溃的来源是驱动脚本：客户端以管理员身份最大化运行时，Win+R 发送的命令落进了编辑器，客户端 `0x40000015` 崩溃后桌面会话的 DWM 随之崩溃并注销（`ERRINFO_GRAPHICS_SUBSYSTEM_FAILED` → `LOGOFF_BY_USER` → `SERVER_DWM_CRASH`），3 分钟后重新登录恢复。已记入 .29 操作备忘。

- **builder 侧事故（r9 构建，19:27–21:18 北京时间，与产品无关）**：`Run-Native014Build-rN.ps1` 包装脚本把 `$env:TEMP` 指到 `T:\work\014-s63f-ops-temp-r6`，而当天上午清理旧 workroot 时把这个目录删掉了。WiX v5 `wixnative smartcab`（dutil `CabCGetTempFile`）在 %TEMP% 下 `CreateFileA` 失败时不分错误码地重试、上限 2^32 次，于是 MSI cab 阶段变成无声空转：8 个 `wixnative.exe` 各占约 14% CPU、全是内核时间、每秒约 1300 次"其他"I/O、零读零写、`SystemTemp\<rand>.ons` 下没有任何 `.cab`。定位依据：`Win32_Process` 的 Read/Other 操作计数差分 + 读进程 PEB 得到的 TEMP 值 + WiX 源码。处理：重建目录后 25 秒内 8 个进程开始读数据，构建原地续跑，未重启；r10 包装脚本改为使用自己的 `ops-temp-r10`。正常 cab 阶段约 45 分钟（r7：wix 启动后 32 分钟出第一个 cab，45 分钟出齐 11 个）。

- **缓存客户端树缺 Simulator.exe（r10，`1c65d842`）**：`widget_main.cpp` 的"编译预览"按 `<运行目录>\Simulator.exe` 启动模拟器，钉死的缓存树和此前所有 0.1.x 包里都没有这个文件（官方 2.4.4 包有，13,540,972 B，SHA `2A9C324C…`）。r10 把官方二进制放进客户端树根目录，并加入 `CachedRelease.ps1` / `validate.ps1` 必备清单。交接里要求的"由 `simulator/` 源码构建"留给下一轮（需要 builder 上的 Qt 源码构建链）。

- **升级后的后端 `.env` 永远不在 s63f prompt 合同内（r9，`08738ccb`）**：0.1.3 写的 `.env` 没有 `XDISPLAY_AI_PROMPT_VERSIONS` 这一行；`Update-BackendPromptVersionPins` 对"没有这一行"直接返回"无需改动"，而退役键只在旧 `runtime.env` 迁移分支才删除。后果：`Test-LocalBackendSkipAllowed` 每次都判"不是本包合同"，桌面图标每次启动客户端都要重跑完整的后端刷新（导 2.3 GB 镜像、重建容器，约 6 分钟）。修复：缺行时按 s63f 注册表整表写入（备份原文件）；只要后端 `.env` 存在就删退役键。原单测"没有显式钉表就保持代码默认"与打包合同（必须有 31 个显式钉）矛盾，已改为"必须补种"。

- **客户端运行时资源（r8，`50038034` / `e00ce8a2`）**：builder 上钉死的缓存客户端树 `inputs\client\xdisplay-win64` 里 `data/keyboard_a..e` 不是官方 2.4.4 模板——每个模板里塞了三份字体（共 175 MB），`keypage.json` 与图片集也与官方不同（例：keyboard_a 官方 36,524 B / 32 文件，缓存 278,558 B / 与 keyboard_d 同）。客户端源码仓 `client/c-181`（cc97e3f）已按架构师裁决把官方资源入仓（`RUNTIME_RESOURCES.md`）。比对 c-181 与缓存树：`res/` 三字体 + 三个 pinyin、`doc/使用手册`、`qrcode_about.jpg`、`logo*.png`、`images/` 86 个文件完全一致；缺 `images/launch/logo_tricolor.png`、`images/base/scale_{less,more}_hover.png` 三个代码引用的文件。处理：缓存树的五个模板目录整体换成 c-181 版本（旧目录移到 `T:\logs\client-data-keyboard-backup-*`），补三张图；`CachedRelease.ps1` / `validate.ps1` 的必备文件清单加 `titlelogo.png`、`logo_tricolor.png`、`res/pinyin.bin`、使用手册、`qrcode_about.jpg`。因为 `Xdisplay.exe` 没变，0.1.3 → 0.1.4 升级时工作目录同步原本会判 `keep`、客户永远拿不到新模板，所以客户端种子指纹改为同时覆盖五个 `keypage.json` 与 `logo_tricolor.png`（附单元测试）。

- `Install-OfflinePrerequisites.ps1` 的 `Test-PendingReboot` 把任何非空 `PendingFileRenameOperations` 当成"需要重启"。实测两次：r5 升级被 36 条 Edge / `%TEMP%` 待删除项拦下；.29 重启后立即做 r6 升级，又被 8 条 `%TEMP%\DEL*.tmp` 拦下——这 8 条是前一步 Burn 卸载 r5 / 安装 0.1.3 自己留下的。也就是说**任何升级都必然要求客户重启一次**，而且旧版 MSI 被 MajorUpgrade 移除后后端已停，直到客户重启登录前后端一直不可用。**已修（`58f4c5cf`，r7）**：CBS / Windows Update 标记照旧；`PendingFileRenameOperations` 只在条目涉及 WSL / VirtualMachinePlatform / Docker / 驱动路径时才算需要重启，其余（临时文件、浏览器更新）记一条日志后忽略。附单元测试。
