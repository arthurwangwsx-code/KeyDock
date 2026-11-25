# 完整配置定义导出 v1 方案

2026-11-25。此方案承接任务28.4，已随[alpha.16](../implementation/alpha16-release-2026-11-25.md)公开并安装；16项定向、735 Swift干净本机、同源CI和原生中英保存／字节子集通过。现有[设置摘要](settings-summary-export.md)继续保持独立格式；摘要不包含完整定义。v1先实现可审阅的定义导出，未来import独立建设，跨存储写事务不作为只读导出的前置。

## 产品合同

入口位于独立设置的“你的数据”，名称明确为“导出配置定义”，提示文件包含用户保存的提示词、片段、命令参数、别名、URL和本机资源描述。文件保存在用户选择的位置，应用不自动上传。已知凭据载体排除，但不保证识别任意正文中手写的秘密，不能称为匿名导出。

选择类别→捕获一致快照→引用与预算预检→审阅冻结JSON及排除项→系统保存。预览和保存使用同一份Data；选项变化需要刷新，另处配置变化不偷偷替换已审字节。取消、失败、关闭、shutdown和迟到回调复用现有presentation／attempt围栏，失败保留候选。

采用`KeyDock.configuration-export`、formatVersion=1／section schemaVersion=1、生成版本、范围与排除manifest。总包8MiB、最多1024定义／4096引用，并继续施加各模型的字段与单项限额；编码前累计字节和数量，编码后再检查实际大小，超限整次拒绝、不截断。引用按每次出现计数，不能用集合去重绕过预算。

六类默认全选，分别为preferences、definitions、shortcuts、desktop、schedules、resources。`AIActionPreset.shortcut`在shortcuts.aiActionShortcuts显式导出，definitions不夹带未选热键；原始commandShortcuts独立保留，不合并覆盖。部分选择不自动扩展范围：源中存在但未选择的定义／全局AI服务进入`unselectedDependencies`，指定target及requiredSection；真正的本机应用、可执行文件、目录、URL及编译工具需求才进入`externalReferences`。断链仍整次失败，部分包不宣称依赖闭包完整。

## 字段与引用

使用专用DTO显式投影，不直接编码AppConfiguration，也不先全量编码再删字段。保留定义源ID、版本、数组顺序和文字UTF8；导出不重映射ID、不更改配置或启停意图。

| 所有者 | 拟包含 | 明确排除 |
|---|---|---|
| 主配置 | CLI、AI动作、Agent、Workflow、Snippet、WebAction、Collection；别名、收藏、全局／动作热键、工具开关、所选基础偏好与非凭据AI服务配置 | 最近项、Keychain值、草稿／输入／结果、用量／运行历史 |
| 应用动作／桌面工作区 | 独立定义、版本、应用及布局策略 | PID、AX对象、窗口标题、实际frame或显示实例 |
| 调度 | 定义及启停意图、触发策略、Workflow引用 | 授权指纹、claim、attempt、nextFireAt、运行／恢复状态 |
| MCP／文件目录 | 显式连接／本机资源需求、协议、参数和所需本地字段 | 秘密引用、授权grant、bookmark；不解析目录或建立连接 |
| 剪贴板面板 | 主动作、分隔符等界面偏好 | ClipboardStore正文、历史和来源明细 |

CLI环境变量值作为已知敏感载体排除，以有界`requiredLocalFields`明确列出待补需求，不能填空后冒充完整配置。stdio模型没有环境变量配置。空AI服务允许导出，明确列出endpoint／model和服务可能要求的API key待补需求，不查询钥匙串判断是否已存。提示词、argv、URL等自由文字仍按原文审阅；资源路径或连接的敏感性由用户判断。排除manifest必须具体说明已排除字段，不能只给笼统“脱敏完成”。

除现有模型限制，v1导出另有限额：普通CLI名称512字节，参数及环境键各4096项，单参数1MiB、环境键256字节；AI动作名称512字节、prompt1MiB、modelOverride／builtinKey512字节；单类别快捷键／别名／收藏4096项，别名1024字节；clipboardExclusions1024项／每项512字节。Agent／Workflow各32、Snippet200、网页100、集合32、应用动作100、工作区32、调度200、MCP及目录各8个。编码前有界累计且检查整数溢出；JSON转义后仍以实际8MiB为准。普通CLI不套用stdio的128参数／16KiB argv限额。新增导出限额不会更改已保存定义或运行策略。

统一检查Workflow→CLI／AI、Agent→CLI／MCP、Collection→命令、Schedule→Workflow，以及别名／收藏／快捷键的引用图。应用路径、编译期工具、目录及连接等外部资源进入`externalReferences`，不声称归档包含这些资源。断裂内部引用、重复ID、未知必需类别或临时窗口等不支持的持久引用阻止完整导出，不能静默丢弃。

## 一致快照与架构

协调器只读各owner已加载定义，不扫描用户目录、不读取Keychain／正文／账本、不启动MCP或命令，也不注册热键。主线程捕获主配置、应用动作、桌面工作区、面板偏好及发布代次；await调度定义快照后重验这些代次。发生跨代修改则要求刷新，不循环重试拼接，也不只靠可回到原值的内容指纹。

主配置和两个独立定义owner需提供随成功定义发布推进的stamp及可用状态，面板已有revision。加载失败或来源不确定时显示不可用，不以默认空数组报告“0项”；不调用可能改变可写状态的PrivateArchiveStore.validateCurrent来冒充纯读取。合同称为“已加载配置定义”，不宣称磁盘逐字备份。

ScheduleLedger增加窄化definitionSnapshot：只含定义投影与定义代次，不包含授权／运行元数据；claim等运行更新不推进定义代次。无需暂停调度、写journal或改存储。Activity、AI usage、Invocation和Clipboard历史均不读取。

投影、引用图与预算使用纯模型验证，捕获协调器在WorkbenchFeature组合，后台Task编码，关闭或换选项使捕获身份失效；系统保存继续采用稳定sheet／fileExporter接线。JSON使用可选择、只读NSTextView及延迟排版，不把数MiB正文拼进辅助名称；基础层不导入App。新用户文案进入现有中英文String Catalog。stdio只做独立结构校验，不调用包含FileManager访问的validate；HTTP／AI复用纯结构校验，不检查服务是否可达。

## 验收与后续边界

覆盖全类别合成内容、引用完整性、Unicode／顺序保真、敏感哨兵／bookmark／授权排除、来源不可用、跨代与ABA修改、未知版本／断链／超限、冻结字节、取消／失败／关闭／迟到回调。证明导出全过程零配置写入、零网络、零执行、零调度claim，再做中英明暗的实际系统保存与取消。

本机AiBox备份的版本清单、最低兼容版本、完整性预检和部分失败报告可作设计参考；其现有备份排除applicationSettings，不能当作KeyDock现成配置导出。仅参考设计，不迁入未经权属核验的私有代码、媒体或备份依赖。

未来导入另需ID冲突／重映射、依赖闭包、资源重新绑定、授权重审、默认禁用调度／MCP、跨库提交／补偿与启动恢复。导出完成不能关闭这些义务，也不能恢复执行授权或触发真实AI。真实API仍按用户决定稍后配置。
