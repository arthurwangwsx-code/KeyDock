# AI费率与历史用量增量复查

2026-11-25，任务32；独立编写，AiBox仅只读设计参考，没有迁入源码、历史、配置或凭据。正式已发布版本仍为alpha.17。本文件记录工程增量，不代表原P0–P4完整产品／真实API验收。

## 实现

- AI服务设置新增可选手工费率，按完整wire endpoint的SHA256及精确UTF8模型名匹配；每百万输入／输出token、三字母币种、启用、移除和配置导出。编辑保留稳定sheet身份、原定义及保存补偿，不读取钥匙串／联网。
- AICore逐实际transport.open记录attempt；同步worker lease使取消、队列尚未消费和body drain不会漏掉已发生的用量。每次Agent轮次独立计数，失败响应中已验证的usage保留，产品解析失败不撤销模型事实。
- 运行冻结费率；Workflow各AI步骤独立leaf，父仅保存child/step索引。旧记录不套用现价，坏费率不抹除有效token。Decimal边界拒绝精度损失、溢出和极小正数归零。
- Activity内独立AI用量区支持7／30／90天、原币小计及覆盖缺口；逐叶有界读取，跨窗冲突检查及双向父子核验。与可选行为统计／其AI总结输入分开。清除／维护／TTL、旧查询及迟到恢复经过代次和单调revision围栏。
- 统一工程CLI接入个人Mac共享存储gate，覆盖整个子流水线；嵌套仍核验租约，缺失显式工具时拒绝旁路，其他公开开发机维持原有本地检查。KeyDock为admission-only，不登记自动清理范围。

## 已完成验证

| 证据 | 结果 | 范围 |
|---|---|---|
| core-tests-v1 | PASS，20项含参数化定义／2套件及既有8个全局函数 | 精确价格、准确服务／模型、未知与零、provider取消及实际请求归因；具体数量以各Swift Testing日志为准 |
| settings-tests-v2 | PASS，35项／5套件 | 保存补偿、override-only、未呈现取消、编辑／移除／导出 |
| workflow-tests-v2 | PASS，58项／8套件 | 多模型／币种、清除两步之间、旧clear与较新family、历史跨revision重读 |
| analysis-tests-v4 | PASS，56项／7套件 | 129次历史请求、双向父子及两种枚举顺序、跨窗冲突、旧记录、symlink／字节／数量预算、查询／清除竞态及上述核心回归 |
| localizations-v3 | PASS，847 key | 两个bundle英文／简中完整；不替代原生排版与VoiceOver |
| storage-adapter-tests-v1 | PASS，4项Python | 准确source admission、嵌套验证、拒绝旁路、退出码 |
| product-budget-tests-v1 | PASS，19项／2套件 | Agent跨轮产品输出预算；wire确实缺usage与同payload已报告usage分开，均不产生命令副作用 |

保留的失败：settings-tests-v1为新测试的throwing宏表达式编译错误，改为先求值后v2通过；localizations-v2遗漏两条简中token标签，补齐后v3通过。没有删除失败receipt或以静默重跑覆盖原证据。

首个完整检查complete-check-v1在旧AILimit测试失败（2条断言）：旧夹具在wire已发第二轮完整usage，却假定产品输出超限后只能保留第一轮。新provider正确保留了第二轮已报告事实。保留旧失败；将原partial夹具明确改成第二轮wire截断／缺usage，原断言不放宽，并增加同payload带usage且触发产品总预算的独立路径，19项定向通过。再次完整检查必须绑定后续干净提交，不继承首次失败的资格。

定向measurement位于ispec/changes/keydock-foundation/receipts/ai-rate-*.json，原始本机日志在被gitignore的.local/desktop/ai-rate-*.log。analysis-tests-v3 measurement为7f0dc3a0-9b33-4f56-a27f-e3b02c40ba90，25.417秒；v4继续验证冲突请求计数不依赖枚举顺序，56项通过；localizations-v3为867b5af5-5167-4691-b38f-696127c0bdd9。它们属于apply attempt 9881b6d8-e08e-4176-b6a2-97706ee67811，不能推断整个apply已完成。

## 待补资格

完整干净源码检查、实际Preview中英明暗的费率编辑／单次与历史／分析观察、同源CI、签名公证／公开回下载／正式安装分别待补。真实兼容API、账单对账、模型质量、完整视觉／物理热键／目标插入／多屏和长期驻留仍保持原验收义务。
