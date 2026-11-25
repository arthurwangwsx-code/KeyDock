# 任务内容原生审阅与显式输入复用

2026-11-26，继续`feature/task-material-retention`，主Agent单写；基线`a5deaca8a63e117f0054eef21d96c352d0805794`。基线[原生CI 45707552951](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45707552951)已通过，但这不代表本轮随后新增的UI源码取得同源CI资格。正式安装和公开Release仍为alpha.19，alpha.20尚未发行。

## 实现与状态

| 范围 | 状态 | 事实与限制 |
|---|---|---|
| 默认关闭／准确捕获 | PASS（定向） | typed AI、CLI、Agent、Workflow沿用同一生产入口；准确输入与后来编辑稿分离，CLI不把argv/env编码为输入。无关单项删除／TTL仅撤销内容票据，不撤销运行中的捕获许可 |
| App维护与历史清理 | PASS（定向） | 独立启动恢复删除意图，owner批量读取不确定时保留正文；历史先清对应birth正文再删父记录，失败保留metadata；纯内存逐出不删除磁盘内容 |
| 预算与收口 | PASS（定向） | read在await前预留解码上界，关闭时不提前释放未完成worker预算；save在创建Task前同步预留并单次接纳，实际完成才释放。shutdown等待读写／删除／维护收口后释放flock |
| 审阅／查看／删除 | PASS（实现及原生子集） | 独立稳定sheet、逐项冻结／默认均未勾选、Agent工具返回明确说明、私有正文不进入导出；删除先显式勾选。后续已实际完成最终删除点击、空库导航和保存失败重审，完整矩阵仍开放 |
| 输入复用 | PASS（定向及原生子集） | 绑定呈现／review／inputRevision／request／material version／文件身份／generation，超限编辑和Unicode ABA也失效。仅填原输入，已有文本需预览后明确替换，无结果兜底、无自动提交 |
| 独立内容库 | PASS（实现／定向／原生子集） | `Saved content`侧栏及隐私设置入口，header-only列表与任务200条内存记录独立；内存逐出后仍能查看及准备新尝试。标题固定预算、最多200行。后续卡片布局和独立AX按钮已实际复查，完整系统矩阵仍开放 |
| 视觉／物理／发行 | PARTIAL | 已观察中文浅色和英文深色、128KiB三字段及1MiB CLI结果子集；AI／范围大文本、完整明暗／辅助功能／IME／全屏多屏、物理热键仍开放；未将退出0或模型绿测当作完整产品验收 |

关闭保留先撤销运行时许可并释放临时审阅，配置失败仍保持本会话关闭，并提供再次保存关闭状态的入口；已存文件仍可读取。文件在7天后过期并拒绝读取，到期清理发生在下次App维护，App关闭时没有后台删除保证；不是应用级加密或SSD安全擦除。

## 定向与原生证据

同一iSpec apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`，共享存储8GiB租约内串行运行。

- `task-material-library-v1`：140项定向通过（Workbench123＋RunStore17），receipt SHA256 `1978306342a49855548a5fe633849d2e9ccb433df67d64f36f5f4d0cf7f56965`。含真实begin等待撤权、2000个metadata key的少量正文清除、保存后最后owner查询期间清除不复活、读取／保存真实worker预算、partial delete父记录保留、无关捕获保留、内存逐出后独立读取，以及新尝试的空值／NFD／非空替换／版本变化／超限ABA／迟到读取与结果不兜底。
- 首轮输入复用检查`task-material-input-flow-v1`保留FAIL：偏好更改推进原有配置范围审阅代次，旧review不能直接复用；测试先重新审阅后通过，未放宽执行门禁。最终更完整检查另行记录，不将上述次数套到新增标题本地化后的精确源。
- 干净源`93b8304`的首轮完整检查`task-material-ui-full-check-v1`保留FAIL：两项既有上下文输入边界测试仍按旧空会话预算设置，新增的200KiB标题固定预留使单槽接纳前提不再成立，共6个断言问题。后续测试基线计入固定预留，单槽拒收／清除和释放／恰好满额的原断言保持；没有取消标题预算或放宽产品上限。137项Python和925条文案在该轮已通过，Swift整体验证必须由随后修正源重新运行。
- 优化隔离Preview `task-material-ui-preview-v1` exit0，86.999秒，receipt SHA256 `623b5a4de6790cabd0073439c4770961de6ca4d989cab9544e3739356ac0560e`；实际观察App摘要`a5821085839769fec1b1cfd9f5d63e6f98c9fb31db1d740a093e5e48016aa9a3`，基线a5deaca／dirty。它早于后续残留提示、到期说明、导出偏好与独立内容库修补，不能作为新精确源的发行资格。
- `task-material-native-review-v1/v2`均正常退出0；生命周期本身不证明UI通过。Cua实际观察中文浅色手动保存两字段、保留原始空白及NFD、只回填不执行、非空输入预览后显式替换、点击开始后才产生第二次纯变换任务；英文深色只读页及英语到期日期、重启仅恢复两份metadata，再点击后查看正文。默认均未勾选；删除按钮仅在勾选后可用，未点击最终删除。
- native结构复核`task-material-native-proof-v1` exit0，receipt SHA256 `48534763e1f7cf9fd9c8431d58734224750a9447bb348ac90e279bdbb45f9b61`。owned样例只有一份正文、两个typed成功attempt、原birth关联保持，重启后没有新attempt／CLI或工具回执，control idle。脚本只核对合成数据后置条件，不声称可替代截图／交互评审；不输出正文。

原生证据和进程记录在`.local/desktop/KeyDock-Review-ab5477f8-523b-4c92-97cc-567fc97ef688`与`.local/desktop/task-material-native-*.log/json`，均为本轮合成内容，不提交到开源资产。Cua在第一次退出后的AX观察重新启动默认Preview；已立即正常退出，未把该域内容用于验收。第二次退出只按owned child receipt确认，不再做退出后AX请求。Terminal和SecurityAgent既有工具拒绝始终遵守。

模拟⌥Space在有／无sheet时未形成可确认的快捷键触发证据，保留NOT_QUALIFIED，不能把“树未变化”写成全局热键互斥通过。App入口已加逻辑owner保护，但物理触发仍须独立验证。

## 待完成

AI／范围大文本及保存失败／取消／清除的完整原生矩阵，以及最终干净源完整本机／指定同源CI／Developer ID与新候选协议App+DMG公证／发布／安装回退继续推进。完整RunStore、P0–P4、真实API与真实系统验收义务不由本轮子集关闭。

## 后续列表状态修补

干净源`d2df5d18e903e17345e5fb5b7aabc0682e29cd1c`已完成916项Swift执行／137项Python／925条中英文案及生产配置合成OCR双轮完整本机检查，`task-material-ui-full-check-v2` exit0，receipt SHA256 `941425217d63f01f6e0f09c4b5a29b31e40bb344cac4805eeec7fb3d0bd6188c`；指定同源原生CI为[45715805578](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45715805578)，状态以运行结果为准。优化Preview `task-material-library-preview-v1`也已构建通过，但以下源码修补不能沿用它的精确源资格。

只读交互评审发现：同名／同日条目缺少区分、首次读取前误显示空态。已增加带秒保存时间、列表序号与包含记录上下文的按钮AX名称，并明确idle／loading／ready／failed。主动撤销索引请求时同步收口旧loading，防止设置关闭保留后永久转圈；旧worker仍不能覆盖新请求状态。

`task-material-library-states-v2`的30项定向检查／3套件通过，receipt SHA256 `c44542ff9101a3848c692316a9c3a571ce87d56693be0316575bc2d150920d91`；真实header阻塞、损坏、移除及关闭捕获后新读取均有覆盖。当前930条中英文案，修补后原生观察与完整同源资格继续执行，35.6／35.7未关闭。

优化干净`0f1a347`的隔离原生检查发现两项实际UI失败：行内按钮被AX合并，且确认空库后贪心空态使标题／底栏／侧栏移出可见区域。删除勾选及最终点击已实际完成，正文移除、父metadata保留，但不能以生命周期exit0覆盖上述视觉失败。后续将列表限制在实际viewport，并对行使用包含独立按钮的AX分组与显式按钮样式，必须重新原生检查。样例位于独立合成域`KeyDock-Review-eb3d2a51-36eb-466a-b2c7-c63e49537270`，原始样例未改写。

干净`f4161f4`第二轮原生观察已确认viewport修补：实际删除后标题／底栏／侧栏可见，侧栏能继续导航。128KiB准确输入经过真实纯变换运行，原输入／结果／最近成功边界默认均未选，长正文内外滚动时固定底栏可达；注入owned陌生文件使保存明确失败，移除故障后重新审阅仍从全未选开始，明确勾选三项后保存成功。这里只覆盖128KiB结果，不声称1MiB结果或完整视觉矩阵已通过。原生List仍合并两个行内AX按钮，后续改用有界惰性卡片容器并再次验证；该轮生命周期exit0不替代未通过的AX项目。

最终本轮原生子集使用干净`ec3c265d205733fbd3f318878bf1e4f3aee8231b`、优化Preview摘要`54518ef52cee126c56e13ca05543a2a70b711c1d7ce44c319d1507f18e6b0618`。惰性卡片现在实际暴露两个独立AX按钮，能直接按索引打开查看和新尝试；英文深色／中文浅色标题、带秒时间、卡片和底栏已观察。关闭捕获后仍可主动查看三字段长正文，原始131072字节输入可准确填入新准备页，取消后未运行；不把AX输出的可见／100000字符摘要当作正文截断。

三轮原生进程均正常退出；`task-material-library-native-v3`只记录生命周期，receipt SHA256 `139d3510c954cea545a9a588c38d771e332a67cd143d76c4e8a5539387f52d8d`。后置条件检查`task-material-library-native-proof-v1`另行核验：第一隔离域确认删除后正文0份而父metadata2份保留；第二隔离域只有一份三字段正文，input／result／checkpoint input／checkpoint output各为131072字节，旧两份回执逐字段未变，合计3份成功回执，重启及回填后没有新增attempt，CLI／工具回执均为空，control无待完成操作，捕获设置已关闭。证明文件为`.local/desktop/task-material-library-native-proof.json`，不输出或上传正文。截图仅通过CUA在对话中实际观察，未声称存在本地截图文件。

第一次原生AX合并与空态布局FAIL保持为历史证据；修补后的子集PASS不扩张为完整VoiceOver／IME／全屏多屏、1MiB结果、物理热键或全部视觉验收。真实API仍按用户决定待配置。本轮代码随后只追加文档／任务进度，最终干净本机和指定同源CI另记，不能由前序d2df5d1的绿测替代。

## 1MiB场景触发的结果显示卡顿

`94f5311`的918 Swift／137 Python／930 key完整本机与[同源CI45718684585](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45718684585)通过，但随后的合成1MiB原生场景暴露实际产品缺陷，因此尚未晋升master或发行。命令在独立owned域中通过原生Run明确启动，使用非交互Python分别向stdout和stderr输出524288个B／C，不使用shell、Terminal、模型或个人文件。

结果区两次CUA观察超时；进程持续约99% CPU，RSS从约736MiB增长到约1096MiB，采样主线程集中在SwiftUI的AppKitTextInteractionView／TextSelection／TextLayoutManager。普通⌘Q未响应，随后仅对已核对PID／路径／owned fixture的本次Preview发送SIGTERM，保留exit-15和E2E非零回执，不称正常退出或App自行崩溃。CLI父metadata仍为running，不把进程输出计划当作已完整接收1MiB的证明。

失败域为`KeyDock-Review-d017f527-e262-4283-99fb-79613f5f0d81`，采样在`.local/desktop/large-result-hang.sample.txt`；`task-material-large-result-native-v1` receipt SHA256 `6df9f9fecfe192248639cd6baf81368092cb36831b0438cc8ff41a4e87e2c06c`。结果区改为复用现有AppKit只读文本组件，保留完整正文、选择、独立滚动与原复制动作；这项修补必须重新做大结果原生验证，不能沿用前序绿测。正式App仍为alpha.19。

同次只读评审确认AI输出（Launcher／Workspace共用）与当前执行范围预览也允许至1MiB，均接入同一组件，保留原compact／workspace高度、字号、DisclosureGroup及复制／替换动作。完整配置导出已使用此原生组件；设置摘要有独立64KiB编码上限和固定字段投影，不以此将修补扩大到全部小型标签。

修补后优化干净源`50a1ccffbf014bf26cfa1bf6f4be157033a83dc8`、Preview摘要`8532591005663d4ad6fd8937ac0469b3b443b4821328cd7eda2cd9db24a13652`在新合成域`KeyDock-Review-2fab8cd5-ed89-4965-900c-024965b0e172`重跑。实际看到Completed／exit0、首尾滚动、默认未选的保存审阅、明确保存、独立卡片及按需查看、切换旧任务后无旧大正文、正常⌘Q退出。最初窗口切换／观察出现一次AX failure和一次工具kernel timeout；同时磁盘回执已成功、App CPU空闲，重绑定后UI操作恢复，不能把它定性为同样的App持续卡顿，工具异常原因仍未完全定位。

`task-material-large-result-native-v2` lifecycle exit0，receipt SHA256 `4ddb60ddccbb319b5c1d8a4713e1ba4bd821c4e4e0fa4d579c31d742d90dd397`。独立文件证明`task-material-large-result-proof-v1`确认保存的visibleResult恰为1048576字节，B／C各524288个、无其他字符且非partial；只保存结果，不把CLI argv当作原输入；一份成功CLI回执、两份旧AI回执逐字段未变、无工具回执、control idle。报告为`.local/desktop/large-result-native-proof.json`，未输出正文。该原生子集仅覆盖CLI结果区及保存／查看，不声称已完成独立AI流式大输出、范围大预览、全部中英明暗或VoiceOver／IME／多屏。931条文案及最终同源检查另行记录，35.6／35.7仍开放。

进一步使用已有loopback SSE夹具检查AI超限输出。隔离Preview只发送合成输入，无API密钥或外部服务；启动台显示Failed及结果不完整提示，Open in Workspace沿用同一任务，服务统计post_requests=1、authorization_seen=0、agent/tool请求均0，随后正常退出并收口自建server。紧凑面板动作区的视觉可见性仍需改善，AX可触发不代替视觉可达。后续将紧凑正文放入有限视口、结果框固定140pt，标题／错误提示／复制／工作区／关闭草稿固定在滚动区外；保持完整正文与工作区交互，需原生复查。该轮`task-material-large-ai-native-v1`仅记录生命周期与已观察子集，不代表改版后的资格。

干净`4945204`优化Preview复查：紧凑动作区在原生鼠标激活／重绘后实际可见；初始动态截图差异保留，未声称完整首帧或焦点矩阵通过。一次坐标操作返回启动台，但旧草稿仍在AI drafts中，因此没有将其当作已确认关闭。通过明确草稿入口在工作区打开关闭审阅，Cancel后原输入及输入焦点恢复；保留结果审阅明确显示partial，默认全未选，手动只保存结果后正常退出。服务统计仍为一次POST、无Authorization及工具请求。

同轮发现未选择任务（selectedTaskID=nil）时，任务空详情会使侧栏顶部及首个Failed行移出视口；选择一个仍可见旧任务后恢复。后续为整个taskContent的HSplitView绑定实际viewport，保留nil和真正零任务分支，不通过自动选首行掩盖；需重新原生验证。该轮生命周期exit0不覆盖这一布局FAIL，原生证据保留在`KeyDock-Review-db5da902-11d2-4137-a81e-09c73f9b5b8b`。
