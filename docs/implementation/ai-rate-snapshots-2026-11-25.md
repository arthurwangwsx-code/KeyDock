# AI费率与历史用量增量复查

2026-11-25，任务32；独立编写，AiBox仅只读设计参考，没有迁入源码、历史、配置或凭据。当前alpha.18已发行并安装，最终资格见[发行证据](alpha18-release-2026-11-25.md)。以下保留各次实现与失败过程，不代表原P0–P4完整产品／真实API验收。

## 实现

- AI服务设置新增可选手工费率，按完整wire endpoint的SHA256及精确UTF8模型名匹配；每百万输入／输出token、三字母币种、启用、移除和配置导出。编辑保留稳定sheet身份、原定义及保存补偿，不读取钥匙串／联网。
- AICore逐实际transport.open记录attempt；同步worker lease使取消、队列尚未消费和body drain不会漏掉已发生的用量。每次Agent轮次独立计数，失败响应中已验证的usage保留，产品解析失败不撤销模型事实。
- 运行冻结费率；Workflow各AI步骤独立leaf，父仅保存child/step索引。旧记录不套用现价，坏费率不抹除有效token。Decimal边界拒绝精度损失、溢出和极小正数归零。
- Activity内独立AI用量区支持7／30／90天、原币小计及覆盖缺口；逐叶有界读取，跨窗冲突检查及双向父子核验。与可选行为统计／其AI总结输入分开。清除／维护／TTL、旧查询及迟到恢复经过代次和单调revision围栏。
- 统一工程CLI接入个人Mac共享存储gate，覆盖整个子流水线；嵌套仍核验租约，缺失显式工具时拒绝旁路，其他公开开发机维持原有本地检查。KeyDock为admission-only，不登记自动清理范围。

## 已完成验证

| 证据 | 结果 | 范围 |
|---|---|---|
| core-tests-v1 | PASS，20项／2套件，含8个既有全局测试 | 精确价格、准确服务／模型、未知与零、provider取消及实际请求归因；具体数量以各Swift Testing日志为准 |
| settings-tests-v2 | PASS，35项／5套件 | 保存补偿、override-only、未呈现取消、编辑／移除／导出 |
| workflow-tests-v2 | PASS，58项／8套件 | 多模型／币种、清除两步之间、旧clear与较新family、历史跨revision重读 |
| analysis-tests-v4 | PASS，56项／7套件 | 129次历史请求、双向父子及两种枚举顺序、跨窗冲突、旧记录、symlink／字节／数量预算、查询／清除竞态及上述核心回归 |
| localizations-v3 | PASS，847 key | 两个bundle英文／简中完整；不替代原生排版与VoiceOver |
| storage-adapter-tests-v1 | PASS，4项Python | 准确source admission、嵌套验证、拒绝旁路、退出码 |
| product-budget-tests-v1 | PASS，19项／2套件 | Agent跨轮产品输出预算；wire确实缺usage与同payload已报告usage分开，均不产生命令副作用 |

保留的失败：settings-tests-v1为新测试的throwing宏表达式编译错误，改为先求值后v2通过；localizations-v2遗漏两条简中token标签，补齐后v3通过。没有删除失败receipt或以静默重跑覆盖原证据。

首个完整检查complete-check-v1在旧AILimit测试失败（2条断言）：旧夹具在wire已发第二轮完整usage，却假定产品输出超限后只能保留第一轮。新provider正确保留了第二轮已报告事实。保留旧失败；将原partial夹具明确改成第二轮wire截断／缺usage，原断言不放宽，并增加同payload带usage且触发产品总预算的独立路径，19项定向通过。再次完整检查必须绑定后续干净提交，不继承首次失败的资格。

干净362a8ba的complete-check-v2通过：803项Swift（含参数化执行）、78项Python、847中英key，本机OCR双轮PASS；原始check-summary在.local/pipeline/20261125T145203379094Z。其独立CI 45638887309在Python新测试暴露/var→/private/var规范化差异，未运行Swift／优化构建；生产入口正确resolve，修正测试期望为canonical路径，不改变共享gate或降低门槛。新候选必须再次取得完整本机及CI资格。

定向measurement位于ispec/changes/keydock-foundation/receipts/ai-rate-*.json，原始本机日志在被gitignore的.local/desktop/ai-rate-*.log。analysis-tests-v3 measurement为7f0dc3a0-9b33-4f56-a27f-e3b02c40ba90，25.417秒；v4继续验证冲突请求计数不依赖枚举顺序，56项通过；localizations-v3为867b5af5-5167-4691-b38f-696127c0bdd9。它们属于apply attempt 9881b6d8-e08e-4176-b6a2-97706ee67811，不能推断整个apply已完成。

## 待补资格

最终源6baaee8的完整本机／指定同源CI、原生观察子集与公开发行／正式安装已在发行证据闭环。真实兼容API、账单对账、模型质量、完整视觉／物理热键／目标插入／多屏和长期驻留仍保持原验收义务。

## alpha.18候选复查

干净c9f2cde的完整本机检查继续通过803 Swift／78 Python／847 key及OCR双轮；Preview构建与正常替换通过。同源CI 45639348403在新双步骤费率测试的5秒收口断言失败：状态running、posts=2、outputBytes=0，原始artifact 15035127919（39117字节，SHA256 867077ef88d65f910a833a8a07d380237bc77723a5b4adfd20b331c60aa3bc38）已回下载核验并保留。费率测试原复用/stream逐字节sleep夹具，新增/usage使用同一真实URLSession／SSE路径且无人工发送延时；原逐字节用例、全部断言及5秒门槛保留，新候选再验。

原生中文浅色已观察USD 2/4费率、单次12输入／5输出估算0.000044；保存3/6后旧结果保持0.000044，新结果0.000066，独立分析为2请求／24输入／10输出和USD 0.00011。默认Preview目录另有两条旧版loopback合成元数据，模型synthetic-ui-model；它们按旧记录独立显示30／10，不套新价格。临时目录环境变量没有改变Foundation选择的默认Preview目录，验收记录已纠正为非新建目录，既有记录保留，不能宣称空库或崭新安装。

英文深色原生观察发现已知金额行的ForEach复用旧中文标题（Catalog英译正确）；绑定locale身份以重建该行，保留范围选择。需新Preview再次实际切换验证。其余已观察表单／范围／时区和原币金额符合预期；本轮完整视觉与VoiceOver仍无全量资格。

后续只读复核补齐同attempt三个冲突副本的全部候选币种集合：跨窗／多币种六种枚举顺序均产生相同调用数、缺口及金额，仅保留未受冲突影响的独立币种。alpha18-rate-transport-tests-v3共42项／4套件通过，10个费率归因夹具已切换到/usage；原网络逐字节、产品预算与取消回归继续保留。

最终6baaee8的原生English→中文→English复验确认金额标题刷新、90天选择保留；重启后旧0.000044／新0.000066不变，最终源主动第三次请求后为USD 0.000176。804 Swift／78 Python／847 key、同源CI与alpha.18公证／公开回下载／安装通过，实际About18已观察。
