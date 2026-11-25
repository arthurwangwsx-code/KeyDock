# 类型化任务恢复Core复查

本轮承接任务33.1，基线master `64e7739f4d03317a4e4eff96fa8056753cd3986f`，主Agent在唯一canonical checkout的`feature/task-attempt-recovery`串行修改。三位Agent只读审查执行、AI合同和生产入口；未复制AiBox源码、个人历史或凭据。产品仍PARTIAL，当前正式App／发行仍为alpha.18。

## 实现与边界

- `InvocationStore`同一actor／文件新增typed查询及CAS。来源revision递增、新UUID intent、logicalRunID／recoveryOf和当前定义引用同一原子写入，无第二份效果真值或第二份200项预算。
- 记录出生身份及actor绑定的worker stamp防止删除后同ID重建被旧finish／abandon／release操作；typed记录拒绝缺stamp调用，旧格式仍保留原兼容入口。
- 同一来源双提交只成功一个；终态但worker未drain及同逻辑组活动任务均拒绝新尝试。仅保护活动尝试的直接来源，旧祖先仍受TTL／数量／字节预算约束；缺祖先显示gap，不重新绑定其ID。
- 真实原子写保留beforeWrite／beforeRename／afterRename故障端口。rename后不确定状态拒绝可执行确认；失败返回的undispatchedStamp仅供未派发补偿，不是执行授权。结果终态不因迟到写改写。
- 四类保存定义采用专用v1白名单DTO；Set和environment确定排序，argv／步骤保序，nil／空与Unicode字节、timeout准确位模式均区分。四个固定向量以独立Python编码／SHA-256计算，防止未来哈希合同漂移。
- MCP选中合同严格解析全部名称，包含来源／配置revision、工具名／描述／完整schema／不可信hint；连接generation及catalog.revision排除。流式长度分帧防止tag树膨胀改变生产预算，不读取密钥、不连接服务或产生权限。

独立准备页、四类生产入口的新授权／输入／代次复查、默认仅展示交付及费用关联仍依33.2–33.5；当前App未使用新runDefinition参数，不会生成v2用户记录。含typed字段的Envelope v2由新Core读取；旧alpha.18拒读。正式接线／发行前须补安装／回退数据版本检查和可验证恢复策略，旧二进制备份不能代替数据回退资格。

## 检查与复审

所有本机构建／测试均在共享存储gate的12GiB预算内执行，使用稳定增量缓存。首次gate在全局存储盘点时遇到另一项目`du`的30秒超时，exit2且未启动子编译器；保留`.local/desktop/task-recovery-storage-preflight-v1.log`。随后以相同预算、阈值和正常入口获得`run-18a4c430eca644a4acb46bb9b6fa1296`租约，未修改全局工具／清理其他项目或移除租约。日常200GB目标当时未达成，不作为产品验收。

同一iSpec apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`下串行测量：

| 测量 | 结果 | 回执SHA-256 |
| --- | --- | --- |
| `task-recovery-core-tests-v1` | 60定义／12套件PASS | `49f66a1edb316bb2a16af3dedf3e19b9b2b737e7c5df294ce5a1f734be0bc75a` |
| `task-recovery-core-tests-v2` | 65定义／12套件PASS | `b7a3227ed0489366c7b1bb1b0f8ac328f99807a7e525b222d9e86edf791ae29f` |
| `task-recovery-core-and-fingerprints-v3` | 66 Core＋7指纹定义PASS | `a8eb1b0f0665a991267d5236f1d6de2de5f5e9551e1a1c9efaa125a775a67e04` |
| `task-recovery-contracts-v4` | 66 Core＋8指纹＋5 MCP定义PASS | `e04f84cafda5632246a384e24f4f008d288a1526f47c001d15eb198fee1a1f6b` |
| `task-recovery-contracts-v5` | 66 Core＋8指纹＋6 MCP定义PASS | `60c694bf2a204774e8b9672d934e8aaadba0d749d42569297bb30bdb9b5183f1` |

以上为测试定义数量，参数化测试另有子案例。原始日志在`.local/desktop/`同名`.log`，回执在iSpec change的`receipts/`。v3复审修补typed缺stamp绕口；v5修补静态复审发现的合法大schema投影拒绝，新增测试先用生产ToolJSONSchema确认4×8000个examples可接受，再验证重连合同一致。没有把原未覆盖的绿测称为这些边界已验证。

工程源[`7dc38517175990da4b2ca079cec2db41fcb23728`](https://github.com/arthurwangwsx-code/KeyDock/commit/7dc38517175990da4b2ca079cec2db41fcb23728)已在干净工作区完成统一`check`：834 Swift执行／813测试定义、78 Python、847中英key，生产配置下合成OCR双轮PASS。资格文件`.local/pipeline/20261125T163907658674Z/check-summary.json` SHA-256 `04c648e5e050b8784200a0609171703daa0b8c52f57c428194b716e0ce0fe5cb`，逐日志大小／哈希核对通过；iSpec `task-recovery-full-check-v1`回执SHA-256 `4bcaaa45ddb0bd634114d1641909069f99ae7f264035227b3e557b7efd8789ef`，exit0。

指定相同源的[规划CI 45656266685](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45656266685)及[core CI 45656266583](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45656266583)均success，native job `139353675111`完成833 Swift（不含系统OCR）／78 Python／847 key及Release优化Preview构建。日志artifact `15043437969`已通过GitHub连接器下载并核对：103051 bytes，SHA-256 `63be392845d9bb45f2b4b67b2a9766de2ccef688ec6093f279121fad20021ccf`，21文件／10个exit0阶段，check-summary来源与每条日志哈希一致。原包及`.local/desktop/task-recovery-ci-7dc3851-summary.json`保留，iSpec `task-recovery-ci-proof-v1`回执SHA-256 `7323d3a9a98cf9013630c950f89e4f35f885983bb48c7a52b183f3705b2840a0`。云端OCR仍为NOT_QUALIFIED，不替代本机资格。

本轮声明的测量回执仍按当前attempt核对，快照／审计在`.local/desktop/task-recovery-core-metrics-final-v1.json`及`task-recovery-core-metrics-audit-final-v1.json`。历史unfinished `a17c06c5-0ab4-4750-b2ca-be7f5e2bf4d2`与两条legacy开始记录缺口继续保留，不宣称全局审计完整，不把阶段apply或产品目标标为完成。

未运行本轮原生UI／真实API／AX／Terminal操作或新发行，不升级视觉和日用资格。alpha.18文档提交64e7739的既有[core CI 45648526661](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45648526661)已回查为success，仅属于该提交。

## 后续接线顺序

1. 四类worker将本次begin返回的store／stamp带到finish、abandon和真实drain后的release；不按ID重新猜测所有权。
2. 稳定独立准备呈现、空白有界输入、审阅刷新、双向modal互斥及实际dismiss所有权；准备阶段不读凭据或发现MCP。
3. 新UUID接入原生产admission／intent，异步接纳确认后才关闭准备页；每次await后核对当前定义／配置／contribution／MCP／history代次。新AI交付固定仅展示。
4. 补安装／回退格式检查、生产保存失败零效果及冷启动新尝试回归，再分别执行本机完整检查、原生中英明暗／重启、同源CI和发行资格。原5.5可选正文／checkpoint及P0–P4完整义务不变。
