# 自动清理、退出与重启验收（2026-11-26）

起点为 `fix/usage-retention-budget-redaction@31a17ca`，基于 `master@eb4b506`。GitHub 同源核心检查 [45825596203](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45825596203) 与文档检查通过。当时公开版本及正式安装均为 alpha.27（27），源为 `e6c7b98`。

## 复现与实现

正常退出时，终态任务的 owner 通过独立 Task 释放，退出流程没有等待它。合成回归在正常关停后观察到仍有一份 ledger 和两条旧预算数值。失败测量 `23814b15-dee1-4df1-bfda-d9b116757437` 有三个断言失败，回执 SHA256 为 `5a65c5d329766325b02f3bc08567c92d49811b065955351e34bd31000173665d`。

退出时登记并等待 owner 释放，停止新请求，已排入 FIFO 的写入先完成，再对现有延期候选执行一次维护。原候选、无账本预算和清除以后的新事实分别核验。未完成的显式意图属于当前进程。若进程被强制终止或持久化失败，用户可以再次清除。下一次启动按 TTL、条数和字节上限重新判断；启动不得凭复用的 UUID 清除新事实。

最后一次盘点失败时，仅对已确认删除或同步结果不确定的具体记录失效摘要，其他子记录及父摘要保留。大小写敏感卷可出现同一 UUID 的两个文件名，扫描遇到该冲突会报告错误并停止。自动逐出某个 Workflow 叶子后，父摘要丢弃这一叶；下一次合成请求成功后，磁盘索引只含新叶及不完整标志。正常退出、进程故障和点击系统界面分别留证。

第一轮修补后的定向测试返回一次失败，测量 `1c63c96f-7653-469c-8b0a-62456117cbb8`。缩小范围后，正常退出已通过；最终盘点用例中，为构造已显示任务调用了历史恢复，它另起异步读取并覆盖预置合成摘要。诊断测量 `c71fab0b-102c-4baf-8218-4c72ab5743c3`。夹具改为写入已结束 worker 的界面投影，保留删除 syscall、失败注入和目录读取。

普通 Preview 启动按 UUID 新建观察目录，保留 launch、started、退出回执与本次日志。同一合成数据目录可以复用；根级 review-process.json 指向最近运行。旧运行按各自目录核验。

`f1f7b61` 的干净完整检查为 1,098 Swift、157 Python、1,037 中英键及两轮生产 OCR，精确源[核心 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45830315173)及优化 Preview 通过。实际 Preview 启动持久化了过期项的未知预算，保留新项的 31 token，进程正常退出。桌面观察器无法选择菜单栏 accessory 进程。为取得可复查的中英文图像，隔离 Preview 支持在已验证的合成 fixture 上执行 `scripts/native-review.py --task-views <first-uuid> <second-uuid>`，打开真正的工作区并绘制其自身内容。用户屏幕合成效果、实际键盘输入、VoiceOver 和外部应用观察另外验收。

## alpha.28 正式交付

| 状态 | 项目 | 可复核证据 |
|---|---|---|
| PASS | 干净源码、本机回归与 CI | `6490bc51d00b45c47e0450c90b8f25f5c508c5b6`。Apple M1 Pro，macOS 27.2，Xcode 27.2。1,098 次 Swift 执行、1,077 条声明、157 项 Python、1,037 个中英文键，生产 OCR 两轮通过。本机 iSpec 回执 SHA256 `1d529b294f8df05b361630ac37fcfa5e3dd5b91a0a79f704c928e79d03ede085`。[分支 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45834424727) · [master CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45836016504) |
| PASS | 优化 Preview、正常退出与重启 | 同一合成域先以中文深色启动，再以英文浅色启动，两个独立进程均退出 0。各打开两项工作区任务，原生视图显示过期任务阈值 100／用量未知，新任务阈值 100／已用 31／剩余 69。不可处理的合成目录在两次启动后都保留，界面提示检查或清除记录。两次 attempt 集合相同，第一次回执字节不变。原生配对回执 SHA256 `49d6b79aed00c39dcd75d4548566dc4e36653f0b137b9c2ee71d109735bab49c`。 |
| PASS | 公开发行、正式安装与回退 | [alpha.28](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.28) 发布 ZIP、DMG、manifest 和 SHA256SUMS。App／DMG 签名、公证、装订、Gatekeeper、ZIP／DMG 内 App 一致及公开回下载均通过。[独立发行检查](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45837561655)。正式路径实测 27 → 28 → 27 → 28，每步复核提交、严格签名与 Gatekeeper。最后安装回执为 `.local/pipeline/20261126T141828365659Z/install-receipt.json`，回退演练记录为 `.local/pipeline/20261126T141801901772Z/install-receipt.json`。 |
| PARTIAL | 桌面与异常终止 | 这里的四张图来自两个真实 Preview 进程绘制的工作区内容。深色图左栏的文字对比仍需用系统合成画面复核。未取得桌面合成器、真实按键、VoiceOver、GUI 手动清除或强制终止两个事务切点的观察。 |

资格摘要（public manifest）为 `722419230fc65e7d2422efc841ca44a6ec2ec907539e2dfa239b0e0b7b7a7a35`。最终 Preview、全量、签名、打包、发布、安装及回退都使用共享存储准入。仅合成内容用于功能测试，未调用付费模型。

## 后续 P0–P4 验收总账

### 发行后的开发资格

普通布局和最小化冻结窗口的生产代码为 `d125202393c1c36f2e61b57b4c4cdc988ff5ecb9`，已通过[同源 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45851482288)。干净本机 1,103 次 Swift、157 项 Python、1,037 个中英键、两轮生产 OCR 通过。优化 Preview 在两个独立进程打开真实任务详情，旧预算未知、新预算 31 token，均正常退出。回执 `02e0ee45-4fc7-4c7b-82bd-c81b1fadde1e`、`06a455a3-119f-445c-86e7-3402ce2e7c06`、`cc2aa9bb-79ca-4524-bb1f-78386107c047`。窗口焦点 A→B 的零写入来自受控适配器；这两次原生进程验证用量恢复。

保留首轮本机全量失败 `cc325337-eaf8-46a4-b860-8a22333c401a`。历史过期用例的 5 秒期限在合成 HTTP 收口中耗尽，当时已有 1 个 POST、20 字节输出，尚未改写日期或运行过期维护。同一源码的该用例连续三次和下一轮完整检查均通过。历史清除、收口、过期用例现使用已有 `/usage` 回路，真实 URLSession、SSE 和 12 输入／5 输出用量仍参与；`/stream` 的逐字节延时保留给传输测试，5 秒观察期限保持原值。

修正后的模型与启动台代码固定源为 `299a240c710f06a4664861c7f35ad35a68500bdd`，同一提交通过 [GitHub 构建检查](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45847402118)。本机干净全量回执 `e15a212e-a26d-4bc0-97c3-e27da06b0fde`、优化 Preview 回执 `dcfd87d5-3e62-407b-a934-355c640bb1a3`。正式 alpha.28 的二进制所含功能仍以发行提交为准。

模型继承最初源码 `6aff14b` 在本机通过 1,102 次 Swift 执行、157 项 Python、两轮系统 OCR 及优化 Preview。同源 [GitHub CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45844223763) 在计算器选择后复制的三处断言失败。合成回归让启动恢复在已显示结果与 Return 之间重建相同目录，观察到一次无变化发布、复制零次，四处 RED，回执 `eb1122e7-dbed-48ee-b2b8-8a6ccececa10`。启动、应用索引与窗口刷新现共用同一目录更新路径。仅完整有序内容变化时发布，标题、身份、绑定或修订变化仍使旧选择失效。定向 9 项通过，回执 `74e49048-507f-47e4-86ed-8ac0f8426173`。

| 范围 | 状态 | 源码和结果 |
|---|---|---|
| 提供方成功登记 | PASS | `7aa8a08`。Chat 和 Responses 在收到成功终态后登记调用成功，再等待传输排空。Responses 本地 1 MiB 历史超限保留 17 输入和 9 输出 token。6 个 RED 断言、51 项定向、干净全量 1,100 Swift／157 Python、两轮系统 OCR、优化 Preview 及[同源 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45839335071)分别留证。费用金额阈值仍开放。 |
| 剪贴板读取失败和重试 | PASS（受控存储） | `d6f7c9a`。独立面板及工作区使用查询实际结果决定错误、空库或无匹配。回归覆盖空／非空查询失败、两窗口隔离、同词重试、断开和迟到结果。干净全量 1,100 Swift／157 Python、两轮生产 OCR 及[同源 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45841572613)通过。 |
| A/B/C 接收端 | PARTIAL（签名原生宿主） | 同源 Review 与 fixture 均以 Developer ID 签名，独立进程启动。三个真实窗口分别显示自己的 Paste 计数 0，正文与各自合成基线相符。PersonalAI 能按窗口读取 fixture；对菜单栏 Review 指定 bundle 和实际 PID 时均不能取得窗口。没有发送 Paste。两进程已正常退出，stop 回执 `7a9acff6-e84a-46bd-8667-8ce29cc7f609`。一次插入、有序字节、目标漂移及权限撤销仍待实际发送与接收验收。 |

只读审查的源码定位：退出等待在 `WorkbenchModel.swift:430`、延迟 owner 等待在同文件第 442 行；维护报告分类在 `AIUsageMetadataStore.swift:42`，相同 UUID 冲突在第 447 行。直接窗口操作的入口在 `KeyDockApp.swift:380`，等待 intent 后取当前窗口在 `DesktopActions.swift:65–84`。剪贴板实际 AX 插入事务见 `ClipboardPasteService.swift:33–54`。模型场景及输出上限的继承顺序由 `AIModelResolver` 处理。三组证据均按该次检查的源码定位。

定向回归 `da1cf767-a556-4969-8e00-38b726f0cf35` 通过 59 项执行，回执摘要 `fd9be8cdf6565875644a6cfe92f90a639144cb7c80791a44726223d7a0694aa5`。合成 HTTP Workflow 的最后一份索引为一个新叶、两次 POST，显示保留 12 输入／5 输出 token。在候选 alpha.28 上另行记录干净全量、CI、优化 Preview 及真正进程重启。

| 项目 | 证据或差距 | 验收条件 |
|---|---|---|
| 真实剪贴板与热键 | 既有签名 Review 的查询、多选与复制有原生子集。`d6f7c9a` 的签名夹具已观察 A/B/C 各为零，正式身份、实际插入与实体按键仍待取证。见 `Tools/KeyDockDesktopFixture/main.swift`、`MacAdapters/ClipboardPasteService.swift` | 合成 A/B/C 三个编辑器按窗计数，A 使用折叠选区及非幂等文本。快速两次 Return，A 只增加一次且字节正确，B/C 零次。逐个改变选区、窗口、实例、焦点和授权，Esc、Secure Input、暂存后竞争均检查零发送。|
| 应用与窗口 | 直接布局／最小化在授权及保存 intent 前后保持同一窗口身份。授权后、异步等待前冻结引用，写前核对焦点；启动台缺失继承引用时拒绝。合成同进程 A→B 在修复前错误提交，两个断言失败，回执 `9972499b-3468-4aa7-9ff4-d423185edcab`；修复后未提交、零写入，32 项定向通过，回执 `d4dfc962-309d-4e6a-96de-642b960da659`。 | 实体键、真实同应用切窗、跨 Space、第二屏、真实恢复、引用删除及冲突回滚各自取证。 |
| 剪贴板查询失败 | `d6f7c9a` 已让独立面板与工作区按读结果显示错误、空库或无匹配，不同窗口及重试已通过受控存储回归。 | 独立表示查询失败、成功空库和成功无匹配。用错误后重试及开关关闭的真实视图验证。|
| 视觉和无障碍 | 启动台随结果数调整高度。剪贴板面板固定 860×540，窄屏有越界风险。设置和工作区分别为独立窗口。原生首帧偏移与旧失败见此前记录。 | 原生中英×深浅×最小/常规；首次可见与稳定画面分开；核验拼音 Return/Esc、VoiceOver 错误及选中行、焦点返回、减少透明度/动态、提高对比度、负坐标与多屏。|
| 模型配置 | `6aff14b` 已改为捕获可继承的有效输出上限；全新配置仍为模型默认思考、2048 输出上限。第三方同名清单独立呈现来源与能力核实状态。 | 原继承 1024/4096 时打开覆盖应沿用有效值；关闭恢复继承。合并同名模型时同时呈现服务清单来源与能力核实状态。正式个人配置保留。|
| 费用阈值 | `BoundedAgentRunner` 已有 token 阈值；`7aa8a08` 已修复 Chat 和 Responses 成功登记顺序。 | 冻结币种、费率、限额，用 Decimal 判定；在下一工具／请求前暂停，缺报或错币种时显示未知。覆盖未保存定义、旧 reader、清除和重启。|
| 持久步骤、附件、增量用量 | Workflow checkpoint 仅在内存；消息为字符串；原增量事件缺少稳定身份。 | 步骤只记录序号、状态与调用引用，重启只读且不重放副作用。先支持明确选择的一张 PNG/JPEG、能力与双重字节限制；取消或不支持时零 HTTP。增量按 attempt 和稳定 event ID 有界去重，核对冲突、乱序、混用及溢出。|
| 最低系统、长期驻留和真实模型质量 | 现有合成及历史实机资格按各自版本保留。 | 最低系统实际启动、8 小时含睡眠、实际屏幕首次呈现、20 个质量样例分别附条件与结果。|

模型与竞品核对日期为 2026-11-26。OpenAI 建议一般任务从 Sol medium 评估，复杂工程、视觉和简单重复工作分别评估 Astra、Terra 和 Luna。Raycast 的逐次顺序粘贴与 Alfred 的追加合并拥有不同的用户动作。本项目本次剪贴板验收采用选定多条、核对顺序、一次插入的合同。[OpenAI](https://developers.openai.com/api/docs/guides/deployment-checklist) · [Raycast](https://manual.raycast.com/clipboard-history) · [Alfred](https://www.alfredapp.com/help/features/clipboard/)
