# 原生界面下一轮切片

更新：任务41.1–41.4已在feature/native-ui-clarity实现并完成开发态原生子集，见[清晰度实施记录](../implementation/native-ui-clarity-2026-11-26.md)。下表保留问题来源；未据此宣告完整视觉合格，41.5–41.6继续开放。

本清单承接用户完整中英／Liquid Glass／独立启动台与设置目标，非新增范围。630ef83已实际修补预算卡语言刷新和关键信息对比度；下列候选由只读Agent审查发现，未复现者不能称为已确认原生FAIL。全部实现仍由主Agent单写，下一分支从master建立。

| 优先项 | 当前证据 | 实现／验收边界 |
|---|---|---|
| 叶子视图语言依赖 | AIContentView的AIUsageStatusView、Workbench结果子View、空草稿菜单内部调用非观察式L；TaskHistoryRow已有language值依赖 | 先复现中英往返，传明确语言依赖，保留正文／结果／选择／焦点；不要给整个List加id |
| 人类可读审批标题 | AgentApprovalView实际显示command_UUID；原生已观察。协议ID来自SavedCommandAITool | 宿主建工具时冻结显示名，审批同时保留实际参数和协议ID，不从当前配置反查。待审改名／删除后仍显示原合同；辅助AI按钮应明确其实际场景模型 |
| 工具栏空壳 | WindowToolbarViews固定160宽右对齐，Coordinator以单NSToolbarItem承载；1920×960实际可见长pill仅靠右一枚齿轮 | 先按可见控件收紧，再评估标准项。AI／非AI、中英深浅、最窄／宽窗口核对点击区、AX名和分组 |
| 启动台密度 | LauncherView和AppKit面板均固定456高，稀疏结果已有实际观察 | 由AppKit有界调整内容高度并保留顶部锚点，复用hosting与输入控件；0／1／3／7／大量结果、↑↓滚动、compact AI和原目标快照单列 |
| 玻璃前景 | KDLauncherSurface只对背景shape施加glassEffect；偏灰根因尚未证明 | 用自建纯色背板固定内容，比较normal／opaque／all及系统合成结果，不直接加深底色冒充Liquid Glass；同时回归文字选区和焦点 |

Apple[工具栏指南](https://developer.apple.com/design/human-interface-guidelines/toolbars)支持标准控件与功能分组；[glassEffect说明](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))是前景／材质接线复查依据，不能单靠文档宣布本应用视觉合格。

调试链还需将普通native-review改成每次不可覆盖的运行记录和明确重启；本轮private helper保存两份快照不等于通用CLI已实现。签名Review旧配对afb97cb未重建，不为真实插入、权限撤销或实体热键补资格。459559a的CI45780991896已定位到ReviewScope并发配置提交／SQLite增长测试invalidScope；630ef83本机和两次CI通过，旧失败保留，确定性重现及根因修补另行验证。

完整视觉、输入法、VoiceOver、多屏、最低系统和长期驻留继续独立，不将CUA操作等同于实体键盘／真实输入法验收。
