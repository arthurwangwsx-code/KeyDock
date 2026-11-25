# 性能采样与查询缓存复查

2026-11-25。本轮增加统一Release查询入口、独立合成CI和明确App／PID的本地资源采样，修补实际测到的查询超标。完整产品、屏幕首帧、8小时驻留、真实采集能耗仍未验收；下列先导测量使用dirty候选，不能当干净发行源资格。

## 原始失败与优化

固定2,000项、10预热、100正式样本，原排序p95为47.369875ms，查询链路p95为51.669292ms，未达到原50ms预算。未重试择优；先保留失败，再将Unicode规范化结果准备到命令值对象。缓存排除在编码／相等／哈希之外，初始化、旧JSON解码和文本／数组修改均更新缓存；别名、收藏、最近项和重复ID权威保持原规则。

修改后同一数据、样本与预算复测：排序p95为10.146292ms，查询p95为9.522375ms。合成目录构建与准备13.911125ms，规范化文本逻辑84,890 UTF8字节单列，不声称实际内存、索引、窗口唤起或首帧收益。

| 记录 | 本地原始目录／回执 | 结果 |
|---|---|---|
| 原查询失败 | `.local/pipeline/20261125T094836552477Z/performance/`；`performance-query-pipeline-v1.json` | FAIL，保留全部样本 |
| 缓存修改后查询 | `.local/pipeline/20261125T095637707735Z/performance/`；`performance-query-pipeline-v2.json` | PASS，测量d2ae1d40 |
| 真实Preview资源短探针 | `.local/pipeline/20261125T100055380235Z/performance/`；`performance-resident-probe-v1.json` | 完成3点／2.013秒；不是30分钟基线 |
| 自有原生生命周期 | `.local/pipeline/20261125T100535688978Z/performance/`；`performance-owned-probe-check-v1.json` | PASS，测量33e40728；正常采样、错路径拒绝、退出后失败 |
| Python边界 | `.local/desktop/performance-python-v3.log`；`performance-python-v3.json` | 16项PASS，含真实owned SIGINT／回收 |
| 查询／目录定向Swift | `.local/desktop/performance-search-targeted-v1.log`；`performance-search-targeted-v1.json` | 36项PASS，测量c8bbaeff，原100ms目录断言保留 |

回执相对路径均位于`ispec/changes/keydock-foundation/receipts/`；原始失败／超时输出保留在忽略的本地证据目录。先导机器为M1 Pro／macOS27.2 (26B123)／Xcode27.2，低电量关闭、查询thermal nominal；主机负载逐次记录，不人为删点。

## 边界与复核

独立只读评审确认值缓存的编码、修改、并发与排序兼容；资源复核另发现并修复阶段往返误归闲置、查询超时丢部分输出及Ctrl-C未留总结。原生进程CPU值按Mach ticks先取差再换算。本机125/3 timebase的忙循环对照POSIX CPU，真实短探针的比例0.999886；不把原始值直接当纳秒。

短探针绑定的Preview源与采样工具源不同，旧Preview配置未保留，因此准确标为`not-retained`。后续优化Preview必须由BuildInfo明确记录ReleasePreview，不能靠profile猜测。CPU／RSS／physical footprint尚无产品阈值；已完成采样不等于能耗PASS。

## 干净候选与30分钟基线

干净候选`2b3d5b66e8b333772d4622208a66c557b6175452`的完整本机检查719 Swift／74 Python／744 key PASS，inventory698（core688／Terminal9／OCR1）。生产OCR配置的合成图双轮通过；测量`performance-full-check-v1.json`耗时90.156秒，摘要`.local/pipeline/20261125T100727900166Z/check-summary.json`，文件SHA256为`a5eb1f9069fc6012ca52ac4fd2ee3d6227e3baf742857b87af714fd60a4deace`，qualification规范化摘要`fdbf5688320e303af62f31b9dd3087f9e51d717df0e6c8a57bc3740bbe2772eb`。

同源[CI 45591952724](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45591952724)的job139128140715全部通过，含优化Preview；cloud-core为718 Swift／74 Python／744 key，OCR明确NOT_QUALIFIED。日志artifact15011833191回下载95,338字节，SHA256 `ca6b5006ff33cd542d0e38fe400e3afffe99c538218069f01f7bc5fb773efae1`；21个文件、10个阶段JSON实际读取，exitCode全部0。

该干净候选的独立查询测量`71208484-c25a-4d90-b8ae-0345c41010ea`通过：排序p95为9.830833ms，查询p95为9.985166ms，目录准备14.173417ms。原始目录`.local/pipeline/20261125T100916905803Z/performance/`，固定数据和50ms预算保持不变。

ReleasePreview构建`547f88f4`与正常替换`10ecd0bd`后，实际About为alpha.15 (15)，BuildInfo明确配置、干净源，safeSmoke=true。只附着该已运行的准确PID93762。App与observer都绑定同一2b3d5b6，1800.014秒保留361点，阶段计数66／111／184；无睡眠／时钟gap，末尾身份、映像／资源及observer完整性核对通过。

| 声明阶段 | CPU中位数／p95（单核100%） | RSS p95 | physical footprint p95 |
|---|---:|---:|---:|
| 隐藏闲置 | 0.0153%／0.3818% | 145.56 MiB | 61.20 MiB |
| 合成操作 | 1.1833%／8.7511% | 211.25 MiB | 123.13 MiB |
| 恢复闲置 | 0.0163%／0.5458% | 194.94 MiB | 120.61 MiB |

阶段由操作方声明，采样器不核验窗口隐藏或采集开关；操作使用隔离Preview、合成剪贴板及自建文本宿主，不读取个人内容或配置外部AI。跨阶段两区间不归普通CPU统计。本轮不是能耗／泄漏判定，未设置临时CPU／内存门槛。无睡眠场景，因此不关闭8小时义务。

原始目录`.local/pipeline/20261125T101349152412Z/performance/`，NDJSON SHA256 `8b280eb40fb6084ee63407faa94c81d4f76f187a2e02f02b25375b3f406ae0f4`；测量`20efe31c-fca7-4964-b9b1-8049987ed0a3`，回执`performance-resident-30min-v1.json`的SHA256 `15bbbdc459c81b244093691f4589af547b22a13917c1214fed057c2b4781d64a`。该基线属于2b3d5b6，不能自动升级为随后UI修补源码的同源性能资格。

## 原生视觉子集与菜单修补

同一候选实际观察Launcher 680×456、Clipboard 860×540、Settings约740×582、Workspace约820×664的中英深浅四组合基础画面。剪贴板搜索、Shift-Return选择两项、清单／合并正文以及全部视觉样例往返保留；启动台第七项方向键可见；独立菜单与配置AI入口可达，未配置模型时CLI建议／Agent保持禁用。AX直接赋值的混合Unicode正文在语言／外观切换后保留。系统／应用名、自建合成定义按原文显示，不算未翻译产品文案。

明确缺陷：英语Light→Dark及中文Dark→Light后，草稿工具栏Menu的AX名称退回Clock／时钟。基线结束后，仅将Image标签换为含本地化标题的iconOnly Label，保留Menu、hosting、菜单内容与外层辅助名称。修补Preview的英文浅→深→浅、中文返回实际保留AI drafts／AI草稿；可打开菜单、选择当前草稿，准确混合文本及焦点保持，最终偏好恢复system／system并清空本轮合成输入。修补构建／安装回执分别为`performance-menu-label-preview-v1.json`和`performance-menu-label-install-v1.json`；这是dirty候选的原生子集，最终发行资格另记。

正常深色玻璃的窗口截图偏灰，opaque／all样例显示更暗阅读底；未确定截图合成或实际背景的影响，不判WCAG失败或唯一根因。[Apple glassEffect说明](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))同时涉及材质和前景效果，后续需隔离验证前景与背景；[材料指南](https://developer.apple.com/design/human-interface-guidelines/materials)强调语义用途与多上下文可读性，不仅凭表观颜色选材。

修补后的`WindowToolbarViews.swift` SHA256为`8a4c186500c87d2d6ff6eaa3946b7b3ad88b731c8b93c4b720aacd43633f5ede`，用于与后续干净源码复核，不将dirty BuildInfo伪装为发行提交。

工具边界保留：一次typeText注入漏中文，AX直接赋值后准确显示，不能据此当IME通过；剪贴板快捷键入口曾返回AXError，但回查已打开独立设置，没有重复操作；Esc后再次读取仍显示Launcher，唯一原因未确认，未计通过。原生UI期间没有改TCC／系统外观、调用真实AI、读取个人剪贴板或在产品中运行CLI／Agent命令。

8小时含睡眠／唤醒、真实启用采集、150ms实际屏幕唤起、IME／VoiceOver／多屏和完整视觉／辅助功能义务保持开放。完整定义导出28.4仍需独立实现，未来导入的跨库事务不作为导出的前置阻断。
