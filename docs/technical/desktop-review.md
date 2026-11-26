# 独立桌面快捷操作验收入口

承接任务10.1–10.2；开发基线为alpha.20后的master。此入口用于验收真实剪贴板插入，不能替代正式App身份、实体键盘、完整AX／多屏／IME与日用资格。

## 运行合同

- 独立`KEYDOCK_DESKTOP_REVIEW`配置、`.desktopreview` bundle与BuildInfo profile；仅本地开发，生产安装／package／publish拒绝。正式与普通Preview均拒绝该入口参数，现有SafeSmoke能力不放宽。
- Review签名metadata绑定固定companion路径、bundleID、Info.plist／binary摘要。companion复用已有三窗口合成宿主源码，使用独立fixture身份；每次运行绑定PID和非空launchDate。
- owned UUID根目录、marker和companion逐层no-follow验证并持有FD；目录与不可变文件分别比较身份。任何已发现的替换、权限／实例变化永久撤销本次scope。每次捕获前后及paste事务的`isCurrent`复查；不是同UID恶意进程沙箱。
- Review只显示原ClipboardPanel和一张窄设置页，复用HotkeyRecorder、主动作偏好、HotkeyCenter和原Host授权／paste事务。仅注册剪贴板绑定，不开放Launcher、AI／CLI／MCP／工作流、导入／文件查询或调度。

## 数据与任务隔离

Workbench显式接收Review scope，`allowContextCapture`保持false，dataDirectory必须匹配scope；禁止真实目录fallback。Review配置仅接受语言／外观及固定剪贴板绑定，其他定义和API配置必须为空。独立持久Data保存合成剪贴板和设置；每次启动新建空auxiliary session，回执／用量／材料实例仅指向它，调度／活动使用空persistence。不恢复旧任务或启动普通维护／索引。

Review模式强制inert ClipboardCaptureSource、nil一般剪贴板reader、拒绝凭据端口；中央Host授权仅放行明确的历史选择复制和受scope限制的插入，任务admission及所有绕过admission的网络／文件／MCP入口同时拒绝。不能用广泛的copyText许可开放其他工具。

只调用读取位置元数据的`capturePasteTarget`，不调用读取选区正文的captureTarget。用户明确选择的合成文本可写为当前剪贴板；发送前只读回本次私有nonce和changeCount，不读取或恢复旧正文。Review自己的文本输入也拒绝标准paste／拖入，避免将个人剪贴板引入验收查询。

## 操作与证据

构建／启动由工程CLI统一执行，并通过共享存储租约。启动器只管理本次companion／Review实例，记录身份和退出，不记录正文；取消只请求精确实例正常退出，不操作其他同名App。新profile默认使用现有Developer ID签名，TCC仍须用户正常授予。

检查实际目标文本恰好插入一次、其他窗口不变、查询／选择／窗口变化与取消拒绝迟到发送、重启不重放，以及快捷键录制／冲突／持久化。自动化注入只证明路由；实体键盘另行验收。缺权限时明确报告拒绝，不自动修改TCC，不把发送请求当作目标已消费。

## 实施进度

2026-11-26，scope基础层及Workbench策略／存储接线已实现，参见[基础层复查](../implementation/desktop-review-scope-2026-11-26.md)和[模型层复查](../implementation/desktop-review-model-2026-11-26.md)。本节完整运行合同仍待App接入；当前尚无可启动的Review配置、窄设置或真实companion会话，不据基础层通过声称真实插入已验收。正式发行与安装仍为alpha.20。
