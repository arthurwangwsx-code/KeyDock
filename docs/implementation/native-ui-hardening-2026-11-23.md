# 原生界面与任务边界复查：2026-11-23

整体仍为 **PARTIAL**。本轮延续用户要求的独立启动台、独立设置、菜单栏入口、Liquid Glass、中英文和组件库。当前基本窗口画面和定向操作通过，用户最终视觉评审、完整系统矩阵与外部模型验收未完成。

## 实际界面

环境为 macOS 27.2／arm64、Xcode 27.2，本地 ad-hoc Debug 的 KeyDockSafeSmoke 模式。真实剪贴板与选区采集、权限请求和钥匙串关闭。截图与 AX 状态通过 CUA 实际观察，未导出个人桌面截图。

| 范围 | 结果 | 本轮证据 |
|---|---|---|
| 启动台 | PASS（基本） | 中文浅色、英文深色实际可见；原生玻璃、搜索、结果、动作入口保持统一 |
| 独立设置 | PASS（基本） | ⌘, 打开标准侧栏窗口，通用和命令页面实际检查；英文长标签完整 |
| 菜单入口 | PASS | 应用菜单实际包含 Open KeyDock、Workspace、Settings…、Quit；状态栏菜单同由组合根管理 |
| 运行时语言 | PASS（定向） | 中文切英文后，现有工作区侧栏、标题、查询占位符、预览与取消固定按钮同步更新；最后恢复中文 |
| 深浅色 | PASS（基本） | 设置和启动台的应用内 Dark／Follow System 实际观察；最后恢复跟随系统，未改全局系统设置 |
| 剪贴板行操作 | PASS（定向） | List 改为 ScrollView／LazyVStack 后，Preview／Pin／Copy／Delete 分别暴露 AX Button；点击预览与固定均命中正确动作 |
| 全文预览与搜索 | PASS | 800 字符合成文本尾部超出列表前400字符，仍可搜索并在原生只读详情看到；关闭预览、固定后查询保持 |
| 正常退出 | PASS（本轮无活跃任务） | CmdQ 后应用清单无 KeyDock；进程核查后只删除本轮两条合成数据库记录，剩余0条 |

复制后原生粘贴全文的证据来自本日稍早的独立预览检查，见忽略的 `.local/clipboard-native-smoke.json`；本轮重点复验新行结构的独立控件与命中。删除／全部清空未进行 UI 操作，另由存储和会话测试验证，不能混为同一证据。完整 VoiceOver、IME 组合输入、多屏、全屏和真实透明度／动态效果开关仍未验收。

## 实现边界

- `KeyDockUI` 继续集中管理玻璃、搜索、行、键帽和提示；当前27主机采用 SwiftUI 原生 glassEffect，14–25保留 NSVisualEffectView 回退。固定 hosting 身份，显示选项改变材料参数，不重建输入树。
- `ClipboardBrowserSession` 每窗口持有查询、轻量预览和一个明确打开的正文；全文匹配在数据库 actor，列表只回传至多1600 UTF-8字节／400字符的预览。迟到结果、失效预览与窗口断开均有围栏；操作发起时固定共享变更通知。
- CLI 编辑、后台执行与终端交接共用 SavedCommand 校验；纯脚本测试验证 argv、环境、目录与 shell 引号。Terminal GUI 被工具禁止访问，真实终端执行仍为 PARTIAL。
- 宿主动作从声明读取上下文和效果，包括剪贴板输入、普通 AI、只读 Agent、复制与替换。普通文本动作 tools=[]；模型命令建议只进入审阅，不自动运行。
- AI 输入上限128 KiB，任务输出上限1 MiB且保持合法UTF-8。超限、截断、空响应、取消和旧 revision 不可自动复制或替换；用户在请求期间改变剪贴板时保留结果并跳过自动复制。
- P1 AI 最小回执在网络前落盘 intent，终态保存元数据；不保存正文、密钥或原目标。三个入口在真实 loopback 请求中被专用子进程 SIGKILL 后，重启仅显示 interrupted／unknown，不重发、复制或审阅。此证据不是完整安装版 GUI 崩溃验收，P2完整 RunStore仍未实现。
- 退出时同步设置围栏并取消已有工作，再异步等待回执收尾。定向回归先复现了退出后请求／审阅仍可能发生的问题，修复后三入口均无新请求或回调。

## 自动化与性能

最新全套 **120项测试通过**：WorkbenchFeature 58、ExecutionCore 21、CommandCore 14、MacAdapters 4、AI／Agent 23。214条源文案 key 的英中静态覆盖通过；原生 Debug safe-smoke 构建通过。真实外部 API、钥匙串联调和20条模型质量样本仍未运行。

2,000条合成命令，预热10次、采样100次：Release 排序 p95 21.84ms；生产 QueryRequest→缓存Provider→QueryCoordinator→首批ResultBatch 的 p95 23.36ms。范围不含渲染、AX和索引；热唤起 p95≤150ms 尚未证明。

本地证据：`.local/foundation-hardening-tests.log`、`.local/foundation-hardening-localization.log`、`.local/foundation-hardening-native-build.log`、`.local/native-ui-hardening-2026-11-23.json`、`.local/query-pipeline-benchmark.log`。iSpec测量绑定当前apply attempt，失败回归也保留。唯一canonical checkout、feature/phase-one、master未晋升；未推送或发布。
