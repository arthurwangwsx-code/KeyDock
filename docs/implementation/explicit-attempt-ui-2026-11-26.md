# 显式新尝试：App接线与原生复查

基线master 0541a85，唯一canonical checkout的feature/explicit-attempt-preparation串行修改。主Agent写入／设备／iSpec，三位Agent只读复审；未迁移AiBox代码、个人上下文或凭据。任务33.2–33.4实现，33.5与完整RunStore／P0–P4仍PARTIAL。alpha.19为候选，发行事实另行记录。

## 生产合同

保存CLI、AI动作、Agent、Workflow的正常执行保存typed引用；任务详情创建独立准备页，旧无引用记录只读。准备页空白新输入、完整有界执行范围、当前定义变化、未知效果确认；刷新保留输入并废弃旧审阅。20步范围和输入分层滚动，按钮固定在外。输入128KiB、审阅1MiB，超限明确拒绝。

当前history／配置／contribution／MCP来源和catalog代次构成审阅围栏；新UUID在原生产入口完成授权、预算及原子intent接纳后才确认。首次派发前的await重新检查，之后保留在途费率／配置冻结与既有撤权／取消／drain。worker捕获准确InvocationStore和出生stamp，finish／abandon／release不重新猜库或ID。modal互斥保留至真实dismiss，已接纳ID不会被迟到关闭覆盖。

新AI使用当前模型和费率、只发送新输入；旧结果／费用不改写。恢复不读取旧target、clipboard或授权，不自动复制／替换／继续步骤。MCP先展示已连接的选中合同，真正新执行重新发现并比对完整合同；journal await后的配置变化会阻止首次连接。准备阶段结构校验不对stdio executable做FS探测。

安装器读取验签BuildInfo的readVersions／writeVersions，quiesce后持有runtime-owner lease，有界检查三个回执库，最终重新核对目录、文件与缺失标记。rollback／补偿／already-rolled-back也重新检查。旧App不能读v2时保留双方并拒绝交换；无数据降级／字段剥离，完整archive／restore仍未实现。

## 定向与签名验证

同一apply attempt 9881b6d8-e08e-4176-b6a2-97706ee67811串行measure，日志在.local/desktop，回执在change的receipts目录：

| 测量 | 结果 |
| --- | --- |
| attempt-ui-swift-v3 | 31条Workbench定义／3套件＋16条RunStore定义通过 |
| attempt-ui-swift-v4 | 14条准备页定义通过，含AI／Agent两个实调用案例、stdio合同变化／journal gap两个案例和3个原子写故障点 |
| attempt-data-python-v3 | 95项通过，覆盖版本合同、租约、目录重绑、补偿、旧receipt和私有review日志 |
| attempt-signed-install-qualification-v1 | owned签名Preview首次安装／替换／回退、v2升级、read-v1-only安装与回退拒绝，数据字节不变 |

签名旧reader是修改能力声明后ad-hoc重签的合成Preview，不是实际alpha.18执行；不兼容补偿仍由单元故障注入覆盖。最初compile-v1的不可访问setter、swift-v2的JSON路径转义及fixture初始化竞态、python-v1的旧夹具缺字段均保留失败回执；修补后才重新验证。当前源完整检查／CI／发行另行留证，不能复用7dc3851的历史全绿。

首轮整仓attempt-full-check-v1发现普通任务尚未开始就取消／shutdown时缺少原有取消终态；现保留普通已接纳任务的intent＋准确owner，由原worker取消检查完成终态，新attempt仍在审阅失效时拒绝接纳。真实SIGKILL的typed冷记录也应拒绝无出生stamp的迟到finish，旧测试已强化为明确断言staleRecovery。24条生命周期／准备页定义通过。首轮CI 45674201862在三个owned目录变换夹具因/var别名失败，生产no-follow保持不变，只在创建自有tempfile夹具时解析真实路径。5019-byte失败artifact已回下载核验，SHA256 756849ef7730b4e6564e6a0570f662053a4d237574e44427e1255e9f933732d2；失败源cd2085c不作为发行资格。

30a72e1的attempt-full-check-v2已通过848 Swift／95 Python／876中英key及生产OCR双轮，但复审仍发现Published同步通知可早于handle登记，Task本身未取消而仅有cancelled flag／shutdown。各AI入口及Agent／Workflow在owner后、任何外部派发前显式核对生命周期。新10参数案例分别从五条入口在该时间窗停止／退出，要求零HTTP、无步骤、准确取消回执。首轮参数测试暴露Workflow把显式CancellationError标failed，修补后attempt-published-lifecycle-v2的19条定义／2套件通过。新App也明确拒绝在Release中传入review-fixture-root，避免忽略参数后误用正式域。最终源码的完整资格仍须重跑，不能消费30a72e1的旧摘要。

## 原生观察与修补

macOS27.2本机CUA在owned合成域观察中文浅／深色和英文浅／深色子集，工作流空白输入、Esc取消、当前20步范围及滚动末尾、明确新执行、旧结果并存、默认仅展示、冷启动只读历史与unknown checkbox；Command-Return未绕过sheet。恢复正文未保留，启动时没有排队重跑。

实测Foundation temporaryDirectory忽略共享gate的TMPDIR，首次Preview启动已正常退出并未执行样例；没有把它当成全新合成库。新增`python3 scripts/keydock.py native-review`创建private owned UUID／marker域，仅KEYDOCK_PREVIEW、SafeSmoke和BuildInfo preview三重条件允许显式根；正式App不接受。复用`--fixture`供重启复查，runner在写入前检查目录／marker，日志O_NOFOLLOW＋regular／owner／nlink检查；新checkout自动建证据父目录。此入口不改变普通Preview默认域或安装器resolver。

原生发现并修补窄详情标题、长路径截断、语言切换后行／用量文案缓存；中间语言id重复使列表复用的失败保留。最终ForEach只用task UUID，语言作为row值依赖，原生List明确56pt最小行高并关闭插入动画，解决新增首行裁切；已实际插入新尝试、核对完整两行及中文刷新。

最终Preview bundle SHA256 d2fc13e74cb15b40468020e9d10224240af0a08413cdaaff2e7eb8722d2f4f23（dirty工程样例，非发行源）；9条合成记录／5条recoveryOf和未知旧终态已核对。结构化证据.local/desktop/KeyDock-Review-268137b1-4f7a-46d1-9d04-e2d9e9ee59e6/native-evidence.json，SHA256 48931ee377311d150b4b6769b436d2e63aaca643863d71676306f7c9a61a49d7。原始图／AX在本轮CUA记录。native-ui-v1–v5的exit0表示GUI进程正常结束，视觉失败及修补按本段单独记录；早期图不能作为最终布局PASS。

物理全局热键因注册冲突未计PASS；不抢占其他App快捷键。真实API按用户决定待配置，Terminal工具拒绝未重试。VoiceOver／IME／完整视觉矩阵、AX／多屏／真实插入、最低系统和长驻仍开放；可选正文、checkpoint、真正续接与稳定usage.delta仍未完成。
