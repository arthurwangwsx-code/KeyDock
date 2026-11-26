# Agent费用停止阈值初稿

状态：原 5.4 的费用停止阈值尚未开放。已发行版本有 token 阈值和可选费率快照。费用判断的第一项依赖为两种协议的成功登记顺序，见本文末的实际回归。完整费用限制仍需要运行、存储、界面及原生验收。

拟增加可选`estimatedCostLimit { currency, maximumAmount }`。nil关闭，不假定默认币种。金额为有界ASCII十进制字符串，复用现有单价输入校验并要求大于零；计算与比较用未舍入Decimal，不经过Double、换汇或逐请求两位小数舍入。单价校验的18位小数限制不能套在计算结果上：1 token乘1e-18每百万单价会得到1e-24。精度损失／上溢／下溢均为无法核实，不能当零。

启用时在凭据读取、MCP建连和模型派发前冻结准确服务／模型的唯一费率、币种、revision和依据指纹。缺费率／币种不符／模型或服务不符时零HTTP并提示补齐；关闭限制仍允许无费率运行。阈值、费率依据和策略版本进入实际run／审批／新attempt合同；在途改价不改变旧run，准备阶段的改价或ABA应使旧审阅失效，不能把不断变化的frozenAt当配置变化。

必须先收口recorder终态顺序：不能在每轮调用`closeAndSnapshot`，它会封口且可能等待Runner自身worker。应让Chat／Responses在发出completed前完成成功attempt登记（保留幂等defer兜底），每轮使用非封口snapshot及既有AICostSummary。否则合法请求可能被竞态识别为running／未知而误暂停。

每轮需新attempt、完整用量、正确冻结费率和唯一币种；缺报、partial、冲突、delta、重复调用或算术错误都暂停并保留已知部分，即使显式零费率也不能把缺报当零。完整用量配合显式零费率可以得到估算零。先核实token，再在任何工具／后续HTTP前核实费用：小于可继续；等于且无工具可完成；等于仍有工具或超出则暂停。取消／超时仍优先，成功模型调用不被改为failed或退款；不把金额倒算为能保证安全的下一轮token数。

持久化须在编码前选定完整reader方案：新配置／导出／定义指纹保护新字段，未保存profile生成的费用事实也须有独立降级保护，不能仅靠配置版本。可复用Invocation数字摘要并统一清除，或给UsageReceipt增加显式reader声明；不能假设向无版本旧ledger加字段就不会被旧App忽略后重写。若复制费用数字到回执，清除／TTL必须同步抹除，保护真正在途worker而非已结束恢复来源。阈值和图关联可保留，重启不重定价或自动继续。

P0证明包括：极小金额精确往返、达线／越线、去重／不同attempt同responseID；全部未知及算术失败；前置拒绝零HTTP；两个Provider终态顺序和多轮不封口；多工具批次停后零派发、cleanup取消／迟到审批；改价／删价／ABA；双run隔离；call成功但task暂停；清除／TTL／重启不复活金额；所有reader与安装回退失败保全。之后再做原生中英和真实服务子集。实现前把这些合同补入iSpec，不以本初稿替代已完成代码。

2026-11-26只读方案补充（尚未实现）：持久化采用配置schema5及Invocation Envelope4路线，费用字段或保留的费用阈值存在即使用4，保护未保存profile；不向Envelope3添加会被旧decoder忽略的可选minReader字段。费用继续复用原ledger，不另造无版本reader。一个AIRateSnapshot同时进入运行合同与recorder，稳定依据排除frozenAt；成功模型终态之后的产品处理失败仍保留成功调用及实际已知费用。

清除／恢复围栏已分别在 alpha.27 和 alpha.28 复现并交付。数字恢复使用读取前的票据，过时或清除中创建的票据不再授权旧数值。已有测试包括迟到回执、新事实、Workflow 和失败事务；将来的费用字段仍须验证相同约束。[清除证据](../implementation/usage-restoration-fence-2026-11-26.md) · [自动维护证据](../implementation/retention-shutdown-2026-11-26.md)

2026-11-26 的合成回归冻结传输排空，Chat Completions 与 Responses 都已收到有效成功终态，但非封口快照仍显示 running；另一次 Responses 调用报告 17 输入／9 输出，随后本地 1 MiB 会话历史超限，旧实现把该调用记为失败并标记用量不完整。RED 回执 `4cd98904-d7b2-440d-a711-fc0934cdc2b7` 有 6 个失败断言。修补在协议终态核验及用量观察后、传输排空前登记成功，原有幂等结束仍负责错误和 worker 释放。51 项定向测试通过，回执为 `b2ad5880-1ea8-48e2-a196-ee47e6edc0f2`。缺失用量继续为未知；此变更未增加金额设置或发起付费请求。
