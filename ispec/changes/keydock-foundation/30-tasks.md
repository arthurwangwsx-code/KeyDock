# KeyDock 实施任务

当前继续保留第一阶段P0/P1验收义务，并按2026-11-24授权实现P2–P4。代码、合成验证、真实Mac／API和发行分别记录。按依赖顺序执行，每项完成须有验收证据；完成 tasks 文档不代表复选框任务已完成。当前实现与真实验收缺口见 [进度](../../../docs/implementation/phase-one-progress.md)。参照 [design](21-design.md)、五个 specs 及 [阶段路线](../../../docs/product/roadmap.md)。

## 1. P0 工程与契约

- [x] 1.1 建立 SwiftPM 核心与 macOS App target，锁定 Swift/Xcode/最低系统、构建命令和矩阵。
- [x] 1.2 定义 CommandDescriptor、对象 identity、QueryRequest/ResultBatch 和 ActionDescriptor，检查单向依赖；查询合同已进入生产Launcher与协调器并经合成测试。
- [x] 1.3 实现异步 Provider fan-out、generation 过滤、取消、限时与稳定排序，验证慢 Provider/旧结果。
- [x] 1.4 建立 ToolDefinition/ExecutionRequest/Broker caller-policy 与纯合成策略测试；该勾选不表示OS沙箱或完整动态能力注册已验收。
- [x] 1.5 建立 AIRequest/AIEvent/ProviderCapabilities、mock streaming/cancel/usage 与独立 AIGateway。
- [x] 1.6 定义 AgentRun/attempt 状态机、预算与停止语义，验证迟到授权/结果不复活终态。

## 2. P0 原生闭环与风险验证

- [ ] 2.1 实现 AppKit Panel、菜单栏入口与原目标快照，验证多屏/全屏/Esc 焦点恢复。
- [ ] 2.2 评估并锁定快捷键实现，提供录制、冲突提示、持久化与禁用，实测 IME；CUA注入alt+space未观察到切换，仍须区分真实按键与注册行为。
- [ ] 2.3 实现 ApplicationProvider 索引与启动，处理应用变化/重复/外置盘失效。
- [ ] 2.4 建立参数表单、动作/详情/结果公共 UI 与 String Catalog、VoiceOver 基线。
- [ ] 2.5 对 AX 窗口身份/选区读取、Process 取消、真实模型 stream 风险分别做 spike，并重估 P1。
- [ ] 2.6 建立性能采样与 P0 实机证据；记录热唤起/本地查询/CPU/内存/耗电基线。
- [x] 2.7 按视觉评审重构独立Launcher／Settings／Workspace和菜单栏设置、标准编辑菜单；原生App构建通过。
- [x] 2.8 建立KeyDockUI、系统Liquid Glass材料／控件分层与availability／高对比度回退、中英语言切换、分bundle String Catalog静态覆盖和旧内置动作迁移。
- [x] 2.9 分离三个窗口Session，AI共享文档按revision／runID固定输出元数据；配置／草稿／导航与完整结果键盘可达、应用目录更新与迟到交互隔离的定向测试通过；本轮增加快捷键深链接、可返回草稿与候选设置事务回归。
- [ ] 2.10 完成新版三窗口深浅色、中英、辅助功能、IME、焦点与截图视觉验收；基本画面/双语/焦点已实查，辅助功能、IME、多屏完整矩阵尚待完成。

## 3. P1 桌面工具

- [ ] 3.1 实现 WindowCatalog/ActivationService，验证同 App 多窗口、关闭/PID 重用/权限撤销。
- [x] 3.2 建立 SavedCommand 参数/cwd/envRef 表单和 executable+argv runner，shell mode 显式隔离。
- [x] 3.3 实现 stdout/stderr 有界输出、超时/进程组取消和退出状态，验证满管/派生进程。
- [ ] 3.4 提供交互 CLI 的用户终端打开 adapter，不伪装 Process 支持 PTY；有界确认／unknown／不可撤回的10项合成回归通过，实际Terminal GUI仍待验收。
- [x] 3.5 实现最小运行列表/输出详情/取消入口和CLI／AI最小durable invocation intent/result，重启仅展示 interrupted/unknown，不重放。
- [x] 3.6 实现读取正文前的 clipboard 类型过滤、暂停/排除/TTL/容量/清空与合成验证。
- [ ] 3.7 实现纯文本 clipboard 搜索/复制，自动粘贴单独校验权限与目标。
- [ ] 3.8 实现P1任务/草稿/输出总预算、终态回执保留与用户清除；代码与36项新增合成回归已完成，保护收口/可见/未知交接并拒绝迟到复活；原生清除交互与长期驻留仍待验收。

## 4. P1 AI 快捷动作

- [ ] 4.1 选择首个公开 API provider/endpoint/model，锁定 wire adapter、能力与数据条款；不读取 AiBox 凭据。
- [ ] 4.2 实现 Keychain/config、HTTPS/localhost 模式、跨源重定向凭据保护和错误映射。
- [x] 4.3 实现版本化 AIAction 配置：提示词、语言/参数、输入/输出、模型和快捷键。
- [ ] 4.4 实现选区翻译/总结、输入缺失提示、流式结果/复制/取消；普通动作 tools=[]。
- [ ] 4.5 实现独立替换选区动作并核对原目标；自动 Cmd+C fallback 留专项 spike，不默认启用。
- [ ] 4.6 实现 AI CommandProposal 草稿/检查/运行和 CLI 输出片段解释，不自动运行模型字符串。
- [ ] 4.7 实现 usage attempt 去重、cumulative/delta、部分/未知用量、费率快照和 ledger。
- [ ] 4.8 让一个只读内置 Tool 经 AgentRunner/Broker 完成真实工具调用，验证 schema 与提示注入边界。
- [ ] 4.9 完成至少 20 条合成翻译/总结质量样本人工评阅，处理术语/格式/长输入/来源回溯。
- [ ] 4.10 使用合成输入完成真实 API、权限拒绝/撤销、离线/限流/取消和无正文日志验收，更新 P1 总账。
- [ ] 4.11 实现usage元数据90天/数量/字节维护及独立清除入口；actor/磁盘与缓存失效/部分失败回归已通过，不把缺失当零；原生清除交互仍待验收。

## 5. P2 窗口、分析与受限 Agent

- [ ] 5.1 实现窗口左右布局/最大化/恢复/跨屏，按窗口 identity 保存 frame，验证屏幕变化和最小尺寸。
- [ ] 5.2 实现用户启用的 ActivityStore、30 天策略、聚合统计/清空/导出与 AI 用量分域。
- [ ] 5.3 实现聚合数据 AIInsight，显示时间范围/覆盖率/依据，建议仅生成用户可审阅草稿。
- [ ] 5.4 实现多步受限 Agent、可见工具/预算/授权卡、暂停/取消，工具调用始终经 Broker。
- [ ] 5.5 扩展 RunStore/任务工作区和 durable receipts，显式恢复创建新 attempt，unknown outcome 不重放。
- [ ] 5.6 真实无害工具验收取消、崩溃、权限变化、提示注入和资源范围；更新 P2 证据。

## 6. P3 扩展与截图

- [ ] 6.1 逐版本评估 MCP Swift SDK 或 AiBox 独立协议核心，完成 license/provenance 后实现 MCP client adapter。
- [ ] 6.2 实现外部 MCP 来源/工具变更/取消/认证处理，文档如实说明进程权限不等于沙箱。
- [ ] 6.3 评估可选 ACP/CLI Agent adapter，区分 session/permission/progress/cancel 与 MCP 工具协议。
- [ ] 6.4 审查截图/OCR 可迁文件，建立 provenance；实现用户选范围、本地 OCR 和 AIAction 输入。
- [ ] 6.5 实现文件/图片上下文、附件生命周期与删除，不扩大保存动作范围。
- [ ] 6.6 实现版本化用户 Workflow、输入输出连接、失败/重试/取消；扩展崩溃不拖垮宿主。

## 7. P4 演进与发行

- [ ] 7.1 根据日用反馈拆分工作区、Snippets、文件搜索、计算转换和更多工具，不一次扩张所有功能。
- [ ] 7.2 为定时任务设计睡眠/漏跑/合并/并发与授权暂停，统一创建 AgentRun。
- [ ] 7.3 若用户启用整机活动分析，单独确定观察范围、保留/导出/删除与指标有效性，不默认录屏或采键。
- [ ] 7.4 评估真实不可信扩展隔离与分发；未验证 OS 沙箱不得宣传权限隔离。
- [ ] 7.5 补正式发布者/隐私政策/支持页、签名公证、更新/干净安装/数据迁移/回滚证据。
- [x] 7.6 按新增授权建立arthurwangwsx-code/KeyDock public仓、push master并回查可见性/default branch/commit；不能把开源托管当产品验收。

## 8. 用户新增：开源、发行与本地安装流水线

- [x] 8.1 复核源码／历史公开候选，更新开源治理和alpha说明；最终资产发布前另行复查。
- [x] 8.2 建立统一Python／Make入口、版本与完整source SHA、隔离Preview和Release构建；Preview实际构建安装通过。
- [x] 8.3 Developer ID、Hardened Runtime、App/DMG公证Accepted／装订、Gatekeeper与最终摘要实际通过，公开包回下载验证通过。
- [x] 8.4 同卷原子安装、精确正常退出、回执／回退和失败补偿通过；owned签名Preview跨build回退、运行中Preview更新及canonical首次安装分别记录。
- [x] 8.5 无发行凭据的原生CI（cb74c41，248 Swift／32 Python／271 key、ReleasePreview与产物）和公开后资产复核均在GitHub实际通过；保留前次未复现失败与完整诊断。
- [x] 8.6 受控fast-forward master，建立公开仓与v0.1.0-alpha.1精确tag，public／master／44ace89来源已回查。
- [x] 8.7 本地四项资产上传draft，回下载验签／验摘要后公开alpha；公开后本地与GitHub release-audit再次通过。
- [x] 8.8 解锁后实机复验语言／外观picker、启动台行、草稿新建／恢复焦点和既有提示；真实按键、AX、IME、多屏及用户视觉评审仍未通过，见2026-11-24复查。
- [x] 8.9 修复原生⌘Return／⌘.与设置工具栏新增按钮、首次恢复任务选择；新增3项边界回归，完整251 Swift／32 Python／273 key通过；Preview用合成服务实查命令到只读Agent链路。
- [x] 8.10 alpha.2干净源ace56ef完成原生远端CI、Developer ID签名／App与DMG公证、运行中正式App升级、回退凭据、公开资产回下载与GitHub发行审计；alpha.1保持原tag与字节。完整产品仍PARTIAL。

## 9. 2026-11-24后续能力实现与验收

- [x] 9.1 只读拆解AiBox运行计划／工作流／调度／截图／协议边界，独立实现并补产品与技术方案，不迁私有源码。
- [x] 9.2 新增纯窗口几何、窗口identity恢复缓存、AX写后读回与统一命令贡献；真实AX／跨屏矩阵仍待验收。
- [x] 9.3 实现默认关闭的ActivityLedger、聚合／清除／导出／用户触发AI总结；核心暂停／清除围栏回归通过。
- [x] 9.4 实现冻结Agent工具、单次审批、调用／输出预算、暂停／新attempt、unknown与真实进程drain；定向回归通过。
- [x] 9.5 实现Workflow编辑、输入绑定、逐次动态参数审批、在途快照、真实进程收口与父子回执原子保护；合成集成通过。
- [x] 9.6 实现MCP HTTP／stdio两个显式协议版本、tools／resources／prompts及来源管理，21项合成协议回归通过；第三方服务兼容未全面验收。
- [x] 9.7 实现单文件文本／PDF文本层／图片OCR、区域截图入口、上下文generation与预算；真实合成Vision OCR通过，屏幕权限仍待用户手动授予。
- [x] 9.8 实现App内调度claim／revision／指纹／unknown人工检查、单owner目录lease；定向核心与宿主回归通过。
- [x] 9.9 完成Snippets／文件搜索／算式和单位换算／URL动作／命令集合的全量核心检查与原生编辑／预览观察；未据此声称所有系统执行入口矩阵已验收，见扩展能力证据。
- [x] 9.10 完成新增中英文覆盖、统一流水线、干净提交、原生core CI、新alpha签名公证／安装／公开资产回下载；alpha.4源fea2bee，384 Swift／43 Python／506 key，云端系统OCR单独NOT_QUALIFIED。
- [ ] 9.11 完成真实API、AX／屏幕权限、多屏／IME／辅助功能和完整视觉矩阵；不能用局部PASS关闭完整产品义务。
- [x] 9.12 完成云端core／本机生产OCR资格分层，独立进程＋repeat实际识别、同源App／manifest／CI绑定与拒绝过期／伪造／篡改证据的流水线回归；实际打包／安装／公开回下载通过，alpha.3旧候选保留。

## 10. 完整快捷操作与视觉验收（用户后续完整目标）

- [ ] 10.1 实现独立剪贴板玻璃面板、专用快捷键／菜单入口、搜索／键盘选择／预览／复制／向原应用插入；覆盖目标变化、迟到结果、权限与剪贴板竞争，完成真实合成输入验收。
- [ ] 10.2 完成窗口／应用动作快捷键配置和可发现分类、别名／收藏等自定义能力；验证冲突／持久化、实际焦点和窗口控制。
- [ ] 10.3 对照竞品官方能力补齐功能／配置矩阵，逐项完成开发及验收，不以子集代替原P0–P4目标。
- [ ] 10.4 继续完整AI动作、Agent、上下文及工作流能力；真实API按原决定待配置，保留实际模型质量验收义务。
- [ ] 10.5 完成Launcher／独立面板／Settings／Workspace的中英、深浅色、输入法、辅助功能及完整视觉验收。
- [x] 10.6 完成alpha.5统一检查（400 Swift／43 Python／524 key）、同源core CI、签名公证／本地替换／开源发行与回退凭据、公开回下载和GitHub资产审计；完整功能／实机验收仍依10.1–10.5及10.7推进。
- [ ] 10.7 扩展剪贴板多项合并／顺序插入与可配置主动作，验证合并预览、总预算、顺序与单次授权；不将多个并发按键请求当作可靠文本插入。

## 11. 稳定窗口与应用控制

- [x] 11.1 实现不读选区正文的窗口目标与布局适配、稳定循环ring／读回提交、当前窗口最小化、取消和实例围栏；核心回归通过，真实AX仍依9.11／10.2验收。
- [x] 11.2 实现命名应用激活／显示／隐藏／前台切换／正常退出，明确实际确认、请求已发送和未知状态，禁止强退及自动重试；原生合成应用隐藏→显示和正常退出通过，其他目标矩阵保留。
- [x] 11.3 独立保存应用动作与原子写入／损坏保护，避免旧版基础设置写入丢失新字段；接入快捷键分类、别名及自定义UI，临时目录故障回归及原生编辑通过。
- [x] 11.4 接入直接dispatcher、精确effects、任务intent／结果、取消与重启不重放；窗口和应用快捷键不闪Launcher的路由已实现，物理热键仍依10.2验收。
- [x] 11.5 建立仅含合成文本的原生测试宿主，验证应用控制及退出计数；真实AX／多屏／物理热键仍需单独证明。
- [ ] 11.6 完成全量与中英视觉检查、alpha.6发行、安装和资产审计；不关闭原完整目标的其他缺口。
