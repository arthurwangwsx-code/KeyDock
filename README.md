# KeyDock

面向 macOS 的原生快捷操作与 AI 工作台。用统一入口搜索应用和窗口、运行命令、处理剪贴板，并通过快捷键完成翻译、总结和可控的 Agent 任务。

**当前阶段：规划与架构提案已建立；尚无可运行的 App。** 本仓库独立于 AiBox，未迁入其源码、个人截图或历史数据。

## 首版方向

- 全局唤起、应用启动、跨应用窗口搜索与切换。
- 保存的命令行工具：参数、工作目录、运行状态、输出与取消；交互工具交给用户终端。
- 本地纯文本剪贴板历史，支持暂停、排除、保留期限和清空。
- 接入外部模型 API，以可配置快捷键完成选区翻译、总结和提示词动作；结果可展示、复制，或经确认后替换选区。
- 后续扩展窗口布局、截图/OCR、个人使用分析、工作流、MCP 和通用 Agent。

AI 是核心能力域，模型账号和联网并非基础桌面操作的前提。

## 文档与下一步

从 [文档总览](docs/README.md) 阅读完整产品、架构和研究结论。

| 入口 | 内容 |
|---|---|
| [产品需求](docs/product/requirements.md) | 能力范围、快捷动作、用户闭环与优先级 |
| [建设路线](docs/product/roadmap.md) | P0 到 P4、阶段验收与待决事项 |
| [系统架构](docs/technical/architecture.md) | 模块、契约、搜索与执行链路 |
| [AI 与 Agent](docs/technical/ai-and-automation.md) | Provider、翻译/总结、命令建议、分析和工具调用 |
| [开源参考](references/README.md) | 固定 revision 的参考工程目录与复用规则 |
| [当前状态](docs/status.md) | 已完成规划与未完成实现的区别 |
| [iSpec 提案](ispec/changes/keydock-foundation/10-proposal.md) | 需求、设计、场景与执行任务 |

下一步实现 P0：原生 Panel、快捷键和焦点恢复、命令注册/搜索、模拟 AI 流与工具策略验证。首个可日用版本 P1 包含 AI 翻译/总结。

## 开发与托管

按 [CONTRIBUTING.md](CONTRIBUTING.md) 准备环境。canonical checkout 在本地；目标 GitHub 为 `arthurwangwsx-code/KeyDock`，尚未创建或推送。默认分支 master，开发从 master 创建命名分支。开源前按 [托管方案](docs/governance/github-publication.md) 确认具体远端。

原创文件采用 [MIT](LICENSE)。技术支持、反馈与隐私请求：arthur.wang.wsx@gmail.com。
