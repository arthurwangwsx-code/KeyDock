## Context

参考 [提案](10-proposal.md) 建立全新 KeyDock。用户要求原生快捷操作、可持续架构及外部 API AI，包含可绑定快捷键的翻译/总结、CLI 扩展、使用分析和通用 Agent。初始方案已进入P0/P1实施；2026-11-23追加开源、预发行和安装流水线。

## Goals / Non-Goals

**Goals:** 以统一命令/工具/上下文/执行模型承接桌面与 AI 动作；P1 可日用；各阶段有真实验收；选择性参考 AiBox 与公开项目。

**Non-Goals:** 不采集个人开发素材、不复制旧源码／凭据；首期不做全屏持续监控、扩展市场或完整Raycast兼容。公开范围按用户新增发行要求与治理文档执行。

## Decisions

- 原生 Swift 6 + AppKit Panel/SwiftUI，暂定 macOS 14；模块化单体，App 薄组合根。Electron/RN 方案推迟到确有跨平台需求。
- CommandCore/ExecutionCore/AICore 为纯合同；SearchEngine/AgentCore 通过 host seams 依赖 OS/模型/存储。统一执行服务避免各功能重复权限和取消逻辑。
- AIAction 直接调 ProviderGateway；只有多步工具任务才进入 AgentRuntime。Provider 独立适配，tool-call 总经 Broker，MCP 与 ACP 分别承担工具和外部 Agent 接入。
- 剪贴板、Activity、模型用量、任务正文分域保存，元数据优先。未知 usage/cost 不伪装为实测；保存动作可在已确认范围内一键运行。
- CLI executable/argv 与 shell/PTY 明确分开；窗口身份不能仅用 PID；查询采用 generation 防止陈旧结果覆盖。
- references 只登记 URL/revision/license，不 vendor 参考仓；AiBox portable 核心只作为后续抽取候选。
- 本机一键发行 `ship` 固定干净且同步远端的master和新版本，复用同源资格/冻结候选；包通过后才推精确tag和draft，回下载一致后公开。保留独立core CI（无云端Preview包），安装显式请求。[流水线](../../../docs/technical/release-pipeline.md)
- AI 快速配置复用现有模型解析器、显式 GET /models 及 Keychain 保存事务，预设只改变草稿；应用图标采用可再生成的多尺寸 ICNS。[方案](../../../docs/technical/ai-service-quick-setup.md)

完整决策、合同、时序和状态机见 [架构](../../../docs/technical/architecture.md)、[AI 与自动化](../../../docs/technical/ai-and-automation.md)、[数据与权限](../../../docs/technical/data-and-permissions.md)。

## Risks / Trade-offs

- [macOS 权限/多屏/Space 行为不同] → P0/P1 做真机 spike，声明公开 API 能力边界。
- [云模型延迟、限流、重复计费] → 搜索隔离、超时/取消、有界重试，生成与执行分开。
- [第三方进程绕过 Broker] → 只允许可信显式启用来源，未验证 OS sandbox 不宣称权限隔离。
- [Agent 崩溃时副作用不确定] → intent/result 回执，unknown outcome 不自动重放。
- [迁移带入私有耦合或许可证问题] → 逐文件 provenance/notices；本轮不复制。

## Migration Plan

从空 master 的 feature/product-foundation 建立文档与 change，经校验与只读评审后 fast-forward master。P0 新建 Swift 工程；每个可迁模块单独 change，保留来源 revision。数据库首次实现即版本化迁移，失败可保留旧文件与前一发布包；没有数据转换或源码删除在本轮发生。

## Open Questions

第一个联调 provider/endpoint/model、最低系统真实验证设备、签名发布者和 App Sandbox 能力 spike 尚待实施前确定。名称 KeyDock 为用户接受代号。公开远端的具体仓库与范围在可审阅内容完成后确认。

## 2026-11-23 范围追加

用户明确要求完整应用GitHub开源、本地Release上传及本地安装替换流水线。当前追加release-engineering合同与任务8.x，技术细节以docs/technical/release-pipeline.md为准。master在编译／测试／审查通过后受控fast-forward，alpha发行与完整P1日用资格分别记录；其余P2–P4产品能力继续后置。签名凭据由系统钥匙串引用，公开源码与发行物不含私钥、API配置或个人数据。

## 2026-11-24 全部后续能力追加

用户明确要求参考AiBox继续实现全部后续功能。P2–P4进入实施范围，产品切片、技术合同和逐项验收见[后续能力方案](../../../docs/technical/capability-expansion.md)。第一阶段未完成的权限／物理快捷键／IME／外部API／质量／兼容性义务不变。采用设计借鉴与独立实现，当前没有迁移AiBox源码的许可receipt。

## 2026-11-25 URL动作编辑隔离

URL运行选择与编辑草稿分别由WorkspaceSession持有；Use和Launcher深链接只选择运行目标，Edit才加载固定编辑ID和完整字段。View重建或切换页面不把空表单配给旧运行ID。成功持久化后清空编辑身份与字段；验证或写入失败保留草稿，沿用配置事务补偿。携带编辑ID的保存只允许更新仍存在的动作，不能隐式重建已删除目标。原生验收只使用合成example.com地址，不打开浏览器。

集合沿用同一窗口会话原则，浏览ID与编辑草稿分离。commandIDs数组是唯一顺序真值，候选过滤只影响展示；勾选追加，前后移动或显式移除才改变顺序。缺失引用保持位置和容量，保存拒绝不可用／窗口／集合引用；用户显式清理后仍保留其余相对顺序。模型JSON格式不变，带ID更新拒绝已删除目标，保存事务失败完整保留草稿。编辑与保存没有批量运行语义。

## 2026-11-25 视觉抽样边界

隔离Preview使用独立环境键和持久宿主注入自有组件样例，不改变OS辅助功能偏好；仅编译／隔离标记／bundle／profile全部匹配时接受切换。有效设置保留系统真实需求，正式构建不能通过启动参数启用样例。26+材质只修饰背景，前景及会话保持在固定结构中；焦点／选区稳定必须原生复查。样例不是OS控件、VoiceOver、IME或完整视觉验收的替代品。

## 2026-11-25 AI配置前置体验

提取Provider的纯结构配置构造，供实际请求、界面和运行菜单复用；准备判断不读凭据、不联网。AI动作使用独立模型覆盖，CLI草稿／只读Agent使用全局配置。主要动作在配置无效时引导设置，运行中保留Stop；配置修改不启动新任务，也不改变旧结果交付权限。匿名服务不因未保存key误禁，真正认证和模型质量留待用户配置后的验收。

## 2026-11-25 工作流初始输入

在已编译计划上追踪初始输入依赖：变换传递依赖，AI和含完整输入占位参数的保存命令消费依赖；固定命令输出与人工输入形成屏障，最终输出仍有依赖时也需前置输入。快捷入口只传工作流ID到独立输入sheet，编辑稿／原输入和页面不变；普通工作流页的用户显式运行与App内计划合同不变。

每个输入呈现有独立UUID，取消／提交／重载均核对该身份。打开时不创建运行、不读剪贴板或凭据；提交时复核保存定义的完整值，修改须显式重载，删除不复活。引用的命令和AI配置仍在真正启动时按原执行宿主冻结，动态argv逐次审批保持不变。输入拒收超过131072 UTF8字节的编辑，保留旧内容并禁止运行，合法编辑后才解除；没有截断执行。

## 2026-11-25 设置摘要导出

按独立字段白名单投影已加载配置，仅允许基础偏好、可选启动器热键与含内置定义的数量摘要；任意用户文本、ID、连接、bookmark与凭据均排除。稳定审阅呈现／冻结Data／每次保存UUID分别管理，预览和FileDocument使用同一字节；系统取消独立回调，关闭与迟到结果受会话身份围栏。详见docs/technical/settings-summary-export.md。摘要不是恢复备份，完整定义迁移的后续义务保留。

## 2026-11-25 定义保存反馈

Agent／工作流的工作区提交复用既有配置写入与补偿事务，失败消息同步到当前Workspace，成功才清除旧失败提示。会话保存入口只在持久化成功后回填真实定义版本，失败不改草稿、步骤或运行输入。保存状态从当前配置与编辑稿派生，区分未保存、存在修改及已保存版本；文本额外核对UTF8字节，导航和界面重建不产生旧成功提示。删除失败同样留在发起页，在途任务快照和执行宿主不受此次UI反馈改动影响。

保存命令与AI动作的移除采用独立审阅sheet，按类型化UUID图列出工作流／Agent／集合／计划引用；指纹与当前引用在最终确认同步重查，不做级联删除。原生发现刷新身份导致Esc失效后，呈现保持稳定ObservableObject身份，每次审阅另有UUID，取消按呈现、确认按当前快照绑定。定义及准确命令ID的快捷键、收藏、别名、最近项由既有注册／持久化补偿事务一次提交。设置编辑会话固定new／edit意图，被移除目标拒绝旧编辑保存。Agent失效工具需显式移除；AI失效动作以占位保持正文和旧结果身份，不自动选择其他动作或终止在途快照。合同见docs/technical/saved-item-lifecycle.md。

## 2026-11-25 性能采样

统一工程入口提供Release查询原始样本及自有App进程资源采样；严格区分App／runner源码和屏幕呈现资格。进程采样使用公开libproc、准确路径／UID／出生身份前后围栏，不获取任务权限或控制GUI，不自动重附着；失败／中断保留原始数据。30分钟短基线与8小时长期样本分别执行，详见docs/technical/performance-sampling.md。

## 2026-11-25 完整配置定义导出

任务28.4采用独立字段白名单DTO、纯预算／引用图检查和已加载owner快照。主线程在await调度前捕获配置／独立定义／面板偏好的值与发布代次，返回后核验代次，ABA也拒绝；ScheduleLedger只返回无授权／运行字段的定义投影及定义generation。编码离开主线程，完成后按呈现／捕获身份接纳；数据冻结后不随当前配置改变。六类可选范围默认全选，未选定义／全局服务依赖与真正外部资源分别声明，断裂或临时引用失败。系统保存复用稳定sheet／attempt语义，预览采用完整可选择的只读文本控件，避免把8MiB JSON拼到辅助名称中。见docs/technical/configuration-export.md；不实现import或跨库写事务。

## 2026-11-25 工作流／MCP移除闭环

新增独立SourceRemoval审阅，MCP不是可路由命令，不制造假commandID。工作流引用从ScheduleLedger窄定义快照与主配置集合计算，确认共用Schedule mutation owner／busy门禁；owner先于Published状态更新，避免同步回调重入。读取后核验主配置代次、目标完整指纹、ledger定义代次与呈现／审阅ID，再无await提交主配置／绑定补偿事务。MCP使用独立settings owner覆盖保存／删除／连接入口；被引用与旧确认不撤权，真正提交后按既有fail-closed语义暂停、取消及清理，失败保留原定义但明确重启风险。旧缓存于await前移除，不能让迟到清理按ID清掉后来目录。

Workspace工作流编辑保存原指纹，MCPServerDraft保存原revision与独立稿身份；新建与编辑分离，异步成功仅更新仍属于该提交稿的状态／key。来源移除不擦除已有正文，只在当前渲染中标记来源失效；失效Agent来源及未呈现的保存工具可显式移除。Workflow孤儿偏好纳入既有显式修复。所有UI中英，原生合成验收与真实API／权限／全视觉范围分别记录。

## 2026-11-25 可选AI费率及逐调用归因

任务32沿用现有usage actor及累计accumulator，新增可选手工平价输入／输出费率与Decimal估算。运行先冻结精确服务／请求模型及费率配置集，各实际open前创建独立attempt并绑定冻结依据，provider记录端口不依赖UI消费；后续改价只影响新run。Workflow保存子调用parent／step归因，父只汇总叶子，所有入口使用同一事实计算。旧记录不追套当前价，缺报／失败／取消不抹去已知部分；不存完整endpoint／query或正文，不猜缓存折扣与汇率。单次、历史和按币种的有界分析共用口径，清除／TTL围栏不另造第二RunStore。详细合同见docs/technical/ai-rate-snapshots.md；alpha.18已实现并发行，804 Swift／78 Python／847 key与原生观察子集及流水线资格见发行证据，稳定delta及完整产品义务保持开放。

## 2026-11-26 任务持久化与显式新尝试（Core切片实施）

任务33采用类型化逻辑run／执行attempt／恢复引用及revision CAS，持久成功后发布；既有InvocationStore继续拥有实际副作用真值。冷启动与检查只读，缺正文须重新提供，不恢复grant、provider session、AX／选区或旧审批。用户经独立稳定准备页明确提交后，重新核对当前定义、贡献／MCP来源与schema、权限、预算和history generation，以新UUID走生产入口和持久intent。旧终态与费率快照保留，恢复输出默认展示。首切片不关闭原5.5完整RunStore及可选正文／checkpoint义务，详见docs/technical/explicit-attempt-recovery.md。

Core已在InvocationStore同一actor／文件实现类型化查询、来源CAS与新intent原子提交，worker使用actor／出生身份／revision stamp条件收口；原格式只读恢复，typed Envelope v2不让旧App忽略字段后覆盖。四类定义采用固定v1白名单指纹，MCP选中合同使用有界流式摘要，均不读取资源或产生授权。生产入口、稳定准备页、await后的发布代次围栏及数据回退检查仍待接线；不能以Core测试关闭33.2–33.5或全产品资格。
