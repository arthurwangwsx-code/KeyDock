# 现有工程复用评估

盘点日期：2026-11-22。仅只读源码和 Git 状态，未复制、构建或运行旧 App，未读取个人截图、剪贴板、会话或凭据。`AiBoxRoot` 指本机 AiBox canonical checkout，具体绝对路径映射仅保存在忽略的 .local 中；表格路径相对该根目录。

基线：AiBox `master @ 19aa63e7cdc827d728745635a41b37c1d20dcfe4`，存在用户 WIP 及历史 detached worktrees，均未改动；Ashot `main @ 118607e` 干净；MacShortCutTest `main @ dc951c0` 有 WIP。本新仓库遵循用户当前 master 基线/命名分支规则，不沿用旧仓过时的直接写 master 规范。

## macOS 能力

| 模块/证据 | 建议与成本 |
|---|---|
| `Platforms/macOS/Packages/MacHotkeyKit/Sources/MacHotkeyKit/GlobalHotKey.swift:11,52,79,118` | 无外部依赖，Carbon 注册/释放可作为低成本抽取候选；与用户动作/焦点恢复解耦 |
| `MacCommandKit/.../MacCommandModels.swift:133-180,221-235,281-292` | 参考稳定 ID/provider/availability/actions/source；新合同补版本、输入输出、取消/策略，中成本 |
| `MacCommandKit/.../MacCommandRegistry.swift:53-90,123-197` 与 `MacCommandSearch.swift:30-58` | 参考别名/收藏/启停/排序；查询编排移出 MainActor，定义 timeout/generation |
| `MacLauncherKit/.../MacApplicationCommandProvider.swift` | 低到中成本新建独立 ApplicationProvider，不链接整个 AiBox |
| `MacWindowManagementKit/.../MacWindowGeometry.swift` 和 `MacWindowManager.swift:14-98` | 参考几何与 AX adapter，中成本；现有接口只有 focused window layout，不等于完整窗口切换 |
| `MacScreenshotKit/Package.swift:5-54` 与 `MacScreenshotUI/ScreenshotOCRService.swift:27-67` | 已分 Core/Capture/UI/Feature，最低 macOS14、依赖 MacShortcutKit；P3 审查后抽取，中成本 |
| `MacSelectionKit/Package.swift:14-40` | 无第三方依赖，可参考 AX selection adapter，须有不支持路径 |
| `MacClipboardKit/.../MacClipboardMonitor.swift:34-58` 与 `MacPasteboardReader.swift:15-24` | 重建轻量采集/存储；共享 ClipboardKit 整包依赖重，不直接迁 |
| `MacNativeToolKit/.../ProcessExecution.swift:14-63,118-136` | 参考 argv/cwd/env/timeout/output/task 语义，独立小 runner；整包 Agent/Workspace 依赖重 |
| `docs/platform/mac/terminal-workbench.md:21-35,76-96` | Process 与 PTY/交互 CLI 分开，AI proposal/insert/run 语义可借鉴 |

必须修正：现有 MacPasteboardReader 直接读正文，缺少读取前 concealed/transient 类型检查；iOS `Packages/ClipboardKit/Sources/ClipboardKit/Capture/ClipboardPasteboard.swift:46-52` 有相应识别可研究。现有 WindowManager 以 PID 存 restore frame，同 App 多窗口会覆盖，应建立窗口级 identity 与生命周期验证。

## AI、Agent 与使用量

| 能力与源码 | 建议 |
|---|---|
| `Packages/AiBoxKit/Sources/AiBoxModelCore/LLMProvider.swift:29-50`、`LLMTypes.swift:539-548` | 参考 async stream/text/tool/usage 合同，独立建立 AIRequest/AIEvent；不复制整个 gateway |
| `Packages/AiBoxKit/Package.swift:79-85,109-110` | AiBoxModelCore 无 target dependencies，AiBoxAgentRuntimeCore 仅依赖它；后期优先评估抽成独立版本包 |
| `Packages/AiBoxFoundation/Sources/AiBoxFoundation/TextGenerationCapability.swift:47-82,104-123` 与 `AiBoxProviderKit/.../TextGenerator.swift:38-56,84-119` | 翻译/总结直接 gateway，参考 purpose、override、stream callback 与 optional usage |
| `AiBoxModelCore/ToolContracts.swift:5,79,100` 与 `AiBoxKit/AgentTool.swift:65-133` | 参考 ToolDefinition/Call/Result；执行策略由 KeyDock Broker 拥有 |
| `AiBoxAgentRuntimeCore/AgentLoopKernel.swift:29-40,238-245,392-445` 与 `AgentRuntimeTools.swift:81-94` | portable kernel 有 ToolHost、SessionRuntimeStore/ContextEngine seam；中高成本后期抽取候选 |
| `AiBoxKit/AgentLoopRunner.swift:42-60,86-99` | 持有 session/repository/registry/compaction，直接迁上层回路耦合高 |
| `Packages/AiBoxAgentServiceProtocol/.../AgentServiceModels.swift:47-63`、`AgentRunStateMachine.swift:3-37`、`AgentServiceClientProtocol.swift:46-68,100-103` | 参考 queued/running/approval/cancel/interrupted、UI/service seam；初期无需 daemon |
| `AiBoxKit/UsageReporting.swift:23-73,123-158`、`UsageAttribution.swift:25-55,104-105`、`AiBoxModelCore/ModelPricebook.swift:54-81` | 采用 provider+wireModel+purpose+run 归因、冻结费率、actual/notional/unknown；独立 ledger，不能照搬旧价格/全局 unsafe sink |
| `Packages/AiBoxFoundation/Sources/AiBoxFoundation/Usage/UsageTracking.swift:16-59` | 参考最小事件；正文/窗口标题/完整 CLI 输出不进普通统计 |
| `Packages/MCPPluginKit/Package.swift:77-104,170-194` 与 `Sources/MCPPluginRuntime/MCPClient.swift:19-25`、`MCPTool.swift:28-70,87-115` | protocol/client targets 和 calling seam 可参考，不迁 UI/State/远控平台 |

核验发现 `AgentLoopKernel.swift` 文件头注释仍说工具回路未接入，但真实实现 `:392-445` 已使用 ToolHost。其 event log 当前有 shadow/fail-soft 路径，仍不能直接当作 KeyDock 的可靠恢复账本。以代码和新项目测试为准，不能用旧注释或已有模块名声称通用 Agent 已完成。

## Ashot 与快捷键实验

Ashot `Ashot/Services/CaptureService.swift:49-92` 的有限坐标/屏幕裁剪/像素上限，以及 `HotKeyManager.swift:8-22,59-100` 的快捷键存储有研究价值。其 README 声明未添加开源许可证授权，最低系统/Xcode 与本项目目标也不同，因此本轮只参考行为/算法，不复制 App、发布脚本或签名身份。

MacShortCutTest `MacShortCutTest/GetShortcutNameIntent.swift:1-28` 是 AppIntent 实验，不是 launcher/runner 底座；可作为后期 Shortcuts 接入入口。

## 迁移门槛

本次未找到 AiBox 根级开放许可证，不能凭用户拥有工程就将所有来源/依赖自动改为 MIT。实际迁移时单独建立 receipt：源 repo/revision、文件列表及 hash、权属依据、第三方 notices、依赖许可证、重命名/修改记录、验证与回滚。

优先独立重建小合同、纯几何、轻量 selection/hotkey；完整 App、私有订阅通道、用户 provider 配置、会话、token 和媒体不进入新仓库。P0/P1 先以独立接口跑通，后续只有当复用收益大于依赖/维护成本时再抽包。

旧正式文档可查 `docs/platform/mac/command-platform.md`、`command-platform-implementation-ledger.md`、`screenshot-integration.md` 和 `terminal-workbench.md`。其实现和历史验收不替代 KeyDock 的真实权限/API/窗口测试。
