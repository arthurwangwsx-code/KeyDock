# 可选任务材料与显式复用

2026-11-26，任务35，实施中；承接完整RunStore的可选正文／checkpoint义务，不把alpha.19的metadata恢复等同正文保留。InvocationStore继续是唯一执行事实，材料不是授权、运行队列或恢复指令。

## 产品合同

设置→隐私默认关闭“允许保留任务材料”。开启后只为未来typed AI／Agent／Workflow捕获准确运行输入及最近一次确认成功的Workflow边界；CLI没有独立文本输入，不把argv／env当作输入。开启前的任务不从后来编辑稿补猜，区分未捕获与准确空输入。任务详情可逐项审阅并手动保存原输入、指定时刻的可见结果、最近成功边界，不自动归档。Agent可见结果包含模型文本和工具返回，明确说明且默认不选；没有脱敏承诺。

停用先同步撤销捕获／保存许可并推进代次，释放临时捕获和保存审阅的正文，再等待已接纳写入收口；配置保存失败仍保持本会话停用，说明重启可能恢复旧设置。已存文件保留至到期，仍可主动查看或删除。清除全部材料会清除保存文件、临时捕获及读取缓存；普通任务结果仍按会话历史规则保留，清除任务历史另有入口。

重启只读小header投影“有保留材料”，不读取正文。用户点击后读取／校验正文，以只读独立页查看或删除。保存及查看使用稳定modal所有权，加入所有相反入口的互斥；实际dismiss后才交接其他准备页。长正文滚动，底部保存／关闭固定，中英文及明暗外观复用原生组件。

“使用保留输入”只填新准备页，不提交。读取票据同时绑定presentationID、reviewID、inputRevision、材料身份／revision、清除generation和requestID；输入任何字节编辑、ABA、刷新、提交、关闭或清除后不再回填。非空输入明确审阅替换，不用可见结果兜底。填入后成为新页独立文本；删除来源不悄悄擦掉新编辑。旧unknown确认、当前定义／工具／费率、重新授权、新UUID和默认只展示合同不变。

## 身份与格式

稳定key为`receiptStore(cli/ai) + invocationID + receiptRecordIdentity`；出生身份取RunAttemptMetadata.recordIdentity，不使用会随新尝试递增的来源revision，也不序列化RunAttemptStamp／actor identity。正文有独立materialIdentity与contentRevision CAS，删除重建换materialIdentity。非Codable一次性保存票据另绑定当前actor、确认nonce、许可epoch和内容generation；不保存任何执行grant。

WorkbenchFeature内独立Foundation／Darwin actor固定目录FD，使用openat、O_NOFOLLOW／O_NONBLOCK及实际FD owner／regular／单链接／身份／有界读取检查。private目录0700、文件0600；路径换绑拒绝。单文件格式固定为8字节ASCII `KDMAT001`、4字节大端header长度、有界header JSON、payload JSON。header最多8KiB，包含formatVersion=1、key、材料身份／revision、时间、选项、raw长度、payload长度和SHA256；单文件总编码后最多4MiB。inventory只读前缀与header，点击后才读／校验payload。Swift／Python固定合成golden fixture约束格式。

payload只允许所选运行输入、可见结果及最近成功边界的准确输入／输出和step身份；不自动序列化system prompt、argv/env、完整endpoint、工具参数、隐藏推理、窗口目标、选区身份、调度claim或callbacks。显式选择的正文可能包含敏感信息，审阅页须说明它保存为本机用户目录文件；不承诺应用级加密。正文不进入配置导出、统计、日志或发行证据。

默认7天、200份、64MiB总量；原输入128KiB、可见结果1MiB，checkpoint输入／输出沿用对应文本上限。包括JSON转义膨胀在内超预算整次拒绝，不静默截断，不为新保存先删除未过期用户材料。输入、成功边界、读取／审阅缓冲纳入32MiB会话预算；活动输入预留抵扣已捕获字节，checkpoint额外空间先接纳。可选捕获缺材料不改变执行终态或重试步骤。

替换时先为完整新临时正文预留空间，旧正文在rename前仍计入64MiB；最终文件能装下但旧文件加新临时文件装不下时，也整次拒绝，不能以最终占用量掩盖崩溃时实际残留。

## 持久屏障与删除

明文写入前先持久化无正文pendingWrite，随后临时文件→file fsync→renameat→directory fsync；目录状态确认后收口pendingWrite并发布成功。前置故障保留旧文件，rename后失败返回durabilityUncertain，不说旧文件未变、不自动重写。临时文件名包含v1 managed前缀和稳定key，崩溃留下的正文临时文件计入扫描、配额和清除。没有临时文件且当前header与已确认保存意图一致时，仅可同步目录确认当前版本，不重写／重建正文；有未确认文件时保留问题，不能当作空库。

文件层持有actor生命周期的独占flock，固定FD并复核锁目录项身份；第二writer拒绝，shutdown后才释放。撤权与正文rename由共享内存Fence线性化，编码和fsync不放入这个短metadata临界区。

清除／单项删除先撤销旧票据和读取发布，再持久写入小型无正文control intent，之后unlink并同步目录；全部完成后收口intent。启动可继续已确认的隐私删除，但不读取待删正文。pending intent遮蔽目标材料，部分失败报告真实remaining／failed；无法持久保存删除意图时明确失败，不声称跨重启已经清除。完整清除包含managed tmp、孤立／坏header文件；陌生目录、symlink或不安全owner不跟随，保留问题供处理。

metadata-only owner查询独立于执行恢复资格，保存／读取和发布分别复查出生身份。父metadata删除后不重新附着到重建同UUID记录；清除history在删除前撤销材料票据并为目标出生key建立删除意图。TTL／孤立材料维护只操作已捕获inventory的具体handle并核对CAS，不根据过期的全量owner集合删除后来新增的材料。用量／费用及旧执行终态不因正文写入或删除改变。

## 成功边界与生产入口

WorkflowRunner新增独立有界成功材料端口，只在完整succeeded且预算检查通过后提供run／definition／step／sequence和准确stepInput／stepOutput。以非闭包WorkflowMaterialObservation值接入，保留既有host／onCheckpoint的trailing closure绑定，并以真实编译回归约束。不能从最终output推断成功边界，因为失败／取消步骤也可能先更新output。捕获器同步接受有界材料或明确等待有界投影；宿主核对worker出生身份、capture epoch与sequence，只保留最近成功边界，不提供continueFromStep。

AI使用validatedAIInput后的冻结输入；Agent／Workflow使用实际函数入参，不回读草稿。beginOwnedReceipt成功后绑定准确recordIdentity，写入失败或未获得持久owner不产生可保存材料。工作区／快捷键／显式新尝试均复用相同生产入口，默认不复制／替换。

## 安装与回退

保留invocation Envelope v2。签名dataCompatibility独立声明taskMaterial读写版本；新声明升级协议，已知alpha.19及更旧视为materialReaders=[]，未知版本缺声明拒绝。安装／rollback持有runtime-data lease，只读有界header和control并复查目录／文件身份，不读正文、不迁移数据。

正式文件、managed临时／孤立文件、坏header、未知schema和pending clear都不能因UI presence缓存为空而忽略。旧reader遇到任何材料或未知状态即拒绝，App和数据保持不变；实际清空全部材料及临时／残留状态后才允许回退。新reader也不得把无法确认的格式当作空库。合成签名旧reader资格和实际旧版运行分别报告。

## 参考与验收

AiBox仅借鉴serialized mutation／expectedRevision、persist后发布、projection与正文分开及session/run身份检查；未迁入私有源码、codec、媒体、thinking或自动队列。KeyDock复用自己的模块边界与预算，不直接复制usage的整档案读取或“先删再写”策略。

必须覆盖：准确输入与后续draft隔离、开关／ABA、NFC/NFD与空输入；成功A后失败／取消／超限B仍保留A；出生身份与CAS、删除重建；raw／编码后／总预算；rename及fsync故障；目录换绑、链接／FIFO／坏header；清除读写交错、部分失败与中断后pending意图；重启header-only及零执行／复制；输入回填旧ticket拒绝；同源新旧费用不重算；签名旧reader对正文／tmp／未知格式拒绝并保全数据，清空后允许。原生中英明暗、长正文、失败／取消／重启留独立证据。新流水线真实发行、完整视觉、物理系统、真实API及原P0–P4验收继续分别记录。

## 当前实现范围

独立文件层、actor、删除控制、固定跨语言样本、未来typed输入捕获、会话配额和成功边界端口已实现；65项Swift定向与137项Python回归已通过，见[本轮实现记录](../implementation/task-material-core-2026-11-26.md)。原生保存／查看／删除审阅、回填票据、App启动维护与history正文清理接线仍未完成；当前没有开放设置开关或正文保存按钮。签名reader协议及安装只读门禁已接通，签名Preview资格、整仓检查及真正发行尚待执行。alpha.20是开发候选，正式安装及公开Release仍为alpha.19。
