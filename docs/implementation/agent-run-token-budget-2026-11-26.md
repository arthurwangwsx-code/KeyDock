# Agent运行token阈值实施与验收

本增量承接5.4的token部分，合同见[技术方案](../technical/agent-run-token-budget.md)。完整产品、费用停止阈值、原图附件、持久步骤、真实插入／热键和完整视觉仍为PARTIAL。

## 已实现行为

每次运行独占有界meter；每轮需一个新attempt的完整累计用量。重复不重复扣额，partial可在同轮补齐，缺报／身份冲突／回退／delta／溢出使额度无法确认并暂停。恰好到线且无工具时可完成；超过阈值或仍有工具时暂停。保留已成功模型调用及实际用量／费用，下一轮只收紧输出cap，不修改历史、opaque或phase。

实际使用的定义（包括未保存草稿）、模型设置、阈值与策略版本进入冻结合同。审批与工具回执绑定该合同；运行中修改不扩旧额度，取消／超时优先于预算暂停。任务恢复仅显示数字事实，不恢复会话、审批或派发。内建只读Agent使用固定32000阈值，普通profile可明确关闭。

配置schema4每个Agent必须含nullable阈值，schema1–3夹带字段拒绝。预算回执使用Envelope3，即使配置仍旧也受旧reader门禁保护；无预算旧记录保持v1／v2。导出definitions v2明确保存关闭状态。清除AI用量会擦除已收口预算计数，保留阈值与关系；在途meter不重置，旧恢复来源计数可清除而新尝试stamp仍有效。

## 本机工程证据

首次核心编译v1／v2失败（测试表达式），修补后v3通过22项；集成v1因新暂停合同的旧期望失败，v2发现合成命令夹具未报告usage，在新门禁下正确暂停；补齐happy-path合成报告后v3通过。缺报专用夹具继续保持缺失，不补零。所有失败日志保留。

完整dirty源检查v1通过，追加恢复来源数字擦除回归后完整v2再次通过：1062 Swift执行、156 Python、1028中英key，1041声明库存（core1031、Terminal9、OCR1），生产OCR双轮PASS。v2目录`.local/pipeline/20261126T090532012739Z`，iSpec测量`6fcae776-a28e-4ed9-89e6-41bb4f52e5a4`，receipt SHA256 `5977e717061d99a1c2f084e575d9d2491188e5670e305f239ea3f9aa4f384c55`。

生产Store＋URLSession使用owned loopback验证Chat与Responses两轮阈值34→cap20、完整用量40后暂停、原opaque／phase／callID准确续接、到线前零工具／后续HTTP、缺报保留正文、未保存定义合同、晚审批取消、重启无重放及清除计数。Python使用合成App声明验证config4／receipt3阻止旧reader安装和回退，动作／数据字节保持。仅内存transport或合成HTTP，不是外部API账单资格。

## 后续资格

干净`218381a`完整本机检查通过（相同1062／156／1028，生产OCR双轮），测量`b79a460f-b7b8-482f-8e68-d8cdacee3739`，receipt `5295be330e7da07c9071ce1bceb638d057d875cd344f26bea0cb22b957cf3539`；优化Preview编译通过。首轮原生实际观察非法输入禁Save／Run且导航保留原文，28阈值开始后改存200，审批仍28，合成printf批准一次后累计31暂停并保留结果；中文浅色及同夹具重启时200配置和28／31预算保留、输出不恢复且无重放。

该轮视觉为FAIL：已完成任务保持选中时切中文，独立预算子View仍显示旧英文，重启／新建View才变中文。已按同页AIUsage组件的方式绑定语言identity，并把关键数值改成primary／callout、说明限宽。首轮脚本也因比较完整配置字节而失败：第二轮主动从Launcher打开Agent会合法更新recent；新脚本保留逐轮快照并比较实际字段，recent变化不冒充数据丢失。首轮失败receipt `9fe340fb606608bdf544eb18417123102e43a997bd1c9cea4cc6abfe1434d4f3`保留。

## 最终精确源与原生复验

最终代码源`630ef838788723c58a6c1ed54f8a47c92bab78ce`，从master建立的feature分支两次提交后受控fast-forward晋升。干净完整检查目录`.local/pipeline/20261126T091842225856Z`，1062／156／1028及OCR双轮PASS；文件SHA256 `9fe570c783826a5ffc66e335455a51b5993dffcb51fac6b87204cede1e2e1fe0`，canonical qualification `bbc0c442d90e8a6b1116936928c7d20715402daf928008780d46ecae00332702`，测量receipt `acd9dbc79ae60ac3011c847160a8f2256964d57ae60e8df18d11e4010d521200`。

修补后优化Preview再次实际确认：非法输入禁Save／Run；28开始、在途改存200，原审批仍28；批准一次合成printf后31暂停；中文浅色即时刷新、关键数值primary可读，重启后阈值200和旧28／31任务保留、无正文恢复与重放。根`.local/desktop/KeyDock-Review-345a9a82-77e5-4de9-bcda-afe124a04c90`，PID67295／68166均正常退出0，逐轮独立receipt和配置快照保留；两轮实际主配置hash均`b462ab2ad5c24c1f1122493d76d589e6b41de65ab5d69fa479cc300b800c683a`，服务全程只有2次POST。证据SHA256 `8f4637bd8219ba8bb8e7d89a2d2d84df722bfb577d67723f18d93b0424d81bad`，测量receipt `b8c3cdeacded166655f037e74603e01d7af72cc7875850813036e5a1a7736fca`。普通native-review的通用逐次receipt改造仍是后续工程，本轮helper留证不冒充已改全流水线。

[feature同源CI45790786801](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45790786801)与[master重复CI45792593390](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45792593390)均PASS；云端OCR明确NOT_QUALIFIED，本机资格独立。218381a的CI45789409261因后续修补被取消，不记通过。前序459559a的CI45780991896失败已定位到DesktopReviewScopeTests的`confirmedConfigurationCommitsAndDatabaseGrowthKeepOneValidOwner`、invalidScope；本轮相同测试本机／两次CI通过，不据此宣布旧失败唯一根因已修复。

## 发行与本地安装

alpha.25／25已[公开发行](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.25)，精确tag指向630ef83，旧版本／tag／资产不改写。冻结包`.local/pipeline/20261126T093025669822Z/package`；Developer ID team `J56BFQN5PZ`，App公证`2f008859-c162-4069-8ca7-df4fc31bbd56`、DMG公证`1bf898e7-ece2-4142-ba96-d5652a788af1`均Accepted，装订／Gatekeeper及挂载比较通过。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| ZIP | 3721613 | `f5caa84072743f1940121c398587dd424affdbbc59a3aa7e346380842b055d3a` |
| DMG | 4242415 | `91813f8a70f97770f1f7d33760f8aa5cc83b53aad3125c27337ecf491dedc0b4` |

草稿上传／回下载验签验哈希／公开后复验通过，[独立发行审计45792975278](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45792975278)PASS。安装receipt `.local/pipeline/20261126T093324383415Z/install-receipt.json`，transaction `1a278af0-0794-460d-ae76-adae4ff41600`，destination `/Applications/KeyDock.app`；旧App保留于对应隐藏backup路径。正式About实际显示25，既有Sol low／Automatic→Responses／4096及翻译Luna none继承均仍可见，密钥只显示已保存，未修改配置或重录凭据。

## 正式App真实OpenAI子集

使用既有钥匙串配置、仅手动合成输入调用api.openai.com；观察脚本不读取凭据或配置。首条验证prompt只要求固定文本，模型判断不需时间工具，一次201／16用量、预算217已完整核实；两轮假设未满足，测量保持FAIL。随后改为确需当前UTC时间的问题，实际调用current_time一次并使用返回值完成回答：gpt-6.2-sol两轮206／14、244／26，共450输入／40输出、预算490，32000阈值及剩余31510与界面／回执一致。

后一轮测量`fc5a9ad9-f332-4ad6-9563-02dc591f8be6`，receipt `e8bd7553e074fef6ebdba89c9ba3fca023c84c953f1a9195f6429e57f170eecb`，新合成账本SHA256 `9b7206390829d2562d4b8d321a07177e8d64e8d639babf8a3273caeababa8b91`。本增量真实请求3次、651／56；费率不匹配时继续显示费用未知，不补零。输入仅ASCII合成文字（CUA中文注入未完整送达，已在运行前更换），不算IME验收。真实服务只证明已观察子集，达线／缺报／故障完整矩阵仍以合成精确验证另列。

按项目保留规则，alpha.23原始冻结App经ZIP压缩、完整tree digest还原比对和codesign验证后清除该旧raw副本，receipt `.local/release-retention/agent-token-630ef83/receipt.json`；最新两份完整raw为24／25，失败22、manifest／分发资产和原回退证据保留。不是通用retention CLI或独立备份资格。

40.1–40.5仅关闭本增量工程与已观察子集。5.4费用限制、完整视觉、真实插入／实体热键、最低系统、8小时和20条AI质量等义务均开放。
