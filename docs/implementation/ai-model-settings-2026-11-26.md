# 模型设置与Responses接入复查

状态：源码工程增量，完整原生／真实最新模型与发行资格待完成。正式App仍为alpha.20，不能把本文件的源码结果套用到已安装包。承接[技术合同](../technical/ai-model-settings.md)及任务37、38。

## 已实现

- 以2026-11-26官方资料固定能力目录；Sol／Astra／Terra／Luna为推荐，4.1 mini保留弃用标记。准确自定义ID及Unicode字节不折叠，不替用户自动换模型。
- 字段分别按定义→场景→全局继承，九种显式场景；区分inherit、modelDefault省略及显式none。模型、协议、强度、输出预算上限、语言、能力版本和服务身份冻结。实际请求继续只能使用冻结预算以内的上限，不自动增加费用。
- 共用原生模型控件已接全局、场景、AI动作和Agent；显示有效模型／协议／强度／预算，不联网或读取密钥。自定义reasoning兼容声明默认关闭且绑定准确服务指纹，换服务不沿用；声明不能覆盖官方已知模型限制。动作编辑器固定标题和底栏，中间滚动，保持草稿及输入法身份。
- 直接文本、命令建议、只读／通用Agent、活动总结和Workflow逐步共用解析；最后wire层按实际tools再验能力。凭据继续使用原配置endpoint槽位；官方自动协议可派生同一来源的Responses URL，费率按原服务＋准确wire模型匹配。
- Provider会话工厂为协议requirement；每run独立会话，Responses不远端保存conversation／previous_response_id。原序保留最终reasoning／assistant phase／function_call投影，call_id与item ID分开；工具在response.completed及网络drain后才可派发。首版按最终item发布可见文本，不公开reasoning或commentary。
- 关闭先撤销、取消producer、等待实际drain，再清历史；32MiB联合接纳为每个Responses run预留额外8MiB，覆盖opaque、组装及wire临时副本。输入历史1MiB、wire2MiB、SSE单事件2MiB，超过即失败而不删历史重试；HTTP交付队列也有上限。
- pending快捷键／Workflow审阅沿用配置generation，attempt保存设置摘要，AI调度绑定持久revision；成功提交A→B→A仍需新批准。在途保留原值。v1定义指纹固定向量不变，新增覆盖采用明确v2投影域。
- App配置schema2读取迁移v1，旧模型及覆盖原样保留，旧协议不自动升级；v2必需字段null或缺失拒读，不能重置后覆盖。签名dataCompatibility schema3新增configuration reader；旧能力原形保留且仅按配置reader1解释。安装／回退／补偿均在现有数据lease下使用固定FD的只读有界探针，新配置阻止旧包交换；不迁移或删除数据。
- 完整定义导出覆盖场景、覆盖参数、能力目录版本和服务设置，排除凭据、运行授权及opaque。DesktopReview仍只接受窄配置，新增AI设置和revision污染均拒绝。
- 命令提案可从输入结果和任务详情按准确runID进入审阅；已有编辑器／迟到请求不消费另一份队列项，仍须人工审阅保存及单独执行。

## 已有证据

同一apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`的测量与原日志保留：

| 测量 | 结果与实际范围 |
|---|---|
| `ai-model-core-v1` | PASS；61项AICore／真实loopback相关回归；后续修改依下列测量 |
| `ai-model-integration-build-v1`、`ai-model-ui-build-v1` | PASS；Swift模块编译，不是App原生视觉 |
| `ai-model-responses-v1` | PASS；Workbench44＋AICore15＝59项，三轮有序opaque／phase、callID、缺终态零Broker及300KiB最终item |
| `ai-model-integration-v2` | PASS；Workbench63＋AICore15＝78项，包含真实URLSession的Chat／Responses参数及在途修改冻结 |
| `ai-model-integration-v3` | PASS；Workbench107＋Automation14＋AICore20＝141项定向；迁移、ABA、总预算、准确CLI审阅、相关Agent／快捷键／工作流 |
| `ai-model-protocol-v4` | PASS；Workbench22＋AICore21＝43项，追加取消后实际drain且零Broker、incomplete原因及已知用量、重复序号／未知工具拒绝、NFC／NFD和服务绑定 |
| `ai-model-installer-python-v2` | PASS；142项Python，包含配置／材料／调用reader与owned真实原子交换；签名为测试替身，不冒充真实发行 |
| `ai-model-localizations-v1` | PASS；978条UI key中英覆盖；不是渲染、读屏或输入法验收 |

三位Agent只读研究／评审，主Agent独占写入和验证。评审发现的wire门禁、准确ID、编辑器高度、声明跨服务、全局展示误继承、v2 null回退及SSE配额／incomplete类别均已修补。

## 保持开放

实际中英设置与展开编辑器、VoiceOver／IME／最小窗口；模型目录在线清单刷新；Responses完整并发／故障矩阵；签名reader门禁；最新模型的真实翻译／总结／命令／Agent／Workflow、活动语言修补及CLI直接入口复验；干净精确源完整本机／CI、公证／公开回下载和本地替换分别验收。旧alpha.20十次调用基线及活动俄语FAIL继续保留，不作新模型质量证明。
