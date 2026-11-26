# 独立桌面验收App接线

目标承接任务36.3–36.5，不改变完整P0–P4验收范围。正式公开及本机安装仍为alpha.23；本增量为本地专用Review配对。

## 当前已验证

- PASS：独立ReleaseDesktopReview原生App构建，测量`receipts/desktop-review-native-compile.json`，约107秒。
- PASS：39项定向Swift测试，测量`receipts/desktop-review-app-tests-v4.json`；配置／Scope、跨profile参数拒绝、原生paste入口及键入／IME组合。
- PASS：150项Python回归，测量`receipts/desktop-review-all-python-v2.json`；包括8项新流水线测试及真实owned Python TERM/HUP，无真实App或TCC操作。其后新增cache symlink回归，待同源完整检查。
- 已保留初次field editor构造参数编译失败、无text network导致空查询／IME失败、CGFloat歧义及测试signal枚举字符串失败；修复后对应回归通过。全Python首次增加package raw Info读取破坏了5个既有注入测试，已改为复用统一inspect_app预检，原断言及发行边界保留。
- 只读评审发现的预期失焦取消、跨文件AppL可见性、预览正文焦点下Command-Return、helper先覆盖、输出／cache symlink和启动中断收口已修正。App随后新增的退出drain及完整签名配对仍需最终构建。

## 接线与限制

普通App和Preview拒绝Review参数；Review只接受固定编译身份／safe-smoke／签名BuildInfo及一个root参数，验证后异步建立Scope，再构造Workbench。无真实用户目录fallback。窄设置提供语言／外观、剪贴板快捷键与主动作／分隔符，以及明确加载合成历史和打开固定目标。菜单栏提供设置入口。

输入限制位于窗口返回的独立NSTextView field editor；菜单不是唯一门禁。面板复用生产ClipboardPanelSession、Host授权、paste事务、generation和activation fence。每次捕获前后都检查固定PID/birth与Scope；第三应用激活撤销准备，Scope失效停用快捷键。

签名配对、实际原生显示／插入消费、拒绝／重启、物理热键尚待后续证据。Review资格不会关闭正式身份、多屏、IME实操、VoiceOver、最低系统或长期驻留。操作方式见[独立桌面验收入口](../technical/desktop-review.md)。
