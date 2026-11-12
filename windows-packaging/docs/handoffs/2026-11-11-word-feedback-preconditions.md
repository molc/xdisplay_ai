# Word 反馈闭环的前提条件（给所有在 xdisplay / xdisplay_ai 上继续推进的 agent）

> 2026-11-11。背景：莫工《AI体验》Word 16 项已在 0.1.4 r6/r10/r11 包上于物理机 .29 逐项验收通过（记录：`xdisplay_ai/windows-packaging/acceptance/2026-11-10-dot29/README.md`）。
> **后续任何一次打包的前提是这 16 项仍然闭环。** 客户端严格线与自由线已经合并（`codex/int-6001`，11-10 合入 `strict/merge-int-6001-20261110`，11-11 继续合入 c-302…c-320）并且还在持续推进，下面这些东西任何人改动、覆盖、漏合都会让 Word 项倒退，打包会被打回。

## 1. 必须保留的客户端代码：PR #1 = `client/c-185`（d4a3d2d4）

| 提交 | 内容 | 影响的 Word 项 |
|---|---|---|
| `251e2248` fix(c-181) | 闭合莫工 Word 剩余 7 项（新建工程分辨率下拉、工程属性同步分辨率、指令工具、图标/提示词等） | 1、7、10、16 等 |
| `10b7a3d5` fix(c-181) | 转换工具白窗：独立进程补 software Quick 后端并去掉透明 QQuickWidget（`Tool_Converter`；打包里钉死的 `Converter.exe` 就是这版） | 11 |
| `fedc4836` fix(c-182) | 同源校验通过的背景 PNG 不再因 Windows 无名 fd 权限误报 restore_failed | 8（图库）|
| `9aa152b7` fix(c-183) | Windows 图库临时文件先释放 QTemporaryFile 再交给 QSaveFile | 8 |

涉及 21 个源码文件（`git diff --stat client/c-180 client/c-185 -- src`）：`src/Core/tc_comp*.cpp`、`tc_project.*`、`src/Helper/dialog_tool_cmd.*`、`dialog_tool_image.cpp`、`helper.*`、`image_file_io_v1.cpp`、`image_library_mutation_v1.cpp`、`src/Part_Launch/dialog_project_add.qml`、`src/Part_Main/widget_main.*`、`widget_panelai.qml`、`AiWorkspaceTheme.qml`、`src/Service_AI/browser_image_apply_transaction_v1.cpp`、`service_ai_image_downloader.cpp`。

- 截至 11-11，`client/c-185` 与 `client/c-184` 都已是 `origin/codex/int-6001` 顶端（`9e59c066`）的祖先。**合并、rebase、squash、冲突解决时不得丢掉这些提交的行为**；上面这些文件出现冲突，优先保留 Word 修法，并在提交信息里写明。
- 自检：`git merge-base --is-ancestor client/c-185 <你的分支>` 必须为真；对上面 21 个文件 `git diff client/c-185 <你的分支> -- <文件>` 若有改动，需要对照 Word 项复测。

### 1a. 2026-11-11 对 `int-6001` 顶端（9e59c066）的守卫检查结果

工具：`xdisplay_ai/windows-packaging/ops/host/word-fix-guard.py --check <提交>`（祖先检查 + 文件哈希 + PR #1 新增行是否仍在）。

- `client/c-185`、`client/c-184` 都是祖先；官方资源 287 个文件 0 漂移。
- 21 个 Word 修法源码文件里 9 个在合并后有改动：`tc_project.cpp/.h`、`widget_main.cpp/.h`、`widget_panelai.qml`、`browser_image_apply_transaction_v1.cpp`、`service_ai_image_downloader.cpp` 的 Word 修法新增行**全部保留**；
- **两个文件缺了修法行**：`src/Helper/dialog_tool_image.cpp` 18/19（缺 `if (!TC_Project::GetInstance()->func_save_json_data(temporaryPath, …` 一带，c-183 图库临时文件 QTemporaryFile→QSaveFile）、`src/Helper/image_library_mutation_v1.cpp` 21/25（缺 `observed.digest == operation.publication.digest`、`observed.size == … acceptedBytes`、`const bool ours = (!operation.publishedObjectId.isEmpty()` 一带，c-182 同源校验）。
- **请合并这两处的 agent 回答**：是等价重写，还是修法被覆盖？在 Windows 上复测 Word 第 8 项（系统图库、背景 PNG 不误报 restore_failed）并把结论写进提交信息；打包侧在拿到答复前不会把这个提交打进包。

## 2. 必须保持字节一致的运行时资源：`client/c-184`（cc97e3f0 / 7f0a94cf / 3ac674f8）

来源是官方 `Xdisplay_2.4.4_20261027` 包（架构师 11-10 裁决入仓，见客户端仓 `RUNTIME_RESOURCES.md`）：

- `data/keyboard_a..e/`、`data/config_res/` —— Word 4（键盘页 300/301，新工程自带）、变量库/字体库默认内容
- `images/{bartitle,barmenu,launch,panelpage,base}/` + `images/_old/{check_press-old.png,toolbox/Button.png}` + 代码引用的 `images/launch/logo_tricolor.png`、`images/base/scale_{less,more}_hover.png` —— Word 2（标题栏三键）、3（图标）、15
- `res/OPPO Sans 4.0.ttf`、`res/SourceHansCN.otf`、`res/fangsong_GB2312.ttf`、`res/pinyin*.bin` —— Word 9
- `doc/Xdisplay使用手册V2.4.4.pdf` —— Word 13；`qrcode_about.jpg`、`logo*.png` —— Word 14

注意：
- 打包把这些目录作为"客户端种子"装到客户机，并按**种子指纹**（`Xdisplay.exe` + 五个 `keypage.json` + `logo_tricolor.png`，`InstallerCorrectness.ps1 Get-WorkspaceFingerprintRelativePaths`）决定升级时要不要覆盖客户工作目录。**只改资源不改 `Xdisplay.exe` 时，改动的文件必须加进这个列表，否则老客户永远收不到。**
- 自检：`git diff --stat client/c-184 <你的分支> -- data res images doc qrcode_about.jpg logo.png logo_about.png` 应为空；不为空就是有人动了资源，需要复测 Word 2/3/4/8/9/13/14 并同步打包指纹。
- 旧缓存树里曾有一版"每个模板塞三份字体、keypage.json 与官方不同"的键盘模板（r8 之前），不要再把那版带回来。

## 3. 第三方运行时（不在客户端仓里，由打包工程钉死）

`Simulator.exe`、`avcodec-62.dll`、`avformat-62.dll`、`avutil-60.dll`、`swresample-6.dll`、`swscale-9.dll`、`ffmpeg.exe`、`optipng.exe`，全部取自官方 2.4.4 包，SHA256/字节数钉在 `xdisplay_ai/windows-packaging/ci/CachedRelease.ps1 Get-PinnedThirdPartyRuntimeFiles`。

- r10/r11 只放了 `Simulator.exe` 没放它导入的 ffmpeg 五个 DLL，客户端"编译预览"起模拟器时 Windows 加载器报"找不到 avcodec-62.dll"（.29 复现）。r12 补齐并加了构建门：`Xdisplay.exe` / `Simulator.exe` / `Converter.exe` 导入的每个非系统 DLL 必须在发布树里。
- 将来按裁决改为从 `simulator/`、`Tool_Converter/`、`Tool_Encrypt/` 源码构建时：`simulator/src_main/Simulator.pro` 链接的是 MinGW 导入库 `../ffmpeg/lib/lib*.dll.a`，仓里只有 `*.def/*.lib`，要在 builder 上用 `dlltool` 从 `.def` 生成；运行时 DLL 仍取官方包那套（`avcodec-62` 等，版本必须与导入表一致，`C:\work\xdisplay-release-7cf47a41\avcodec-62.dll` 是另一套别混用）。
- Qt 运行时布局是 windeployqt 式（`qt.conf`：`Plugins=plugins`、`Qml2Imports=qml`），官方包是平铺式；换布局要同时改 `qt.conf`。

## 4. 后端侧前提

Word 15/16 与提测卡依赖后端 `ai_orchestration` `prod/s63f`（`dd6ab3d50`）镜像：镜像三标签（`xdisplayai.packaging.git-sha/tag/runtime-fingerprint`）、31 个 prompt 钉、退役键删除、`APP_HOST_PORT=18001`。合并线里 c-302（AssetOriginV3）、c-311/315（运行宿主）、c-320（迁移源合同 v2）如果要求后端升级，必须先走后端导出流程（`backend-export/<tag>/rebuild-orches-app-image.sh`）并整体换钉，不能只换客户端。

## 5. 任何客户端合并之后的验证程序（不可省）

1. 在 builder 上从合并线重新编译 `Xdisplay.exe`（当前出货的 r11 客户端是合并前的 `9aa152b7`，合并线 `src/` 已改 163 个文件）。
2. 两场景安装验收（全清全新安装 + 已装 0.1.3 直接升级）+ 二次启动走"健康即跳过"。
3. **Word 16 项逐项重走**（客户端二进制一换就要重走，约 2.5 小时；步骤、坐标、截图规范见 acceptance README），其中第 4 项要在官方模板上核 ID 300 / 301 的存在与尺寸，第 11 项要真的点开转换工具并做一次转换。
4. 提测卡客户端侧流程（24-902 原话出稿、空调键盘链）。
5. 机制与命令见 `xdisplay_ai/windows-packaging/ops/README.md`。

## 6. 仍然开放、与 Word 无关但会被问到的事

- 客户端没有 480×800 竖屏选项（提测卡 24-902 用 800×480 旋转替代）。
- 空调页"点击设定"写绑定在后端日志里 `write_action_declare needed 1 / resolved 0`。
- 升级后 Docker Desktop 仪表盘弹到前台；卸载不停后端容器；新机器首装时 MSI 自定义动作里的长流程没有进度（用户会点取消触发回滚，见 11-11 反馈）。
