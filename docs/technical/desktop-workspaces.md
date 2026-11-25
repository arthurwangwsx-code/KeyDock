# 桌面工作区建设方案

这是原窗口域“工作区”能力的实现合同。alpha.8已提供独立定义管理，支持命名、有序应用／布局／屏幕策略和修订。后续alpha.9候选已接通组合执行、逐项结果和profile快捷键；真实AX／多屏与完整系统资格仍待验收。alpha.7不含这项增量。任务Workspace、命令集合和桌面工作区分别承担任务、单项入口与窗口组合职责。

## 产品与持久定义

支持命名工作区，例如浏览器左侧、编辑器右侧。定义档案schema1、最多32个工作区／1MiB，每项1–8个有序应用目标、首版每应用一项；名称最多160 UTF8字节。选择器明确为“调用时该应用报告的焦点窗口”；不持久化PID、AX引用、窗口哈希或隐式采集的标题。独立UUID进入未来的执行目录／快捷键，定义管理阶段仅开放管理入口。多窗口选择器后续扩展，不通过应用路径、数组第一项或窗口标题假装稳定指向某窗口。

定义采用独立版本化存储，包含修订、稳定应用引用、有序布局、显示器策略和缺失应用策略。默认要求应用已运行；允许后台启动为显式选项，其启动本身是副作用。旧版重写基础configuration不能丢失独立定义。编辑／删除和快捷键注册必须可回滚，运行不修改保存定义。

当前定义实现采用`DesktopWorkspaceArchive`与`desktop-workspaces.json`。应用引用只做绝对／规范路径词法检查，不解析磁盘或符号链接，不全路径转小写；加载时保留语法有效但当前不可用的引用。新目标须从当前应用目录选择。布局限半屏／四角／最大化／居中，显示策略为调用屏幕／原窗口屏幕／主屏幕；不保存临时显示器编号，restore／nextDisplay／previousDisplay不作为工作区行布局。

新建revision1；实际更改才递增，保存绑定expectedRevision，旧编辑不能覆盖新版本或复活删除项。无变化保存不写候选、不增版本，但仍核对目录身份与原文件快照；外部替换、删除或目录漂移使其只读并保留草稿。未知schema／枚举、损坏、符号链接或未知事务残留不自动重置。

`PrivateArchiveStore<Value>`复用原ApplicationActionStore的dirfd／原子交换／fsync／补偿／未知内容保护；旧公开类型名通过typealias保留，旧文件名、前缀与codec不变。新档案有独立文件名和残留前缀，各自隔离未知恢复残留，互不改写对方数据。字节超预算在创建候选前拒绝，不误报回滚失败。当前删除遇到已保存快捷键、别名、收藏或集合引用会拒绝；执行接通时仍须完成跨档案的快捷键生命周期收口，不能宣称已具备跨文件原子事务。

## 两阶段执行

1. 核对全部应用目录身份、唯一运行实例和显示器规则；只读捕获每项当前窗口，不读取标题／选区。默认缺失、多实例不明确或无可核对窗口时在布局前拒绝。
2. 若明确允许启动，先记录启动child intent，有界后台准备应用并返回PID＋启动时间；不激活、不发Cmd+N、不选第一窗口。准备失败保留已启动事实，不能声称零副作用。
3. 全部目标就绪后冻结窗口对象、原frame、目标frame、显示拓扑及计划指纹，再做批次复核。实际对象比较使用CFEqual，不能用窗口哈希替代身份。
4. 逐项核对预期源→目标应用的焦点交接，raise原冻结窗口并读回确认；布局写入只消费已冻结计划，不重新捕获另一窗口或在断屏后悄悄重算。
5. 父租约撤销全部fresh child lease并等待worker收口；第三方抢焦点、新入口、定义变化和取消撤销计划。保留已确认、未执行及unknown各项事实，不承诺桌面原子回滚或自动重试。

显示器策略可覆盖调用屏幕、各窗口原屏幕和主屏幕。指定显示器需增加可持久标识适配并验证重启／插拔；不能保存临时NSScreenNumber。断屏默认停止；允许回退时重新形成可审阅计划。

## 现有接缝与必须补齐的边界

ApplicationCatalog已有目录身份和validatedURL；captureWindowTarget(identity:)可以捕获无标题窗口元数据。DesktopService.windows()读取窗口标题且缓存可变，不用于批次预检。WindowLayoutController已经拆出prepare／revalidate／applyPrepared；原单窗口入口也使用相同计划内核，保持原激活授权guard。

`WindowDisplaySnapshot`冻结controller身份、拓扑代次及全部可见区域；`PreparedWindowLayout`冻结原AX对象、原frame和目标frame，只能消费一次，失败后新lease也不能重放。`prepareWorkspaceWindows`在同一屏幕快照上准备1–8项并统一复核，拒绝重复进程／窗口、失效屏幕和不明确的调用屏幕；准备阶段不激活、布局或更改Restore基线。当前不持久化显示器编号，也不从当前键盘焦点屏幕猜测指定的调用屏幕。

Restore缓存改用PID／启动时间和CFEqual驻留UUID，不依赖CFHash身份；旧Restore计划绑定基线operation nonce，不能清掉后续建立的新基线。首个frame系统请求前标记独立witness，确定零frame提交的失败只撤回自己的候选基线；部分提交保留。应用激活的lease.didSubmit不能代替frame提交证据。

原生显示变更通知增加代次；即使拓扑几何随后相同，旧计划仍失效。worker每步检查代次、进程、权限和lease，返回后再次检查；取消会撤销写lease并等待真实worker返回。主屏幕规则使用screens首项，区别于当前键盘焦点所在屏幕，依据[Apple screens文档](https://developer.apple.com/documentation/appkit/nsscreen/screens)；变更观察依据[Apple通知文档](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification)。这两项是接口合同依据，未代替本机断屏验收。

DesktopApplicationFocus仍仅允许KeyDock→目标或目标已前台。新增`WorkspaceWindowFocusController`与`DesktopWorkspaceFocusSession`专用于批次，未放宽原全局guard。fence仅按PID＋非空启动时间许可holding(A)→crossing(A,B)→holding(B)，观察到B后A也不能再放行；第三方／未知进程事件永久撤销，B的迟到通知不能恢复。只读验证等待期间仍holding源，确认后同一MainActor片段才arm／activate。raise与focused-window setter使用原冻结对象，setter正负返回都必须CFEqual读回；最终读回后不再等待另一轮membership验证。

session持续覆盖准备／步骤间隙／布局／worker收口，显式close或释放均撤销fence；原生通知同步推进围栏，不能延迟到Task里再处理。`DesktopOperationGroup`原子封闭新child注册并撤销已有lease，保留pending计数，真实worker完成后才release；group本身不假装等待worker。预取消也进入取消处理器。上述内核已有合成回归，但尚未接入工作区执行组合根。

应用准备现由独立`DesktopApplicationPreparationService`承担。`inspectWorkspace`冻结全部目录修订、缺失策略、唯一运行实例及同一fence，并在全量检查后统一复核；原running变为absent或原absent已被外部启动均拒绝旧计划，不改变策略或重新绑定。`PreparedDesktopApplication`按service／调用围栏绑定且只能claim一次，`ReadyDesktopApplication`只表示身份就绪，不代表窗口已准备或布局成功。原`ApplicationControlService.perform`保持行为与启动gate，共享的唯一实例查询只做等价提取。

`ensureRunning`只有冻结策略允许缺失启动时才提交一次请求。原生配置为activates=false、promptsUserIfNeeded=false、allowsRunningApplicationSubstitution=false，不创建第二实例、不添加Recent Items。回调转为Sendable候选身份，返回Ready前重新核对目录／精确路径／唯一实例及最终fence／lease。参考[Apple异步启动合同](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:))及[activates](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/activates)，回调线程不直接改UI或继续执行。

每个计划保留notSubmitted／submittedUnconfirmed／confirmedReady事实；最后一种仅表示请求后候选实例已重新核验，不声称由本次请求独占创建。同步／重复／并发回调与期限由一次性gate收口。取消立即撤销授权，已提交请求仍等待回调或三秒观测期限；迟到候选不能恢复执行或升级事实。应用自行抢焦点也会停止，不把计划内全部应用加入豁免。

`InvocationStore`已支持精确前缀keydock.desktop-workspace-run.<parentUUID>、父`DesktopWorkspaceRunContext`和子`DesktopWorkspaceReceiptContext`。父保存workspace UUID／revision及1–8个有序条目UUID，子保存parent UUID／entry UUID／0–7索引／launch、focus或layout；这些字段独立于恢复时会替换的message，不保存PID／路径／frame／AX。旧档案无需新字段；错误索引、未知阶段、关联不符或parent／child双重context会拒绝且保留原文件。

新子回执必须关联仍在运行、含对应manifest的父回执，条目ID与索引一致；缺失父、普通CLI父和已结束父均不能产生新子intent。历史已裁剪的孤立子事实允许只读恢复，不能用它继续旧调用。初始化在prune之前保护恢复中的父／子／兄弟事实，避免先裁掉已确认项；消费恢复快照前不解除保护。运行中的child依既有liveParentIDs原子保护，所有worker与回执收口后宿主再释放parent。缺少回执不能从可变定义推断为未执行。组合根的durable intent→单次原生派发→结果落盘及逐项partial汇总仍需接通。

## 验收与状态

实施按可验证边界串行推进：

1. 纯定义／Archive、独立`desktop-workspaces.json`与设置编辑器已经接入，原存储字节内核已抽取并保留wrapper与故障回归。中文浅色／英文深色的添加、重排、保存重开、校验失败保留及取消已观察；完整验证证据见[定义管理复查](../implementation/desktop-workspace-definitions-2026-11-25.md)。
2. 当前仅贡献`utility.desktop-workspaces`管理入口，归入窗口管理快捷键分类。profile不进入执行catalog，setShortcut拒绝新执行绑定，ShortcutPlan过滤此阶段不受支持的profile配置项；管理快捷键直接打开设置，不读取选区。
3. 冻结布局／全目标窗口复核、专用焦点交接和child撤销内核已实现；独立应用准备与父子回执存储后续接入，77项定向回归通过，见[准备与回执复查](../implementation/desktop-workspace-preparation-2026-11-25.md)。运行组合根、逐项汇总及profile快捷键仍待串联，完整接通后再开放执行目录。定义管理或内核合成通过不能代替20.3完整执行或20.4真实系统验收。

需覆盖应用替换／多实例、同App换窗口不重绑、全部冻结后再写、第二项失败保留第一项事实、第三方焦点变化、屏幕变化、取消与worker drain、启动／布局unknown重启不重放，以及存储／快捷键回滚。

模型、编辑器和合成端口可先独立推进；真实AX／多屏／快捷键必须另做当前Mac验收。本轮正式App仍显示AX未授权，不代授予。此方案不改变OCR或发行门禁，任务20仍需实现与验证；自定义动作删除和Agent／工作流保存反馈另在任务21跟踪。

## 组合执行接通（alpha.9候选）

DesktopWorkspaceRunner共用可注入端口和NativeDesktopWorkspaceRun适配。父intent及每个launch／focus／layout child intent均写入同一InvocationStore后才派发。父占一个活跃任务槽，child不另占UI槽；取消同步撤销group，真实worker与回执结束后才释放handle／父保护。FocusSession和拓扑快照先于旧worker drain建立，调用源屏幕在等待前只读冻结；原生运行复用同一session／snapshot，第三方短暂激活和拓扑代次变化也停止，不事后重选。

先完成AX／显示器检查、全部应用inspect与全部已运行窗口prepare，再允许显式后台启动。缺失应用的初始窗口只在有界准备期观测，不发送Cmd+N、选第一窗口或冻结后改绑。全部准备好后统一复核。工作区布局逐次检查原冻结焦点窗口，单项入口默认合同不变。

父回执新增可选DesktopWorkspaceRunResult，保存有序阶段枚举，不记录应用名称／PID／路径／窗口元数据。已确认结果与receiptUncertain分离，finish失败不会降为unknown；后续步骤停止。恢复先聚合父子再套历史预算，缺失child为unrecorded，不能推断notExecuted；旧快照不能覆盖本进程已确认结果。当前任务的应用显示名仅由调用目录冻结在内存，最多每项256字节，不写回执；恢复按有序编号显示。

profile贡献真实descriptor／catalog，支持Launcher、设置应用与直接快捷键。失效热键按前缀拒绝并打开设置，不读取选区。快捷键复用既有注册／文件补偿；删除仍要求先移除快捷键／别名／收藏／集合引用。成功修改才取消对应旧运行，保存失败保留它。运行中设置提供Stop并禁用View result；仅隔离Preview提供进程内结果样例，不写回执或触发系统操作。

本节更新当前候选状态，前面尚待接通的文字保留为alpha.8阶段记录，不代表该发行版本具备新执行器。检查见[本轮复查](../implementation/desktop-workspace-execution-2026-11-25.md)。

别名清空通过候选配置事务真正移除key，纯空白同样处理；非空保留原文。写前／写后失败保留旧内存与原文件，删除仍受有效引用阻止；历史blank不算有效引用。该修补不引入跨档案原子删除承诺。
