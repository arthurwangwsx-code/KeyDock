# 后续能力建设与AiBox设计参考

日期：2026-11-24。用户授权继续建设P2–P4全部目标；以下是实现合同，勾选、测试、系统验收和发行分别记录。既有第一阶段未验收项不因扩大范围而取消。

## 产品切片与交付标准

| 能力 | 可交付产品行为 | 必须验证 |
|---|---|---|
| 窗口管理 | 可搜索／绑定快捷键的左右、四角、最大化、居中、跨屏和恢复；作用于唤起前窗口 | 同App多窗口各自恢复、负坐标、最大交集选屏、最小尺寸、断屏clamp、写后读回、权限撤销／目标过期 |
| 使用分析 | 默认关闭的工具内事件；30天趋势、结果分类、耗时、热门命令、暂停、清除与聚合导出 | 不记录正文／argv／标题；启用范围和覆盖率明确；暂停不补采；与AI token账本分离 |
| AI总结 | 用户选择时间范围后将聚合报告送给已配置模型；展示范围、覆盖率和依据 | 无后台发送；原始事件不进prompt；建议只生成可审阅草稿；未知费用保持未知 |
| Agent工作区 | 可配置指令、模型、工具allowlist、步数／时间／输出预算；可见工具进度、逐次批准副作用、取消与显式新尝试 | 工具与策略冻结；schema在调用前校验；迟到批准无效；副作用intent/result先后明确，unknown不重放 |
| 手动工作流 | 版本化、可编辑的保存命令／AI动作／文本变换步骤，引用初始输入或前一步输出；统一任务详情 | 引用预检、冻结在途快照、失败／取消停止后续步骤、总预算、无自动重试副作用 |
| MCP工具 | 用户显式登记来源并连接，发现、启停、冻结工具目录，经同一Broker调用 | 初始化／协议版本／有界分页／错误／超时／取消；来源变化不扩权；annotations不是授权，进程不等于沙箱 |
| 截图与OCR | 用户选图或明确触发区域截图，本地Vision识别，结果进入指定AI草稿 | 像素／字节限制、用户取消、无权限失败、无默认历史、不在prompt暴露绝对路径 |
| 附件与上下文 | 明确选择、来源可见、可移除、请求前预算检查；文本先行，图片只在Provider明确支持时发送 | 关闭草稿释放附件；无自动目录／屏幕扫描；不声称未实现的多模态能力 |
| 调度 | 用户启用的App运行期间interval／daily计划；睡眠后合并漏跑，记录计划点与attempt | 禁用／编辑generation、同计划点只派发一次、unknown不重放、后台不弹审批；App退出时不假称仍运行 |
| 常用工具 | Snippets、文件名搜索、计算／转换、URL动作与用户工作区按统一命令贡献 | 输入有界、无shell求值、只搜索用户选定目录、只按明确动作复制／打开 |
| 扩展与CLI Agent | 版本化可信贡献目录，外部CLI可作为已保存命令运行；ACP独立adapter评估 | 禁用不进入新运行、现有运行冻结版本；不将普通Process伪装PTY或ACP；真实协议未实现不得显示已支持 |
| 发行与更新 | 所有新增能力进入同一构建／签名公证／安装回退／GitHub资产流水线 | source SHA与版本一致、保留前版、系统权限和真实模型独立验收 |

## 架构与单一真值

继续使用原生模块化单体：CommandCore保存目录与纯几何；MacAdapters承载AX／Vision／系统文件选择；AICore承载Provider；AgentCore承载冻结工具回路与审批端口；新增AutomationCore承载纯工作流和工具内统计，MCPAdapters承载MCP。WorkbenchFeature负责界面与宿主装配，App保持窗口／菜单组合根。

CLI、AI、Agent、Workflow均投影到现有 `WorkbenchModel.tasks` 和最小InvocationStore回执；ActivityLedger只存统计事件，不成为第二任务库。工作流定义、Agent定义与运行实例分离。定义编辑不改变已启动实例。失败、取消或unknown不自动重新执行；用户明确发起新attempt时重新检查当前配置与权限。

用户主动调用、保存快捷键和Agent授权分开。既有P1只读Broker继续保持只读；新增受限Broker仅接受宿主构造的工具、冻结资源范围和真实审批结果。模型JSON无法构造PolicyGrant。副作用批准绑定run／call／工具版本／资源，不授权下一次调用。普通同用户进程仍有宿主权限，此设计不是OS沙箱。

## AiBox可借鉴内容与迁移边界

只读基线为AiBox `19aa63e7cdc827d728745635a41b37c1d20dcfe4`，当前有用户WIP和既有worktree，均不修改。未发现根级通用开放许可证；本轮参考设计并独立实现，不迁源码、凭据、会话、截图或发布身份。

- `AiBoxAgentRuntimeCore/AgentLoopKernel.swift`、AgentTurnExecutionPlan：冻结工具暴露与执行范围，Provider／ToolHost／Store seam分离。
- `AiBoxAgentServiceProtocol`、`docs/engine/task-center/design.md`：稀疏生命周期事实、任务投影、类型化控制；KeyDock复用现有任务真值。
- `SmartActionKit/RunRecordDraftFactory.swift`：成功运行仅生成新ID、手动触发的草稿，不复制隐私实参或自动开启计划。
- `AiBoxFoundation/Workflow/ActionWorkflow.swift`、`PortableWorkflowRuntimePorts.swift`、`PortableWorkflowExecutionPolicy.swift`：类型化步骤、宿主端口、预算与重试许可分开。
- `ScheduledTasksKit`的claim／expectedAttemptID／lease：计划点去重与迟到围栏，未知副作用不重放。
- `Platforms/macOS/Packages/MacWindowManagementKit`：可参考布局目录和纯几何；不采用按PID恢复、首个相交屏和无读回确认的实现。
- `MacScreenshotKit`：Core／Capture／UI／Feature分层；KeyDock不继承默认截图历史。
- `MCPPluginRuntime`的会话single-flight／generation：协议adapter独立于loop；不迁全套聊天／SwiftData／PluginHost和产品门控。
- `AiBoxACPProtocolKit`：可参考duplex channel／session接口；现有deadline、pending取消和buffer边界须独立补齐，不能仅改名即宣称兼容。

## 验收与推进顺序

先窗口几何／AX命令和工具内统计，再受限Agent／工作流，随后MCP／OCR／调度／常用工具。每个切片先落生产入口和有意义的合成边界测试，再做当前Mac的原生观察与流水线。API仍按用户决定稍后配置，期间使用本地合成服务；AX／屏幕权限由用户手动授予，既有权限拒绝不绕过。全产品资格继续以docs/status.md为准。
