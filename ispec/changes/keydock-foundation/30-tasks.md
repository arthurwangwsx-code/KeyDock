# KeyDock 实施任务

当前正在实现第一阶段P0/P1，并按2026-11-23用户新增要求推进开源／发行／安装流水线；其他P2–P4保持后续范围。按依赖顺序执行，每项完成须有验收证据；完成 tasks 文档不代表复选框任务已完成。当前实现与真实验收缺口见 [进度](../../../docs/implementation/phase-one-progress.md)。参照 [design](21-design.md)、五个 specs 及 [阶段路线](../../../docs/product/roadmap.md)。

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
- [ ] 8.5 建立无发行凭据的原生CI与公开后资产复核，远端实际运行通过。
- [x] 8.6 受控fast-forward master，建立公开仓与v0.1.0-alpha.1精确tag，public／master／44ace89来源已回查。
- [x] 8.7 本地四项资产上传draft，回下载验签／验摘要后公开alpha；公开后本地与GitHub release-audit再次通过。
- [ ] 8.8 实机复验picker语言、启动台完整行、草稿焦点和既有提示；全产品未验项保持PARTIAL。
