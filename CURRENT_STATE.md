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
| P0 | 微调链路失败 | 后端 + 前端 + 协议 | 需要核实 draftId/previewId 生命周期、Qt 状态写入、后端响应字段 |
| P0 | draftId 丢失或读取不一致 | 前端为主，后端配合 | 曾定位到 preview_ready 等路径写入/读取不一致，需要任务书修复 |
| P0 | P3/V0 文档与实际代码可能不同步 | 总指挥项目 | 需要把 P3 轻量任务卡拉回 Superpowers spec/plan 双轨 |
| P1 | Undo/Redo 与 AI 微调语义 | 前后端协议 | 需要明确 AI tweak 是否可撤销、如何不误撤用户手工编辑 |
| P1 | 组件联动能力验证 | 前端 + 后端生成能力 | Qt 客户端已有绑定变量能力基础，后端是否能稳定生成 AI_LinkagePlan 需验证 |
| P1 | 服务器部署与本地代码差异 | 运维/总指挥 | 服务器日志和 GitHub 代码可能不完全一致，需要 Warp/Augment 在现场核实 |

## 6. 当前风险

1. AI 工具上下文不足，容易基于过期结论继续执行。
2. 后端、前端、协议文档三者可能不同步。
3. 服务器部署内容可能包含 GitHub 未体现的变更。
4. 微调失败可能不是单点 bug，而是状态机、协议字段、异步时序共同导致。
5. 任务书如果没有明确 DoD，Cursor/Windsurf 可能各修各的，最后仍联调失败。

## 7. 下一步建议

### Step 1：现场核实

在 `ai_orchestration`、`xdisplay`、`xdisplay_ai` 三个仓库分别执行：

```bash
git status --short
git rev-parse --short HEAD
git log -1 --oneline
```

### Step 2：复现微调失败

使用当前标准运行方式启动后端和客户端，复现一次微调失败，收集：

- 后端请求日志
- WebSocket 消息
- Qt 客户端日志
- draftId / previewId / conversationId
- 前端收到的完整 JSON 响应
- 用户操作序列

### Step 3：更新任务卡

复现后把问题拆为：

- `T-BE-*`：交给 Cursor 的后端任务
- `T-QT-*`：交给 Windsurf 的前端任务
- `T-CMD-*`：交给 Warp/Augment 的总指挥诊断任务
- `T-DOC-*`：总指挥项目文档同步任务

## 8. 最近一次行动记录

### 2026-05-31

- 创建 `PROJECT_BRIEF.md`、`CURRENT_STATE.md`、`RUNBOOK.md` 三个总指挥上下文文件。
- 目标：降低 Warp AI 上下文不足导致的漂移，让每次新会话都从稳定、短小、可更新的项目事实开始。

## 9. 待补充

以下内容需要从实际仓库或服务器补充：

- 当前三个仓库最新 commit hash。
- 后端服务实际部署路径、Docker compose 文件名、容器名。
- Qt 客户端构建命令、运行命令、日志路径。
- 当前标准测试命令。
- 当前已知 failing tests。
- 当前微调失败的最新日志样本。
