# CURRENT_STATE.md

> 用途：记录 `xdisplay_ai` 总指挥项目的当前真实状态。每次联调、修复、PR 合并后必须更新本文件。

## 1. 当前日期

- 当前记录日期：2026-06-10
- 记录人：项目总指挥 / AI 协作流程
- 状态可信度：基于本次会话实际执行结果，已在服务器验证

## 2. 当前阶段

项目处于 `ai_orchestration` 后端与 `xdisplay` Qt/QML 客户端的 P3/V0 集成测试阶段。

当前核心问题不是“从零开发”，而是联调稳定性、协议一致性、微调链路可靠性、撤销/重做语义、测试闭环与文档同步。

## 3. 已知仓库状态

| 仓库 | 已知状态 | 备注 |
|---|---|---|
| `ai_orchestration` | M1-M8 已完成，包含 production store、PGVector、Agentic RAG 等能力 | 远端部署上可能存在 GitHub 不可见的 Agentic RAG 实现或配置，需要从服务器/ Cursor 指令核实 |
| `xdisplay` | Qt 6/QML-first 客户端，P3/V0 多个 BE/QT 修复任务已合并 | 当前重点是 PanelAI、微调、预览、draftId、undo/redo、组件联动 |
| `xdisplay_ai` | 总指挥项目 | 保存项目状态、任务书、运行手册、联调记录与 AI 协作约束 |

近期已知主线状态：`ai_orchestration` main HEAD 曾记录为 `25791185`，`xdisplay` main HEAD 曾记录为 `6966793b`。执行任何任务前必须重新运行 `git rev-parse --short HEAD` 核实。

## 4. 已完成事项

- `ai_orchestration` 已完成 M1-M8 里程碑。
- 已有 FastAPI 后端、LLM provider、PGVector、Agentic RAG、OpenRouter 图像生成兼容处理等基础能力。
- `xdisplay` 已进入 Qt 侧 P3/V0 联调阶段。
- BE/QT 多个修复任务已合并，包括 T-BE-01~04、T-BE-FIX-01~04、T-QT-01、T-QT-03、T-QT-04、T-QT-FIX-01~03。
- `xdisplay` 的 PanelAI UX refactor 已围绕 WebSocket、画布右键"AI 改成"、底部输入框、按钮合并、预览卡片合并等方向推进。
- 项目已采用 Superpowers 方法论，后端和前端仓库均有 `docs/superpowers/{plans,specs}` 相关文档。

### 2026-06-01 新增完成

| 任务ID | 内容 | 状态 |
|---|---|---|
| T-QT-FIX-04 | Qt 请求超时从 300s 升至 900s（`service_ai_transport.cpp`） | ✅ 已在代码中确认 |
| T-BE-FIX-05 | 服务器模型从 `qwen3-next-80b-a3b-thinking` 换为 `qwen/qwen3-32b`，`MAX_TOKENS_THINKING=8192`（`.env`） | ✅ 已在服务器确认 |
| T-QT-05 bug | `widget_main.cpp:3245` eventType 修复：`"stage_changed"` → `"stage.changed"` | ✅ 已修复 |
| T-BE-06 | 新建 `app/ws/pipeline_ctx.py`（ContextVar 进度推送器）；`main.py` 注入 `set_pipeline_stage_emitter`；`openai_compatible_agent.py` 推送 `intent_extract`/`drafter`/`image_gen`；`autofix.py` 推送每轮 `autofix_round_N` | ✅ 语法验证通过，容器已重启 |

### 2026-06-06 新增完成

| 任务ID | 内容 | 状态 |
|---|---|---|
| T-BE-LOGIN-FREE-01 | 自由生成登录页语义合约：label/title 匹配可见文本组件，input/button 匹配对应能力；非模板路径加入语义校验 | ✅ 本地测试通过，远端已部署 |
| T-BE-AUTOFIX-GATE-01 | AutoFix 视觉审核低分/拒绝时设置 `canApply=false`，并在 `apply_preview` 服务端二次拦截 | ✅ 本地测试通过，远端已部署 |
| T-BE-LOGIN-ICON-TWEAK-01 | 登录按钮“改成图标”微调：登录/账号/密码候选映射到内置 `ms_lock.png`；显式 tweak 走确定性 fast path，普通登录页生成不自动加图标 | ✅ 本地测试通过，远端已部署 |

## 5. 当前关注问题

| 优先级 | 问题 | 归属 | 当前判断 |
|---|---|---|---|
| P0 | **微调链路稳定性** | 后端 + 前端 | ✅ 网络恢复后 turn_000006 成功（78s）。主要风险：超长请求（HVAC 14组件 336s）仍会超时，已通过 T-QT-FIX-04 缓解 |
| P0 | **撤销按钮消失** | 前端（Qt draft session） | ✅ 代码已修复，已编译验证，代码已提交（`xdisplay` HEAD `666cbec`） |
| P0 | **缩略图背景与画布不一致** | 前端 + 后端 | ⚠️ 部分修复。后端 `pageTheme.page_bg_color` 已输出（`"#1E3A5F80"`），前端链路已通。tweak 场景仍需端到端验证 |
| P1 | **Qt 进度 UI 未收到 stage 事件** | 前端 + 后端 | ✅ T-BE-06 + T-QT-05 已实现，**待人工测试验证**：发起生成时 PanelAI 卡片是否显示"理解需求中…"/"AI 生成布局中…"等文案 |
| P1 | `AUTOFIX_EMPTY_PAGE` fixer 产出空页 | 后端 | 偶发，已知问题，fixer fallback 到 drafter 结果，不阻断流程 |
| P1 | 服务器代码与 GitHub 严重不同步 | 运维 | 服务器含大量未推送改动，回滚风险高，需在下一个稳定点同步 |
| P1 | P3/V0 文档与实际代码可能不同步 | 总指挥项目 | 需要把 P3 轻量任务卡拉回 Superpowers spec/plan 双轨 |
| P1 | 自由生成登录页质量闸门 | 后端 | ✅ 已修复基础链路：坏语义不再通过，视觉审核低分/拒绝不再允许应用；仍需继续改善表单布局美观度 |

## 6. 当前风险

1. AI 工具上下文不足，容易基于过期结论继续执行。
2. 后端、前端、协议文档三者可能不同步。
3. 服务器部署内容可能包含 GitHub 未体现的变更。
4. 微调失败可能不是单点 bug，而是状态机、协议字段、异步时序共同导致。
5. 任务书如果没有明确 DoD，Cursor/Windsurf 可能各修各的，最后仍联调失败。

## 7. 下一步建议

### Step 1（立即）：重新编译 Qt 并人工测试进度 UI

```bash
# 重新编译 xdisplay（包含 widget_main.cpp 修复）
# 连接到 172.19.103.21 WebSocket 后发起草稿生成
# 观察 PanelAI 卡片文案是否按阶段切换
```

验收点：
- 发送请求后卡片显示"理解需求中…"
- LLM 开始生成时切换到"AI 生成布局中…"
- 有背景图时出现"生成背景图中…"
- autofix 时出现"自动优化中（第1轮）…"

### Step 2：验证 page_bg_color 缩略图一致性

测试场景：生成含深色背景的页面 → 检查缩略图背景色是否与画布一致。

### Step 3：同步服务器代码到 GitHub

服务器含大量未推送改动（包含本次 T-BE-06），需要推送到 GitHub，消除不同步风险。

## 8. 最近一次行动记录

### 2026-06-06（本次会话）

- **根因确认**：`生成一个登录页面` 在禁用模板自由生成时，LLM 能识别 `login_page`，视觉审核也能给出低分/拒绝；真正缺口是自由生成缺少通用语义合约，且 AutoFix 失败/低分后仍允许 `canApply=true`。
- **后端修复**：新增 `app/page_dsl/semantic_contract.py`；`openai_compatible_agent.py` 在 DSL/组件计划阶段校验语义角色与组件能力；`dsl_to_ir.py` 对 label/title 误用输入组件做通用归一化；`service.py` 和 `shadow_store.py` 增加质量闸门与 `apply_preview` 二次拦截。
- **测试结果**：聚焦与邻近回归共 58 个通过；新增覆盖语义合约和 AutoFix 低分预览不可应用。
- **远端部署**：已通过 `rsync + docker restart ai_orches_app` 部署到 `root@192.168.64.2:/mnt/ai_orchestration`，未重建镜像。
- **远端验证**：真实请求 `生成一个登录页面`、`recipePolicy=disabled` 返回 `preview_ready`，6 个组件：`page_title/statictext`、`username_label/statictext`、`username_input/wordtext`、`password_label/statictext`、`password_input/wordtext`、`login_button/setbutton`；随后 `apply_preview` 返回 `page_draft_ready/completed`。
- **残余风险**：本次真实请求中 `drafter_feedback` 90s 超时降级，AutoFix 第二轮 regression 后回退到 78 分版本；语义正确性已改善，但登录页视觉布局仍需后续优化。
- **登录按钮图标微调修复**：用户选择 `login_button_5_setbutton` 并输入“登录按钮改成图标”后，旧链路落到 LLM 并生成 `it_map_*_text_context=""` + `it_map_*_text_id="power"` 的不可落地伪图标字段，导致按钮图标和文字同时为空。后端新增登录图标候选和显式 tweak fast path，输出 `login_button_icon/image` + `src="ms_lock.png"`，同时保留普通“生成登录页”不自动增加图标。已同步 `app/service.py` 到 `root@192.168.64.2:/mnt/ai_orchestration` 并重启 `ai_orches_app`。

### 2026-06-08（登录页上传 logo/背景图生成失败修复）

- **问题现象**：Qt 发起“生成登录页面，使用上传 logo 和全屏背景图”请求后，后端返回 `clarification_needed / needs_clarification`，没有返回 `pageDraft` 或 `preview`。
- **日志证据**：远端 `root@172.19.103.21:/mnt/ai_orches_log/app.log` 中请求 `req_02c6afb2-b11e-4933-bc25-ae976117b9b6`，session `chat_session_652bfffe-c219-4954-b33c-960cf85f7007`。Qt 已正确上传 2 个资源：`logo.png` 为 `usage_kind=logo`，背景图为 `usage_kind=full_background`；两个文件均已落盘到 `/mnt/ai_orches_data/xdisplay_images/`。
- **根因**：昨天引入 staged drafter 后，多阶段 LLM 输出中出现带空白/大小写漂移的 `componentType`，例如 `" rectangle"`。后端没有在模型/assembler/IR 编译入口统一归一化，导致最终 `_validate_page_draft` whitelist 校验失败：`componentType ' rectangle' is not in the allowed whitelist`。
- **修复**：在 `ai_orchestration` 中对 `PageDSLV1.RegionComponentV1.componentType`、`staged_drafter.ComponentSpec.componentType` 增加 strip+lower 归一化；在 staged assembler 直接使用 cleaned type，避免 `" Image "` 影响 logo/background 资源绑定；在 `page_dsl_to_ir` 和 semantic contract 入口加兜底清洗。
- **验证通过**：
  - `pytest -q tests/unit/test_semantic_contract.py tests/component/test_staged_drafter.py tests/component/test_staged_drafter_agent_integration.py`
  - `pytest -q tests/unit/test_page_compiler.py tests/unit/test_pipeline_stages_order.py tests/integration/test_multi_asset_upload.py`
  - `git diff --check`
- **部署**：仅同步运行时相关 5 个后端文件到 `root@172.19.103.21:/mnt/ai_orchestration` 并重启 `ai_orches_app`。容器内最小验证输出：`rectangle setbutton image`，确认新代码已加载。
- **待人工联调**：重新在 Qt 发起同样“登录页 + logo + 全屏背景图”请求，预期不再因 `componentType` 前导空格进入校验澄清。

### 2026-06-05（A2 多资源上传与微调基础审查修复）

- **审查范围**：复核 `ai_orchestration` 后端 A2B1/B2 与 `xdisplay` Qt A2Q0/Q1/Q2/Q3 相关实现，重点关注聊天附件资源、用途选择、澄清问答、prompt 版本、微调入口的一致性。
- **后端修复**：`page_draft -> clarification -> clarification_answer` 链路现在会保存并恢复 `available_assets` 与 `_prompt_version_override`，避免 Qt 在澄清成功后清空本地附件导致后端二次起草丢失资源上下文。
- **后端修复**：prompt 版本判断改为语义化版本比较，避免 `v2.10` 被字符串比较误判为小于 `v2.2`。
- **后端修复**：`chat_upload_max_decoded_bytes` 配置已接入附件持久化流程，避免配置项声明后不生效。
- **Qt 修复**：附件用途必填不再只依赖 QML 主按钮禁用；C++ 发送入口与继续微调入口都会先校验 `usage_kind`，阻止 Enter、继续修改、右键微调等路径绕过。
- **验证通过**：
  - `ai_orchestration`: `pytest -q tests/unit/test_chat_uploaded_assets_protocol.py tests/unit/test_chat_upload_assets.py tests/unit/test_available_assets_prompt.py`
  - `ai_orchestration`: `pytest -q --integration tests/integration/test_multi_asset_upload.py`
  - `xdisplay`: `make -C src -j2 widget_main.o service_ai_request.o service_ai_transport.o Part_Main_widget_panelai_qml.cpp Part_Main_widget_panelai_asset_tray_qml.cpp`
  - `xdisplay`: `qmlcachegen` 校验 `widget_panelai.qml` 与 `widget_panelai_asset_tray.qml`
  - 两仓库 `git diff --check` 均通过
- **待人工联调**：重新编译/运行 Qt 客户端后，验证上传资源选择用途、生成页面、澄清问答、应用后微调四条路径；重点观察后端日志是否持续包含 `available_assets`，以及微调中人工调整内容是否仍被保留。
- **部署与编译**：已将 `/Users/molc/Documents/tricolor_work/ai_orchestration` 通过 rsync 同步到 `root@172.19.103.21:/mnt/ai_orchestration`，并重启 `ai_orches_app`；远端 18001 端口由新 `uvicorn` 进程监听。已在本机执行 `make -C src -j4` 编译 `/Users/molc/Documents/tricolor_work/xdisplay`，产物为 `bin/Xdisplay.app/Contents/MacOS/Xdisplay`（2026-06-05 18:03）。

### 2026-06-01（本次会话）

- **微调超时根因确认**：Qt 客户端硬超时 300s，服务器模型 `qwen3-next-80b-a3b-thinking` 实际耗时 336~635s，必然超时。WebSocket 因心跳存活，但 Qt `QTimer::singleShot` 先行 abort，服务端处理完后无法投递响应。
- **日志路径说明**：日志确认打入 `/mnt/ai_orches_log/app.log`（容器挂载 `/mnt/ai_orches_log → /data/logs`），早期只有 64 行是因容器刚重启，不是路径问题。
- **T-QT-FIX-04**：确认 `service_ai_transport.cpp` 已是 900000ms，无需修改。
- **T-BE-FIX-05**：确认服务器 `.env` 已是 `qwen/qwen3-32b` + `MAX_TOKENS_THINKING=8192`，无需修改。
- **T-QT-05 bug 修复**：`widget_main.cpp:3245` `"stage_changed"` → `"stage.changed"`（dot 与 underscore 不匹配，stage 事件永远不会被 Qt 处理）。
- **T-BE-06 实现**：新建 `app/ws/pipeline_ctx.py`（asyncio ContextVar 推送器）；`main.py` 在 `create_task` 前注入推送函数；`openai_compatible_agent.py` 在 `intent_extract`/`drafter_dsl`/`image_gen` 三处推送；`autofix.py` 每轮推送 `autofix_round_{N}`。语法验证通过，容器已重启正常。
- **待人工测试**：重新编译 Qt（含 widget_main.cpp fix）后，验证 PanelAI 进度文案是否随阶段切换。

### 2026-05-31

- 创建 `PROJECT_BRIEF.md`、`CURRENT_STATE.md`、`RUNBOOK.md` 三个总指挥上下文文件。
- 目标：降低 Warp AI 上下文不足导致的漂移，让每次新会话都从稳定、短小、可更新的项目事实开始。

### 2026-05-31 晚间（本次会话）

- **诊断问题**：微调应用后撤销按钮消失 + 预览缩略图背景与画布不一致。
- **Issue 1 根因定位**：undo guard 取页面 ID 路径与 tweak apply 不一致 → `project.currentPageRuntimeId=-1` 导致 `no_active_page` 拒绝。Windsurf 已修复（未提交）。
- **Issue 1 验证**：用户运行新编译二进制，日志确认 `[UNDO-GUARD] allowed=true`、`[UNDO-VISIBLE] visible=true`，撤销按钮恢复正常。
- **Issue 2 根因定位**：前端 `pageBgColor` 链路已通，但后端 tweak 响应 `pageTheme=null`（背景用 image 组件实现），缩略图只能显示 image 占位色 `#F59E0B`。需后端配合在 `pageTheme.page_bg_color` 写入图片主色调。
- **后端日志**：从 `192.168.64.2:/mnt/ai_orches_log/app.log` 提取。tweak 链路 turn_000011 成功，7 组件，drift_ratio=0.167，pageTheme=null。

## 9. 已核实事实

| 项目 | 核实结果 |
|---|---|
| `xdisplay` HEAD | `666cbec`，未提交修改存在于工作区 |
| `ai_orchestration` HEAD | 需重新运行 `git rev-parse --short HEAD` |
| 后端部署地址 | `ws://192.168.64.2:18001`，运行正常（FastAPI + WebSocket） |
| 后端日志路径 | `root@192.168.64.2:/mnt/ai_orches_log/app.log` |
| Qt 客户端日志路径 | `/Users/molc/Documents/workspace/xdisplay/bin/Xdisplay.app/Contents/MacOS/log/app.log` |
| 未提交修改文件 | `service_ai_draft_session.cpp`（T-QT-BUG-01）、`CompAiResultCard.qml`（pageBgColor）、`widget_main.cpp`（pageBgColor 桥接） |
| undo guard 修复状态 | ✅ 代码修复 + 新二进制编译 + 用户验证通过 |
| 缩略图背景修复状态 | ⚠️ 前端链路通，需后端补充 `pageTheme.page_bg_color` |
