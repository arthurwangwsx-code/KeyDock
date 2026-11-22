# 竞品与能力调研

查询日期：2026-11-22。证据为官方产品页、帮助文档和开发者资料；未在本机安装竞品实测。动态功能、价格与支持平台在实施/发布前再次核查。表内事实附来源，KeyDock 定位与取舍属于本项目判断。

## 快捷操作基线

| 产品 | 官方确认的能力 | 模式/平台与借鉴 |
|---|---|---|
| [Spotlight](https://support.apple.com/guide/mac-help/mchl4953dfeb/mac) | 应用/文件搜索、Actions/Shortcuts、Quick Keys、菜单搜索；当前系统还有[剪贴板历史](https://support.apple.com/guide/mac-help/mchl40d5b86b/mac) | macOS 内置。不能用旧版“只有搜索”的描述设计差异化 |
| [Raycast](https://www.raycast.com/pricing) | 核心剪贴板、Snippets、Quicklinks、计算器、窗口管理、扩展；[Navigation](https://manual.raycast.com/navigation) 包含跨应用按标题搜索/切换窗口 | 核心免费、Pro 提供 AI 等；macOS 为主，Windows 公开 beta。统一命令/动作与开发体验值得参考 |
| [Alfred 6](https://www.alfredapp.com/) | 搜索；[Powerpack](https://www.alfredapp.com/powerpack/) 提供剪贴板、文本展开、Workflows、Universal Actions 和 Alfred UI toolkit | macOS，核心免费/Powerpack 付费。JSON 驱动的原生扩展 UI、对象动作和工作流很有价值 |
| [LaunchBar 6](https://www.obdev.at/products/launchbar/features.html) | 自适应缩写、Instant Send/Send To、Quick Look、脚本动作和剪贴板合并 | 付费 macOS。参考“选中对象→可执行动作” |
| [Keyboard Maestro](https://www.keyboardmaestro.com/main/) | 宏/触发器/条件/循环、脚本、OCR、窗口、多剪贴板与应用切换 | 付费 macOS。[Window Switcher](https://wiki.keyboardmaestro.com/manual/Window_Switcher) 描述当前应用窗口，不据此宣称跨应用窗口搜索 |

Raycast 内置窗口管理属于免费核心，但[开发者 WindowManagement API](https://developers.raycast.com/api-reference/window-management) 文档标明 Pro，且不支持 Windows；功能权益与扩展 API 不能混记。本文不冻结价格数字，避免长期需求受一次快照误导。

## AI 能力基线

| 产品/能力 | 官方描述 | KeyDock 的设计启发 |
|---|---|---|
| [Raycast AI Commands](https://manual.raycast.com/ai/ai-commands) | 自定义提示词、选择模型、selection/clipboard/argument 输入、窗口输出或替换选区 | AIAction 是一等命令，输入/模型/输出/shortcut 结构化 |
| [Raycast AI Extensions](https://manual.raycast.com/ai/ai-extensions) | 扩展暴露 tools，可由 AI 选择工具/参数，提供权限配置 | Command 和 Tool 区分入口，共享执行实现 |
| [Raycast Agents](https://manual.raycast.com/ai/agents) | 保存角色、模型、工具及推理配置 | AgentDefinition 与一次 AgentRun 分离 |
| [Raycast Screen Awareness](https://manual.raycast.com/ai/screen-awareness) | 用户触发附加前台 App/AX/选区/窗口截图与浏览器正文 | ContextEnvelope 保存来源和范围，屏幕截图与文本权限分开 |
| [Raycast Automations](https://manual.raycast.com/ai/automations) | 定时 AI、tools/MCP/Skills；需要输入/授权时暂停 | 调度创建统一 Run，不能另造一套执行系统 |
| [Alfred Brain Outsourcing](https://alfred.app/workflows/alfredapp/brain-outsourcing/) | Alfred 6 workflow，支持远端和 Ollama/LM Studio/llama.cpp 等 endpoint | 模型接入独立于启动器 UI，本地模型同样做能力协商 |
| [BoltAI](https://boltai.com/) | 多模型、本地模型、Agent/MCP、文件截图分析、全局入口与提示词 | 瞬时快捷面板和长任务工作区各有职责 |
| [Enconvo](https://www.enconvo.com/) | 选区/屏幕上下文、Agent、插件、MCP/Skills、工作流 | 系统工具和 AI 使用共同能力层，首期不全量复制其功能 |

Raycast 当前 [AI 总览](https://manual.raycast.com/ai) 已覆盖工具、Agent 和自动化，因此目标不能仅为“启动器加聊天框”。Alfred 团队[旧 ChatGPT workflow 公告](https://www.alfredforum.com/topic/21483-chatgpt-openai-integrations/)也已指向新版 Brain Outsourcing。

## 隐私与个人分析

Raycast 的 [BYOK 文档](https://manual.raycast.com/ai/bring-your-own-key)分别描述经其服务器和直达 Provider 的路径；自带 key 不自动代表直连。[AI 隐私页](https://manual.raycast.com/ai/raycast-ai-privacy-security)另有图像附件、历史、同步和服务商保留说明。KeyDock 需按最终真实数据流说明，不能借用竞品营销语保证“全本地”。

[Raycast Personalization](https://manual.raycast.com/ai/personalization)的近期聊天记忆与整机活动观察是不同类别。[ActivityWatch](https://activitywatch.net/)可参考前台活动、类别、时间归属和本地数据体验；它不是已经替 KeyDock 完成的 AI 洞察引擎。使用分析首期只针对本工具最小事件，个人全机活动为另行启用的后续范围。

[Alfred Clipboard](https://www.alfredapp.com/help/features/clipboard/)的 concealed/密码管理器排除、保留/清理属于可借鉴基线；仍不能推断任何实现能发现全部敏感剪贴板内容。

## 产品判断

以原生快捷工作台、结构化 CLI 任务、可配置 AI 短动作和可审阅 Agent 为主线。搜索/切换/剪贴板是基础完整性；差异化需要实际任务成本和用户反馈验证。首版纳入 AI 翻译/总结、命令草稿和只读工具验证；个人洞察、多步 Agent、截图/OCR、MCP 与定时任务按路线逐步建设。
