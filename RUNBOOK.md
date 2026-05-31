# RUNBOOK.md

> 用途：给 Warp AI / Augment / 人类开发者的现场操作手册。默认先读，不要凭历史记忆执行危险命令。

## 1. 默认安全规则

1. 默认只读诊断，不修改代码、不重启生产服务、不清空数据。
2. 需要修改代码时，先说明要改哪些文件、为什么改、如何回滚。
3. 需要执行破坏性命令时，必须先请求人工确认。
4. 不要把完整密钥、token、数据库密码贴到 AI 对话中。
5. 日志超过 200 行时，只提取关键错误、时间点、服务名、请求 ID、draftId、previewId、conversationId。
6. 每次行动结束必须输出：已执行命令、关键发现、下一步建议、风险。

## 2. 推荐目录结构

建议在同一工作区放置三个仓库：

```text
~/workspace/
  xdisplay_ai/          # 总指挥项目
  ai_orchestration/     # FastAPI 后端
  xdisplay/             # Qt/QML 客户端
```

如果实际路径不同，请先更新本节。

## 3. 快速巡检命令

### 3.1 三仓库状态

```bash
cd ~/workspace/xdisplay_ai && pwd && git status --short && git rev-parse --short HEAD && git log -1 --oneline
cd ~/workspace/ai_orchestration && pwd && git status --short && git rev-parse --short HEAD && git log -1 --oneline
cd ~/workspace/xdisplay && pwd && git status --short && git rev-parse --short HEAD && git log -1 --oneline
```

### 3.2 查找关键文档

```bash
cd ~/workspace/xdisplay
find docs -iname '*v0*' -o -iname '*p3*' -o -iname '*tweak*' -o -iname '*superpowers*'

cd ~/workspace/ai_orchestration
find docs -iname '*v0*' -o -iname '*p3*' -o -iname '*tweak*' -o -iname '*superpowers*'
```

### 3.3 查找 draftId / previewId 相关代码

```bash
cd ~/workspace/xdisplay
rg -n "draftId|previewId|conversationId|componentPlan|preview_ready|tweak|undo|redo" .

cd ~/workspace/ai_orchestration
rg -n "draftId|previewId|conversationId|componentPlan|preview_ready|tweak|undo|redo" .
```

## 4. 后端诊断

> 以下命令需根据实际项目文件名调整。执行前先 `ls` 查看。

### 4.1 查看后端项目结构

```bash
cd ~/workspace/ai_orchestration
ls
find . -maxdepth 3 -type f \( -name 'pyproject.toml' -o -name 'requirements.txt' -o -name 'docker-compose*.yml' -o -name 'Dockerfile' -o -name '.env*' \)
```

### 4.2 本地运行测试

```bash
cd ~/workspace/ai_orchestration
pytest -q
```

如项目使用 Docker：

```bash
cd ~/workspace/ai_orchestration
docker compose ps
docker compose logs --tail=200
```

### 4.3 健康检查

先确认端口和 API base URL，再执行：

```bash
curl -sS http://127.0.0.1:8000/health || true
curl -sS http://127.0.0.1:8000/docs | head || true
```

## 5. Qt 客户端诊断

### 5.1 查看项目结构

```bash
cd ~/workspace/xdisplay
ls
find . -maxdepth 3 -type f \( -name 'CMakeLists.txt' -o -name '*.pro' -o -name '*.qml' -o -name '*.cpp' -o -name '*.h' \) | head -100
```

### 5.2 查找 PanelAI 相关代码

```bash
cd ~/workspace/xdisplay
rg -n "PanelAI|widget_panelai|WebSocket|AI 改成|componentPlan|preview_ready|draftId|tweak" .
```

### 5.3 构建/运行

构建命令以仓库 README 或现有脚本为准。若不确定，先执行：

```bash
cd ~/workspace/xdisplay
find . -maxdepth 3 -type f \( -name 'README*' -o -name 'build*.sh' -o -name 'run*.sh' -o -name 'CMakePresets.json' \)
```

## 6. 微调失败排查流程

### 6.1 必须收集的信息

每次排查微调失败，都必须收集：

- 用户操作：输入了什么、点击了什么、当前画布状态。
- 后端请求：HTTP/WebSocket 路由、请求体、响应体。
- 关键字段：`draftId`、`previewId`、`conversationId`、`componentPlan`。
- Qt 日志：收到什么事件、写入了什么状态、触发了什么 UI 更新。
- 服务端日志：生成阶段、存储阶段、返回阶段是否成功。

### 6.2 最小诊断顺序

1. 先确认后端是否返回了 `draftId`。
2. 再确认 Qt 是否在 `preview_ready` 或等价事件中保存了 `draftId`。
3. 再确认发起 tweak 时 Qt 是否带上同一个 `draftId`。
4. 再确认后端是否能根据 `draftId` 找到对应 draft/preview。
5. 最后确认 UI 是否应用 tweak 结果，以及 undo/redo 栈是否被正确更新。

### 6.3 给 Warp/Augment 的标准提示词

```text
你是 xdisplay_ai 项目的现场总指挥。
任务：诊断“AI 微调失败”。
请先只读，不要修改代码。

步骤：
1. 读取 PROJECT_BRIEF.md、CURRENT_STATE.md、RUNBOOK.md。
2. 在 ai_orchestration 和 xdisplay 中搜索 draftId、previewId、tweak、preview_ready。
3. 复述当前协议链路：生成预览 -> 保存 draftId -> 发起 tweak -> 返回 tweak result -> Qt 应用。
4. 找出字段名、状态写入、异步时序、日志证据中的不一致。
5. 输出根因假设，按证据强度排序。
6. 最后生成 Cursor 后端任务卡、Windsurf 前端任务卡、总指挥验证清单。
```

## 7. 任务卡模板

### 7.1 Cursor 后端任务卡

```markdown
# T-BE-XXX: <任务名>

## 背景
<问题背景和证据>

## 目标
<后端要达成什么>

## 约束
- 不修改 Qt 客户端代码
- 不破坏现有 API 兼容性，除非任务明确要求
- 必须补测试或给出最小验证命令

## 待检查文件
- <文件 1>
- <文件 2>

## 验收标准
- <可验证标准 1>
- <可验证标准 2>

## 回滚方式
<如何回滚>
```

### 7.2 Windsurf 前端任务卡

```markdown
# T-QT-XXX: <任务名>

## 背景
<问题背景和证据>

## 目标
<Qt/QML 要达成什么>

## 约束
- 不修改后端代码
- 不绕过协议字段
- 必须说明状态字段的生命周期

## 待检查文件
- <QML/CPP 文件>

## 验收标准
- <手工或自动验证步骤>

## 回滚方式
<如何回滚>
```

### 7.3 总指挥验证卡

```markdown
# T-CMD-XXX: <验证任务名>

## 验证目标
<要证明什么>

## 命令
```bash
<命令 1>
<命令 2>
```

## 通过标准
- <标准 1>
- <标准 2>

## 失败时下一步
<失败后如何分派>
```

## 8. 日志提取规范

不要直接贴全量日志，统一提取为：

```text
[time]
[service]
[request_id / conversationId / draftId / previewId]
[operation]
[error_summary]
[stack_trace_top_20_lines]
[related_payload_redacted]
```

## 9. 更新本 Runbook 的规则

发现以下情况必须更新 `RUNBOOK.md`：

- 实际服务端口变化。
- Docker compose 文件名变化。
- Qt 构建命令变化。
- 日志路径变化。
- 新增标准验证脚本。
- 新增 P0/P1 级排查流程。
