# 快速重打包手册（ops/）

> 适用范围：**后端或客户端更新后，重新打出一个可交付的 0.1.4 离线安装包并在 .29 上验收**。
> 这是 2026-11-10 r5→r11 六轮打包的沉淀。老文档 `PACKAGING_RUNBOOK.md` / `ONE_CLICK_PACKAGING_GUIDE.md` 讲的是脚本职责与"从源码构建"模式，仍然有效但不是日常路径；日常路径只看本文。

## 0. 一页纸流程与时间

| 步骤 | 在哪 | 工具 | 典型耗时 |
|---|---|---|---|
| 1 改输入与钉 | 本机仓库 + builder 的 `inputs\` | 见 §2 / §3 | 10–30 min |
| 2 把改动同步到 builder、跑单测 | 宿主机 → builder | `host/stage-overlay.sh` + `builder/Sync-SourceOverlay.ps1` | 3 min |
| 3 构建 | builder | `builder/Invoke-NativeBuild.ps1` | 30–35 min（cab 阶段 ~12 min） |
| 4 传回宿主机并校验 | builder → 宿主机 | `builder/Invoke-DeltaUpload.ps1` + `host/recv.py` + `host/verify-dist.py` | 3–5 min |
| 5 .29 场景二：已装 0.1.3 → 升级 | 宿主机驱动 .29 | `host/render-run.py` → `Stage/Upgrade/Steady` | 15 min |
| 6 .29 场景一：全清 → 全新安装 | 同上 | `Wipe` → `Fresh` → `Steady` | 12 min |
| 7 证据 → builder 放行 | 宿主机 → builder | `make-evidence-<run>.py` → `builder/Invoke-VerifyPass.ps1` | 8 min |
| 8 回传元数据、拷到 Downloads | builder → 宿主机 → 本机 | `builder/Upload-DistMeta.ps1`、`rsync`、`host/verify-dist.py` | 5 min |

**顺利时约 1.5–2 小时**。时间几乎都花在构建与两场景的安装上；人工动作只有改钉、起脚本、看结果。

## 1. 环境拓扑（都已就位，不用重搭）

- 控制端：本机 Mac（仓库在 `~/Documents/tricolor_work/xdisplay_ai/windows-packaging`，无 pwsh，PowerShell 只能在 builder 上解析/运行）。
- 宿主机 `172.19.103.18`（root，ssh 免密）：跑 libvirt；用 `host/qga.py <vm> <script.ps1>` 通过 qemu-guest-agent 在 builder 里以 SYSTEM 身份执行 PowerShell；用 `python3 -m http.server <port> --bind 172.19.103.18` 给 builder / .29 提供文件；用 `host/recv.py <port> <dir>` 接收 builder 上传。
- builder VM `win11-wsl2-builder`（IP 172.19.103.27，无网、无 git、无 dotnet；WiX v5、Docker Desktop 已装）：源码树 `T:\source-e2e27dd8\windows-packaging`（含 `inputs\`），日志 `T:\logs`，工作目录 `T:\work\014-s63f-<commit8>-<run>`，每个 workroot 约 7 GB，T 盘 64 GB，**开工前保证 ≥ 12 GiB 空闲**（脚本会拒绝）。
- 测试机 `.29`（172.19.103.29，物理 Win11 IoT LTSC，只开 RDP）：宿主机上 Xvfb `:29` + xfreerdp 驱动，共享目录 `/tmp/xdisplay29-rdp-results` 在 .29 上是 `\\tsclient\results`；客户已交付的 0.1.3 包在 `C:\Temp\XdisplayAI_20261108_full\`（场景二基线）。详细驱动规则见记忆文件 `dot29-test-machine`。

## 2. 只更新客户端时要改什么

客户端是**钉死的缓存发布树**（不在 builder 上重新编译）。

1. 把新的发布树放到 builder：`T:\source-e2e27dd8\windows-packaging\inputs\client\xdisplay-win64\`（整棵树：`Xdisplay.exe`、Qt dll、`data/keyboard_a..e`、`images/`、`res/`、`doc/`、`Simulator.exe`…）。必备文件清单在 `ci/CachedRelease.ps1 Get-RequiredCachedClientReleaseRelativePaths`（`ci/validate.ps1` 有同一份），缺一个构建就停。
2. 算新 `Xdisplay.exe`（以及若变了的 `Converter.exe`）的 SHA256 与字节数，改 **四处**：
   - `ci/CachedRelease.ps1`：`Get-PinnedCatalogwriteClientSha256` / `Get-PinnedCatalogwriteClientBytes`（Converter 同理）；
   - `build-offline-package.ps1` 的默认参数 `-ExpectedClientSha256` / `-ExpectedConverterSha256`；
   - `tests/Test-S63fPackagingContract.ps1`、`tests/Test-CachedReleasePackaging.ps1` 里引用的常量（跑单测会告诉你哪一行）。
   - `manifests/pins/offline-inputs.s63f.json` / `offline-inputs.0.1.4.json` 若记录了客户端 SHA 也要同步。
3. 如果官方资源（键盘模板、图片）变了而 `Xdisplay.exe` 没变：升级时工作目录是否同步由**种子指纹**决定，指纹覆盖 `Xdisplay.exe` + 五个 `keypage.json` + `logo_tricolor.png`（`InstallerCorrectness.ps1 Get-WorkspaceFingerprintRelativePaths`）。改了别的资源文件又希望升级覆盖到客户机，就把它加进这个列表并补单测。
4. **第三方运行时**（与 exe 同目录、不在客户端仓里）：`Simulator.exe`、ffmpeg 五个 DLL（`avcodec-62/avformat-62/avutil-60/swresample-6/swscale-9`）、`ffmpeg.exe`、`optipng.exe` 取自官方 `Xdisplay_2.4.4_20261027` 包，SHA256/字节数钉在 `ci/CachedRelease.ps1 Get-PinnedThirdPartyRuntimeFiles`，资格检查时逐个核对；换官方包版本就改这张表。构建期还有"导入闭包"门：`Xdisplay.exe` / `Simulator.exe` / `Converter.exe` 导入的每个非系统 DLL 都必须在树里（r10/r11 漏 ffmpeg 的教训）。
5. 版本号不变时（0.1.4 内多次 rN）无需动 `manifests/bundle.json`；要升到 0.1.5 时改 `bundle.json` 并检查 `tests/Test-InstallerCorrectness.ps1` 末尾对版本的断言。

## 2a. 分层固定：什么锁死、什么跟着线走（2026-11-11 起的打包策略）

严格线与自由线同时推进，变的是后端和客户端 AI 侧；核心 Xdisplay 6001 功能与莫工 Word 16 项的修法不能动。打包按层处理：

| 层 | 内容 | 钉在哪 | 变更方式 |
|---|---|---|---|
| 冻结：官方运行时资源 | `data/`、`res/`、`images/`、`doc/`、根目录三张图（client/c-184） | `manifests/pins/word-fix-guard.json` `resourceFiles`（287 个文件 SHA256）；资格检查 `Assert-FrozenClientResources` 逐字节核对，差一个字节构建失败 | 只能由架构师裁决后 `ops/host/word-fix-guard.py --write` 重生成并在提交信息写明 |
| 冻结：第三方运行时 | Simulator.exe、ffmpeg 五 DLL、ffmpeg.exe、optipng.exe、Qt 运行时布局 | `ci/CachedRelease.ps1 Get-PinnedThirdPartyRuntimeFiles` + 导入闭包门 | 换官方包版本时改钉表 |
| 守卫：Word 修法源码 | PR #1（client/c-185）改过的 21 个 `src/` 文件 | `word-fix-guard.json` `sourceFiles`；控制端 `ops/host/word-fix-guard.py --check <客户端提交>` 做祖先检查 + 文件哈希 + "Word 修法新增行是否还在" | 允许改（AI 侧功能会碰 `widget_main.cpp` 等），但 `--check` 一报 DRIFT 就必须在 .29 重走对应 Word 项，并把结论写进验收记录 |
| 跟线：客户端二进制 | `Xdisplay.exe`（含 AI 侧） | 构建提交号 + SHA 钉（`Get-PinnedCatalogwriteClientSha256`） | 从合并线重编；编前先 `--check` |
| 跟线：后端 | s63f 镜像与源码快照 | `manifests/pins/offline-inputs.s63f.json` + 镜像三标签 | 父流程导出后整体换钉 |
| 冻结：安装器 | `src/scripts/**`、WiX、ci | 本仓提交 + 单测 + .29 两场景 | 只修缺陷 |

打包前的固定动作：`python3 ops/host/word-fix-guard.py --check <要打的客户端提交>`。2026-11-11 对 `int-6001` 顶端 `9e59c066` 的结果：资源 287/287 未动；21 个守卫源码文件里 9 个有改动，其中 7 个 Word 修法新增行全部保留，`src/Helper/dialog_tool_image.cpp`（18/19）与 `src/Helper/image_library_mutation_v1.cpp`（21/25）各缺了几行 c-182/c-183 的修法——打这个提交前必须在 .29 重走 Word 第 8 项（图库），或由合并的 agent 说明这些行是等价重写。

## 3. 只更新后端时要改什么

后端走 **"已有镜像 + 源码快照 bind-mount"** 模式（`-UseExistingBackendInputs`），不在 builder 上构建镜像。

1. 父流程（`backend-export/<tag>/rebuild-orches-app-image.sh`，需要有 Docker 的机器）产出：四个镜像 tar（`orches_orchestration-app_latest.tar`、`orches_embedding-http_latest.tar`、`pgvector_pgvector_pg15.tar`、`redis_7.tar`）、源码快照（含 `SOURCE_REVISION.txt`、`app/main.py`、`external/xdisplay/bin/xd_render_cli/*`、`Dockerfile`、`pyproject.toml`、`.dockerignore`）、`compose/upstream/docker-compose.yml`、`migrations/*.sql`。放到 builder 的 `inputs\backend\{images,source,compose\upstream,migrations}`。
2. **app 镜像必须带三个标签**，否则 `ci/CachedRelease.ps1` 会在构建时拒绝、安装器在客户机上会永远判"不是本包"：
   - `xdisplayai.packaging.git-sha` = 快照修订（前缀与 `Get-ApprovedBackendRevisionPrefix` 一致）；
   - `xdisplayai.packaging.tag` = `Get-ApprovedBackendTag`（当前 `prod/s63f`）；
   - `xdisplayai.packaging.runtime-fingerprint` = `ci/Common.ps1 Get-SourceContentFingerprint` 对 `Get-OrchestrationAppRuntimeFingerprintPaths`（8 个文件）的值。安装器端用 `Get-PathContentFingerprint -IncludeInputRows` 算同一个值（r11 修的 `bf74d56d`/`d203e24`，单测 `Test-InstallerCorrectness.ps1` 把两者钉在一起，别拆）。
   - 伴随 tag：`orches/orchestration-app:s63f-<rev>` 与 `:latest`（`ci/Common.ps1 Get-S63fAppImageCompanionTags`）。
3. 修订变了就改：`manifests/pins/offline-inputs.s63f.json`（`requiredRevisionPrefix/Full`、`requiredTag`、`sourceArchiveSha256`、`forbiddenAppImageSha256` 指向上一版 app 镜像）；`src/scripts/common/InstallerCorrectness.ps1` 的 `Get-ApprovedBackendRevisionPrefix` / `Get-ApprovedBackendTag`；`ci/Common.ps1` 的伴随 tag；`.29` 场景脚本里 `LocalBackend` 门校验的 git-sha / 指纹常量（模板 `dot29/templates/Upgrade.ps1.tmpl` 与 `Fresh.ps1.tmpl` 内搜 `dd6ab3d5`、`5f1b3896`）。
4. prompt 钉：`XDISPLAY_AI_PROMPT_VERSIONS` 的 31 个代理钉与五个作者钉由 `src/scripts/update/PromptPinMigration.ps1` 的注册表生成（`tests/Test-PromptPinMigration.ps1`、`Test-GeneratedPromptRegistry.ps1`），后端改了 prompt 版本时改那里，升级会自动补种、删退役键。
5. 迁移 SQL 只能追加（`0004_*.sql`…），安装器按 `offline_migration_history` 跳过已执行的。

## 4. 把改动送到 builder 并构建

```bash
# 本机：提交后记下 HEAD；builder 树当前等于的提交写在 T:\logs\<上一个run>-state.json 的 sourceCommit
cd ~/Documents/tricolor_work/xdisplay_ai/windows-packaging
git log --oneline -1
scp -r ops root@172.19.103.18:/dev/shm/xdai-ops          # 第一次或 ops/ 变了才需要

# 宿主机：把相对上一个 builder 提交的改动摆成 overlay 并起 HTTP（18049）
ssh root@172.19.103.18
cd /path/to/windows-packaging-checkout && ops/host/stage-overlay.sh r12 <builder-tree-commit>   # 或在本机跑后 scp /dev/shm/xdai-overlay/r12
(cd /dev/shm/xdai-overlay && setsid nohup python3 -m http.server 18049 --bind 172.19.103.18 >/dev/null 2>&1 </dev/null &)
cp /dev/shm/xdai-ops/builder/*.ps1 /dev/shm/xdai-overlay/   # 让 builder 能下载到 ops 脚本

# builder（通过 qga）：下载 ops 脚本到 T:\logs，先 overlay+单测，再启动构建（两条都是 detached）
cat > /dev/shm/kick-r12.ps1 <<'PS'
$b='http://172.19.103.18:18049'
foreach($n in 'Sync-SourceOverlay.ps1','Invoke-NativeBuild.ps1','Get-BuildPhase.ps1','Invoke-DeltaUpload.ps1','Invoke-VerifyPass.ps1','Upload-DistMeta.ps1'){ Invoke-WebRequest -UseBasicParsing "$b/$n" -OutFile "T:\logs\$n" }
Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File T:\logs\Sync-SourceOverlay.ps1 -Run r12 -BaseUrl $b/r12"
Start-Sleep 15
# 注意：-ArgumentList 用一整个字符串；分成数组元素时 Start-Process 不会给含空格的 -Reason 加引号，脚本会在参数绑定阶段失败且不留状态文件
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File T:\logs\Invoke-NativeBuild.ps1 -Run r12 -SourceCommit <40 hex> -Reason "client c-186"'
PS
python3 /dev/shm/xdai-ops/host/qga.py win11-wsl2-builder /dev/shm/kick-r12.ps1
# 轮询（每 4 分钟）：
#   python3 qga.py win11-wsl2-builder <(echo '& T:\logs\Get-BuildPhase.ps1 -Run r12')  → PHASE NATIVE_EXIT0_ACCEPTANCE_PENDING 即成功（status 仍是 built_not_ready，正常）
```

`Invoke-NativeBuild.ps1` 会等 `T:\logs\r12-unit-tests.log` 出现 `EXIT 0` 再开始；单测失败就停在 `STOPPED_SEE_ERROR`，错误在 `r12-state.json`。想核对 overlay 真落盘，可传 `-RequiredFileHashes @{'ci/validate.ps1'='<SHA256>'}`。

## 5. 传回宿主机

```bash
# 宿主机：接收端（上一个 run 的目录做硬链接种子，省掉未变文件）
mkdir -p /dev/shm/xdai-pkg-r12 && cp -al /dev/shm/xdai-pkg-r11/. /dev/shm/xdai-pkg-r12/
nohup setsid python3 -I /dev/shm/xdai-ops/host/recv.py 27120 /dev/shm/xdai-pkg-r12 >/dev/shm/recv-r12.log 2>&1 </dev/null &
# builder：增量上传（与上一个 run 相同的文件不传）
python3 qga.py win11-wsl2-builder <(echo '& T:\logs\Invoke-DeltaUpload.ps1 -Run r12 -PreviousRun r11 -ReceiverUrl http://172.19.103.18:27120/')
#   进度：T:\logs\upload-r12-progress.txt 最后一行 DONE
python3 -I /dev/shm/xdai-ops/host/verify-dist.py /dev/shm/xdai-pkg-r12     # BAD_COUNT 0，EXTRA 为空（有陈旧多余文件就删）
sha256sum /dev/shm/xdai-pkg-r12/XDisplayAI-0.1.4-dev.exe                    # 记下 bundle SHA
(cd /dev/shm/xdai-pkg-r12 && setsid nohup python3 -m http.server 18055 --bind 172.19.103.18 >/dev/null 2>&1 </dev/null &)   # 给 .29 下载
```

## 6. .29 验收（两场景 + 二次启动）

```bash
# 宿主机：渲染本 run 的脚本（UTF-8 BOM 自动加）
python3 /dev/shm/xdai-ops/host/render-run.py --run r12 --bundle-sha <sha> --http-port 18055 --packaging-commit <commit8>
cp /dev/shm/xdai-ops/dot29/{Wipe-29.ps1,Reboot-29.ps1,Launch-Client-29.ps1} /tmp/xdisplay29-rdp-results/xdai/   # 第一次
H=/dev/shm/xdai-ops/host
$H/restart-rdp29.sh                                   # 需要时重连 RDP（密码在 /tmp/rdp29-now.pass，别打印）
$H/run29.sh  'xdai\Stage-R12-29.ps1'                  # 下载 + 逐文件校验 → stage-r12.json: STAGED_VERIFIED
$H/launch-elev.sh 'xdai\Upgrade-R12-29.ps1' up12      # 场景二：卸当前 → 清容器/待删除项 → 装 0.1.3 → 升级 → 19 门 → upgrade-r12-DONE.txt = DONE SCENARIO2_UPGRADE_PASS
$H/launch-elev.sh 'xdai\Steady-R12-29.ps1' st12       # 二次启动：steady-r12.json seconds 应为个位数且含"且为本包 s63f 镜像与 prompt 合同"
cp .../steady-r12.json .../steady-r12-after-upgrade.json
$H/launch-elev.sh 'xdai\Wipe-29.ps1' wipe12           # 全清 → wipe-DONE.txt = DONE WIPE_CLEAN
$H/launch-elev.sh 'xdai\Fresh-R12-29.ps1' fr12        # 场景一 → fresh-r12-DONE.txt = DONE SCENARIO1_FRESH_PASS（17 门）
$H/launch-elev.sh 'xdai\Steady-R12-29.ps1' st12b      # 再测一次二次启动
```

规则（血泪）：发任何 Win+R 命令前**客户端不能处于最大化前台**（会把命令打进编辑器、客户端崩、桌面会话跟着崩）；`launch-elev.sh` 自己点 UAC；升级如果真的要求重启（exit 3010 或 `bootUnchanged` 为假），用 `reboot-chain.sh r12` 走重启→登录→`PostResume-R12-29.ps1`。0.1.3 基线的两个脾气已经由 `Upgrade` 模板处理（先移除项目容器、清掉 `%TEMP%\*.tmp` 待删除项），不要再手工重启 .29。

Word 16 项与提测卡只在客户端二进制变化时需要重走；流程见 `acceptance/2026-11-10-dot29/README.md`。

## 7. 证据 → 放行 → 交付

```bash
# 宿主机
python3 -I /tmp/xdai-s63f/make-evidence-r12.py          # 读 upgrade/fresh/steady 的 state → windows-pass-dot29.json（三项都 pass 才有意义）
mkdir -p /dev/shm/xdai-overlay/r12 && cp /tmp/xdisplay29-rdp-results/xdai/windows-pass-dot29.json /dev/shm/xdai-overlay/r12/
# builder：放行门（约 5–8 分钟，重算整棵交付树的哈希 + Burn 绑定）
python3 qga.py win11-wsl2-builder <(echo '& T:\logs\Invoke-VerifyPass.ps1 -Run r12 -EvidenceUrl http://172.19.103.18:18049/r12/windows-pass-dot29.json')
#   看 T:\logs\r12-verify-pass.stdout.log 末尾 "Build succeeded" + "EXIT 0"；dist 里 NOT_READY.txt 消失、release-status.json status=pass
python3 qga.py win11-wsl2-builder <(echo '& T:\logs\Upload-DistMeta.ps1 -Run r12 -ReceiverUrl http://172.19.103.18:27120/')
rm -f /dev/shm/xdai-pkg-r12/NOT_READY.txt && python3 -I /dev/shm/xdai-ops/host/verify-dist.py /dev/shm/xdai-pkg-r12
# 只交付清单里的文件 + 四个 json（硬链接出一个干净目录再 rsync），本机再校验一次
```

```bash
# 本机
rsync -a -e ssh root@172.19.103.18:/dev/shm/xdai-deliver-r12/ ~/Downloads/XDisplayAI-0.1.4-dev-s63f-r12/
python3 -I ops/host/verify-dist.py ~/Downloads/XDisplayAI-0.1.4-dev-s63f-r12
```

交付目录应为 20 个文件：bundle `XDisplayAI-0.1.4-dev.exe`、MSI、`xdp1..8`（含 2a/2b）十个 cab、三个前置（Docker Desktop / VC / WSL）、`artifacts-dev.json`、`release-status.json`（pass）、`cached-release-pins.json`、`input-pins.json`、`.wixpdb`。

## 8. 已知坑（每条都踩过）

- **builder TEMP**：`Invoke-NativeBuild.ps1` 把 TEMP 指到 `T:\work\ops-temp-<run>`，构建期间不要删 `T:\work\ops-temp-*`；症状是 8 个 `wixnative.exe` 各 14% CPU、零读写、无 cab，原因是 WiX `CabCGetTempFile` 失败无限重试。重建目录即可原地恢复。
- builder VM 时钟比时区慢 8 小时：`release-status.json`、清单里的 UTC 时间戳偏早，不影响校验。
- `qga.py` 单次等待 180 s，长任务一律 `Start-Process -WindowStyle Hidden` 放后台再轮询状态文件；偶尔会读到别的进程输出，脚本里加 MARK 行。
- 用 qga 跑的 `-Command` 脚本自身包含 "Run-Native/build-offline-package" 字样时会被进程扫描匹配到，Invoke-NativeBuild 的守卫用的是更窄的 `-File ...build-offline-package.ps1` 模式。
- .29：共享目录里的 `.ps1` 必须带 UTF-8 BOM（渲染器已处理）；`-ExecutionPolicy Bypass`；别 `Get-ChildItem C:\ProgramData\XDisplayAI -Recurse`。
- 0.1.3 老包：任何 `PendingFileRenameOperations` 都会让它回滚；栈还活着就走健康即跳过不铺自己的镜像；它的"启用远程桌面"步骤在桌面会话崩过之后可能挂住。
- 升级后 Docker Desktop 仪表盘会弹到前台（安装器启动它时未最小化），不影响流程。
- 密钥：包是 keyless 的；测试用的百炼 key 只通过 `POST /api/v1/assistant/provider-key`（baseUrl 必须显式给 dashscope 地址）注入 .29 的运行卷，全清即消失，绝不能写进仓库、包、日志。

## 9. 目录说明

```
ops/
  README.md                 本文
  builder/                  在 builder 上用 -File 运行（ASCII，无中文）
    Invoke-NativeBuild.ps1  一次构建：守卫 + 等单测 + TEMP + 启动 build-offline-package.ps1 + <run>-state.json
    Sync-SourceOverlay.ps1  从宿主机 HTTP 拉改动文件（manifest.json 校验 SHA）+ 跑单测 → <run>-unit-tests.log
    Get-BuildPhase.ps1      读 <run>-state.json 打印 PHASE
    Invoke-DeltaUpload.ps1  dist 增量上传到 recv.py（进度 upload-<run>-progress.txt）
    Invoke-VerifyPass.ps1   用 .29 证据跑 -VerifyExistingOutputsOnly 放行
    Upload-DistMeta.ps1     放行后回传刷新的小文件
  host/                     宿主机 172.19.103.18 上用
    qga.py recv.py verify-dist.py render-run.py stage-overlay.sh run29.sh launch-elev.sh restart-rdp29.sh reboot-chain.sh
  dot29/
    templates/*.tmpl        Stage/Upgrade/Fresh/PostResume/Steady 场景脚本 + make-evidence.py 的模板（__RUN__/__BUNDLE_SHA__/__HTTP_PORT__/__PACKAGING_COMMIT__）
    Wipe-29.ps1 Reboot-29.ps1 Launch-Client-29.ps1 Probe-Resume-29.ps1   与 run 无关的 .29 脚本
```
