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

### Requirement: 冻结的跨轮token停止阈值
系统 MUST 将定义级可选已报告token阈值及内建只读Agent固定阈值纳入实际运行合同，按请求身份合并input+output累计，并在工具及后续模型派发前检查。它不是账单硬上限，不自动加额度或重试；原可测费用预算义务继续保留。

#### Scenario: 已达阈值或用量未确认
- **WHEN** 完整响应返回后总量达到阈值且仍需工具、超过阈值，或本轮缺报／不完整／身份冲突／回退／delta／溢出无法确认消耗
- **THEN** 运行暂停并保留输出和真实已知用量，后续工具及模型请求均为零；同轮可补齐partial不提前失败，恰好达线的最终答案可完成

#### Scenario: 准确下一轮输出额度
- **WHEN** Agent仍有已确认剩余额度并提交工具结果
- **THEN** Chat及Responses仅将下一次输出上限缩为冻结每请求上限与剩余量的较小值，历史／callID／phase／reasoning保持准确且先验证后修改

#### Scenario: 预算编辑及旧审批
- **WHEN** 运行中编辑profile预算、运行暂停／取消，或新尝试重新审阅
- **THEN** 旧运行继续使用原冻结阈值，旧审批不能派发已关闭run；新尝试核对当前定义／预算并创建新UUID和空累计器，不恢复旧队列

#### Scenario: schema4显式预算与回退
- **WHEN** 保存新配置或旧reader尝试安装／回退
- **THEN** schema4 Agent显式编码nullable阈值，旧1–3不接纳新字段且合法旧定义迁移为关闭阈值；缺失／非法新字段拒绝，签名reader门禁防止旧版重写丢弃预算

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

### Requirement: 独立服务互通与schema语义

系统 MUST 使用固定来源与完整依赖哈希的独立官方MCP服务验证生产adapter，原样保留服务端schema与协议；合法annotation和默认值不产生权限或偷偷填入参数，未知约束不得静默忽略。兼容修补不得改变原allowlist、逐次审批、来源revision、取消和输出预算。

#### Scenario: 官方工具目录
- **WHEN** 独立服务提供含title／default和省略additionalProperties的合法schema
- **THEN** 宿主按明确支持的JSON Schema语义接受并验证参数，保留原schema；未知约束拒绝并给出目录拒绝事实，零工具或只有握手不算互通成功

#### Scenario: 两版本两传输
- **WHEN** 使用owned环境的未修改官方服务进行stdio及loopback HTTP、2025-11-25及2026-07-28验收
- **THEN** 每格创建新连接，实际发现并调用工具，核对结构化结果和isError，断开后旧目录不可调用，并核对owned进程收口；无密钥且不访问个人数据

#### Scenario: 验收覆盖边界
- **WHEN** 时间服务的四格工具互通通过
- **THEN** 回执绑定KeyDock源、解释器、全部依赖及服务版本哈希，保留先前失败；未覆盖的真实resources／prompts、长耗时取消、其他服务和全产品验收继续开放

#### Scenario: 旧HTTP取消与会话生命周期
- **WHEN** 2025-11-25的已派发带ID请求被取消／超时、显式断开或重新发现
- **THEN** 宿主仅对仍在途的原请求发送一次取消通知，不取消initialize或notification；清理已知session时使用同endpoint／revision的原认证上下文发送DELETE并收口，迟到session仅能进入旧channel清理，失败保留未确认；2026-07-28仅关闭自身请求流
