# KeyDock 文档总览

更新时间：2026-11-24。当前处于第一阶段实现，已有签名公证的公开alpha；完整真实验收未完成。事实来源顺序：用户最新决定 → AGENTS.md → 当前规格/技术方案 → 状态证据 → 外部调研快照。

| 文档 | 用途 |
|---|---|
| [产品愿景](product/vision.md) | 用户、定位、产品原则、成功指标 |
| [扩展能力使用说明](product/expanded-tools-guide.md) | Agent、MCP、工作流、调度、OCR和常用工具的实际入口 |
| [完整快捷操作建设与验收](product/quick-actions-completion.md) | 独立剪贴板面板、快捷键分类、竞品能力和完整目标验收矩阵 |
| [稳定窗口与应用动作](technical/desktop-actions.md) | 直接快捷键、窗口循环、应用行为、独立配置及合成宿主；alpha.6开发中 |
| [窗口与应用控制增量复查](implementation/desktop-controls-2026-11-25.md) | 模型／事务回归、原生双语编辑、显示失败与修补及alpha.6待验收门禁 |
| [产品需求](product/requirements.md) | 统一能力模型、AI 快捷动作和核心流程 |
| [竞品调研](product/competitive-research.md) | 官方来源支持的能力矩阵与产品判断 |
| [建设路线](product/roadmap.md) | 每阶段闭环、依赖、验收与投入估算 |
| [系统架构](technical/architecture.md) | 模块、依赖、数据流和架构决策 |
| [界面与交互规范](product/interface-design.md) | 三窗口职责、Liquid Glass、中英文与视觉验收 |
| [UI架构与组件库](technical/ui-architecture.md) | 状态所有权、KeyDockUI与本地化边界 |
| [AI 与自动化](technical/ai-and-automation.md) | Provider、快捷 AI、CLI、分析、Agent/MCP/ACP |
| [后续能力与AiBox设计参考](technical/capability-expansion.md) | P2–P4产品目标、模块拆分、实现合同与完整验收义务 |
| [Agent与外部协议边界](technical/agent-protocol-boundaries.md) | MCP版本、来源授权、回路与ACP评估结果 |
| [数据与权限](technical/data-and-permissions.md) | TCC、上下文、存储、采集与执行策略 |
| [P1会话保留](technical/session-retention.md) | 已实现的总预算、元数据维护、清除和恢复围栏及待验收边界 |
| [复用评估](technical/reuse-assessment.md) | AiBox/Ashot 可借鉴模块与迁移条件 |
| [验证方案](technical/validation.md) | 合成测试、真实 Mac/API 验收及性能预算 |
| [工程流水线](technical/release-pipeline.md) | 共用检查／调试／签名公证／安装回退／上传与回下载 |
| [GitHub 托管](governance/github-publication.md) | 公开范围、目标账号、分支与发布准备 |
| [alpha.4发行说明](releases/v0.1.0-alpha.4.md) | 扩展能力、系统资格与验收边界；实际发布状态见Releases及状态总账 |
| [alpha.5发行说明](releases/v0.1.0-alpha.5.md) | 独立剪贴板快捷面板与快捷键分类；实际发行状态见状态总账 |
| [alpha.6发行说明](releases/v0.1.0-alpha.6.md) | 稳定窗口动作、命名应用控制与最小回执；实际发行状态见状态总账 |
| [剪贴板原生交互复查](implementation/clipboard-panel-2026-11-24.md) | 查询／选择／插入围栏、快捷键定制和中英深浅色实查 |
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
