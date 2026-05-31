# PROJECT_BRIEF.md

> 用途：给 Warp AI / Augment / Cursor / Windsurf 等 AI 工具的“项目总指挥上下文”。每次新会话先读取本文件，再读取 `CURRENT_STATE.md` 和 `RUNBOOK.md`。

## 1. 项目定位

`xdisplay_ai` 是 xdisplay AI 集成体系的“总指挥项目”，不是单一业务模块仓库。它的职责是统一管理 `ai_orchestration` 后端与 `xdisplay` Qt/QML 客户端的联调、任务分派、问题诊断、验收标准与项目状态。

核心目标：让 AI 工具以“受控工程团队”的方式协作，而不是各自根据零散上下文自由发挥。

## 2. 关联项目

| 仓库 | 角色 | 主要职责 | 默认执行工具 |
|---|---|---|---|
| `github.com/molc/xdisplay_ai` | 总指挥项目 | 统一项目状态、任务书、运行手册、联调记录、验收清单 | Warp AI / Augment |
| `github.com/molc/ai_orchestration` | 后端服务 | FastAPI、LLM provider、Agentic RAG、PGVector、WebSocket/API、页面/组件生成 | Cursor |
| `github.com/molc/xdisplay` | Qt 客户端 | Qt 6 / QML、PanelAI、画布交互、预览、微调、组件联动 | Windsurf |

## 3. 当前产品目标

构建一套 AI + Qt 的低代码页面生成系统：用户在 xdisplay 客户端中通过自然语言描述页面或组件变更，后端 `ai_orchestration` 生成结构化计划、DSL/组件方案、预览与微调结果，客户端负责展示、应用、撤销/重做与交互闭环。

当前重点不是扩展新功能，而是稳定 P3/V0 联调质量，特别是后端协议、Qt 状态机、draftId/previewId、微调链路、撤销/重做语义和测试闭环。

## 4. 工具分工

| 工具 | 定位 | 做什么 | 不做什么 |
|---|---|---|---|
| Warp AI | 现场总指挥 | 读 `PROJECT_BRIEF/CURRENT_STATE/RUNBOOK`、跑命令、看日志、复现问题、分派任务、生成诊断结论 | 不长期记忆所有架构细节，不直接大范围重构生产代码 |
| Augment AI | 代码库总工程师 | 大代码库理解、跨文件修改、重构、补测试、生成 PR 级实现 | 不绕过人工验收，不直接操作生产环境 |
| Cursor | 后端执行者 | 修复 `ai_orchestration` 服务端、API、WebSocket、RAG、provider、存储与测试 | 不修改 Qt/QML 客户端 |
| Windsurf | 前端执行者 | 修复 `xdisplay` Qt/QML、PanelAI、画布、预览、交互与本地状态 | 不修改后端服务 |
| Perplexity/架构评审 | 外部架构参谋 | 需求澄清、架构判断、任务拆解、风险识别、任务书/PR Review | 不直接读取内网日志或服务器状态 |

## 5. 权威文档

以下文档是 P3/V0 阶段的优先参考来源，任务执行前必须优先查阅：

- `xdisplay_v0_arch_design.md`
- `v0_audit_findings.md`
- `cursor_task_v0_remediation.md`
- `cursor_task_v0_remediation_followup.md`
- `windsurf_task_v0_remediation.md`
- `windsurf_task_v0_remediation_followup.md`
- `v0_tweak_protocol_diagnosis.md`
- 两个仓库中的 `docs/superpowers/{specs,plans}`
- 两个仓库中的 `.cursor/rules`、`.windsurf/rules`、`.agents/skills`、`.warp/rules` 等 AI 约束文件

如果代码事实与旧文档冲突，以“当前代码 + 当前协议 + 当前测试失败证据”为准，并把文档偏差登记到 `CURRENT_STATE.md`。

## 6. 工作原则

1. 先读文档，再读代码，最后改代码。
2. 先复现问题，再定位根因，不允许凭猜测直接修。
3. 每个问题必须明确归属：后端、前端、协议、配置、环境、测试数据或部署。
4. 修复必须有最小验证命令，优先补自动化测试。
5. 任务必须拆成可交给 Cursor/Windsurf/Augment 的执行卡。
6. 总指挥项目只保存状态、任务、诊断、Runbook，不把它变成混杂代码仓库。
7. 大改动必须先生成计划，列出影响文件、风险、回滚方式和 DoD。

## 7. Definition of Done

一次联调修复只有同时满足以下条件才算完成：

- 已明确根因，不只是绕过症状。
- 后端与前端协议字段一致。
- 关键状态字段如 `draftId`、`previewId`、`conversationId`、`componentPlan` 的生命周期清楚。
- 本地或服务器环境通过最小验证命令。
- 相关日志没有新的 ERROR/WARN 异常。
- 有测试或手工验收记录。
- `CURRENT_STATE.md` 已更新状态、提交号、风险与下一步。

## 8. 给 AI 的默认指令

每次新会话开始时，先执行：

```text
你是 xdisplay_ai 项目的现场总指挥。
请先阅读 PROJECT_BRIEF.md、CURRENT_STATE.md、RUNBOOK.md。
不要假设历史上下文。
每次行动前先复述：当前目标、已知事实、待验证假设、下一步命令。
默认只读诊断，除非我明确说“允许修改”。
遇到超过 200 行日志，只提取关键错误栈、时间点、服务名、请求 ID、关联 draftId/previewId。
```
