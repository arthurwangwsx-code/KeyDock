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

2026-11-26，scope基础层、Workbench策略及App组合根已接入。独立Coordinator只组合原ClipboardPanel、窄设置和HotkeyCenter，不构造通用Launcher／Workspace。原生field editor拒绝paste／readSelection／drop，保留键入与组合输入；关闭时等待本次捕获／插入任务收口。源、签名配对与原生结果分别记录在[App复查](../implementation/desktop-review-app-2026-11-26.md)，不据编译通过声称真实插入已验收。正式发行与安装为alpha.23。

## 可重复调试入口

在干净的命名分支运行`make desktop-review-build`，默认使用release/config.json中的Developer ID签名。先签名companion，再把最终binary／Info摘要写入Review的BuildInfo并签名Review；固定cache为`build/pipeline/desktop-review/DerivedData`。活动配对存在、任何固定输出祖先为symlink或源发生变化时拒绝重建；普通build／install／package／publish不接纳此profile。

`make desktop-review`新建private UUID会话，先持久化intent再启动companion／写marker／启动Review。输出的launch receipt保存PID、非空birth、精确路径和源，不含正文。`ready=false`只表示启动器没有证明App/UI就绪，不是失败结论；需原生观察。启动失败保留partial回执，只对已确认的本次实例请求正常退出；未确认身份或退出拒绝时保留，绝不强杀。TERM/HUP同样进入这一收口。它不提供同UID恶意进程隔离。

用`make desktop-review-status RECEIPT="<输出的绝对回执路径>"`核对；`make desktop-review-stop RECEIPT="..." REVIEW_ONLY=1`只正常退出Review，保留原companion，然后`make desktop-review REVIEW_ROOT="<原root绝对路径>"`验证重启持久化。复用前检查owner锁已释放且companion的PID/birth未变，不改活跃marker。完整结束使用`make desktop-review-stop RECEIPT="<最新回执>"`，先Review后companion；任一身份未知先整批拒绝。

窄设置中明确载入合成历史，再选择“为合成目标打开剪贴板”，或在companion前台按用户录制的快捷键。系统Accessibility须由用户在系统设置正常授权；本入口不改TCC。缺权限时仍可验证面板及复制，插入保持不可用。真实目标文本、其他窗口、取消／切换／重启与实体按键需分别取证。
