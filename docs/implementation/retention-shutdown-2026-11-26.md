# 自动清理、退出与重启验收（2026-11-26）

起点为 `fix/usage-retention-budget-redaction@31a17ca`，基于 `master@eb4b506`。GitHub 同源核心检查 [45825596203](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45825596203) 与文档检查通过。当时公开版本及正式安装均为 alpha.27（27），源为 `e6c7b98`。

## 复现与实现

正常退出时，终态任务的 owner 通过独立 Task 释放，退出流程没有等待它。合成回归在正常关停后观察到仍有一份 ledger 和两条旧预算数值。失败测量 `23814b15-dee1-4df1-bfda-d9b116757437` 有三个断言失败，回执 SHA256 为 `5a65c5d329766325b02f3bc08567c92d49811b065955351e34bd31000173665d`。

退出时登记并等待 owner 释放，停止新请求，已排入 FIFO 的写入先完成，再对现有延期候选执行一次维护。原候选、无账本预算和清除以后的新事实分别核验。未完成的显式意图属于当前进程。若进程被强制终止或持久化失败，用户可以再次清除。下一次启动按 TTL、条数和字节上限重新判断；启动不得凭复用的 UUID 清除新事实。

最后一次盘点失败时，仅对已确认删除或同步结果不确定的具体记录失效摘要，其他子记录及父摘要保留。大小写敏感卷可出现同一 UUID 的两个文件名，扫描遇到该冲突会报告错误并停止。自动逐出某个 Workflow 叶子后，父摘要丢弃这一叶；下一次合成请求成功后，磁盘索引只含新叶及不完整标志。正常退出、进程故障和点击系统界面分别留证。

第一轮修补后的定向测试返回一次失败，测量 `1c63c96f-7653-469c-8b0a-62456117cbb8`。缩小范围后，正常退出已通过；最终盘点用例中，为构造已显示任务调用了历史恢复，它另起异步读取并覆盖预置合成摘要。诊断测量 `c71fab0b-102c-4baf-8218-4c72ab5743c3`。夹具改为写入已结束 worker 的界面投影，保留删除 syscall、失败注入和目录读取。

普通 Preview 启动按 UUID 新建观察目录，保留 launch、started、退出回执与本次日志。同一合成数据目录可以复用；根级 review-process.json 指向最近运行。旧运行按各自目录核验。

`f1f7b61` 的干净完整检查为 1,098 Swift、157 Python、1,037 中英键及两轮生产 OCR，精确源[核心 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45830315173)及优化 Preview 通过。实际 Preview 启动持久化了过期项的未知预算，保留新项的 31 token，进程正常退出。桌面观察器无法选择菜单栏 accessory 进程。为取得可复查的中英文图像，隔离 Preview 支持在已验证的合成 fixture 上执行 `scripts/native-review.py --task-views <first-uuid> <second-uuid>`，打开真正的工作区并绘制其自身内容。用户屏幕合成效果、实际键盘输入、VoiceOver 和外部应用观察另外验收。

## 后续 P0–P4 验收总账

定向回归 `da1cf767-a556-4969-8e00-38b726f0cf35` 通过 59 项执行，回执摘要 `fd9be8cdf6565875644a6cfe92f90a639144cb7c80791a44726223d7a0694aa5`。合成 HTTP Workflow 的最后一份索引为一个新叶、两次 POST，显示保留 12 输入／5 输出 token。在候选 alpha.28 上另行记录干净全量、CI、优化 Preview 及真正进程重启。

| 项目 | 证据或差距 | 验收条件 |
|---|---|---|
| 真实剪贴板与热键 | 既有签名 Review 的查询、多选与复制有原生子集。接收端没有逐窗口粘贴计数，正式身份和实体按键仍待取证。见 `Tools/KeyDockDesktopFixture/main.swift`、`MacAdapters/ClipboardPasteService.swift` | 合成 A/B/C 三个编辑器按窗计数，A 使用折叠选区及非幂等文本。快速两次 Return，A 只增加一次且字节正确，B/C 零次。逐个改变选区、窗口、实例、焦点和授权，Esc、Secure Input、暂存后竞争均检查零发送。|
| 应用与窗口 | `KeyDockApp.swift` 的直接布局热键只传进程身份，`DesktopActions.swift` 异步写 intent 后才取窗口。同一应用切窗可改变实际目标。| 入口冻结具体窗口和目标应用出生身份，写入前复核；A→B 期间 B 零写入。实体键、跨 Space、第二屏、真实恢复、引用删除及冲突回滚分别记录。|
| 剪贴板查询失败 | `ClipboardBrowserSession.swift` 和 `ClipboardPanelView.swift` 可能同时显示存储错误、无结果及启用建议。 | 独立表示查询失败、成功空库和成功无匹配。用错误后重试及开关关闭的真实视图验证。|
| 视觉和无障碍 | 启动台随结果数调整高度。剪贴板面板固定 860×540，窄屏有越界风险。设置和工作区分别为独立窗口。原生首帧偏移与旧失败见此前记录。 | 原生中英×深浅×最小/常规；首次可见与稳定画面分开；核验拼音 Return/Esc、VoiceOver 错误及选中行、焦点返回、减少透明度/动态、提高对比度、负坐标与多屏。|
| 模型配置 | `AIModelSettingsView.swift` 打开输出上限覆盖固定写入 2048。九类场景已有逐字段继承、在途冻结。 | 原继承 1024/4096 时打开覆盖应沿用有效值；关闭恢复继承。合并同名模型时同时呈现服务清单来源与能力核实状态。正式个人配置保留。|
| 费用阈值 | `BoundedAgentRunner` 已有 token 阈值；两种 Provider 的成功登记顺序仍待调整。 | 将成功用量登记移到对外完成通知之前。冻结币种、费率、限额，用 Decimal 判定；在下一工具／请求前暂停，缺报或错币种时显示未知。覆盖未保存定义、旧 reader、清除和重启。|
| 持久步骤、附件、增量用量 | Workflow checkpoint 仅在内存；消息为字符串；原增量事件缺少稳定身份。 | 步骤只记录序号、状态与调用引用，重启只读且不重放副作用。先支持明确选择的一张 PNG/JPEG、能力与双重字节限制；取消或不支持时零 HTTP。增量按 attempt 和稳定 event ID 有界去重，核对冲突、乱序、混用及溢出。|
| 最低系统、长期驻留和真实模型质量 | 现有合成及历史实机资格按各自版本保留。 | 最低系统实际启动、8 小时含睡眠、实际屏幕首次呈现、20 个质量样例分别附条件与结果。|

模型与竞品核对日期为 2026-11-26。OpenAI 建议一般任务从 Sol medium 评估，复杂工程、视觉和简单重复工作分别评估 Astra、Terra 和 Luna。Raycast 的逐次顺序粘贴与 Alfred 的追加合并拥有不同的用户动作。本项目本次剪贴板验收采用选定多条、核对顺序、一次插入的合同。[OpenAI](https://developers.openai.com/api/docs/guides/deployment-checklist) · [Raycast](https://manual.raycast.com/clipboard-history) · [Alfred](https://www.alfredapp.com/help/features/clipboard/)
