# 桌面工作区应用准备与回执复查

2026-11-25，继续任务20.3，root为唯一代码／Git／设备写入者，两名子Agent只读审查。前轮执行内核之后，本轮完成独立应用准备服务和有序父子回执元数据。**完整工作区组合执行、逐项结果UI及profile快捷键仍未接通**，任务20.2／20.3／20.4继续未关闭。随后alpha.8已完成同源发行与安装，见[独立发行证据](alpha8-release-2026-11-25.md)。

## 应用准备

`DesktopApplicationPreparationService`不调用会激活应用的旧perform入口。inspect／inspectWorkspace固定目录revision、缺失策略、初始实例、service owner及调用fence，全量准备后统一复核。要求已运行的缺失应用、多实例、重复进程、目录变化、原running退出或原absent外部启动均在本层拒绝，不悄悄改变策略。

显式允许后台启动时，ensureRunning只消费一次计划及fresh lease，标记launch提交后发一次后台请求。原生配置禁止自动激活、提示、跨URL实例替代、新实例和Recent Items；回调只转成候选PID／启动时间，重验目录／精确路径／唯一性和最终取消围栏后才返回Ready。原来的单应用perform及其launch gate保持行为；唯一实例查询等价抽出共用resolver。

launchFact分别为notSubmitted／submittedUnconfirmed／confirmedReady。确认后再出现其他条目失败，不降级前项事实；取消／期限后不发布Ready或接纳迟到回调。三秒是提交API排队后的回调观测期限，不能声称撤销了原生启动。应用自行激活同样撤销fence，不授权全部计划应用。Ready只证明进程身份，后续无窗口时仍须保留启动事实，不自动重试／退出／Cmd+N／选择第一窗口。

## 回执与恢复

InvocationReceipt增加可选、无正文的父manifest和子context，旧归档仍能解码。父只存workspace UUID、revision及1–8个有序条目UUID；子只存父UUID、条目UUID、0–7索引和launch／focus／layout阶段。它们不随通用interrupted message被覆盖，不从后续编辑的定义猜顺序；没有PID、AX、frame、标题或应用路径。

新子intent只接纳仍在运行、带对应manifest的父记录；缺失、普通CLI、已结束父及索引／ID错配均拒绝。历史孤立子事实仍可读取，不能因此创建新旧调用。新前缀进入liveParentIDs与保护逻辑，重启时先扩展恢复family保护，再执行prune：未知父的已确认child、未知child的已知父和兄弟事实都保留到恢复快照消费。无child回执不等于未执行，组合根仍须完成每项派发与收口协议。

## 审查与修补

审查补齐了末次实例查询期间撤销授权却仍返回Ready的竞争：inspect、两种revalidate及ensureRunning的已运行／启动分支均在最终查询之后检查fence，执行分支同时检查lease。另一项关联缺口是已存在普通父也能接受工作区child；现已要求manifest及active状态，并保留历史缺失父的只读事实。

测试数据全部为内存应用／屏幕／回调和独占临时回执文件。测试只传递合成PID与时间戳，不解析真实应用或执行NSWorkspace启动；没有个人剪贴板／窗口／凭据／外部API。参考合同见[技术方案](../technical/desktop-workspaces.md)。

## 验证

| 测量 | 结果 | 范围 |
|---|---|---|
| `beee0ef4-6056-4798-a522-032c074ddae3` | PASS | 71 tests／7 suites，96.860s；应用准备、取消／回调、焦点／布局和旧回执容量回归 |
| `57e41158-db5a-4f92-b329-9c844efaf0d0` | PASS | 73 tests／7 suites，134.340s；父manifest、条目顺序及三种parent前缀保护 |
| `422f17f1-97a3-4bdf-8cba-aed62fb20456` | PASS | 77 tests／7 suites，46.083s；并发回调／期限、末次查询取消、active typed parent及历史孤立事实 |
| `c643f20e-57f2-40ff-a8b8-3c478ee728a8` | PASS | 干净8c2c600完整本机native-system，601 Swift／46 Python／660 key，301.254s，含原生产OCR双轮 |

计数采用两个测试进程的Swift Testing test-run结果求和，参数化case另列日志；没有把所有case当成独立声明。上述三轮没有编译失败或弱化断言，所有测量与日志保留。

开始时可用空间约1.14GiB，随后外部空间状态恢复到100GiB以上。本轮没有删除缓存、发行、安装回退或其他项目文件，也没有修改OS服务／TCC。原2GiB完整检查门禁保持不变；空间恢复不是OCR恢复证据，原生产模式与双轮180秒资格仍以实际结果为准。

干净源`8c2c60063303fa218b9803257d8a66441b1d6cb7`完整检查于2026-11-25T00:32:39Z–00:37:40Z通过；原accurate／revision3／自动语言／纠正／支持CPU配置的OCR两轮分别约107.875s和0.460s匹配，未改配置、图片、断言或180s门禁。资格summary SHA256 `9b8d9c92c8e2f15294ba7d50c8843b9515d177bb6c679e5238427328444fa7d5`，8份原始stage日志摘要／字节数均核对。首次长耗时与此前FAIL保留，不能据这次PASS认定唯一根因或长期稳定性。

[同源CI 45518861646](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45518861646)及job `138885286276`PASS：600 Swift／46 Python／660 key，Release优化Preview、归档及上传通过，云端OCR NOT_QUALIFIED。回下载artifact `14978983810`（84,751字节，SHA256 `797aeea86007cd0b657bc8209b14db687da89ef4001e99dc39e2ad18c5840928`），核对clean source与7份stage日志。清单580个声明ID（core570／Terminal9／OCR1），SHA256 `ddba92550532f0d16d878d50bf362746009882dd383b3da8e4621dfb7258426f`；执行数包含参数化。安装／公证／发行以随后独立证据为准。

下一段是运行组合根：先保护父intent并核验全部既有窗口，再执行允许的缺失应用准备；全窗口冻结／统一复核后逐项focus／layout，保证每个child的intent先于原生请求、取消等待真实worker，分别保留confirmed／unexecuted／unknown及receiptUncertain。接通总任务槽位、定义变化／新入口取消、profile目录与快捷键后再做原生入口和真实AX／多屏验收。此段尚未实现，不用本轮绿测代替。
