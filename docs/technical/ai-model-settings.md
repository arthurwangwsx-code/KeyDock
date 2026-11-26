# 模型目录、场景默认与思考设置

2026-11-26用户追加要求；解析、Provider及原生控件已有源码接入，当前资格见[实施复查](../implementation/ai-model-settings-2026-11-26.md)，真实最新模型及完整发行仍开放。三位Agent只读调研／架构／交互，主Agent写入和验证。承接原AI／Agent能力，不能只增加不被请求消费的选择器。

## 统一解析与界面

解析顺序为“定义显式覆盖→调用场景→全局默认”。翻译、总结、普通动作、CLI建议／解释、只读Agent、通用Agent、活动洞察和Workflow AI均须传明确场景；Workflow各步继续尊重引用AIAction的显式覆盖，不增一个不会被消费的工作流总开关。

设置的AI服务保留连接信息，新增全局默认与场景默认；AIAction／Agent复用同一原生模型选择器，显示继承来源和最终模型。保留准确自定义ID、目录消失的ID及已弃用选择，不自动改成首项。推荐、弃用、自定义、能力未知及核对日期中英文对应。打开页面不联网或取密钥；目录刷新由明确动作发起，`/models`仅表示模型清单，不能当作思考／工具能力证据。

思考选项区分“跟随上级”“模型默认（省略参数）”及明确强度；`none`是实际参数，不是默认或继承。只显示该模型／协议支持的强度，保留但拒绝不兼容的旧选择，不静默降级。输出上限包含思考token，较高强度可能在可见答案前耗尽；不自动增加计费预算。其他高级参数按明确能力显示。

自定义服务可由用户明确声明兼容OpenAI推理参数，声明绑定准确服务指纹，默认关闭；换服务不会带入，且不能覆盖官方已知模型限制。目录版本核对与可用模型ID清单是不同证据，在线清单刷新仍开放。

## 最新模型核对

依据[官方部署清单](https://developers.openai.com/api/docs/guides/deployment-checklist)和[GPT-6.2迁移说明](https://developers.openai.com/api/docs/guides/latest-model)，核对日2026-11-26：

| 模型 | 产品用途建议（需样本验证） | 明确限制 |
|---|---|---|
| GPT-6.2 Sol | 均衡全局默认，复杂总结／命令／Agent | low至max五档；无none；工具需Responses |
| GPT-6.2 Astra | 复杂推理／专业任务的显式选择 | 同上；不默认启用昂贵强度 |
| GPT-6.1 Terra | 写作、视觉与交互类可选模型 | 另支持none；工具需Responses |
| GPT-6 Luna | 快速翻译与小任务 | 另支持none；Chat工具仅显式none时支持 |

不把Codex的内部档位当公共API选项。以上产品用途是选型判断，不是已验收质量。[弃用表](https://developers.openai.com/api/docs/deprecations)已将4.1 mini列为旧模型；它保留历史验证资格，不能标成最新推荐。自定义兼容服务不自动套用OpenAI能力。

## 请求、授权与存储

所有入口共用`FrozenAIExecutionSettings`，冻结服务身份、准确wire模型、协议、思考、输出语言、预算、能力版本与无密钥指纹；provider、可用性、Host授权、用量和费率消费同一份值。Agent多轮不跟随后来编辑，Workflow逐步保留准确设置。活动JSON分析显式写入有效输出语言，翻译目标优先于界面语言，CLI仅约束人类文案，不翻译JSON key／argv。

Chat与Responses分别编码参数；新Responses adapter接入现有AIProvider和Broker，支持store=false、有界流、工具调用及每run隔离的continuation。不得以共享provider可变状态串联不同任务，也不依赖远端保存的previous_response_id。opaque reasoning资料只作有界会话数据，不进普通日志／导出／授权或默认持久化。

会话工厂必须是AIProvider协议requirement，默认Chat wrapper兼容旧provider；每次Runner.run创建独占AIConversation。Responses只接受initial请求和准确callID的工具结果，保存类型化、有序的reasoning／message phase／function_call；不把整个response对象原样重发。流式reasoning只采纳output_item.done的最终内容，完成前的工具delta不得触发Broker；未知输出工具类型拒绝。参考[无状态推理](https://developers.openai.com/api/docs/guides/reasoning#preserve-reasoning-without-stored-responses)、[函数调用](https://developers.openai.com/api/docs/guides/function-calling)。

continuation、工具参数与编码临时副本纳入原32MiB联合接纳，不能只统计可见输出。关闭先撤销epoch、取消本次producer并等实际drain后释放；在途关闭不重放工具、不自动改协议重试。测试需覆盖多轮有序续接、item ID与call_id不同、部分／最终opaque差异、伪造或缺失返回、两run隔离、预算与迟到回调，以及所有普通持久化中无opaque哨兵。

pending快捷键、attempt、调度和Workflow授权纳入有效设置指纹／策略版本；改变模型、思考或输出语言会使旧审批失效。在途结果仍保留自己的事实。费率按准确服务身份与wire模型匹配，继续只累计leaf调用，不以显示名计价。

配置采用明确schema v2并读取迁移v1，保留旧非空modelOverride；Agent新增字段显式缺省解码。导出覆盖新定义／引用／继承，不包含凭据与运行授权。签名安装／回退纳入配置reader能力；旧包不能忽略再重写丢弃新设置。DesktopReview只接受其窄配置，不能因新增字段开放AI。

## 验收

覆盖优先级、迁移幂等／故障保全、未知ID、默认省略与none、非法强度零请求、实际wire消费、旧快捷键／审批／调度拒绝、在途冻结、Responses多轮与取消／用量、导出和回退门禁。最后使用真实最新模型完成翻译、总结、命令审阅、Agent、Workflow及中英原生设置；兼容基线与模拟通过不替代这些资格。
