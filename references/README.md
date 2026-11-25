# 开源参考工程

本目录把参考工程纳入工程知识库，采用链接 + 固定 SHA + 研究用途，不克隆/vendor 第三方源码，不带入私有媒体。2026-11-22 核对了 GitHub 元数据、固定版本 README/根许可；未进行构建或安全审计。所有项目当时 archived=false，最近提交仅是维护信号。

机器可读登记：[catalog.json](catalog.json)。原有13项为 reference-only；2026-11-25新增Time为独立测试环境依赖，copiedFiles 均为空。固定 SHA 用于研究复现，不是建议依赖的发布版本。

| 项目 | 技术与许可证快照 | 参考方向/使用判断 |
|---|---|---|
| [ospfranco/sol](https://github.com/ospfranco/sol/tree/873ae1c28b153f190a57a56a5ad2bea2159611f8) | TypeScript / React Native macOS；MIT | launcher 与各工具的组合边界。研究整体结构，不引入 RN 作为复用代价 |
| [mikker/LeaderKey](https://github.com/mikker/LeaderKey/tree/16bcb307dcc5309fbc3a00fe398d913e1f7ddc51) | Swift；MIT | leader key 与多层快捷动作配置。作者转向 Tuna，研究交互，不作为持续维护底座 |
| [p0deje/Maccy](https://github.com/p0deje/Maccy/tree/f0b571e32e4031d7b91ba811f50d0f33e8e5548b) | Swift；MIT | clipboard 过滤/搜索/暂停/固定/粘贴。剪贴板设计首选参考，逐模块审查后可考虑复用 |
| [rxhanson/Rectangle](https://github.com/rxhanson/Rectangle/tree/adbc8a0560367a6c0a56b2e8ae6f39a24740ab14) | Swift；MIT (LICENSE text; GitHub NOASSERTION) | 窗口几何/跨屏/恢复/URL actions。窗口参考；可先做用户可选 URL scheme 集成，保留 Spectacle attribution |
| [lwouis/alt-tab-macos](https://github.com/lwouis/alt-tab-macos/tree/950c1a4e749aef53637bf2833b4a09328cdbce8e) | Swift；GPL-3.0 | 窗口切换/缩略图/最小化/Space 边界。仅研究行为和验收，独立实现；复制/派生另行评估许可 |
| [Hammerspoon/hammerspoon](https://github.com/Hammerspoon/hammerspoon/tree/23e387e2805a9890066366e0ac96c71b27f0cfd5) | Objective-C / Lua；MIT | OS 模块/事件订阅/modal hotkeys/脚本桥。参考 API，逐项检查公开/私有系统接口 |
| [oliverschwendener/ueli](https://github.com/oliverschwendener/ueli/tree/94104292d82b95dfa9300a432dd2ad45d41c2e28) | TypeScript / Electron / React；MIT | 扩展启停/设置/结果动作/终端。产品与配置参考，不引入 Electron |
| [johnlindquist/kit](https://github.com/johnlindquist/kit/tree/e82e7846392ba7ec8dac252a12af317d14486579) | TypeScript；MIT | 脚本 prompt/参数/CLI 自动化 SDK。SDK API 参考，不把 SDK 当整个桌面宿主 |
| [raycast/extensions](https://github.com/raycast/extensions/tree/d0cd72a2a83719a8a8ef93633655b93b0df1b254) | TypeScript / React；MIT (root; per-extension dependencies separate) | manifest/List/Detail/Form 与真实服务扩展。仅扩展示例；不是 Raycast 宿主，不承诺 runtime/API 兼容 |
| [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58) | Swift / SPM；MIT | 全局快捷键录制/冲突/持久化/原生 UI。P0 直接依赖候选，锁 release 与许可后引入 |
| [modelcontextprotocol/swift-sdk](https://github.com/modelcontextprotocol/swift-sdk/tree/c0ffca7b7d564aa750203988782d1f9966893a00) | Swift；Apache-2.0 / historical MIT; docs CC-BY-4.0 | MCP client/server/stdio/HTTP/取消/进度。MCP adapter 候选；当前 Swift6.1+/macOS13+，按实际版本复核 |
| [aaif-goose/goose](https://github.com/aaif-goose/goose/tree/36b29113aff691e1a46a21a5c25900824caf9949) | Rust；Apache-2.0 | Agent 状态机/operations/providers/恢复/ACP。旧 block/goose 重定向；oi-kit alpha，参考或可选 ACP adapter |
| [anomalyco/opencode](https://github.com/anomalyco/opencode/tree/ee5fe34e136488a1839ac73bcca8321c51a31b75) | TypeScript；MIT | 多 Provider/自定义 endpoint/plan-build/权限档。可选 CLI/Agent adapter，不强绑核心；权限规则不是 OS 沙箱 |

| [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers/tree/c799c8552b0f27b7a33a7b9233773da144dddcf5) | Python；包metadata MIT，根许可Apache-2.0／历史MIT过渡，文档CC-BY-4.0 | 官方Time 2026.11.18，仅在owned临时环境验证两协议／两传输；固定SDK 2.3.0及完整wheel哈希，不加入App。见[互通合同](../docs/technical/mcp-independent-interoperability.md) |

## 优先级

P0 先评估 KeyboardShortcuts 与 AiBox 现有 hotkey 接缝，二选一或独立实现，不重复叠加。P1 优先研究 Maccy 的剪贴板策略；P2 研究 Rectangle 和 AltTab 的几何/窗口行为；P3 再做 MCP SDK 与 ACP/CLI Agent adapter 的具体集成；AI Provider/ToolBroker/Agent 契约从 P0 设计。Sol/Ueli/Script Kit/Hammerspoon/Raycast extensions 用于产品与契约设计。

## 许可与范围

Rectangle 的 GitHub 自动许可证分类为 NOASSERTION，但固定 [LICENSE](https://github.com/rxhanson/Rectangle/blob/adbc8a0560367a6c0a56b2e8ae6f39a24740ab14/LICENSE) 正文为 MIT，需保留 Spectacle attribution。[MCP SDK LICENSE](https://github.com/modelcontextprotocol/swift-sdk/blob/c0ffca7b7d564aa750203988782d1f9966893a00/LICENSE) 处于 Apache-2.0/历史 MIT 过渡，非规范文档另有 CC-BY-4.0；不能简单写 MIT。最终以实际纳入版本、文件头和全部依赖许可为准。

AltTab 按 GPL-3.0 行为研究并独立实现；若将来复制/派生，重新评估整个组合和分发要求。Raycast extensions 的根 MIT 不覆盖 Raycast 宿主、SDK 二进制、品牌或服务 API 权利，不构成可直接运行的兼容层。Goose 当前仓库为 aaif-goose/goose，oi-kit 是 alpha，ACP 是外部 Agent 接入协议，不等于 MCP 工具协议。

实际采用某库时新增 provenance receipt：来源 URL/revision、文件 hash、依赖版本、license/notices、用途、修改、已验证行为和回滚。不要将 stars 或 recent commit 当作质量、安全或授权的证明。
