# CURRENT_STATE.md

> 用途：记录 `xdisplay_ai` 总指挥项目的当前真实状态。每次联调、修复、PR 合并后必须更新本文件。

## 1. 当前日期

- 当前记录日期：2026-05-31
- 记录人：项目总指挥 / AI 协作流程
- 状态可信度：基于近期项目记忆与用户确认，执行任务前仍需用 Git 和服务器日志再次核实

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
- `xdisplay` 的 PanelAI UX refactor 已围绕 WebSocket、画布右键“AI 改成”、底部输入框、按钮合并、预览卡片合并等方向推进。
- 项目已采用 Superpowers 方法论，后端和前端仓库均有 `docs/superpowers/{plans,specs}` 相关文档。

## 5. 当前关注问题

| 优先级 | 问题 | 归属 | 当前判断 |
|---|---|---|---|
| P0 | **微调链路失败** | 后端 + 前端 + 协议 | 根因：backend 返回 `responseType=page_draft_ready` 时 `draftId` 正常；turn_000011 实测成功，7 组件，drift_ratio=0.167 |
| P0 | **撤销按钮消失** | 前端（Qt draft session） | ✅ **已修复**。根因：`undo guard` 取页面 ID 路径与 `tweak apply` 不一致 → `project.currentPageRuntimeId=-1` 导致 `no_active_page` 拒绝。Windsurf 未提交代码修复：统一 `func_resolve_active_page_runtime_id()` 优先 `currentPage.runtimeId` fallback `project.currentPageRuntimeId`。日志验证：`[TWEAK-APPLY] done canUndo=true`、`[UNDO-GUARD] allowed=true`、`[UNDO-VISIBLE] visible=true`。待提交。 |
| P0 | **缩略图背景与画布不一致** | 前端 + 后端 | ⚠️ **部分修复**。`pageBgColor` 链路已通（C++桥接提取 `pageDraftSummary.pageBgColor` + QML Canvas `fillRect`）。但 tweak 场景后端返回 `pageTheme=null`（背景用 image 组件实现），缩略图仍显示橙色色块 `#F59E0B`（image 占位色），与画布真实背景图差异显著。 |
| P1 | draftId 丢失或读取不一致 | 前端为主，后端配合 | 曾定位到 preview_ready 等路径写入/读取不一致，需要任务书修复 |
| P1 | P3/V0 文档与实际代码可能不同步 | 总指挥项目 | 需要把 P3 轻量任务卡拉回 Superpowers spec/plan 双轨 |
| P1 | 组件联动能力验证 | 前端 + 后端生成能力 | Qt 客户端已有绑定变量能力基础，后端是否能稳定生成 AI_LinkagePlan 需验证 |
| P1 | 服务器部署与本地代码差异 | 运维/总指挥 | 服务器日志和 GitHub 代码可能不完全一致，需要 Warp/Augment 在现场核实 |
| P1 | 后端 drafter 补充 page_bg_color | 后端 | tweak 生成 image 背景时，在 `pageTheme.page_bg_color` 写入图片主色调，使缩略图可渲染近似背景色 |

## 6. 当前风险

1. AI 工具上下文不足，容易基于过期结论继续执行。
2. 后端、前端、协议文档三者可能不同步。
3. 服务器部署内容可能包含 GitHub 未体现的变更。
4. 微调失败可能不是单点 bug，而是状态机、协议字段、异步时序共同导致。
5. 任务书如果没有明确 DoD，Cursor/Windsurf 可能各修各的，最后仍联调失败。

## 7. 下一步建议

### Step 1：提交 Issue 1 修复代码

`xdisplay` 工作区存在未提交的 `T-QT-BUG-01` 修复（撤销按钮消失），需 Windsurf 提交：

```bash
cd ~/Documents/workspace/xdisplay
git diff --stat src/Service_AI/service_ai_draft_session.cpp src/Part_Main/CompAiResultCard.qml src/Part_Main/widget_main.cpp
```

### Step 2：推进 Issue 2 后端配合

Cursor 负责后端 drafter 修改：当 tweak 生成 image 背景组件时，在 `pageTheme.page_bg_color` 写入图片主色调（如提取 `#1a237e` 深蓝），使缩略图 QML Canvas 可渲染近似背景色。

### Step 3：验证提交后的端到端链路

重新编译 Qt 客户端 → 启动 → 生成草稿 → 应用 → 微调（image 背景）→ 应用 → 确认：
- 撤销按钮始终可见（`[UNDO-VISIBLE] visible=true`）
- 缩略图背景色与画布一致（需后端配合后验证）

## 8. 最近一次行动记录

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
