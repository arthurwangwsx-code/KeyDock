## Why

常用桌面操作、命令行与 AI 翻译/总结分散在不同入口，用户希望以快捷键和统一搜索降低操作成本，并持续接入更多本地工具和通用 Agent 能力。KeyDock 以全新原生 macOS 项目承接这一目标，先完成可执行规划，逐阶段实机验证。

## What Changes

- 建立独立仓库、产品文档、技术设计、开源参考目录和阶段验收任务。
- 统一命令、对象、上下文与执行策略，支持搜索、直接快捷键和未来工作流三个入口。
- P0/P1 建立启动/窗口切换、保存的 CLI、纯文本剪贴板，以及外部 API 翻译/总结快捷动作。
- 分阶段加入窗口布局、截图/OCR、使用分析、工具调用 Agent、MCP 和可隔离扩展。
- 以本地数据、显式上下文、可取消任务和结构化使用量记录作为架构基础。
- 本 change 的交付止于规划工件；运行时代码、系统权限授予、公开发布不在本轮完成范围。

## Capabilities

### New Capabilities
- `command-platform`: 统一命令、搜索、唤起、动作及执行策略。
- `desktop-tools`: 应用/窗口、CLI、剪贴板、窗口布局和截图工具的阶段合同。
- `ai-actions`: 模型接入、快捷翻译/总结、命令生成与个人使用分析。
- `agent-runtime`: 带工具边界、预算、取消和恢复语义的通用 Agent。

### Modified Capabilities
无；全新项目，不修改 AiBox/Ashot 的行为或代码。

## Impact

暂定技术栈 Swift 6、AppKit/SwiftUI、AX、Foundation Process、Vision、ScreenCaptureKit、SQLite 和 Keychain。实际引入依赖在实施前逐项锁定。所有 AiBox/Ashot 迁移先做 provenance 与许可证审查；参考工程只记录链接、revision 和评估，不 vendor 第三方源码。本轮不启动 App、不采集个人使用数据、不调用付费模型、不推送远端。
