## ADDED Requirements

### Requirement: Agent 定义与运行分离
系统 SHALL 分离可复用 AgentDefinition 与单次 AgentRun，并保留模型/工具/策略版本。

#### Scenario: 运行中工具更新
- **WHEN** 外部工具目录变化但已有 run 正在执行
- **THEN** 系统继续使用已冻结范围或暂停重新评估，不自动扩大 run 权限

#### Scenario: 工作区定义保存失败
- **WHEN** 用户在Agent或工作流工作区保存，验证失败或文件写入前后抛错
- **THEN** 发起页面显示明确失败，保留全部编辑字段、输入和版本；沿用配置补偿恢复旧文件或原无文件状态，不显示成功

#### Scenario: 保存版本与未保存编辑
- **WHEN** Agent或工作流定义成功保存，或用户随后修改、导航离开再返回
- **THEN** 当前会话同步真实持久化版本并显示已保存状态；后续修改显示未保存，不把先前成功或规范等价但不同UTF8的文本当作当前草稿已保存

### Requirement: 有界工具回路
系统 MUST 让所有工具调用经 Broker，并支持步数、时间、token/可测费用预算及取消。

#### Scenario: 达到调用预算
- **WHEN** Agent 达到允许的最大工具调用数
- **THEN** 系统暂停或结束并给出原因，不继续循环等待模型自行停止

#### Scenario: 等待授权时取消
- **WHEN** 用户取消等待授权的 run
- **THEN** run 标记 cancelled，后续迟到的授权或模型结果不派发工具

### Requirement: 副作用回执与恢复
P2 系统 MUST 记录有副作用调用的 intent/result，重启后的 unknown outcome 不自动重放。

#### Scenario: 写入期间崩溃
- **WHEN** run 重启时存在 intent 但无完成回执
- **THEN** 系统标记 interrupted/结果未定并要求核对，不能静默再次写入

### Requirement: 第三方协议边界
P3 系统 SHALL 区分 MCP 工具适配与 ACP 外部 Agent 适配，不将进程隔离描述为 OS 权限沙箱。

#### Scenario: 导入 MCP server
- **WHEN** 用户启用外部 MCP server
- **THEN** 系统展示来源与实际进程权限边界，远端 annotations 不提升本机权限

### Requirement: Frozen effectful Agent tools

The Agent runtime MUST freeze the selected command and MCP tool scopes, validate arguments before dispatch, obtain invocation-bound approval for effects, persist intent first and retain unknown outcomes without replay.

#### Scenario: Cancelled approval arrives late

- **WHEN** a user cancels while a tool awaits approval and a late approval arrives
- **THEN** no intent or tool dispatch occurs, and the closed run cannot accept another call.

#### Scenario: Tool completed but receipt failed

- **WHEN** a tool may have effects and result persistence fails after dispatch
- **THEN** the parent run preserves an unknown outcome and cannot silently retry the tool.

### Requirement: Explicit external sources

The host MUST keep MCP source transport, protocol version, catalog revision and tool selection independent from model instructions and must recheck invalidation after asynchronous connection cleanup.

#### Scenario: Source revoked during cleanup

- **WHEN** a source is disabled while an older connection is closing
- **THEN** a late discovery result cannot reinstall its client or tools, and a cancelled stdio launch cannot start another process.

#### Scenario: Resource preview

- **WHEN** the user selects a listed resource or prompt
- **THEN** bounded text enters the selected preview as data and is not sent to AI automatically.
