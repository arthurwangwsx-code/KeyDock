# 分阶段建设路线

以下是依赖顺序和粗估工作量，不是日历承诺。以一位主要开发者、目标版本明确且基础 macOS 经验充足为假设；真实工期在 P0 结束后用测量结果重估。每阶段都需“实现/测试/真机/发布”分别记账。

| 阶段 | 交付闭环 | 关键依赖/退出标准 | 粗估 |
|---|---|---|---|
| P0 基础验证 | AppKit Panel、全局唤起/焦点恢复；CommandRegistry；AI mock stream/cancel；ToolBroker/AgentRun 接缝 | 多屏、全屏、IME、快捷键冲突实测；慢/过期搜索不会污染当前查询；合成 AI/工具策略测试 | 1–2 周 |
| P1 首个日用版本 | 应用/窗口搜索切换、保存 CLI、最小任务列表/输出详情/取消入口、纯文本剪贴板；外部 API 翻译/总结、自定义 AI 快捷键；AI 命令草稿与一个只读 Tool | 至少一个真实外部 API 路径、synthetic 输入、Keychain 与无正文日志；权限拒绝/撤销与取消实测；CLI/AI 不阻塞面板；固定合成中英/技术文本集的忠实度、术语、结构与长输入提示通过[质量验收](../technical/validation.md) | 3–5 周 |
| P2 桌面与受限 Agent | 基础窗口布局/跨屏/恢复；本工具统计；有边界的多步 Agent 工作区与持久恢复 | 多窗口身份/屏幕变化；max-step/预算/中断/重试；用聚合数据生成可追溯建议 | 3–5 周 |
| P3 扩展与上下文 | MCP client、可选 ACP/CLI Agent、截图/OCR、文件输入、用户工作流 | 第三方进程权限边界清晰；上下文选择/删除；扩展挂起不拖垮宿主；协议兼容性固定 | 4–6 周 |
| P4 完整工作台 | 工作区、调度、扩展分发、可选前台活动分析与本地模型增强 | 定时漏跑/重叠/睡眠、版本升级/迁移/恢复与长期隐私验收 | 按反馈拆分 |

P1 保持范围可收敛：仅一个云适配器先跑通，gateway 保持多 Provider 接缝；支持自定义 endpoint 不代表所有兼容服务已验收。可先接用户已有模型服务，实施前确认 provider/endpoint/model，不读取 AiBox 凭据或发送隐藏计费请求。

## P0 首批实施切片

1. 创建 SwiftPM 纯核心和 macOS App target，锁定部署版本与工具链。
2. 实现 Panel/快捷键/目标上下文快照，完成焦点与 IME 的实机 spike。
3. 建立 command/query/result/action 合同、异步 fan-out、取消与稳定排序。
4. 接一个 ApplicationProvider，形成真实“搜索→启动→返回”闭环。
5. 建立 AIGateway mock 及 AIAction 表单/流式结果，定义 ToolBroker 与 AgentRun 状态机。
6. 给 P1 风险最高的 AX 窗口、CLI cancel、选区读取、模型流取消做定向 spike，再估工期。

## 风险与前置决策

| 事项 | 当前决定 | 验证/调整触发点 |
|---|---|---|
| 名称 | KeyDock 为用户接受的工程代号 | 公开产品前做商标/同名检查 |
| 平台 | macOS 原生，暂定最低 14 | P0 编译、依赖可用性、最低系统 Mac/VM 实测 |
| 分发 | 建议 Developer ID + 公证，直接分发 | CLI/AX/插件需求与 App Sandbox spike；不承诺 Mac App Store |
| AI 服务 | 直连用户配置 endpoint，Keychain 保存 secret | 第一个真实联调前选择厂商和模型，记录数据路径/费用 |
| 复用 | 本轮仅研究，不复制源码 | 每个文件明确权属/依赖/notices 后单独提迁移 change |
| 个人分析 | 首期仅工具内事件，默认不采集全机活动 | 用户明确启用后才设计 P4 观察范围 |
| 开源 | MIT 原创规划；目标 arthurwangwsx-code/KeyDock | 具体远端公开审批后才建仓/push |

## 项目维护节奏

每个 change 同步产品需求、技术决策、BDD 场景和状态证据。每个里程碑结束做一次可日用评审，依据失败与使用反馈排下一批工具。AI 质量、API 花费和本地性能分别度量；不能用模型能力掩盖基础路径缺陷。
