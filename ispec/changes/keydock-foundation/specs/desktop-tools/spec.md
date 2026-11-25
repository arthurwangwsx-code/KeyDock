## ADDED Requirements

### Requirement: 桌面工作区定义与批量布局
系统 SHALL 提供独立、版本化的桌面工作区定义，并将配置管理、调用时窗口冻结和批量布局执行分开验收。每工作区1–8个有序应用目标、最多32个定义／1MiB；持久字段不得包含PID、AX对象、窗口标题或选区正文。

#### Scenario: 定义编辑与持久化
- **WHEN** 用户新建或编辑工作区名称、应用、布局及显示策略
- **THEN** 系统验证重复应用／行ID、预算与已知策略，独立保存并仅实际更改时递增revision；保存本身不启动应用或移动窗口

#### Scenario: 过期或未改动的编辑
- **WHEN** 编辑期间定义已更新、移除，或未改内容但磁盘文件／目录身份发生变化
- **THEN** 保存拒绝并保留草稿，不覆盖新版本、不复活已删定义，也不将未经磁盘核对的无变化保存报告为成功

#### Scenario: 不支持或恢复中的档案
- **WHEN** 独立档案包含未知schema／策略、损坏或未知事务残留
- **THEN** 原文件保留并停写，不静默降级或重置；旧版基础配置保存不会丢失该档案，另一档案的残留不污染本档案

#### Scenario: 独立工作区执行快捷键
- **WHEN** 用户绑定保存的profile，或定义失效后触发旧profile快捷键
- **THEN** 有效目标走宿主策略约束的直接入口，注册／文件写入失败补偿旧方案；无效目标显示设置失败，不回退Launcher捕获选区，删除仍受引用阻止

#### Scenario: 完整工作区执行
- **WHEN** 用户主动应用已保存工作区
- **THEN** 系统在布局写入前统一预检并冻结全部目标，逐项校验焦点交接、身份与屏幕拓扑，保留已确认／未执行／unknown事实；取消等待子任务收口，重启不重放（实现／合成与任务20.4真实系统验收分开记录）

#### Scenario: 显式后台应用准备
- **WHEN** 工作区全量预检通过且冻结策略允许启动缺失应用
- **THEN** 系统只提交一次不激活的后台请求，候选实例经目录修订／唯一性／PID及启动时间与取消围栏重验后才就绪；取消或期限后保留已提交事实，迟到回调不升级结果、不重试或改绑

#### Scenario: 有序父子回执恢复
- **WHEN** 父调用中断而部分子步骤已确认或未知
- **THEN** 系统在裁剪前保留恢复family的已知事实，按独立父manifest与子context还原条目顺序／阶段，不保存PID／路径／AX／frame，不从可变定义或缺失child回执推断未执行，也不自动重放

#### Scenario: 工作区子步骤关联失效
- **WHEN** 新子intent引用缺失、普通或已结束的父回执，或条目索引／ID与manifest不符
- **THEN** 系统拒绝写入和后续派发；历史已裁剪父的孤立事实允许读取，但不能授权继续旧调用

#### Scenario: 等待旧调用期间的用户干预
- **WHEN** 上一轮原生worker仍在排水，用户短暂切换第三方应用再返回或显示拓扑发生变化
- **THEN** 新调用在等待前建立的源焦点session与屏幕快照永久失效，不通过事后采样或重选恢复授权

#### Scenario: 确认结果后回执写入失败
- **WHEN** 原生阶段已经确认，但child或parent结果持久化失败
- **THEN** 内存保留确认并标记receiptUncertain，停止后续派发；父有序结果不依赖child保留周期，旧历史快照不能覆盖本进程结果

### Requirement: 应用与窗口切换
系统 SHALL 提供应用启动与窗口搜索/切换，窗口 identity 不得仅为 PID，AX 权限不足时保留可用的应用级路径。

#### Scenario: 同一应用多个窗口
- **WHEN** 用户选择某一窗口且同进程还有其他窗口
- **THEN** 系统按窗口身份解析并激活所选目标；目标失效则明确报告

#### Scenario: 应用目录变化
- **WHEN** 已索引目录内安装、移动或删除应用，或目录被移除后重新创建
- **THEN** 系统在后台重新扫描并更新已有查询，不阻塞启动台，也不重置别名、收藏和用户输入

#### Scenario: 同路径替换应用
- **WHEN** 用户选中的应用被另一对象替换，且新扫描已发布同路径的新条目
- **THEN** 旧动作不能借用新缓存的身份启动替换对象；激活请求必须绑定选择时的对象修订

#### Scenario: 卷观察准备与停止重入
- **WHEN** 应用目录的卷通知中心或目录监听准备缓慢、准备失败，或准备期间停止后重启
- **THEN** 系统准备和清理不在启动台主线程片段执行，旧代次与排队通知不能刷新新实例；目录准备失败仍保留卷通知恢复通道，观察准备完成后才扫描以覆盖安装窗口；现有100ms响应断言保持不变

### Requirement: 结构化 CLI
系统 MUST 区分 executable/argv、显式 shell 和交互终端，提供退出状态、输出上限、超时与取消。

#### Scenario: 参数含 shell 元字符
- **WHEN** 用户在 argv 模式传入含空格或元字符的参数
- **THEN** 参数按单独 argv 传递，不隐式交由 shell 展开

#### Scenario: 取消命令
- **WHEN** 用户取消仍在运行的命令
- **THEN** 系统停止后续派发并按适配器管理进程生命周期，显示取消/已发生副作用，不伪报成功

#### Scenario: 终端交接未确认
- **WHEN** 系统已收到终端打开请求但未在有界时间内确认
- **THEN** 系统展示结果未知并保留可能仍被打开的脚本；提交后不提供虚假的撤回，不自动重试，退出不无限等待，迟到回调不覆盖终态

### Requirement: 剪贴板敏感过滤与清理
系统 MUST 在读取正文前检查敏感类型，支持启停、排除、TTL、容量限制和清除。

#### Scenario: Concealed 文本
- **WHEN** pasteboard 变化且带有 concealed 或 transient 标记
- **THEN** 系统跳过正文读取与历史索引，不将内容写入日志

#### Scenario: 固定条目占满容量
- **WHEN** 新条目无法与现有固定条目共同满足条数或正文容量上限
- **THEN** 系统拒收该条并明确说明，保留已有历史；重复正文仍可刷新，不消耗新容量

#### Scenario: 剪贴板事务失败
- **WHEN** 接纳新条目所需的写入或旧条目逐出失败
- **THEN** 整笔操作回滚，不留下半笔写入或误删旧历史，不伪报采集成功

#### Scenario: 暂停与恢复采集
- **WHEN** 用户暂停采集或系统会话挂起后恢复
- **THEN** 暂停期间不读正文，不补采被跳过的变化；停止后的排队轮询也不读取正文

### Requirement: 会话预算与历史清除
P1 系统 MUST 对 CLI/AI 管理任务、会话正文和最小回执施加总预算，保护活跃/可见对象并提供有明确结果的历史清除；清除不能自动重放或声称停止用户终端命令。

#### Scenario: 超过并发与会话预算
- **WHEN** 用户发起第九个管理任务，或新输入无法在总预算内与受保护对象共同保留
- **THEN** 系统在网络/进程/交接前拒绝，显示原因，保留既有输入和有效结果，不让同步窗口回调绕过槽位

#### Scenario: 清除与编辑或恢复交错
- **WHEN** 用户确认清除已结束历史，而任务仍在落盘收口、草稿随后编辑或旧恢复快照迟到
- **THEN** 系统保留收口任务与新编辑，不恢复已清记录，分别报告存储失败，移除成功清除对象的正文与窗口引用

### Requirement: 独立剪贴板快捷面板

系统 MUST 通过可配置全局快捷键、启动台和菜单栏打开独立的剪贴板面板，支持搜索、方向键选择、完整预览、复制及向原应用插入纯文本。

#### Scenario: 键盘查询与插入
- **WHEN** 用户从其他应用打开历史面板、输入查询并按方向键和Return
- **THEN** 面板保持输入焦点、同步选中项与预览，并只在用户主动提交后读取当前有效条目的完整正文进行插入

#### Scenario: 原输入目标变化
- **WHEN** 异步加载期间面板关闭、查询或选择改变，或原进程、窗口、焦点、选区、权限在插入前变化
- **THEN** 旧操作不写剪贴板或发送粘贴事件，不向新目标插入；无权限时保留明确的复制路径，不报告插入成功

#### Scenario: 单次插入与剪贴板竞争
- **WHEN** 用户明确插入选中历史正文
- **THEN** 系统将纯文本留在当前剪贴板，以瞬态类型避免再次采集，不读取或恢复此前个人剪贴板正文；若写入后有其他写者或目标变化，则拒绝发送粘贴事件，已发送的事件不自动重放

### Requirement: 有序剪贴板合并与统一主动作

系统 MUST 将用户明确勾选的最多20项历史按选择顺序组成单份纯文本，包含分隔符最多1MiB。选择与搜索游标分离，完整预览、复制和插入使用相同顺序；插入只沿用一次既有目标校验事务，不逐项发送粘贴事件。

#### Scenario: 跨查询选择与重排
- **WHEN** 用户勾选条目后改变查询、移动游标或重新排列合并清单
- **THEN** 清单不被搜索刷新静默删除，顺序可见且可调整，预览只保留一份合并正文；重排、查询或偏好改变撤销旧提交

#### Scenario: 合并成员失效或超过预算
- **WHEN** 同一批量快照内有条目删除／过期、重复ID，或UTF8正文连同分隔符超过1MiB
- **THEN** 整批停止，不复制部分条目、不截断正文、不发送插入事件，保留清单并明确提示

#### Scenario: 合并正文提交前改变
- **WHEN** 用户已预览的合并正文与提交时重新读取的快照不同
- **THEN** 系统只更新预览并要求用户重新查看及主动提交，不能将未展示的新正文直接写入剪贴板或输入目标

#### Scenario: 可配置主动作与复制失败
- **WHEN** 用户在设置选择Return为复制或插入，并通过搜索框、Command-Return、原生菜单或底栏操作
- **THEN** 主动作与替代动作解析一致，不自动开启采集；复制失败留在面板并明确说明，不能无条件关闭或报告成功

### Requirement: 可发现的全局动作定制

系统 SHALL 在设置中提供剪贴板、窗口布局、应用和其他常用动作的快捷键与别名入口，保留冲突／保存失败的整套事务与原配置。

#### Scenario: 不搜索也能找到窗口动作
- **WHEN** 用户进入快捷键设置并选择窗口类别
- **THEN** 所有窗口布局动作显示且可录制、清除快捷键和设置搜索别名；应用类别可查询应用并绑定稳定应用身份

### Requirement: 不读取正文的直接桌面动作

系统 MUST 为窗口循环、最小化、布局和用户保存的应用行为提供稳定命令与直接快捷键路由；不先展示Launcher或读取选区正文。

#### Scenario: 三窗口连续循环
- **WHEN** 同一应用有A、B、C三个窗口且系统在raise后改变AXWindows排序
- **THEN** 已冻结的循环仍按A→B→C→A进行，只有焦点读回确认才推进cursor，旧nonce回执不能改变新基线

#### Scenario: 显式应用行为与正常退出
- **WHEN** 用户为精确命名应用配置显示、隐藏、前台切换或正常退出动作
- **THEN** 行为分支在发起时冻结，权限效果由代码声明，缺失或歧义目标不被按名称重绑；退出只发正常terminate并保留保存提示，未观察退出不能报告退出完成

#### Scenario: 迟到准备与用户切换
- **WHEN** 准备／后台启动期间用户切到第三个应用、修改动作、取消或打开新入口
- **THEN** 旧请求不迟到抢回焦点或变更新目标；已经请求的副作用保留未知事实，重启和回执失败都不自动重放

#### Scenario: 应用动作配置与旧版回退
- **WHEN** 用户保存应用动作后回退到不认识该功能的旧App并保存其设置
- **THEN** 新动作独立存储保持原样，旧版不能在重写基础配置时无声丢弃；存储损坏时保护原文件并禁用该模块写入

### Requirement: 窗口布局恢复
P2 系统 SHALL 按窗口保存恢复 frame，并处理屏幕变化和目标最小尺寸。

#### Scenario: 外接屏移除
- **WHEN** 恢复布局时原屏幕已断开
- **THEN** 系统将 frame 合理限制在现有屏幕可见范围，不复用其他窗口记录

### Requirement: 用户触发截图与 OCR
P3 系统 SHALL 在用户选择范围并满足屏幕权限后获取截图，OCR 输出可进入明确选定的 AIAction。

#### Scenario: 无屏幕录制权限
- **WHEN** 用户未授权截图但仍使用窗口标题搜索
- **THEN** 标题搜索的可用性只按其所需权限判断，不被截图权限连带阻止

### Requirement: Safe workflow and schedule ownership

The host MUST compile typed workflow steps against a frozen reference snapshot, preserve child receipts while their parent runs, and claim each scheduled attempt durably before dispatch.

#### Scenario: Dynamic command input

- **WHEN** a whole argv argument is bound to workflow input
- **THEN** the complete resolved command needs one user approval, shell syntax remains literal, and unattended execution is rejected.

#### Scenario: Scheduled references change

- **WHEN** a workflow, referenced command or AI target differs from the approved fingerprint
- **THEN** its schedule pauses before dispatch and requires new review; unknown attempts are never replayed.

### Requirement: Explicit bounded local context

The application MUST limit OCR/document input and search only explicitly chosen file-name roots without reading file bodies; file reveal must revalidate the current root and target identity.

#### Scenario: Removed scope or changed file

- **WHEN** a cached result is selected after its allowed root or file identity changes
- **THEN** Finder reveal fails closed and the user is asked to search again.

#### Scenario: Clear a context preview

- **WHEN** an import is pending and the user clears the preview
- **THEN** late extraction cannot repopulate it and no AI request is made.

### Requirement: Optional local activity analysis

Statistics MUST default off, store only bounded metadata, preserve explicit coverage and offer pause, clear and aggregate export independently from AI usage.

#### Scenario: Pause and clear

- **WHEN** the user pauses or clears activity recording
- **THEN** queued older events do not backfill the cleared interval and raw text never enters the report.
## 发行系统资格与云端分层

### Requirement: 生产OCR资格绑定发行源

系统 MUST 区分云端core检查与Vision系统能力；发行必须有同一干净SHA的生产OCR实际识别资格，并绑定完整检查与指定core CI。

#### Scenario: 完整本机资格才能进入分发
- **GIVEN** 本机运行完整测试和生产OCR配置，独立进程及重复识别合成PNG均成功
- **WHEN** 构建、打包、复用既有DIST、发布或回下载新格式发行
- **THEN** 核对源SHA、version/build、模式、清单、实际结果、图片与日志摘要、App资格摘要和指定同源push core CI；缺失或不符则拒绝

#### Scenario: 云端OCR未获资格
- **GIVEN** 云端core检查不运行系统OCR资格用例
- **WHEN** 生成检查summary
- **THEN** 显示NOT_QUALIFIED，精确清单覆盖其余core与Terminal分区，不能据此单独授权发行或改写已有VM失败

#### Scenario: 构建磁盘空间不足
- **GIVEN** 工程所在卷可用空间少于2GiB
- **WHEN** 执行统一check或build
- **THEN** 编译前报告空间不足，check记录失败且不生成该次资格；不自动删除源码、发行资产或用户内容
