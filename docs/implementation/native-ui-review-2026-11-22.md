# 原生界面实机复查：2026-11-22

当前结论 **PARTIAL**。早前 Mac 锁屏阻碍已解除。本轮实际观察了新版启动台、独立设置、工作区与 AI 输入界面，修复了动态切换语言、控件宽度和输入焦点问题；完整系统矩阵与真实 AI 仍待验收。

环境：macOS27.2／arm64，Xcode27.2，本地ad-hoc Debug，KeyDockSafeSmoke隔离模式。上下文采集、真实钥匙串访问关闭，剪贴板录制关闭；只使用合成文本和合成命令。截图与AX状态已在本会话的CUA结果中实际观察，未导出或上传个人桌面截图。

| 操作 | 结果 | 证据范围 |
|---|---|---|
| 启动台展示 | PASS | 680×440浮层、圆角、原生玻璃背景、搜索与动作层级实际可见 |
| ⌘,打开设置 | PASS | 独立原生侧栏窗口；启动台收起，菜单中有设置入口 |
| 中文→英文→中文 | PASS | 侧栏、菜单、正文、占位符和内置AI动作同步变化；修复List旧标签缓存 |
| 长英文标签 | PASS | 增加侧栏宽度后Privacy & Permissions完整显示 |
| 深浅外观 | PASS（基本） | 应用内Dark与Follow System（当前浅色）实际观察；动态系统色与标准导航可见；未改全局系统设置 |
| 第七项结果 | PASS | 六次Down实际选到第七个对象，列表自动滚动；默认动作标签随类型变更 |
| 中文搜索／粘贴 | PASS | 合成“翻译”进入搜索，正确返回AI动作；不等同真实IME组合输入验收 |
| AI无选区 | PASS | 明确空输入提示、禁用空Run；打开后自动获得输入焦点，直接按a进入文本 |
| AI进入工作区 | PASS | 合成输入原样保留；未配置API时显示明确提示，无外部请求 |
| 查询→后台CLI→工作区 | PASS | 最终QueryCoordinator链路搜索printf、Return执行、⌘,仍可打开设置；工作区自动选中新任务，输出KeyDock synthetic CLI PASS，exit 0 |
| 正常退出 | PASS（无活跃任务） | CmdQ退出；本机进程确认无残留；有活跃sleep退出证据仍来自初版独立测试 |
| 终端交接 | PARTIAL | UI与回执显示handedOff，但测试marker未产生；CUA明确拒绝访问com.apple.Terminal。已改为显式Terminal应用URL与异步打开回调，尚未重跑真实终端验收 |
| 辅助功能显示选项 | PARTIAL | 代码采用SwiftUI实时环境切换透明度／动态效果；未在真实系统开关下验收 |
| 多屏／全屏／AX／VoiceOver／IME | NOT_RUN | 仍需真实操作与权限；不得由合成测试或上述截图推断通过 |

材质从创建时读取系统偏好改为固定hosting + SwiftUI原生glassEffect；切换背景参数不重建搜索前景，旧系统使用NSVisualEffectView回退。减少透明度采用动态系统实色，减少动态效果禁用交互和动画。当前基本画面复查通过，不等同完整视觉矩阵或用户最终视觉认可。

终端测试采用独立合成touch命令，目标仅为随机命名的/tmp空文件；未写入个人目录。尚未执行的本轮合成.command脚本已清理。旧的默认文件关联路径不能作为终端执行通过证据。终端回查细节保存在忽略的.local/terminal-handoff-smoke.json。

自动化：77项测试通过（CommandCore14、ExecutionCore17、MacAdapters3、AI/Agent23、WorkbenchFeature20）。其中WorkbenchFeature包含12项会话／配置／生产查询链路测试和8项Store HTTP测试函数（9个场景）。真实URLSession loopback包含流式、取消、无副作用建议、过期请求、只读current_time工具两轮、401/429脱敏；未访问外部模型。201条UI key中英文静态覆盖通过。
