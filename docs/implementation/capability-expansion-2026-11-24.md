# 扩展能力实现与验收记录

2026-11-24，canonical唯一目录，分支`feature/desktop-capability-expansion`从master `a147e3c`创建。主Agent独占写入／分支／提交／设备，子Agent只读研究评审及/tmp原创提案；没有新建worktree、复制checkout或改动AiBox。

## 交付范围

当前源码已接入窗口布局、可配置多步Agent、工作流／App内调度、MCP HTTP／stdio、OCR／文件文本上下文、工具内分析、Snippets、文件名搜索、计算／换算、URL动作和命令集合。入口与限制见[使用说明](../product/expanded-tools-guide.md)；架构与AiBox对照见[能力方案](../technical/capability-expansion.md)及[协议边界](../technical/agent-protocol-boundaries.md)。

CommandCore保持纯命令与几何／工具模型；ExecutionCore统一策略、真实进程与回执；AgentCore保持有界回路／冻结工具／逐次审批；AutomationCore独立承载工作流、调度与统计；MCPAdapters隔离协议；MacAdapters承载AX／Vision／文件身份。UI通过WorkbenchFeature装配，App保留菜单／窗口薄组合根。

## 已验证证据

- 最终统一检查`expansion-unified-check-v3`通过382项Swift（主体373＋独立Terminal生命周期9）、34项Python、503条中英key、文档与lifecycle helper编译；测量`5bd6e3e6-99e7-4858-a000-e2f4e5c6b505`，2026-11-24T11:34:13Z–11:35:13Z，退出码0。
- 合成Vision图片实际识别；UTF-8、PDF文本层、输入限制、取消与排他目录owner测试通过。
- 真实owned子进程忽略TERM的取消／回收回归通过；Broker关闭等实际调用收口，派发后异常与回执保存未知不伪报普通无副作用失败。
- 工作流真实printf→文本变换、字面`$()`、逐次动态argv审批、在途冻结、拒绝／NUL零派发、最终checkpoint通过。
- 调度claim落盘失败零派发、引用指纹变化暂停、精确schedule ID授权、睡眠合并、DST／时区与unknown人工检查通过。
- MCP21项合成HTTP／stdio协议测试通过。真实第三方来源兼容未全面验收，ACP只有协议评估，没有宣称实现。
- 503条UI key中英静态覆盖；新增回归检查恢复后的Workflow／Agent通用任务标题，避免动态key遗漏。

iSpec当前apply attempt为`d3f5e2a2-0c44-46b6-850a-5dbc8619e906`，CLI测量均串行，日志与receipts保留在本机ignored证据目录；未把失败回执改写成PASS。

两次混合套件check的退出时限失败原日志保留（`expansion-unified-check-v1/v2`）。第二次shutdown实际2.087s，3.688s是完整用例时间；并发MainActor合成夹具同步poll／usleep会污染墙钟。现将两个Terminal套件作为独立且强制的互补阶段，保留原两秒断言和全部用例，空匹配也失败；没有失败后自动重试。Adapter改为提交时捕获绝对deadline，detached计时经线程安全gate收口。最终该用例0.279s通过；不承诺繁忙系统硬实时。另保留仅在有启用计划时启动调度循环的节能修补。

最终公开性静态复核覆盖260个tracked／未忽略候选，未发现凭据、个人媒体、机器home路径、额外邮箱或AiBox迁入源码；不替代最终资产检查。

## 原生观察

Preview由统一debug流水线构建、原子替换并启动，与正式App数据／bundleID分离。已实际观察中文Agent／Tools／Workflow页面、独立MCP设置、英文深色设置以及语言／外观恢复。工具页算式`2×(3+4)`得到14，`1 GiB to MiB`得到1024 MiB；按钮和原生菜单均可运行合成trim工作流。

最新Preview再次原子更新通过（测量`7948b897-5a27-4900-a78a-63d1cf3ceeff`）。原生UI实际保存／重新编辑合成Snippet，保存URL模板并显示`hello & KeyDock`编码后的`hello%20%26%20KeyDock`，创建并选中包含该Snippet的集合；未打开外部网站或批量执行。通过系统文件选择器仅选择临时合成目录，文件名搜索显示“已扫描2个条目·1个结果”；同一合成文本文件导入后显示完整预览。恢复后的工作流标题已显示中文。保存新集合后现在自动选中它，重复保存沿用其ID，避免意外重复创建。

集合体验修补后再次重建／安装Preview（`7fe9fed7-56e2-468e-a6b2-f200729adfb6`）并实际创建合成集合；保存后Picker立即显示其名称及已选动作，原生观察通过。

发现三项真实问题并修复：

1. ImageIO能对非图片返回未识别source；按已识别image类型分派，PDF走文本层路径。
2. Foundation将/private/var折回/var系统别名，使逐级O_NOFOLLOW误拒目录；改用realpath，仍拒最终symlink并核对目录链／文件身份，alias和物理路径回归通过。
3. 三个运行菜单使用同一⌘Return时，禁用项可能挡住后续项；改为一个原生run owner按当前输入页路由。重建Preview后，⌘Return实际产生`Native shortcut verified`完成结果。

CUA首次typeText丢失×，改用保留UTF-8的输入后结果正确；这不是应用表达式求值失败。Preview与正式App同时注册默认全局快捷键会冲突，隔离预览如实显示停用提示，未据此认定物理快捷键通过。普通Terminal的既有工具拒绝继续尊重，未绕过。

## 发行和未关闭义务

候选为0.1.0-alpha.3／build3。Preview是dirty源码验证，不作为正式分发包。正式包须在最终干净提交上重新构建、Developer ID签名／公证、Gatekeeper、安装与回下载核对；alpha.1／alpha.2不改tag或资产。

整体产品仍PARTIAL：真实外部API按用户决定稍后配置；真实模型质量样本未评阅，AX／Screen Recording需用户手动授予，物理快捷键、跨屏／全屏、权限撤销、IME、辅助功能、长期驻留／耗电和完整视觉矩阵尚未关闭。文本上下文不等于多模态图片发送，普通CLI不等于ACP／PTY，可信进程不等于OS沙箱，App内计划不等于后台daemon。整机活动分析与自动更新器没有宣称实现。
