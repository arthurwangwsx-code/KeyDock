# 当前状态总账

日期：2026-11-22。范围：产品规划与架构提案；当前应用整体状态为 PARTIAL（尚未实现），不可日用、不可安装，无产品版本。

| 项目 | 状态 | 证据/边界 |
|---|---|---|
| 用户需求与 KeyDock 代号 | PASS | 产品需求纳入启动/窗口/CLI/剪贴板、AI 总结/翻译快捷键、命令扩展、使用分析和 Agent |
| 竞品调研 | PASS | 官方来源快照；未做竞品本机实测 |
| 开源参考 | PASS | references/catalog.json：13 项固定 SHA/许可证据，全部 reference-only，零源码复制 |
| AiBox/Ashot 复用评估 | PASS | 当前源码只读盘点与成本评估；未迁代码、数据或凭据 |
| 架构与执行策略 | PASS | 原生模块边界、模型/工具/Agent、权限/数据/usage/恢复设计；仍待实现验证 |
| iSpec 规划工件 | PASS | proposal/design/4 capability specs/tasks，CLI 严格校验通过；apply 未执行 |
| 产品/技术/开源只读评审 | PASS | 三路评审问题已整合：任务入口、质量门槛、状态机、usage 去重、许可证据 |
| 文档与工程脚本检查 | PASS | 24 份 Markdown、13 个参考、17 条需求/22 个场景/47 个任务；链接/JSON/脚本语法/分支规则/iSpec strict 通过，见 [回执](planning-validation.json) |
| P0–P4 运行时 | PARTIAL | 47 项实施/发布任务均未完成；尚无 Swift App 或产品构建 |
| 真实 Mac / 外部模型 API 验收 | PARTIAL | 尚未开始，不能用文档/mock/Git 代替 |
| GitHub 公开托管 | PARTIAL | 已核对账号，候选 arthurwangwsx-code/KeyDock；未创建、无 remote、未 push |

## 后续入口

从 iSpec 30-tasks.md 的 1.1 开始 P0：Swift 工程、命令合同、原生 Panel/快捷键、搜索和 AI mock。首个 P1 日用版本必须包含 AI 翻译/总结、可配置快捷键与最小任务列表；最低 OS/真实 API 选择在实施前锁定。

本地 canonical checkout 只有一个，使用 master 基线与 feature/product-foundation 规划分支，未建立 worktree。未改动既有 AiBox/Ashot/MacShortCutTest 工程。支持与隐私联系 arthur.wang.wsx@gmail.com。
