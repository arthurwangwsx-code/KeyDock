# alpha.8原生OCR复发记录

2026-11-25。本记录保存alpha.8曾被原生OCR门禁阻止的事实；后续在明确空间状态变化后通过原配置完整资格，并已完成[alpha.8发行与安装](alpha8-release-2026-11-25.md)。UI及URL增量没有跳过完整本机OCR门禁；长期原生可靠性仍PARTIAL，以下失败没有被覆盖或重试成功改写。

## 已确认事实

前一UI候选`36812e07dc17a7368b79ff5824825e429e36b9a6`完整本机检查通过（474 Swift／46 Python／587 key），生产Vision双轮识别合成PNG通过，OCR用例耗时86.251秒。测量`843e1c4a-f4cd-45e2-9c8e-fcdad25b111f`，19:08:51Z–19:12:17Z；Release构建测量`c6b7c0b3-0e30-4642-9adb-0fe915676063`亦通过。该候选未发布。

补URL编辑隔离后的`57f308d6540ac6705cc0b84db4f477568a16ed37`完整检查在生产OCR失败：TextRecognition.CRImageReaderError code1，Swift错误描述包含e5rt precompiled compute operation code13，67.607秒；完整测量`9c859a2e-c41f-4760-b254-718443703cea`，19:24:33Z–19:27:00Z。主体及Terminal阶段通过，但完整检查FAIL、不生成资格。[同源core CI 45469904470](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45469904470)通过且明确system OCR NOT_QUALIFIED，不能代替本机门禁。

生产OCR工厂与模式相对alpha.7没有变化，未降低accurate／revision3／自动语言／语言纠正／支持阶段CPU配置，未修改180秒门禁或两轮识别断言。

## 有界合成诊断

忽略目录中的原创独立phase probe，只生成同一张1200×200、15593字节PNG，SHA256为`06db6e05ce33913ef1ec983f48496c89ff7112b5f2a1ab26dd782f349499e161`，所有输出明确`product_acceptance=false`。每个场景独占新进程，180秒上限，仅可结束其自身进程组；没有用户文件、截图、网络或服务操作。

| 场景 | 测量 | 实际结果 |
|---|---|---|
| 当前生产配置顺序，两轮新请求 | `211fe1eb-ac5d-4586-b7f7-7dd944fc0179` | 设备查询约0.036秒完成，main声明支持ANE／GPU／CPU、选中CPU；第一轮约69.57秒匹配成功，第二轮perform约0.033秒失败 |
| 查询前先选可访问CPU，查询后验证支持范围 | `94c8d51d-f648-4a7a-939a-5ecc70a52a6a` | 第一轮约69.61秒成功，第二轮约0.028秒失败；不采用该顺序作为生产修复 |
| 同一请求成功后串行复用 | `291ee524-c6c5-4cce-9778-b8455a6fd6e4` | 第一轮约66.10秒成功，第二轮约0.053秒失败；不据此引入请求池或取消后复用 |

三个场景均FAIL。对照过程可用磁盘约1.7–4.2GB变化，memory_pressure报告free约40%–46%；不是唯一故障原因证明。只读取本工具进程的UnifiedLog，观察到ANE driver打开／map／unmap成功及最后TextRecognition错误；这些成功日志也不能证明ANE是故障根因。没有清除OS模型缓存、重启服务、杀其他项目进程或修改权限。

## 生产路径轮次日志

现有资格测试只增加轮次开始／完成／失败时的单调耗时，仍调用同一DocumentContextService.read，原双轮、文本匹配、usedOCR、设备与配置断言保留。最终资格JSON格式和成功条件不变。

增强日志后的独立生产路径测量`72aa27e0-f0b3-41d7-a1d9-70ff3b9b854d`在**第一轮**约34.77秒失败，同域／码。由此不能把问题归因为第二轮、新建请求或实例复用。该独立运行没有生成或恢复完整发行资格。

## 公开API证据与后续

[Apple设备选择](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:))要求支持范围校验，允许nil恢复框架选择；[支持设备查询](https://developer.apple.com/documentation/vision/vnrequest/supportedcomputestagedevices)可抛错且没有无初始化成本保证。[Apple OCR示例](https://developer.apple.com/documentation/vision/extracting-phone-numbers-from-text-in-images)展示成功请求串行复用，但没有证明本次错误原因；[cancel](https://developer.apple.com/documentation/vision/vnrequest/cancel())也没有承诺取消后的复用恢复。

保留根因未确认状态，暂不修改生产模式或调度模型。后续应以明确条件变化或生产修复进行有界验证，不能反复重跑直到变绿；新源码仍需完整本机PASS、同源CI及全部发行门禁。其余URL／集合／视觉工作可独立推进，不能把发行等待报告为整个产品已完成。

## 空间状态变化后的完整验证

后续开发期间，卷可用空间从约1.14GiB恢复至100GiB以上；本次KeyDock工作没有清理缓存、改OS服务／TCC或结束其他项目进程。以此明确条件变化，在干净`8c2c60063303fa218b9803257d8a66441b1d6cb7`执行了一次原流程完整本机check：测量`c643f20e-57f2-40ff-a8b8-3c478ee728a8`，2026-11-25T00:32:39Z–00:37:40Z，601 Swift／46 Python／660 key PASS。

生产OCR第一轮107.875秒、第二轮约0.460秒均实际匹配，仍为同一PNG、accurate／revision3／自动语言／纠正／支持阶段CPU、双轮与180秒门禁；没有新fallback或改断言。8份原日志摘要和精确source已核对，[同源CI与优化Preview 45518861646](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45518861646)亦通过，云端OCR仍NOT_QUALIFIED。原失败、三种对照及长首轮耗时保留；空间变化与本次PASS的相关性不是唯一根因证明，长期可靠性仍PARTIAL。后续发行只消费其实际精确源码的新资格，不把这份旧source PASS移植到新提交。
