# Agent运行token停止阈值

承接原5.4有界工具回路及剩余工程。每请求输出上限继续使用已冻结模型设置，不增重复字段。本增量增加跨轮、按服务商已报告input+output累计的停止阈值；它不是账单硬上限，下一轮输入消耗在返回前未知，单次请求可能越线。不发额外token计数请求，不自动加额度或重试。

## 定义与冻结

AgentDefinition增加可选`maxRunTokens`，正整数范围1...1,000,000,000；nil明确关闭此阈值，旧定义缺省nil。新配置schema4中每个Agent必须显式提供该nullable字段，schema1–3夹带新字段拒绝。schema4继续要求schema3的应用动作迁移字段。签名reader升级read[1,2,3,4]／write[4]，旧reader不能丢弃阈值再保存。

未保存的Agent草稿也能运行，授权合同必须由实际传入定义、模型设置、阈值与策略版本计算，不能依赖可能不存在的savedRunReference。预算在本次运行冻结，编辑profile只影响后续运行。恢复定义指纹在启用阈值时使用新投影版本，关闭时保留旧v1／v2黄金身份。新尝试重新审阅当前预算，以新UUID和新累计器开始，不恢复会话、额度、旧审批或工具队列。

内建只读Agent使用明确的32,000已报告token阈值，继续固定工具／轮数／时间边界；每请求输出上限仍继承其模型场景设置。需要自定义运行阈值时使用Agent profile，不把只读模式变成任意工具模式。

## 用量与执行顺序

每run独占有界meter，复用AIUsageAccumulator。每轮必须有一个新attemptID的完整input／output；同轮partial可后续补齐、responseID可由nil补值，重复累计不重复扣额。缺报、跨轮重用旧attemptID、身份冲突、累计回退、delta、非法计数及求和溢出均使剩余额度不可确认，不能被后续普通快照洗掉。空accumulator不能当作完整零用量。

完成一轮并检查取消后，先核对meter，再派发任何工具。小于阈值才能继续；恰好达到且没有工具可完成，超过阈值或仍有工具则暂停；无法核对用量时即使已有正文也暂停，保留结果供查看。每次tool及下一HTTP前仍检查取消，审批返回后仍走原intent／dispatch围栏，不为预算引入并发工具。MCP内部自行调用模型不属于本run的provider账本。

下一次输出上限为min(冻结每请求上限, 剩余额度)。Chat与Responses的continuation输入增加可选cap，先核对cap、callID集合和输出预算，再改变历史；不改旧reasoning／phase／opaque bytes或工具结果来表达额度。关闭阈值时保留原配置上限行为。

## 交互与持久化

预算字段与现有Tools and budgets同组，明确开关和正整数验证；草稿原文由WorkspaceSession持有，导航／重绘不重置，非法输入阻止保存与运行。工具审批展示冻结合同／阈值，任务显示冻结阈值、已知消耗和用量未确认／达线状态；纯数字状态可进入最小回执，不保存正文或授权。暂停不把已成功模型请求改成失败、退款或零费用，最终用量继续经原recorder／ledger收口。

费用停止阈值尚不在本增量内；可选费率和费用估算继续保留，原有“可测费用预算”义务保持开放，不能因token阈值完成而关闭整个5.4。

## 验证

预算回执使用Invocation Envelope v3，与配置schema4分别声明reader能力。即使未保存配置的内建只读Agent也会写v3，旧reader不能忽略新字段后重写。v1/v2拒绝预算键（包括null）；无预算的旧记录仍保留v1/v2。启动遇到未收口intent只恢复为interrupted和用量未确认，不恢复审批或继续请求。清除AI用量历史同时擦除已收口回执的token数及轮数副本，保留阈值和用量未确认状态；在途meter不重置，结束后仍可能产生新账本。

纯meter覆盖重复、补齐、缺报、倒退、冲突、delta、溢出、越线及双run隔离；生产Chat／Responses loopback证明准确cap、原续接bytes不变、预算停后零新HTTP／工具。再覆盖迟到审批、在途改profile、未保存定义合同、新尝试、历史用量保留、schema4／导出／旧reader拒绝和原生双语保存／重启。真实服务用量与完整质量、视觉、系统矩阵独立留证。
