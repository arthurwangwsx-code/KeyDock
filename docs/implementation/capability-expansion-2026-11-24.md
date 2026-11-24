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

干净提交`5e6c70b`的首次release在检查阶段停止（`expansion-release-alpha3-v1`，退出码1，未生成发行资产）。`oversizedTextFailsExplicitlyAndNeverAutomaticallyCopies`的五秒drain超时，当时只消费524288字节、状态running；其他并发合成进程夹具在主线程同步startup／cleanup。诊断显式使用`--no-parallel`，19项集成用例8.943s通过且顶层套件不再重叠（`expansion-serial-diagnosis-v1`）。流水线现显式串行两个Swift阶段，不调整五秒等待、一MiB输出上限或原断言；新版全量结果随后记录。

显式串行的完整check-v4通过全部382项Swift／34项Python／503 key，测量`83cadb0f-13c1-4333-871f-de18169fc079`，11:44:29Z–11:45:57Z。首轮远端CI `45386390231`仍失败于并发HTTP夹具等待和Vision unknownError，完整artifact已保留。OCR依[Apple设备选择API](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:))在最终请求配置后为支持CPU的阶段选择其声明的CPU；未支持的阶段保持默认，不使用弃用usesCPUOnly或伪造设备。真实识别断言继续强制执行；失败诊断仅增加NSError域／码，无正文／图片。

CPU设备配置后本机ContextAndLeaseTests六项通过，其中实际Vision合成图识别1.004s（`c9904375-9421-4cea-9446-faa945191b12`）。这只证明本机结果；首轮CI的unknownError不能据此定性为已确认的VM硬件缺失，新版远端结果另记。

干净源`bf3267b37bd3979a15420364406debd6c08acb37`的本地release-v2完整检查、Developer ID、Hardened Runtime、App／DMG公证装订及Gatekeeper通过（`a439c7ef-3fab-4407-a4bb-7edeef0faa3e`，11:50:56Z–11:55:43Z）。App公证`a5c331b9-08ea-4b35-9d3e-c24155f59d06`；DMG公证`b742e8df-5a88-40ab-9b68-4ca83c7881a4`。本地alpha.3 ZIP摘要`fc23da928db593946e2941512bca2b57f0496688f0c4a362e7fc59b02d5d6c7e`，DMG摘要`87c4e6b4f1bad18542b89f0dd7e5a8258b0274e52f17368411c9012c86b54e95`。

第二轮原生CI `45387890552`已解决并发HTTP／Terminal问题，只剩真实OCR失败；完整artifact记录`TextRecognition.CRImageReaderError`／code9、无underlying。CPU修补不能被表述为远端OCR已通过。未晋升master、推alpha.3 tag、安装或公开该候选；继续隔离准确模式的语言／执行环境差异，若修改源码则递增发行版本，不覆盖已有候选。

新增独立合成OCR诊断入口，保持五个场景均为accurate，结果不代表产品验收。首版探针被主动终止并保留失败；第二版对齐后台识别、完整读取输入及隔离CI并发组。第二版本机五场景的中文优先中英配置识别成功，其他场景达到45秒时限；owned子进程sample显示等待TextRecognition／ANE服务，主线程未阻塞，不能据此归因为管道或主线程。诊断失败回执`ea017625-75c7-47a8-92a7-34f56baa5dd5`保留，继续对比远端结果，不静默改变产品默认语言。

远端独立诊断`45391005566`的五个准确场景全部失败：自动／中文优先为TextRecognition code9，英语类为Foundation nilError。支持列表只有Paravirtual GPU及CPU；没有充分证据将其解释为某一个硬件原因。旧公共CPU标志及提前设置CPU的本机额外探针仍超时，未引入产品fallback。随后原生产路径在独立Swift测试进程0.560s通过（`561fd827-a1b1-4672-aec5-f1208b7c927e`），因此将云端core与本机系统OCR资格分别记录，而不是把VM错误改写为PASS。

alpha.4／build4新增受控资格门禁：完整本机检查保留原生产accurate配置（显式revision3），独立进程与重复提取均须实际识别；云端core只排除这一项，精确清单分区确保不遗漏其他用例。App／manifest／指定core CI与资格回执同源绑定，包／发布／重用和回下载均重新核验；失败、伪造汇总、日志变更及错误环境scope的门禁反例纳入测试。完整新版结果待记录；alpha.3候选保持原字节、未安装／未公开。

新增门禁43项Python回归通过；生产OCR独立进程与重复读取的结构化记录通过（`6cbca95c-2036-4083-ae78-8ab7a35cb9c6`，两轮真实识别，准确模式／revision3／自动语言／纠正／CPU配置均验证）。新版只读DMG内容核验已对公开alpha.2实际回下载通过（`d2871b38-8c3c-47af-bc28-35a9909a802b`），保持旧资产原字节。

完整qualified-check-v2在高内存压力（当时约26GB swap）下出现合成HTTP服务准备超时；只将隔离Python准备预算改为20秒并使用`-I -S`，应用五秒drain不变。check-v3工作区全通过，stdio合成源冷启动遇短RPC预算；新增独立30秒启动／整轮发现预算（1–120秒可配），普通调用预算单独保留、HTTP行为不变。外层client、transport与设置保存均统一；延迟1.25秒启动后慢工具仍按1秒超时、旧JSON缺省及预算保存回归共7项通过（`b87997b2-04a4-470c-a595-da8f87d6616a`）。新增请求／启动字段中英文后共506个key；最终同源全量结果随后记录。

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
