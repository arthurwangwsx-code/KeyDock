# KeyDock 文档总览

更新时间：2026-11-25。当前已有签名公证的公开alpha.10，并已替换本地常规App；完整真实验收未完成。事实来源顺序：用户最新决定 → AGENTS.md → 当前规格/技术方案 → 状态证据 → 外部调研快照。

| 文档 | 用途 |
|---|---|
| [产品愿景](product/vision.md) | 用户、定位、产品原则、成功指标 |
| [扩展能力使用说明](product/expanded-tools-guide.md) | Agent、MCP、工作流、调度、OCR和常用工具的实际入口 |
| [完整快捷操作建设与验收](product/quick-actions-completion.md) | 独立剪贴板面板、快捷键分类、竞品能力和完整目标验收矩阵 |
| [稳定窗口与应用动作](technical/desktop-actions.md) | 直接快捷键、窗口循环、应用行为、独立配置及合成宿主；alpha.6已发行 |
| [窗口与应用控制增量复查](implementation/desktop-controls-2026-11-25.md) | 模型／事务回归、原生双语编辑、显示失败与修补及alpha.6发行证据 |
| [产品需求](product/requirements.md) | 统一能力模型、AI 快捷动作和核心流程 |
| [竞品调研](product/competitive-research.md) | 官方来源支持的能力矩阵与产品判断 |
| [建设路线](product/roadmap.md) | 每阶段闭环、依赖、验收与投入估算 |
| [受信版本化工具目录](technical/trusted-contributions.md) | 编译期provider／handler、精确版本、工具开关与在途快照 |
| [工具目录实现与原生复查](implementation/trusted-contributions-2026-11-25.md) | 三个生产路径、失败记录、45项定向回归与双语原生子集 |
| [系统架构](technical/architecture.md) | 模块、依赖、数据流和架构决策 |
| [界面与交互规范](product/interface-design.md) | 三窗口职责、Liquid Glass、中英文与视觉验收 |
| [UI架构与组件库](technical/ui-architecture.md) | 状态所有权、KeyDockUI与本地化边界 |
| [AI 与自动化](technical/ai-and-automation.md) | Provider、快捷 AI、CLI、分析、Agent/MCP/ACP |
| [后续能力与AiBox设计参考](technical/capability-expansion.md) | P2–P4产品目标、模块拆分、实现合同与完整验收义务 |
| [Agent与外部协议边界](technical/agent-protocol-boundaries.md) | MCP版本、来源授权、回路与ACP评估结果 |
| [数据与权限](technical/data-and-permissions.md) | TCC、上下文、存储、采集与执行策略 |
| [P1会话保留](technical/session-retention.md) | 已实现的总预算、元数据维护、清除和恢复围栏及待验收边界 |
| [导入文本上下文](technical/imported-text-context.md) | 单槽来源、AI冻结、联合预算与清除；alpha.10候选 |
| [导入来源实现复查](implementation/imported-text-context-2026-11-25.md) | 合成提取／MCP／AI隐私、失败接纳与原生观察边界 |
| [AI输入提交复查](implementation/ai-input-commit-2026-11-25.md) | Unicode字节编辑、输入法组字门禁与保留的原始失败 |
| [AI草稿显式关闭](implementation/ai-draft-closing-2026-11-25.md) | 冻结确认身份、取消与实际worker收口、共享引用和保留历史 |
| [复用评估](technical/reuse-assessment.md) | AiBox/Ashot 可借鉴模块与迁移条件 |
| [验证方案](technical/validation.md) | 合成测试、真实 Mac/API 验收及性能预算 |
| [工程流水线](technical/release-pipeline.md) | 共用检查／调试／签名公证／安装回退／上传与回下载 |
| [GitHub 托管](governance/github-publication.md) | 公开范围、目标账号、分支与发布准备 |
| [alpha.4发行说明](releases/v0.1.0-alpha.4.md) | 扩展能力、系统资格与验收边界；实际发布状态见Releases及状态总账 |
| [alpha.5发行说明](releases/v0.1.0-alpha.5.md) | 独立剪贴板快捷面板与快捷键分类；实际发行状态见状态总账 |
| [alpha.6发行说明](releases/v0.1.0-alpha.6.md) | 稳定窗口动作、命名应用控制与最小回执；实际发行状态见状态总账 |
| [alpha.7发行说明](releases/v0.1.0-alpha.7.md) | 有序剪贴板合并、可配置主动作和AI复制兼容；实际发行状态见状态总账 |
| [alpha.9发行说明](releases/v0.1.0-alpha.9.md) | 多应用工作区组合执行、profile快捷键与逐项结果 |
| [alpha.10发行说明](releases/v0.1.0-alpha.10.md) | 准确输入提交、导入来源、联合预算与AI草稿显式关闭 |
| [alpha.10发行与安装证据](implementation/alpha10-release-2026-11-25.md) | 650 Swift／同源CI／公证／公开回下载／实际About10及alpha.9回退 |
| [alpha.9发行与安装证据](implementation/alpha9-release-2026-11-25.md) | 627 Swift／同源CI／公证／公开回下载／实际About9及alpha.8回退 |
| [alpha.8发行说明](releases/v0.1.0-alpha.8.md) | 界面／编辑／工作流／保存反馈及工作区定义管理；组合执行尚未开放 |
| [alpha.8发行与安装证据](implementation/alpha8-release-2026-11-25.md) | 同源本机／CI、公证、原子替换、公开回下载及真实About版本 |
| [剪贴板原生交互复查](implementation/clipboard-panel-2026-11-24.md) | 查询／选择／插入围栏、快捷键定制和中英深浅色实查 |
| [有序剪贴板合并](technical/clipboard-composition.md) | 独立勾选清单、合并预算、准确预览与可配置主动作；alpha.7已发行 |
| [剪贴板合并增量复查](implementation/clipboard-composition-2026-11-25.md) | 定向回归、实际合并复制、双语原生观察与发行证据及失败恢复 |
| [界面语义与文本复查](implementation/ui-semantics-2026-11-25.md) | 准确正文同步、编辑器AX名称与计划显示时区；alpha.8候选 |
| [URL动作编辑隔离](implementation/url-action-editing-2026-11-25.md) | 运行选择与编辑身份分离、失败保留草稿及合成原生复查；alpha.8候选 |
| [alpha.8 OCR复发记录](implementation/ocr-recurrence-2026-11-25.md) | 完整检查失败、逐轮诊断与不放宽发行门禁；尚未确认根因 |
| [有序命令集合](technical/command-collections.md) | 顺序、编辑隔离、可用引用和AI／CLI单项入口合同；alpha.8候选 |
| [集合实现与原生复查](implementation/command-collections-2026-11-25.md) | 定向检查、真实渲染行冲突及修复、双语深浅子集；发行仍未放行 |
| [隔离视觉样例复查](implementation/visual-samples-2026-11-25.md) | Preview专用环境、玻璃切换选区修补、剪贴板双语抽样及未完成矩阵 |
| [AI配置前置体验复查](implementation/ai-setup-guidance-2026-11-25.md) | 无密钥／联网的结构准备检查、配置主动作、草稿往返与在途取消 |
| [工作流快捷入口输入](technical/workflow-launch-input.md) | 初始文本依赖、独立输入呈现、迟到／定义变化／预算与执行合同 |
| [工作流输入原生复查](implementation/workflow-launch-input-2026-11-25.md) | 18项定向执行、编辑稿保留、双语输入页及实际纯变换任务 |
| [目录观察生命周期复查](implementation/catalog-volume-lifecycle-2026-11-25.md) | 保留远端100ms失败、后台卷通知准备／清理、恢复与停止重入回归 |
| [工作区定义保存复查](implementation/definition-saving-2026-11-25.md) | Agent／工作流失败提示、原文件补偿、编辑状态与真实保存版本 |
| [保存动作生命周期](technical/saved-item-lifecycle.md) | 独立移除审阅、引用阻止、事务清理与旧编辑／在途快照边界 |
| [保存动作生命周期复查](implementation/saved-item-lifecycle-2026-11-25.md) | 精确事务／引用／恢复、保留的测试失败与在途结果回归 |
| [桌面工作区组合执行复查](implementation/desktop-workspace-execution-2026-11-25.md) | alpha.9运行／回执／取消／profile入口及已知失败复查 |
| [桌面工作区建设方案](technical/desktop-workspaces.md) | 独立定义、冻结／焦点／两阶段执行与真实系统验收合同 |
| [桌面工作区定义管理复查](implementation/desktop-workspace-definitions-2026-11-25.md) | 共用存储回归、版本与外部变化围栏、中英编辑原生子集 |
| [桌面工作区执行内核复查](implementation/desktop-workspace-kernel-2026-11-25.md) | 冻结计划／Restore、专用焦点交接和取消收口；执行组合根仍待接通 |
| [桌面工作区准备与回执复查](implementation/desktop-workspace-preparation-2026-11-25.md) | 单次后台应用准备、有序父子元数据、恢复保护；组合运行及入口仍待接通 |
| [开源参考目录](../references/README.md) | 13 个参考工程及固定版本登记 |
| [第一阶段进度](implementation/phase-one-progress.md) | 实现、测试、真实验收与下一步 |
| [新版界面实机复查](implementation/native-ui-review-2026-11-22.md) | 三窗口、语言、外观、输入焦点和终端验收边界 |
| [界面与任务边界复查](implementation/native-ui-hardening-2026-11-23.md) | 上轮120项测试、214条文案、全文预览与独立行控件 |
| [日用边界复查](implementation/runtime-acceptance-2026-11-23.md) | 容量拒收与回滚、采集门槛、终端交接未知状态、原生带任务退出 |
| [启动台与AI状态复查](implementation/application-shortcuts-2026-11-23.md) | 应用更新、快捷键/API回滚、迟到交互隔离与用量未知状态 |
| [会话保留与清除复查](implementation/retention-acceptance-2026-11-23.md) | 8任务/200历史/32草稿/32MiB、90天维护、清除与失败回归 |
| [玻璃界面与双语复查](implementation/interface-refinement-2026-11-23.md) | 组件分层、导航上下文、可返回草稿、动态提示与设置失败边界 |
| [发行工程实查](implementation/release-engineering-2026-11-23.md) | 统一流水线、真实安装／替换／回退、启动问题与发布证据 |
| [解锁后原生交互复查](implementation/native-actions-2026-11-24.md) | 原生运行／停止快捷键、新增工具栏、命令到Agent的合成服务实查与CI失败定位 |
| [扩展能力实现与验收](implementation/capability-expansion-2026-11-24.md) | P2–P4新增实现、合成回归、原生观察与剩余真实验收 |
| [状态总账](status.md) | PASS/PARTIAL/FAIL/BLOCKED、证据与未完成义务 |
| [iSpec 提案](../ispec/changes/keydock-foundation/10-proposal.md) | proposal、design、五个能力规范和分阶段 tasks |

产品需求表中的 P0–P4 均为建设计划。已验证的竞品官方材料不等于在本机测试过竞品，AiBox 现有源码不等于 KeyDock 已实现。
