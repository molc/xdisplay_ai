# 2026-06-10 会话摘要：AI Orchestration 质量门闭环与非模板生成问题

> 用途：在会话上下文过大后，给后续 Codex / Cursor / 人工继续排查和实现使用。本文只记录本轮会话中已经讨论、执行、验证或从日志确认的事实，不把未经验证的假设写成结论。

## 1. 结论

本轮会话的主线不是单个登录页样式问题，而是 `ai_orchestration` 的页面生成质量闭环问题：

- 服务端不能把未通过质量门、不可应用、或无法证明可交付的草稿直接交给 `xdisplay` 客户端。
- `clarification_needed` 只能用于用户意图不明确，不能用于低质量草稿、AutoFix 失败、视觉模型失败或协议不可应用。
- 成功交付必须是 `preview_ready/page_draft_ready` 且 `canApply=true`，失败必须是 machine-readable 的 `quality_failed` 或 `generation_failed`。
- 当前质量闭环已经开始收紧，但非模板自由生成主链路仍不完整，尤其是 P2 `IntentSpec/ConstraintSpec` 在部分页面类型上没有产生可执行约束，导致质量判断过度依赖视觉模型。

最新一次明确追踪的非模板失败请求是：

- requestId: `req_06d5133b-296b-4181-a2d0-013df59f3e2e`
- traceId: `trace_84880b1da7fd`
- sessionId: `chat_session_47f860b3-8645-47ee-a0e8-c40d917d2398`
- turnId: `turn_000003`
- 时间：中国时间 2026-06-10 17:24:47 至 17:27:33
- 请求类型：`page_draft`
- 路由：`non_template`
- 结果：`quality_failed / failed`

这次不是模板问题。之前处理模板登录页资产绑定，是我基于自己 smoke 暴露出的旁支问题做的修复，不是用户这几次非模板测试失败的根因。

## 2. 会话背景

用户最初要求读取当前项目文档，并了解 `ai_orchestration` 与 `xdisplay` 现况。随后指出一天联调中登录页、logo、全屏背景图、多步生成、视觉评分、微调链路都不稳定。

核心架构质疑包括：

- 为什么服务端经过多轮生成、审核和 AutoFix 后，还会把低评分或不可应用结果交给客户端。
- 评分低时是否应该由后端继续修复，只有意图不明确才让客户端提示澄清。
- 是否用上 RAG 领域知识库。
- P1 typed patch 与 P2 IntentSpec 两份专门设计文档是否应进入实现。
- 多步生成后是否破坏了原先可工作的微调链路。
- 后端质量门闭环到底有没有真正落地。

用户明确拒绝针对单个登录页或单个请求的硬编码，要求从架构全局解决。

## 3. 相关文档

本轮会话中反复引用或要求对齐的文档：

- `/Users/molc/Documents/tricolor_work/ai_orchestration/docs/quality_closed_loop_solution.md`
- `/Users/molc/Documents/tricolor_work/ai_orchestration/docs/superpowers/specs/2026-06-09-p1-typed-patch-design.md`
- `/Users/molc/Documents/tricolor_work/ai_orchestration/docs/superpowers/specs/2026-06-09-p2-intent-spec-design.md`

这些文档的共同目标是：阻断低质量结果绕过、建立结构化意图和约束、让 AutoFix 通过 typed patch 做可验证修复，并把 RAG/设计系统规则纳入 QualityReport 证据链。

## 4. 已形成的实施计划

用户最终指定的实施计划摘要如下：

1. Delivery Gate 收紧
   - `audit_error_*`、视觉模型 429/超时、AutoFix 无 round、缺少可验证 DSL、quality report 缺失时，不再静默返回原始草稿。
   - 失败响应必须带 `error.details.quality_report`、`terminated_reason`、`trace_id`。

2. P2 IntentSpec / ConstraintSpec 主链路
   - 打开 `intent_spec_enabled=true`、`deterministic_gate_constraint_driven=true`。
   - 扩展登录页字段、label/input 同行、按钮尺寸、背景全屏、logo 方位、上传资源绑定等启发式抽取和设计系统规则。
   - ConstraintSpec 贯穿 drafter、template gate、autofix、protocol、trace artifact。

3. P1 Typed Patch 收敛
   - typed patch 可以灰度，但不能在失败后直接退回完整 DSL 并放行。
   - PatchApplier apply 后必须执行 PageDSLV1 validate、semantic normalize、compile/Flex/validator，并生成可审计 diff。
   - patch reason/source 必须引用 deterministic issue code、visual issue id 或 constraint id。
   - 当前 DSL 不支持的 `set_region_anchor` 不应作为 fixer 可输出 op。

4. RAG 闭环
   - RAG 检索结果只能进入 typed `KnowledgeContext`，不能直接影响 DSL。
   - 支持 `layout_rule`、`quality_rule`、`component_capability`、`repair_rule` 的归一化。
   - QualityReport 填充 `rag_constraints_used`、`rag_rules_conflicted`、`rag_rules_missing`。

## 5. 已完成或已提交的变更事实

本轮会话中已经完成并提交过一次后端改动：

- 仓库：`/Users/molc/Documents/tricolor_work/ai_orchestration`
- commit: `34e6cf9 fix quality gate template asset closure`
- 主要涉及文件：
  - `app/service.py`
  - `app/services/autofix.py`
  - `tests/services/test_constraint_spec_integration.py`
  - `tests/unit/test_autofix_loop.py`
- 部署目标：
  - `root@172.19.103.21:/mnt/ai_orchestration`
  - 容器：`ai_orches_app`
  - 端口：`18001`
  - 日志：`/mnt/ai_orches_log/app.log`

该提交主要修复了模板登录页 + 上传 logo + full background 的资产绑定与模板质量门闭环问题。远端 smoke 通过：

- requestId: `req_codex_login_assets_fix2_1781083072`
- traceId: `trace_fd5f2d91709d`
- 响应：`preview_ready/completed`
- 质量：`quality pass=true`
- 可应用：`canApply=true`
- 组件：8 个
- 关键布局：`page_background` 覆盖 `1024x720`，`brand_logo` 位于左上角附近 `x=24 y=24`

重要边界：这次提交解决的是模板/资产闭环旁支，不是用户后来多次非模板自由生成失败的根因。

## 6. 当前最新非模板请求的日志事实

用户后来强调：最近几次测试都没有使用模板，要求跟踪当前请求。

远端日志确认：

- `agent.draft.route branch=non_template`
- `page_kind=settings`
- `ConstraintSpec` 构建结果为空：
  - `bbox_count=0`
  - `layout_count=0`
  - `resource_count=0`
  - `presence_count=0`
  - `component_type_count=0`
  - `relative_layout_count=0`
  - `rag_constraints_used=[]`

用户请求内容摘要：

> 生成一个系统管理设置页面，分辨率 1280x720，横屏，深灰专业设置风。顶部显示 System Settings；左侧分类导航 Language、Brightness、Network、Devices、Security、Theme；中间详情设置区；右侧系统状态摘要；底部管理员区域，点击后弹出密码验证，验证通过进入内嵌高级设置。

服务端生成情况：

- 解析后的 PageDSL：
  - `pageKind=system_settings`
  - 区域：6
  - 组件：15
  - 协议校验错误：0
- Flex/Validator：
  - 已布局 15
  - validator 修正 2 个 height clamp
- 渲染：
  - 非空截图

视觉审核第 0 轮：

- `score=75`
- `verdict=fixed`
- `deterministic_verdict=pass`
- `deterministic_blocking=0`
- `quality_pass=false`
- blocking issue:
  - `visual.wrong_semantic`
  - component: `status_text`
  - description: `System Status 文字位置与用户要求不符`
- advisory issue:
  - `visual.alignment`
  - component: `category_theme`

AutoFix 第 0 轮：

- fixer 模型：`qwen/qwen3-32b`
- 第一次 typed patch schema invalid：
  - 模型输出 `components_id`
  - schema 要求 `component_id`
- 重试后只输出并应用 1 个 patch：
  - op: `set_component_props`
  - rejected: 0

视觉审核第 1 轮：

- `score=75`
- `verdict=fixed`
- `quality_pass=false`
- blocking issues:
  - `visual.alignment`：`page_title` 标题未居中对齐
  - `visual.visual_empty_space`：底部区域空白过多
- advisory issue:
  - `visual.color_contrast`：`admin_area_button` 按钮文字对比度低

最终：

- `autofix.loop_exit reason=regression`
- `service.autofix.quality_gate_blocked`
- `responseType=quality_failed`
- `status=failed`
- HTTP 状态码：200
- 耗时约 165 秒

## 7. 当前根因判断

### 7.1 事实

这次服务端没有把不合格草稿作为 `preview_ready` 交给客户端，而是阻断为 `quality_failed`。这一点符合“不能把不可应用草稿交付客户端”的方向。

但是后端没有完成服务端自修复闭环，导致用户仍然只能看到失败信息，无法得到可应用结果。

### 7.2 推断

非模板主链路的核心问题是：`settings` 页面虽然被识别为 page kind，但 P2 `ConstraintSpec` 没有把用户要求转为可验证约束。

因此：

- deterministic gate 无法判断标题、三栏布局、底部管理员区、状态摘要是否符合用户要求。
- RAG/设计系统没有形成 evidence。
- 视觉模型的主观判断直接成为 blocking issue。
- AutoFix 没有足够结构化目标，只能根据视觉文本做局部 patch。

### 7.3 不能下结论的点

当前不能简单断言视觉模型“错了”或“没错”。可确认的是：视觉模型给出的 blocking issue 没有被 P2/ConstraintSpec 或 bbox 规则充分复核。

这意味着质量门当前缺少“视觉问题证据接地”的机制。

## 8. 风险与代价

1. `ConstraintSpec` 为空会让质量闭环失去主干
   - 只靠视觉模型会造成误判、漂移、不可复现。

2. 视觉模型结果被直接 blocking 风险高
   - 例如 `page_title 未居中`、`底部空白过多` 这类判断必须结合组件 bbox、页面区域和用户约束确认。

3. typed patch 容错和约束不足
   - `components_id` vs `component_id` 说明模型仍会输出轻微 schema 漂移。
   - 当前重试后只应用一个弱 patch，无法系统性修复布局。

4. RAG 闭环仍未在该请求生效
   - 日志中 `rag_constraints_used=[]`。
   - 这说明至少在 `settings/system_settings` 场景下，知识规则没有参与质量证据链。

5. 非模板自由生成更容易暴露架构缺口
   - 模板路径可以通过模板约束快速通过。
   - 非模板路径必须依赖 IntentSpec、ConstraintSpec、设计系统、deterministic gate 和 typed patch 全链路。

## 9. 推荐下一步

下一步应聚焦非模板主链路，不再以模板路径现象解释用户当前失败。

建议按以下顺序处理：

1. 补齐 `settings/system_settings` 的 P2 约束生成
   - 标题存在与顶部布局。
   - 左侧分类导航 presence 和相对位置。
   - 中间详情区 presence 和组件类型。
   - 右侧状态摘要 presence 和组件类型。
   - 底部管理员区 presence、button type 和位置。
   - 页面分辨率、深灰专业设置风作为 theme/layout constraints。

2. 让视觉 blocking issue 接地
   - blocking visual issue 必须关联至少一种结构化证据：
     - `constraint_id`
     - deterministic issue code
     - bbox/layout violation
     - component role/presence violation
   - 不能证实的视觉主观问题应先 advisory，或者进入“需要二次审核/二次修复”而不是直接决定交付失败。

3. 修 typed patch schema 收敛
   - 对常见字段别名做协议层归一化时要有日志记录，不能静默吞掉。
   - patch reason/source 必须引用 issue code 或 constraint id。
   - apply 后必须再次 validate、compile/Flex、validator、QualityReport。

4. 强化 AutoFix 失败闭环
   - 失败时返回的 `quality_failed` 需要包含可读、可追踪的 blocking constraints。
   - 不能只给客户端“质量检查未通过”，否则用户不知道是后端无法修、视觉模型不可用、还是约束冲突。

5. 补 RAG/KnowledgeContext 证据
   - 对 `settings` 页面加入可归一化的 `layout_rule`、`quality_rule`、`component_capability`、`repair_rule`。
   - QualityReport 中必须能看到 `rag_constraints_used` 或明确 `rag_rules_missing`。

## 10. 验证方式

### 10.1 同请求复测

复用系统管理设置页请求，预期日志：

- `branch=non_template`
- `ConstraintSpec` 不再全 0
- `presence_count/layout_count/component_type_count/relative_layout_count` 至少有实际约束
- `rag_constraints_used` 或 `rag_rules_missing` 有明确记录
- visual issue 被约束系统复核
- typed patch 不再出现 schema invalid 或者 schema normalization 有明确记录
- 成功时返回 `preview_ready/completed` 且 `canApply=true`
- 失败时返回 `quality_failed`，并带明确 blocking constraints 和 trace artifact

### 10.2 登录页资源回归

保持已通过的模板登录页 + logo + full background smoke：

- 背景图全屏覆盖。
- logo 位于左上角合适位置。
- 成功响应可应用。
- 不允许因视觉模型不可用而静默返回未审核草稿。

### 10.3 微调回归

针对用户已反馈的微调问题单独验证：

- “字体变黑”必须映射为可执行 patch。
- “居中显示”必须映射为 bbox/layout/align 约束。
- tweak 成功响应必须保留可继续微调的 draft/result 链接。
- 不允许返回旧草稿预览或不可继续作为当前预览的结果。

## 11. 已知环境与路径

后端：

- 本地仓库：`/Users/molc/Documents/tricolor_work/ai_orchestration`
- 远端部署：`root@172.19.103.21:/mnt/ai_orchestration`
- 远端日志：`/mnt/ai_orches_log/app.log`
- 容器：`ai_orches_app`
- 服务端口：`18001`

前端：

- standalone 仓库：`/Users/molc/Documents/tricolor_work/xdisplay`
- 不要直接修改：`/Users/molc/Documents/tricolor_work/ai_orchestration/external/xdisplay`

总指挥/状态仓库：

- 当前文档仓库：`/Users/molc/Documents/tricolor_work/xdisplay_ai`

## 12. 给下一位执行者的注意事项

1. 先查最新请求，不要用旧模板请求解释用户的新非模板问题。
2. 修改 `ai_orchestration` 后必须部署到 `172.19.103.21`、重启 `ai_orches_app`、跑行为 smoke、查远端日志，再提交。
3. 不能只跑本地单元测试就声称完成。
4. 不要编辑 `ai_orchestration/external/xdisplay` 子模块。
5. 对用户的问题必须区分事实、推断、假设和建议。
6. 当前最重要的未闭环点是：非模板 P2 ConstraintSpec 为空，以及视觉问题缺少结构化证据接地。
