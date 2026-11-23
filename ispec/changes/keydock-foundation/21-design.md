## Context

参考 [提案](10-proposal.md) 建立全新 KeyDock。用户要求原生快捷操作、可持续架构及外部 API AI，包含可绑定快捷键的翻译/总结、CLI 扩展、使用分析和通用 Agent。初始方案已进入P0/P1实施；2026-11-23追加开源、预发行和安装流水线。

## Goals / Non-Goals

**Goals:** 以统一命令/工具/上下文/执行模型承接桌面与 AI 动作；P1 可日用；各阶段有真实验收；选择性参考 AiBox 与公开项目。

**Non-Goals:** 不采集个人开发素材、不复制旧源码／凭据；首期不做全屏持续监控、扩展市场或完整Raycast兼容。公开范围按用户新增发行要求与治理文档执行。

## Decisions

- 原生 Swift 6 + AppKit Panel/SwiftUI，暂定 macOS 14；模块化单体，App 薄组合根。Electron/RN 方案推迟到确有跨平台需求。
- CommandCore/ExecutionCore/AICore 为纯合同；SearchEngine/AgentCore 通过 host seams 依赖 OS/模型/存储。统一执行服务避免各功能重复权限和取消逻辑。
- AIAction 直接调 ProviderGateway；只有多步工具任务才进入 AgentRuntime。Provider 独立适配，tool-call 总经 Broker，MCP 与 ACP 分别承担工具和外部 Agent 接入。
- 剪贴板、Activity、模型用量、任务正文分域保存，元数据优先。未知 usage/cost 不伪装为实测；保存动作可在已确认范围内一键运行。
- CLI executable/argv 与 shell/PTY 明确分开；窗口身份不能仅用 PID；查询采用 generation 防止陈旧结果覆盖。
- references 只登记 URL/revision/license，不 vendor 参考仓；AiBox portable 核心只作为后续抽取候选。

完整决策、合同、时序和状态机见 [架构](../../../docs/technical/architecture.md)、[AI 与自动化](../../../docs/technical/ai-and-automation.md)、[数据与权限](../../../docs/technical/data-and-permissions.md)。

## Risks / Trade-offs

- [macOS 权限/多屏/Space 行为不同] → P0/P1 做真机 spike，声明公开 API 能力边界。
- [云模型延迟、限流、重复计费] → 搜索隔离、超时/取消、有界重试，生成与执行分开。
- [第三方进程绕过 Broker] → 只允许可信显式启用来源，未验证 OS sandbox 不宣称权限隔离。
- [Agent 崩溃时副作用不确定] → intent/result 回执，unknown outcome 不自动重放。
- [迁移带入私有耦合或许可证问题] → 逐文件 provenance/notices；本轮不复制。

## Migration Plan

从空 master 的 feature/product-foundation 建立文档与 change，经校验与只读评审后 fast-forward master。P0 新建 Swift 工程；每个可迁模块单独 change，保留来源 revision。数据库首次实现即版本化迁移，失败可保留旧文件与前一发布包；没有数据转换或源码删除在本轮发生。

## Open Questions

第一个联调 provider/endpoint/model、最低系统真实验证设备、签名发布者和 App Sandbox 能力 spike 尚待实施前确定。名称 KeyDock 为用户接受代号。公开远端的具体仓库与范围在可审阅内容完成后确认。

## 2026-11-23 范围追加

用户明确要求完整应用GitHub开源、本地Release上传及本地安装替换流水线。当前追加release-engineering合同与任务8.x，技术细节以docs/technical/release-pipeline.md为准。master在编译／测试／审查通过后受控fast-forward，alpha发行与完整P1日用资格分别记录；其余P2–P4产品能力继续后置。签名凭据由系统钥匙串引用，公开源码与发行物不含私钥、API配置或个人数据。
