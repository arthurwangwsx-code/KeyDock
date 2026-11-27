# KeyDock

面向 macOS 的原生快捷操作与 AI 工作台。用统一入口搜索应用和窗口、运行命令、处理剪贴板，并通过快捷键完成翻译、总结和可控的 Agent 任务。

**当前阶段：P0–P4能力按增量实现，已公开并本机安装签名公证的 [alpha.28 测试版](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.28)；完整日用验收尚未完成。** 本仓库独立于 AiBox，未迁入其源码、个人截图或历史数据。

安装包见 [GitHub Releases](https://github.com/arthurwangwsx-code/KeyDock/releases)：macOS arm64，Developer ID签名、App／DMG公证与装订。下载包、完整源SHA和摘要随Release提供；这是早期预览，已知限制见发行说明。

## 首版方向

- 全局唤起、应用启动、跨应用窗口搜索与切换。
- 保存的命令行工具：参数、工作目录、运行状态、输出与取消；交互工具交给用户终端。
- 独立剪贴板面板与快捷键，提供查询、键盘选择、复制／插入及有序多条合并，支持暂停、排除、保留期限和清空；真实跨应用／权限矩阵仍在验收。
- 接入外部模型 API，以可配置快捷键完成选区翻译、总结和提示词动作；结果可展示、复制，或经确认后替换选区。
- 已接通多应用桌面工作区、独立profile快捷键与逐项执行结果。当前源码另有窗口布局、本地OCR、使用分析、多步Agent、MCP HTTP／stdio、工作流与App内调度，以及Snippets／文件搜索／换算／URL动作／命令集合。入口见[扩展能力使用说明](docs/product/expanded-tools-guide.md)。

AI 是核心能力域，模型账号和联网并非基础桌面操作的前提。

支持[全局／场景／动作及Agent模型设置](docs/product/model-settings-guide.md)，包含官方推荐、服务模型清单、思考强度、协议和输出预算。alpha.27修补清除用量后的旧任务快照回流，保留任务与阈值，失效消耗显示未知；[实施记录](docs/implementation/usage-restoration-fence-2026-11-26.md)保存RED／GREEN、同源检查、双语原生子集及发行安装资格。alpha.26的启动台密度、冻结审批、任务滚动及最小窗口改进见[前序记录](docs/implementation/native-ui-clarity-2026-11-26.md)。

历史alpha.20新增默认关闭的任务内容保留、独立内容库和明确的新尝试输入复用，并修补大文本玻璃界面与关闭审阅。具体资格见[发行证据](docs/implementation/alpha20-release-2026-11-26.md)，未完成工程和系统验收见[后续清单](docs/technical/remaining-engineering-2026-11-26.md)。

设置页支持[脱敏设置摘要导出](docs/technical/settings-summary-export.md)，可预览准确JSON再保存。摘要排除自定义正文与连接／凭据，不能恢复应用，完整定义迁移另行建设。

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

当前已实现原生 Panel、应用索引、搜索/收藏/别名/快捷键配置、AX 窗口/选区适配、CLI/任务回执、SQLite 剪贴板、AI API/动作/只读工具基础。完整状态及真实验收缺口见 [第一阶段进度](docs/implementation/phase-one-progress.md)。

## 开发与托管

按 [CONTRIBUTING.md](CONTRIBUTING.md) 准备环境。

```sh
make doctor
make check
make debug
# 在已审查、已提交且同步 GitHub 的 master 上发布新版本：
make ship-plan
KEYDOCK_NOTARY_PROFILE=<已有profile> make ship
# 可选：安装已验证的正式包
make install
```

需要 Xcode、XcodeGen，当前构建使用 Xcode 27.2 / Xcode Swift 6.4.2；`xcrun` 可避开 PATH 中另一套不兼容工具链。最低目标 macOS 14 尚待真实最低系统验证。API 端点/模型由用户配置，密钥在设置页写入 Keychain；尚未进行真实外部模型验收。

源码已开源于 [arthurwangwsx-code/KeyDock](https://github.com/arthurwangwsx-code/KeyDock)，默认分支master。调试Preview与正式App分离，安装保留可核验的回退凭据。[工程流水线](docs/technical/release-pipeline.md)说明本地／CI入口、签名公证和资产复核；[托管方案](docs/governance/github-publication.md)记录公开范围。实际远端和发行状态见状态总账。

原创文件采用 [MIT](LICENSE)。技术支持、反馈与隐私请求：arthur.wang.wsx@gmail.com。
