# 当前状态总账

更新：2026-11-25。用户已授权在保留P0/P1验收义务的同时推进P2–P4。**完整产品仍为PARTIAL**；当前源码、真实系统验收、已发布版本分别记录，不能用代码或CI绿测替代日用验收。

后续修补分支`fix/ui-semantics-and-text-sync`从master `703b9a1`创建，已实现任务13的文本字节同步、编辑器AX名称、计划时区与Launcher副标题，33项定向执行及Agent／计划中英深浅四组合等原生子集通过。前一候选`36812e0`的474 Swift／46 Python／587 key完整检查、Release构建及同源CI通过，但未发布。随后`57f308d`补URL运行／编辑隔离及工作区失败提示，27项定向执行和合成原生操作通过，共590个中英UI key；其core CI通过，完整本机检查却在OCR失败。增加轮次日志后真实提取首轮也失败，三个独立对照均未解决；未改变生产模式或门禁。alpha.8发行保持未放行，正式版本继续为alpha.7。详见[语义复查](implementation/ui-semantics-2026-11-25.md)、[URL编辑复查](implementation/url-action-editing-2026-11-25.md)及[OCR复发记录](implementation/ocr-recurrence-2026-11-25.md)。

后续有序集合增量已实现：32项有序草稿、浏览／编辑隔离、明确失效清理、AI空白手动草稿和CLI可见任务。23项定向检查及原生重排／保存／双语／AI入口子集通过；首版Form运行行与编辑行混用的真实渲染缺陷已复验修补。干净源`0d3a0c2`本机cloud-core检查为491 Swift／46 Python／602 key，[同源core CI 45477121418](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45477121418)通过；此范围的OCR明确NOT_QUALIFIED，完整本机／发行仍未放行，见[集合复查](implementation/command-collections-2026-11-25.md)。

继续增加仅隔离Preview可启用的视觉样例，强化剪贴板选中态、实色正文与合并行辅助名称。原生发现材质切换导致Launcher文本选区丢失后，将玻璃移至背景；修补后的选区、剪贴板查询／合并选择及AI草稿往返得到保留。中文浅色／英文深色剪贴板样例及独立设置页已观察；9项定向检查及干净源`8ae77c3`的493 Swift／46 Python／608 key cloud-core检查、[同源CI 45483484071](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45483484071)通过。OCR仍NOT_QUALIFIED，它不改变OS偏好，也不替代真实辅助功能／IME矩阵，见[视觉样例复查](implementation/visual-samples-2026-11-25.md)。

AI配置前置增量已实现：配置不完整时以设置入口替代运行，原生菜单共用Provider结构校验，检查不读密钥／不联网。动作模型覆盖与两个辅助动作的全局模型分别判断。21项定向检查通过；中文浅色工作区／紧凑入口、未配置⌘Return及设置往返保留输入已观察。干净源`6633d70`本机cloud-core为496 Swift／46 Python／609 key通过；[同源CI与优化构建45486089503](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45486089503)的实际结果单独以该run为准。OCR仍NOT_QUALIFIED，真实API仍未配置，见[配置引导复查](implementation/ai-setup-guidance-2026-11-25.md)。

工作流快捷入口已修补固定空输入问题：依赖初始文本时打开指定工作流的独立输入页，保留原编辑稿；专用快捷键跳过通用Launcher捕获，固定流程仍直接运行。18项定向执行、中文浅色／英文深色输入页、取消／Esc、主窗口菜单围栏和实际纯变换任务子集通过。干净源`9cd6d10`本机cloud-core为508 Swift／46 Python／615 key通过；[同源CI与优化构建45493283966](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45493283966)实际结果单独以该run为准，OCR仍NOT_QUALIFIED。见[本轮复查](implementation/workflow-launch-input-2026-11-25.md)及[输入合同](technical/workflow-launch-input.md)。

该同源CI实际FAIL：应用目录原start小于100ms断言失败，优化构建未执行，旧run未重试。复查发现卷通知注册／清理仍同步调用NSWorkspace，现已移入后台观察生命周期，保留目录失败后的卷恢复、取消／旧代次围栏和原100ms断言。23项定向执行及原生刷新／搜索子集通过；干净修补源`df2a367`本机cloud-core为513 Swift／46 Python／615 key，[新同源core与优化构建45496727323](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45496727323)通过，OCR仍NOT_QUALIFIED。旧失败和未确认唯一根因保留在[目录观察复查](implementation/catalog-volume-lifecycle-2026-11-25.md)。

Agent／工作流的保存反馈后续已实现：验证或写入失败在发起工作区可见，原文件补偿及草稿／输入保留；成功回填实际版本，后续编辑显示未保存。29项定向执行、中文浅色／英文深色状态与验证失败子集已观察，见[定义保存复查](implementation/definition-saving-2026-11-25.md)。首次工作流保存后活动窗口切到Launcher的单次观察保留，重开及后续保存确认数据无丢失，来源尚未确认；不计完整可见性矩阵通过。

保存命令／AI动作的生命周期后续已实现：引用阻止、定义指纹复查、快捷键／偏好同事务清理、旧编辑拒绝复活、失效Agent工具清理及AI旧结果保留。31项定向执行及原生新建／编辑、中文浅色引用页／英文深色确认页通过；发现重新检查后Esc失效，拆分稳定呈现与审阅身份后中英原生复验通过。干净源`fed3a0a`完整cloud-core为529 Swift／46 Python／631 key通过，[同源core与优化构建45503410004](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45503410004)PASS；本机此范围与云端系统OCR均NOT_QUALIFIED，见[生命周期复查](implementation/saved-item-lifecycle-2026-11-25.md)。

完整范围复查仍保留**代码层待实现义务**：任务20的多应用桌面工作区。不能把目前的Workspace页面或命令集合视作多窗口工作区完成。设计见[桌面工作区方案](technical/desktop-workspaces.md)；完整目标并非只剩权限或实机检查。

桌面工作区第一段定义管理已接入：独立档案／有序目标／屏幕策略／revision，设置编辑器与仅管理入口快捷键；30项档案定向、48项编辑／事务回归，以及中文浅色／英文深色添加、重排、保存重开、失败保留和取消子集通过。原应用动作存储算法抽成共用内核，保留旧wrapper与完整事务回归；no-op外部变化校验已补齐。完整core与同源CI另录，见[定义复查](implementation/desktop-workspace-definitions-2026-11-25.md)。**全目标冻结与批量执行、profile快捷键生命周期仍未接通**，任务20保持未关闭。

本轮已发布并安装alpha.7：有序多选合并、完整预览与可配置主动作，最多20项／1MiB。中文浅色／英文深色、跨查询、重排、空行与Shift-Return、偏好重启保留及实际合并复制均已观察。AI生成成功但复制失败会保留完整结果和成功回执。当前源472项Swift、46项Python、583条文案、同源CI及公证／公开回下载通过；真实自动插入仍依10.1验收。详见[本轮证据](implementation/clipboard-composition-2026-11-25.md)及[合并合同](technical/clipboard-composition.md)。

2026-11-25交付增量：alpha.6已加入直接窗口／应用动作、独立应用动作设置与事务存储；457项Swift、46项Python、556个中英UI key、同源CI及发行门禁通过，并已替换正式alpha.5。首次编辑和显示提前短路已修补，合成应用真实隐藏→显示、退出只请求一次和正常结束得到确认。原生双语视觉仅通过已观察子集，完整目标仍未关闭。详见[本轮增量复查](implementation/desktop-controls-2026-11-25.md)。

此前alpha.5交付了独立剪贴板面板、键盘搜索／预览／复制／受控插入、快捷键分类和视觉修补。见[剪贴板实查](implementation/clipboard-panel-2026-11-24.md)及[完整目标矩阵](product/quick-actions-completion.md)；本轮多项合并交付不代替原P0–P4或关闭真实插入／物理热键／AI质量验收。

## 当前源码

canonical目录唯一；合并分支从master `2fe35b6`创建，验收后的`59d1680be17fb5713cf79834fbceec3df496ed27`已受控fast-forward到master并标记`v0.1.0-alpha.7`。发行证据在从master创建的`chore/alpha7-release-evidence`补齐，不修改已发布字节。主Agent独占写入／集成／提交／设备，子Agent只读研究评审或提供/tmp原创提案。未新建worktree或修改AiBox／Ashot。

| 范围 | 状态 | 当前证据与限制 |
|---|---|---|
| 产品／架构／开源参考 | PASS（工程） | 原生模块化单体、13项固定revision参考；AiBox只读设计对照，新代码独立编写 |
| 构建与模块 | PASS（本机） | Swift6／macOS14目标，当前27.2 arm64原生构建；最低系统未真实验证 |
| 启动台／设置／工作区 | PARTIAL | 独立窗口、菜单栏入口、KeyDockUI、系统玻璃材料和中英；基本深浅色／焦点已观察，完整视觉／辅助功能矩阵未完成 |
| 搜索与快捷键 | PARTIAL | 动作分类、剪贴板专用绑定／别名、目录／generation／过期结果和注册事务测试；Preview录制与重启持久化已观察，物理全局快捷键、IME／全屏／多屏未完整验收 |
| 窗口切换与布局 | PARTIAL | 13项单窗口布局、循环／最小化与identity恢复；桌面工作区已有独立定义管理，批量执行与profile快捷键仍未实现；真实AX授权／撤销／多屏矩阵仍待验收 |
| 应用控制与定制 | PARTIAL | 命名动作、显示／隐藏／前台切换／正常退出、独立存储与直接快捷键；合成原生宿主隐藏→显示及单次正常退出请求通过，真实保存界面／Spaces／物理热键仍待验收 |
| CLI与任务 | PARTIAL | executable+argv、有限输出／超时、真实进程组取消与回收、durable intent／result／unknown不重放；Terminal GUI继续尊重既有工具拒绝，未计真实通过 |
| 剪贴板 | PARTIAL | 独立两栏Panel、搜索／↑↓／预览、20项／1MiB有序合并、主动作与分隔符偏好、复制／受控插入及取消／竞争围栏；中文浅色／英文深色、Shift-Return、重排与实际合并复制已观察。记录默认关闭，真实自动插入、物理热键及完整矩阵仍待验收 |
| AI服务与快捷动作 | PARTIAL | 自定义兼容API、Keychain事务、重定向保护、翻译／总结／命令建议／选区输出、loopback全链路；真实外部API按用户决定稍后配置 |
| AI质量 | NOT_RUN | 20条合成质量样本已准备；真实模型质量与人工评阅未执行 |
| 多步Agent | PARTIAL | 保存命令／MCP工具allowlist、冻结范围、schema／预算、逐次审批、暂停／新attempt与unknown回归；真实外部模型／工具组合未全面验收 |
| 工作流与App内计划 | PARTIAL | 编辑／输入输出绑定、完整动态argv审批、快照冻结、child drain、durable claim／指纹／revision／DST／睡眠合并／unknown检查；真实长期驻留仍待验收 |
| MCP与扩展 | PARTIAL | HTTP／stdio、两个显式协议版本、tools／resources／prompts及21项合成协议回归；第三方兼容未全面验收，ACP仅评估、无OS沙箱或扩展市场承诺 |
| OCR与文件文本 | PARTIAL | 真实合成Vision OCR、UTF-8／PDF文本层、预算／取消；区域截图入口已实现，Screen Recording由用户手动授予；未声称多模态原图发送 |
| 常用工具 | PARTIAL | Snippets、选定目录文件名搜索／Finder显示、算式／单位、URL模板、命令集合；核心回归和部分原生交互已通过，完整入口矩阵待验收 |
| 使用分析 | PARTIAL | 默认关闭、最小metadata、30天聚合、暂停／清除／导出与明确用户触发AI总结；只有工具内部分覆盖，无整机追踪 |
| 回执／历史／容量 | PARTIAL | 8管理任务／200历史／32草稿／32MiB逻辑预算、90天元数据维护、原子父子保护、显式清除；崩溃后不重放，长期／完整GUI矩阵待验收 |
| 性能 | PARTIAL | 早期2000命令Release排序／缓存链p95约21ms；新增无计划时不启动调度循环；热唤起150ms、真实RSS／耗电与长期驻留尚未证明 |

干净源`59d1680be17fb5713cf79834fbceec3df496ed27`的完整本机检查与Release构建通过：472项Swift执行（core462＋Terminal生命周期9＋生产OCR1，两轮实际识别）、46项Python、583个中英UI key、文档及lifecycle helper。测试清单包含451个声明ID，参数化执行次数另计。完整检查测量`e3dee961-a0a9-4d94-af44-3609ab20bd16`，18:24:46Z–18:27:44Z；Release构建测量`84a2bdee-4509-4819-b3a9-6b182d43fde1`，18:28:36Z–18:32:15Z。

同源[core CI 45456156935](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45456156935)通过源码／流水线检查及优化版Preview构建；云端系统OCR明确NOT_QUALIFIED。完整本机资格在macOS27.2 arm64／Xcode27.2，保持生产accurate／revision3／自动语言／纠正／支持CPU阶段配置，两轮识别通过。资格摘要`9f708d24234061e9480c3add628a4c620bb324d27b1e265970074d2d06745bcc`同时封入App和manifest；不是第三方硬件认证或完整真实场景验收。

本轮曾被2GiB预检拦截、在编译中遇到ENOSPC，并出现一次TextRecognition／e5rt原生OCR失败；全部失败与日志保留。生产OCR和资格代码相对alpha.6无变更，未放宽门禁、未改OS服务；隔离双轮及后续完整检查均在原配置下通过。空间／内存／并发负载是调查线索，未确认唯一根因，OCR可靠性和长期性能仍保持PARTIAL。

先前Terminal超时、并发HTTP等待与远端Vision失败均保留。现强制串行互补分区、独立服务准备与stdio启动预算，原退出／drain／普通调用时限不放宽。远端Vision仍为TextRecognition code9等诊断失败，未认定特定硬件根因。alpha.3已公证候选保持原字节、未安装／未公开；alpha.4增加了同源系统资格和精确CI门禁。详细失败、修复与回归见扩展能力证据。

详见[扩展能力证据](implementation/capability-expansion-2026-11-24.md)、[使用说明](product/expanded-tools-guide.md)、[技术合同](technical/capability-expansion.md)和[iSpec任务](../ispec/changes/keydock-foundation/30-tasks.md)。勾选仅表示对应实现／定向验证，不关闭本表更广的真实验收。

## 已发布与安装

公开仓库为[arthurwangwsx-code/KeyDock](https://github.com/arthurwangwsx-code/KeyDock)，默认分支master。用户已授权公开此项目源码、Release本地打包上传、流水线及本地安装替换。

- [alpha.7／build7](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.7)已公开并安装至`/Applications/KeyDock.app`，App源为上述`59d1680`。Developer ID／Hardened Runtime、App与DMG公证装订、Gatekeeper、只读DMG内部App一致性、公开后实际回下载均通过。原alpha.6及回退receipt保留；未force kill或改TCC。
- [GitHub发行资产审计45461512603](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45461512603)已通过，核验精确alpha.7资产；不是云端OCR或真实自动插入验收。
- 正式App已实际启动，「关于」显示`0.1.0-alpha.7 (7)`。本轮未代授予TCC。Preview中文浅色／英文深色、主动作／分隔符、重启持久化及实际合并复制已观察，语言／外观与默认主动作均已恢复；物理全局热键未计PASS。没有保存MCP来源、运行外部服务或配置真实API。
- [alpha.6／build6](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.6)为本次可回退旧版，源`d61598a`；当时457 Swift／46 Python／556 key、发行及资产审计通过，见[桌面控制证据](implementation/desktop-controls-2026-11-25.md)。alpha.5及更旧历史发行与备份继续保留。
- alpha.2／build2的历史源为`ace56efdf67faae0f8dd2df3f0871b8e61a7829f`，历史发行／安装验收见[alpha.2证据](implementation/native-actions-2026-11-24.md)；当前直接回退目标是alpha.6。alpha.3／build3仅保留本地候选；Preview的dirty源码构建不作为正式分发包。
- 所有旧版tag和资产字节保持不变。个人配置、bookmark、密钥、截图、剪贴板、正文和本机日志不进入公开资产。

## 历史证据与边界

此前第一阶段／视觉／任务／发行检查记录保留在[文档总览](README.md)。旧日志中的“尚未实现”仅描述当时alpha.2源码，不能套到本轮扩展源码；既有FAIL也不因后来通过被删除。

真实API仍按用户决定稍后配置，AX／屏幕权限不能代为绕过。物理快捷键、系统／多屏／IME／辅助功能、模型质量、完整视觉评审和长期性能尚未关闭，因此不报告“全部功能与验收已完成”。支持与隐私请求：arthur.wang.wsx@gmail.com。
