# 任务显式新尝试（任务33计划）

## ADDED Requirements

### Requirement: 冷启动只恢复可信记录，不恢复执行权

系统 MUST 从有界类型化manifest恢复只读任务，非终态显示interrupted／unknown。加载记录、打开任务或检查恢复能力 MUST NOT 发送网络、执行命令、恢复grant或重放副作用；旧格式缺少可信引用时只读。

#### Scenario: 派发后未持久终态即退出
- **WHEN** 重启读取只有intent而无可信结果的执行
- **THEN** 显示效果未知，不将其排入执行队列，也不宣称未执行或可撤销

### Requirement: 用户审阅后创建独立新尝试

系统 MUST 以稳定呈现及record revision准备新尝试。用户补齐输入并提交后重新验证当前定义／工具／权限／预算，以新任务、invocation及请求身份走生产入口，所需持久写入成功后才执行。新尝试 MUST 保留recoveryOf，MUST NOT 覆盖旧终态、费用、旧草稿或沿用旧目标与授权。

#### Scenario: 审阅期间配置或来源变化
- **WHEN** 定义编辑／删除／同ID重建、MCP禁用或session-disabled、清除／TTL使审阅依据过期
- **THEN** 旧确认不能派发；保留输入和说明，重新检查由用户主动发起

#### Scenario: 新尝试intent保存失败
- **WHEN** 最终提交未能可靠持久化新的执行依据
- **THEN** 没有外部效果，准备页保留字段；旧记录和当前配置不被改写

### Requirement: 恢复材料与交付动作显式分离

首切片 MUST 默认不保存正文，缺材料要求重新提供；不得从成功状态伪造下一步输入。恢复输出默认展示，复制／替换／工具执行均须新动作和新条件。后续内容保留及完整checkpoint续接仍须独立设计与验收。

#### Scenario: 旧记录含unknown工具或Terminal交接
- **WHEN** 用户准备新尝试
- **THEN** 说明可能重复已完成效果，要求检查；不自动重投未知操作，不复用旧窗口／选区或审批callback
