# 任务持久化与显式新尝试

2026-11-25，任务33计划，尚未实现。承接原5.5的完整RunStore义务，首个切片是“持久类型化记录 → 重启只读检查 → 准备新尝试 → 重新授权与持久化 → 新UUID执行”。原输入／输出的可选保留、完整checkpoint材料及真正续接另行建设；本切片不能代替完整RunStore验收。

## 产品闭环

任务详情使用“准备新尝试”，与“继续执行”区分。Interrupted／unknown表示效果不明，Paused表示旧尝试已停止，两者都不能证明尚未执行或可撤销。打开历史、启动App和准备审阅不发送请求、不占执行槽、不读剪贴板／MCP资源／钥匙串。

准备页显示旧状态、当前可用定义与版本变化、目标／服务／工具范围、预算和重复效果提示；输入默认空，用户重新提供。旧编辑稿和结果保持原身份。定义删除时只读查看；定义变化须重新加载审阅。Esc取消无效果，保存／配置失败保留字段，双击只消费一次当前呈现。

新尝试采用当前定义、当前费率和新授权；旧终态、调用证据与费用不改写。恢复后输出默认只展示，不自动复制、替换选区、打开命令审阅或重投工具。CLI／MCP／Terminal unknown须先检查实际效果，不能承诺exactly-once。首个无外部依赖验收选择保存的非交互CLI与纯文本Workflow；既有Terminal工具拒绝和真实API稍后配置决定继续保留。

## 数据与权威边界

区分逻辑run、一次任务执行和provider网络请求：逻辑run用于关联；每次新执行使用新的任务／invocation身份；每次transport.open继续使用独立AI request attemptID。Workflow usage的parent仍指实际Workflow执行，不指逻辑分组，不能把父索引和新旧attempt重复入账。

持久DTO仅允许类型化kind、逻辑关联、当前attempt／recoveryOf、定义ID／版本／指纹、revision、时间及既有invocation／usage引用。旧metadata-only回执保持只读，不从标题或任意commandID猜恢复入口，不伪造原正文。首版不保存prompt、正文、argv/env、完整endpoint、工具参数／输出、隐藏推理、授权grant、AX引用、窗口／选区／剪贴板身份、调度claim或可执行callback；内容不进入配置导出。

RunStore负责逻辑快照与CAS，既有InvocationStore继续负责实际副作用intent／result。不得建立第二份互相覆盖的效果真值。最终派发必须先完成新的接纳和全部所需持久写入；写失败零执行。跨store中断可能留下准备记录或unknown intent，冷启动只检查，不排队重试。只有落盘成功才发布快照；后置fsync不确定保持durabilityUncertain，不能回退到旧文件后执行。

复用目录fd固定、owner/no-follow、原子写、单条／数量／字节预算与90天保留合同；新记录纳入现有任务总预算及清除generation，不另给恢复记录分配第二份200项预算。恢复记录不占8个执行槽，真正提交才接纳；旧worker未收口时不能重叠启动。清除／TTL、旧加载及迟到结果不能复活被删除记录。

## 恢复事务

1. 只读检查版本化manifest与既有回执，非终态显示interrupted／unknown；无可信引用的旧记录只读。
2. 主线程创建稳定准备呈现，冻结history generation、record revision和当前定义审阅；独立有界输入不覆盖原草稿。
3. 用户提交时复查呈现／revision、定义及contribution、MCP enabled／session-disabled／catalog/schema、文件范围、模型／API结构、OS权限及预算。检查结构不代替真正提交时的凭据与网络检查。
4. 创建新UUID，重新走现有生产admission／authorization／intent入口，成功持久化后才派发；任何await后重新核对身份／代次。旧审批、provider／broker session及调度授权不恢复。
5. 终态与checkpoint按expectedRevision保存后发布；保存结果失败保留unknown，不提示“可安全重试”。旧attempt保留，新费用由新调用快照决定。

## AiBox参考与验收

三位Agent只读核对KeyDock基线6baaee8及AiBox基线19aa63e7（AiBox已有WIP保留）。借鉴PlaybookRunStore的持久成功后发布／revision CAS、Run/Task/Attempt分离及Environment重验。AiBox冷启动自动入队、加载checkpoint即running，以及包含thinking／参数／正文的codec不进入KeyDock；代码与数据格式独立编写，不迁源码、个人数据或凭据。

必须覆盖：intent前／后、派发后、结果返回／落盘前的中断；重启零执行；新UUID与旧事实不覆盖；旧审阅遇到编辑／删除／同ID重建／来源撤权／失败后的session-disabled；取消、双击、旧sheet回调、清除／TTL与迟到读；容量满及未drain拒绝；持久写失败零效果；恢复零自动复制／替换／命令执行；usage不重复计价。原生中英明暗的新尝试／未知提示／取消／重启、完整检查、CI及发行分别留证。真实API／系统、完整视觉及原5.5保持独立。
