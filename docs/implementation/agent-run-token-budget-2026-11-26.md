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

原生中英保存／重启、干净精确源检查、同源CI、签名公证、公开回下载与本地替换继续独立记录。当前正式安装与公开版本仍为alpha.24；alpha.25尚未发行。本记录的局部绿测不关闭全产品验收。
