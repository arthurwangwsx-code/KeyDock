# 任务持久化与显式新尝试

2026-11-26，任务33实施中：Core及独立准备页、四类生产新授权入口、默认仅展示和安装数据版本门禁已接通。承接原5.5的完整RunStore义务，产品切片是“持久类型化记录 → 重启只读检查 → 准备新尝试 → 重新授权与持久化 → 新UUID执行”。原输入／输出的可选保留、完整checkpoint材料及真正续接另行建设；本切片不能代替完整RunStore验收。见[Core复查](../implementation/task-recovery-core-2026-11-26.md)和[App接线与原生复查](../implementation/explicit-attempt-ui-2026-11-26.md)。

## 产品闭环

任务详情使用“准备新尝试”，与“继续执行”区分。Interrupted／unknown表示效果不明，Paused表示旧尝试已停止，两者都不能证明尚未执行或可撤销。打开历史、启动App和准备审阅不发送请求、不占执行槽、不读剪贴板／MCP资源／钥匙串。

准备页显示旧状态、当前可用定义与版本变化、目标／服务／工具范围、预算和重复效果提示；输入默认空，用户重新提供。旧编辑稿和结果保持原身份。定义删除时只读查看；定义变化须重新加载审阅。Esc取消无效果，保存／配置失败保留字段，双击只消费一次当前呈现。

新尝试采用当前定义、当前费率和新授权；旧终态、调用证据与费用不改写。恢复后输出默认只展示，不自动复制、替换选区、打开命令审阅或重投工具。CLI／MCP／Terminal unknown须先检查实际效果，不能承诺exactly-once。首个无外部依赖验收选择保存的非交互CLI与纯文本Workflow；既有Terminal工具拒绝和真实API稍后配置决定继续保留。

## 数据与权威边界

区分逻辑run、一次任务执行和provider网络请求：逻辑run用于关联；每次新执行使用新的任务／invocation身份；每次transport.open继续使用独立AI request attemptID。Workflow usage的parent仍指实际Workflow执行，不指逻辑分组，不能把父索引和新旧attempt重复入账。

持久DTO仅允许类型化kind、逻辑关联、当前attempt／recoveryOf、定义ID／版本／指纹、revision、时间及既有invocation／usage引用。旧metadata-only回执保持只读，不从标题或任意commandID猜恢复入口，不伪造原正文。首版不保存prompt、正文、argv/env、完整endpoint、工具参数／输出、隐藏推理、授权grant、AX引用、窗口／选区／剪贴板身份、调度claim或可执行callback；内容不进入配置导出。

RunStore是既有InvocationStore同一actor上的类型化查询与CAS；逻辑关联与副作用intent／result共用文件、原子提交及预算，不建立第二份互相覆盖的效果真值。新intent和来源revision递增同一事务持久化，成功后才返回worker出生身份／actor／revision stamp。类型化finish／release／abandon必须带准确stamp，旧无stamp调用不能操作后来重建的类型化记录。最终派发仍须由App完成新的接纳和全部所需持久写入；写失败零执行。冷启动只检查，不排队重试。后置fsync不确定保持durabilityUncertain；失败返回的undispatchedStamp只允许收口，不能作为执行成功或派发授权。

复用目录fd固定、owner/no-follow、原子写、单条／数量／字节预算与90天保留合同；新记录纳入现有任务总预算及清除generation，不另给恢复记录分配第二份200项预算。恢复记录不占8个执行槽，真正提交才接纳；旧worker未收口时不能重叠启动。清除／TTL、旧加载及迟到结果不能复活被删除记录。

## Core切片的固定合同与回退边界

保存CLI／AIAction使用定义ID及专用fingerprint v1，Agent／Workflow另带已有定义version。专用白名单DTO不依赖整个模型的默认Codable：Set／environment按准确UTF8键排序，argv／steps保序；nil与空、Unicode字节差异及有限Double位模式保留。四类固定SHA-256向量防止日后编码漂移；摘要不是依赖或授权快照，配置／contribution／history发布代次仍需App重验。

MCP合同仅比较完整选中工具、来源ID／配置revision、原名／模型名／描述／schema及不可信只读hint，不包含连接generation／catalog.revision；后两者继续由当前会话用于迟到围栏。流式长度分帧hash沿用生产64KiB单schema、256KiB目录、8192节点／32层预算，不因投影膨胀拒绝合法目录。它不连接服务、不读取密钥，也不产生工具权限。

含类型化元数据的文件使用Envelope v2，新App读v1／v2；纯legacy仍写v1。alpha.18仅支持v1，会明确拒读v2，不能忽略字段后重写。alpha.19候选的四类保存定义执行会生成v2。统一安装器实施只读版本门禁；旧二进制备份不能宣称完整数据回退，跨版本archive／restore仍未建设。

安装门禁从已验签候选App的BuildInfo读取schema1能力声明，不用当前checkout配置推断；只对已知alpha.1–18缺省声明映射为v1，未知版本缺失或无效声明拒绝。正式交换前正常退出并持有既有runtime-owner data lease，再有界只读复查三个固定回执文件的Envelope版本、目录和文件身份（含原缺失项）。install／rollback／失败补偿及“已经回退”快路均重新检查，dry-run不创建目录或锁、不退出App。alpha.18遇到v2拒绝交换并保留双方App；不剥离字段或删除数据来放行。旧安装回执的结构兼容与本次fresh capability检查分离。签名Preview的合成v2放行／read-v1-only拒绝已验证；拒绝声明是重签合成合同，不是真实alpha.18运行验证。手工拖拽、历史脚本及任意自定义数据域不在统一工具门禁范围内。

正式域按当前UID的用户Application Support定位，默认Preview域按OS getconf定位，不继承构建gate的TMPDIR。实测Foundation temporaryDirectory在本机也未采用该TMPDIR；原生验收使用单独的`native-review`入口及仅Preview编译接受的private owned UUID／marker目录。它不修改安装器resolver，不改变普通Preview的默认域，不构成OS沙箱。

## 恢复事务

1. 只读检查版本化manifest与既有回执，非终态显示interrupted／unknown；无可信引用的旧记录只读。
2. 主线程创建稳定准备呈现，冻结history generation、record revision和当前定义审阅；独立有界输入不覆盖原草稿。
3. 用户提交时复查呈现／revision、定义及contribution、MCP enabled／session-disabled／catalog/schema、文件范围、模型／API结构、OS权限及预算。检查结构不代替真正提交时的凭据与网络检查。
4. 创建新UUID，重新走现有生产admission／authorization／intent入口，成功持久化后才派发；任何await后重新核对身份／代次。旧审批、provider／broker session及调度授权不恢复。
5. 终态按本worker出生身份／actor／revision stamp保存后发布；checkpoint仍按其独立合同校验。保存结果失败保留unknown，不提示“可安全重试”。旧attempt保留，新费用由新调用快照决定。

## AiBox参考与验收

三位Agent只读核对KeyDock基线6baaee8及AiBox基线19aa63e7（AiBox已有WIP保留）。借鉴PlaybookRunStore的持久成功后发布／revision CAS、Run/Task/Attempt分离及Environment重验。AiBox冷启动自动入队、加载checkpoint即running，以及包含thinking／参数／正文的codec不进入KeyDock；代码与数据格式独立编写，不迁源码、个人数据或凭据。

必须覆盖：intent前／后、派发后、结果返回／落盘前的中断；重启零执行；新UUID与旧事实不覆盖；旧审阅遇到编辑／删除／同ID重建／来源撤权／失败后的session-disabled；取消、双击、旧sheet回调、清除／TTL与迟到读；容量满及未drain拒绝；持久写失败零效果；恢复零自动复制／替换／命令执行；usage不重复计价。原生中英明暗的新尝试／未知提示／取消／重启、完整检查、CI及发行分别留证。真实API／系统、完整视觉及原5.5保持独立。
