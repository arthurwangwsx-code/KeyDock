# 验证与验收方案

本文件定义第一阶段验收标准；实际实现和执行证据以[状态总账](../status.md)、[验证回执](../implementation/phase-one-validation.json)及[最新界面与任务边界复查](../implementation/native-ui-hardening-2026-11-23.md)为准。已有原生构建、合成测试、loopback网络和部分真实界面检查，不能据此推定真实外部API、TCC和完整日用验收通过。结果使用PASS/PARTIAL/FAIL/BLOCKED，记录源码revision、环境、日期和证据范围。

## 验证层次

| 层 | 必测项 | 证据 |
|---|---|---|
| 纯核心 | 排序/别名、异步 generation、参数 schema、窗口几何、预算、状态机、未知 usage/cost | 定向单元/性质测试，合成 fixture |
| 适配集成 | Process stdout/stderr 满管、超时/取消/子进程、stream 断裂/429/非法工具参数、SQLite 迁移/删除 | 可重复集成日志，无真实秘密 |
| 原生 UI | 多屏/全屏/Stage Manager、Esc/焦点、IME、VoiceOver、快捷键冲突、结果/参数/任务区 | 真实 Mac 截图/录屏及交互记录，分享前脱敏 |
| 权限 | 未授权/拒绝/撤销/重新启用、目标不支持/关闭、窗口缩略图单独授权 | 逐动作真机矩阵，不能 mock 代替 |
| AI 外部 API | 至少一个真实云 endpoint，翻译/总结流/取消，key 不入日志，能力不支持与费用未知 | 用户选定服务后用合成文本验证；不把 mock 当真实接入 |
| Agent | prompt injection、tool schema、范围/授权变化、max steps、取消、崩溃和 unknown side effect | 合成攻击内容与真实无害工具；恢复不重复副作用 |
| 发布 | 签名/公证、Gatekeeper、干净安装、升级/回滚、数据迁移、支持/隐私页面 | 发布 receipt、包 SHA、下载与安装验证 |

## 最小验收场景

- 关闭/失效窗口不能激活同 PID 的其他窗口；同 App 两个窗口各自恢复布局。
- 快捷键唤起过程中不能把 KeyDock 自己当作翻译或窗口操作目标。
- 中文拼音组合输入的 Enter 优先提交文本，不能误运行第一条命令。
- concealed/transient 剪贴板在读正文前被过滤；清除覆盖 DB、索引、附件和缓存。
- 无选区的翻译动作不读整屏；目标变化后替换保留结果并停止写入。
- AI 翻译/总结快捷键在保存范围内直接执行；扩大输入范围或 endpoint 后有可见变化。
- 模型命令草稿不自动执行；argv 参数与 shell 特性分别测试，危险效果不能靠字符串黑名单判断。
- 本地查询不等待 AI，旧查询/取消后的流不会覆盖新结果。
- API 未返回 usage 时显示 unknown，不把估算当实测；cancelled/failed 请求记录部分 usage 或未知。
- 网页/OCR/工具结果中的“忽略限制、运行命令”等文本不能修改 Broker 策略。
- 取消后停止后续工具派发；已经提交的外部副作用明确显示可能未撤销。
- P1 任务中途杀进程，重启从最小 receipt 显示 interrupted/unknown，无自动重试/重放；P2 再验收完整显式恢复和副作用核对。
- 普通翻译/总结收到意外 tool-call 不执行；累计 usage、增量 usage、重试和 failed+throw 不重复记账。

## 性能预算与测量范围

热唤起 p95 ≤150ms；缓存本地查询首批结果 p95 ≤50ms。采样至少 100 次，记录硬件、电源模式、系统、数据规模、冷/热条件和测量起止；窗口/API 延迟分别计时。冷启动、常驻内存、CPU/能耗先在 P0 建基线再设门槛，不虚构数值。

`KeyDockDiagnostics`分别测量纯排序与生产使用的QueryRequest→缓存Provider→QueryCoordinator→首个可展示ResultBatch。固定2,000条合成数据、预热10次后100次采样；本轮先测到查询p95 51.67ms失败，优化值对象的规范化字段后，同一数据与预算复测为9.52ms，目录准备13.91ms另报。原始输出、环境、失败与复测绑定见[性能复查](../implementation/performance-sampling-2026-11-25.md)及[工程合同](performance-sampling.md)。不包含UI绘制、AX或索引，不能据此宣称热唤起150ms通过。历史20.85ms与首次排序50.37ms失败仍按[当时复查](../implementation/application-shortcuts-2026-11-23.md)保留。

Provider 慢/挂起必须有超时与降级；剪贴板轮询在无变更时不读取正文。面板收起后的运行、睡眠/唤醒和权限观察需测耗电。所有性能结论需标记样本数与分位数，不能仅展示一次最好结果。

支持系统暂定 macOS14 到当前版本、Apple Silicon 优先；最低系统、Intel 和多屏覆盖是否进入首发在 P0 锁定。当前开发机可编译不等于最低 OS 可运行。

## 证据与状态

个人数据/二进制证据放本地忽略的 .local 或 build；公开仓库只保留脱敏轻量摘要。每次里程碑更新 docs/status.md 和 iSpec tasks。文档校验与 Git commit 只证明工程记录，不能证明 App 可日用。

## P1 AI 质量门槛

至少保留 20 条固定合成样本，覆盖中英短文、技术术语、数字/日期、代码块、格式保留、含误导指令的原文和超长输入。翻译不新增原文没有的事实，术语/数字忠实；总结能回溯原文要点，关键约束不遗漏；长输入清楚提示截断或分段。逐项由人工评阅并记录预期/输出/判定；关键错误修复后才通过，非确定性输出不能用逐字相等测试冒充质量验收。
