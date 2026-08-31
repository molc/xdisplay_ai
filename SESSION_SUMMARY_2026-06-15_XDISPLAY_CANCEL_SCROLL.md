# 2026-06-15 会话摘要：xdisplay 生成取消、服务端 operation 取消与输入框滚动修复

> 用途：记录本轮围绕 `xdisplay` 客户端 AI 面板的改动、验证证据、风险边界和后续人工测试要点。本文只记录已经执行或从代码/日志/命令确认的事实，不把未做的 GUI 人工测试写成结论。

## 1. 结论

本轮主要修复 `xdisplay` 客户端两个用户可见问题：

1. 生成/修复过程中用户无法取消，只能退出 app 才能发起下一次请求。
2. AI 输入框长文本没有滚动条，无法滚动查看下方文字。

已经在独立 `xdisplay` 仓库完成代码修改并 rebuild 实际 app 二进制：

- 仓库：`/Users/molc/Documents/tricolor_work/xdisplay`
- 实际二进制：`/Users/molc/Documents/tricolor_work/xdisplay/bin/Xdisplay.app/Contents/MacOS/Xdisplay`
- binary mtime：`Jun 15 16:55:23 2026`

重要使用要求：已经打开的旧 app 进程不会热加载新二进制，必须退出当前 app 后重新打开。

## 2. 问题根因

### 2.1 为什么“取消生成”没有出现

截图里的状态是：

- `HTTP · 发送中`
- 结果卡显示 `自动优化中（第1轮）...`

这说明客户端处于 `requestInFlight=true`，请求还在 HTTP 等待阶段，并不是已经收到后端 `operation_accepted/operation_status` 后进入 `serverOwnedOperationRunning`。

上一轮只覆盖了“服务端已接管并返回 operationId 后”的取消路径：

- `POST /api/v1/assistant/operations/{operation_id}/cancel`

但没有覆盖“HTTP 请求仍在发送中”的取消路径。因此按钮条件只看 `serverOwnedOperationRunning` 时，在用户截图这个状态下不会出现。

### 2.2 为什么输入框不能滚动

底部用户输入框原来是普通 `TextArea`，没有包在 `ScrollView` 中，也没有强制显示垂直滚动条。长提示词超出可视区域后，只能看到上半段。

之前修过的详情页滚动条和全文弹窗滚动条，不等于底部输入框也已经修复。这里是单独漏点。

## 3. 本轮代码改动

### 3.1 发送中 HTTP 请求取消

涉及文件：

- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_transport.h`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_transport.cpp`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_main.h`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_main.cpp`

新增能力：

- `Service_AI_Transport::func_cancel_active_request(...)`
- `Widget_Main::func_ai_panel_cancel_generation()`
- 保存当前 `QNetworkReply` 为 `m_active_reply`
- 用户取消时调用 `QNetworkReply::abort()`
- 取消结果归一为 `user_canceled_request`
- 导出状态：
  - `activeRequestCancelAllowed`
  - `activeRequestCancelMarker`
  - `cancelGenerationAllowed`
  - `cancelGenerationSummary`

设计边界：

- 发送中取消用于解除客户端当前 HTTP 锁定。
- 如果请求已经被后端受理并返回 `operationId`，则进入 operation cancel 路径。
- 客户端 abort 不等价于保证后端立刻停止执行；后端是否停止取决于服务端是否监听断连或 cancellation token。

### 3.2 服务端 operation 取消

涉及文件：

- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_transport.h`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_transport.cpp`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_draft_operation_state.h`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Service_AI/service_ai_draft_session.cpp`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_main.cpp`

新增/完善能力：

- `Service_AI_Transport::func_cancel_operation(operationId, ...)`
- 调用后端契约：
  - `POST /api/v1/assistant/operations/{operation_id}/cancel`
- `Service_AI_DraftOperationState::shouldAllowOperationCancel(...)`
- `Service_AI_DraftSession` 导出：
  - `serverOwnedOperationId`
  - `operationCancelAllowed`
  - `operationCancelSummary`
  - `operationCancelMarker`

远端接口确认：

- 对 fake operation 执行 curl 返回业务 404：
  - `operationId ... not found`
- 这说明路由存在，不是 endpoint 不存在。

### 3.3 “取消生成”按钮显示位置

涉及文件：

- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/CompAiResultCard.qml`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_panelai.qml`

改动：

- 在结果卡顶部进度行显示“取消生成”按钮。
- 进度行覆盖两类状态：
  - `requestInFlight=true`
  - `serverOwnedOperationRunning=true`
- 结果卡底部操作区也保留“取消生成”按钮作为兜底。
- QML 统一调用：
  - `func_cancel_generation_action()`
  - 该函数转发到 C++ 的 `func_ai_panel_cancel_generation()`

这次不是把主“生成草稿”按钮改成取消按钮，而是保持：

- 主按钮仍表达“发送新请求”
- 取消按钮表达“中断当前生成/修复”

这样避免请求语义混乱。

### 3.4 输入框滚动条

涉及文件：

- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_panelai.qml`
- `/Users/molc/Documents/tricolor_work/xdisplay/src/Part_Main/widget_main.cpp`

改动：

- 底部输入框由普通 `TextArea` 改为：
  - `Rectangle` frame
  - `ScrollView`
  - `TextArea`
- 垂直滚动条策略：
  - `ScrollBar.vertical.policy: ScrollBar.AlwaysOn`
- 横向滚动关闭：
  - `ScrollBar.horizontal.policy: ScrollBar.AlwaysOff`
- 保留：
  - 自动预览刷新
  - Enter 发送
  - Shift+Enter 换行
  - 文本选择
  - 字数显示

新增 binary marker：

- `AI_INPUT_SCROLLVIEW_ALWAYS_ON_V1`

## 4. 测试与验证

### 4.1 单元/集成测试

测试命令：

```bash
cd /Users/molc/Documents/tricolor_work/xdisplay/tests/integration
./test_draft_state_machine_v2
```

结果：

- `15 passed`
- `0 failed`
- `0 skipped`

新增覆盖：

- `test_active_generation_request_allows_user_cancel`
- 断言：
  - `requestInFlight=true` 且请求类型为 `page_draft` 时允许取消。
  - `requestInFlight=true` 且请求类型为 `tweak_page` 时允许取消。
  - `requestInFlight=false` 时不允许取消。
  - 当前请求为 `cancel_operation` 时不允许重复取消。

### 4.2 rebuild

构建命令：

```bash
cd /Users/molc/Documents/tricolor_work/xdisplay/src
/Users/molc/Qt/5.15.2/clang_64/bin/qmake Xdisplay_V2.pro
make -j4
```

增量确认命令：

```bash
make -j4
```

结果：

- build 通过。
- 只看到既有 QML duplicate alias、SDK version、deprecated API warning。
- 最后一次增量 build 输出：`make: Nothing to be done for 'first'.`

### 4.3 binary marker

验证命令：

```bash
strings /Users/molc/Documents/tricolor_work/xdisplay/bin/Xdisplay.app/Contents/MacOS/Xdisplay \
  | rg "ACTIVE_GENERATION_REQUEST_CANCEL_V1|AI_INPUT_SCROLLVIEW_ALWAYS_ON_V1|func_ai_panel_cancel_generation|user_canceled_request|SERVER_OWNED_OPERATION_CANCEL_V1"
```

确认进入实际二进制的 marker：

- `SERVER_OWNED_OPERATION_CANCEL_V1`
- `user_canceled_request`
- `ACTIVE_GENERATION_REQUEST_CANCEL_V1`
- `AI_INPUT_SCROLLVIEW_ALWAYS_ON_V1`
- `func_ai_panel_cancel_generation`

### 4.4 diff check

命令：

```bash
git diff --check
```

结果：

- 无输出，表示未发现 whitespace error。

## 5. 当前 xdisplay 工作树状态

截至本摘要写入前，`/Users/molc/Documents/tricolor_work/xdisplay` 仍有未提交改动：

```text
 M src/Makefile
 M src/Part_Main/CompAiResultCard.qml
 M src/Part_Main/widget_main.cpp
 M src/Part_Main/widget_main.h
 M src/Part_Main/widget_panelai.qml
 M src/Service_AI/service_ai_draft_session.cpp
 M src/Service_AI/service_ai_draft_session.h
 M src/Service_AI/service_ai_transport.cpp
 M src/Service_AI/service_ai_transport.h
 M tests/integration/test_draft_state_machine_v2.cpp
?? src/Service_AI/service_ai_draft_error_state.h
?? src/Service_AI/service_ai_draft_operation_state.h
?? src/Service_AI/service_ai_draft_result_scope.h
```

说明：

- `src/Makefile` 是 qmake rebuild 产生/更新的构建文件。
- 三个 `service_ai_draft_*` 新头文件属于此前状态机/错误态/operation 状态抽取改动，不是本摘要新增的无关文件。
- 本轮没有提交 git commit。

## 6. 风险与边界

### 6.1 客户端取消与服务端停止不是同一个保证

客户端现在可以：

- 取消发送中的 HTTP 请求。
- 在收到 `operationId` 后调用后端 operation cancel endpoint。

但如果后端已经进入长时间 LLM/AutoFix loop，是否立即停止取决于后端实现。若后端没有在 loop 内检查 canceled 状态或 cancellation token，服务端可能继续跑一段时间。

这不是客户端可以单独彻底保证的事情。

### 6.2 还没有完成 GUI 人工验证

已完成：

- 代码路径验证。
- 状态机测试。
- rebuild。
- binary marker 验证。

未完成：

- 人工打开 app，实际发起生成请求，观察按钮、滚动条和取消行为。
- 取消后检查远端 `/mnt/ai_orches_log/app.log` 是否出现对应 cancel event。

因此不能写成“端到端 GUI 已验证”，只能写成“客户端改动已构建并具备人工测试条件”。

## 7. 人工测试步骤

1. 退出当前正在运行的 Xdisplay app。
2. 重新打开：
   - `/Users/molc/Documents/tricolor_work/xdisplay/bin/Xdisplay.app`
3. 连接服务地址：
   - `http://172.19.103.21:18001`
4. 输入一个长提示词，确认：
   - 输入框右侧出现垂直滚动条。
   - 可以滚动查看下方文本。
5. 发起生成页面请求，进入 `HTTP · 发送中` 或 `自动优化中...` 状态后确认：
   - 进度行右侧出现“取消生成”按钮。
6. 点击“取消生成”，观察：
   - 客户端不再被发送中状态锁死。
   - 可再次发起新的生成请求。
7. 如果后端已经返回 `operationId` 且进入服务端修复中，点击“取消生成”后检查远端日志：

```bash
ssh root@172.19.103.21 "grep -n 'operation.cancel' /mnt/ai_orches_log/app.log | tail -40"
```

期望看到：

- `operation.cancel.request.received`
- `operation.cancel.request.completed`

如果仍继续 AutoFix，需要转后端检查 cancellation token / loop stop 机制。

## 8. 给后续接手者的判断

这次修复不是硬编码某个页面、某个提示词或某类视觉结果，而是补齐客户端状态机中的两个真实缺口：

- `requestInFlight` 阶段的用户取消入口。
- AI 输入框自身的滚动容器。

如果后续仍出现“取消后服务端继续修”的问题，应优先进入 `ai_orchestration` 后端检查：

- operation cancel 是否只改存储状态。
- AutoFix loop 是否每轮读取 canceled 状态。
- LLM 调用是否支持超时/中断。
- WS/HTTP 断连是否能传播到 runtime task。

客户端侧下一步只需要根据人工测试结果微调按钮位置或文案，不应再引入与页面内容相关的硬编码规则。
