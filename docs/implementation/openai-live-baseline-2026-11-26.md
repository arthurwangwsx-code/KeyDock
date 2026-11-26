# 真实OpenAI合成基线与发现

2026-11-26，经用户授权，已安装alpha.20（源`aa0edfc`）通过原生设置页将凭据写入钥匙串，使用官方`api.openai.com`和`gpt-4.1-mini`完成真实调用。凭据未进入工程、测试命令或本地证据。此模型只是兼容基线；当前最新模型建设见[模型与场景方案](../technical/ai-model-settings.md)。

| 路径 | 已观察结果 | 输入／输出token |
|---|---|---:|
| 翻译 | 中文保留周五、30秒与不执行命令的含义 | 62／25 |
| 总结 | 中文保留负责人、时间、默认关闭及未完成状态 | 107／95 |
| CLI建议 | 生成准确`touch`／argv／cwd，原生审阅后取消；独立后置检查确认合成目标文件不存在 | 133／121 |
| 只读Agent | 真实`current_time`工具及最终中文答复 | 283／68 |
| 通用Agent | 配置入口完成真实时间工具回路，未添加CLI／文件工具 | 253／41 |
| 两步Workflow | 去除空白→AI总结，两步完成；首次费率快照估算USD 0.000142 | 95／65 |
| 合成活动 | 再运行一次Workflow，形成一条成功记录，随后恢复关闭活动记录 | 68／24 |
| 活动AI总结 | 请求完成，保留一条事件及不完整覆盖，但输出俄语：**FAIL_LANGUAGE** | 413／363 |

原生用量页实际显示10次模型调用、1414输入／802输出token；已知估算USD 0.0009536，7次请求无费率。与各任务相加一致，Workflow父子未重复计价。费率在后半段设置，旧请求继续保持未知，不反向套用当前价格；金额不是服务商账单。[基线模型官方价格](https://developers.openai.com/api/docs/models/gpt-4.1-mini)支持当时手填的USD 0.40／1.60每百万token。

## 发现及处理

活动总结原提示只说“用户语言”，实际user输入是JSON，没有明确中文依据。已在源码中冻结有效界面语言，并通过中英真实loopback请求及调用后切换语言的回归；**新二进制真实API复验尚未完成**。不能把请求成功算语言质量通过。

另观察到CLI待审入口只在设置页、draftReady使用错误图标、新Agent／Workflow来源显示未保留。中性图标与新来源已有源码修补；准确runID的直接审阅与原生复验仍开放。旧历史不补猜来源。

本地证据为`.local/desktop/OpenAI-Live-662e2f87-b145-4d33-b4eb-7d7d63aefe00/`的started／finished／receipt／postconditions，以及iSpec的`openai-real-ui-v1`和`openai-real-postconditions-v1`。UI原图保留在CUA记录；测量退出0表示记录／后置检查完成，整体AI仍PARTIAL。未验证取消、完整模型质量、全部工具权限、外部MCP或完整P0–P4。
