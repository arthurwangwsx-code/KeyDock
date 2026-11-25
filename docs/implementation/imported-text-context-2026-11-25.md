# 导入文本来源与预算复查

2026-11-25。alpha.10开发候选，当前公开／已安装常规App仍为alpha.9；完整产品PARTIAL。

实现[单槽来源合同](../technical/imported-text-context.md)：实际提取类型、有界来源快照、Tools到草稿、普通AI／命令建议／只读Agent冻结、当前输入与旧运行分别显示、准确字节编辑、完整清除和迟到围栏。来源不赋予执行／MCP／AX替换权限，来源标签不加入网络或持久回执。

保留第一轮编译失败：MacAdapters曾误引用仅WorkbenchFeature定义的TaskTextLimits，measurement `0520738b-1bc6-41ad-a84b-f15810395bed`；改为本层直接验证basename UTF8上限，无反向依赖。`.local/desktop/text-context-initial-regression.log`未删除。

后续54 tests／6 suites定向PASS（52 Workbench＋2文本／PDF提取），measurement `de42ddac-28ac-40f3-8c4f-4e24de52e2cf`；43 tests／6 suites PASS（新增真实stdio MCP两协议版本、参数、三类loopback运行与来源隐私），measurement `3ef70be4-b0f2-4178-afd2-5bc9c58ef19c`。

只读评审发现草稿来源漏计预算、失败导入先占槽、MCP标签不区分项目及AI无法单独清来源，已修补并补边界测试。36 tests／5 suites PASS（26 Workbench＋10 MCP），measurement `d9040bab-f007-464e-9135-dd9a30fe1318`；包括8个活跃任务满额、任务和槽联合预算无法满足时，原闲置草稿／owner／generation／正文均不改变。MCP无效参数校验随后前移并与客户端共用校验，最终记录与原生观察继续追加。

上述服务均为工程拥有的合成loopback／stdio夹具，没有调用真实API、读取个人剪贴板或截图，不能充当独立第三方MCP互通或真实模型质量验收。

最终参数前置校验与回归23 tests／4 suites PASS（13 Workbench＋10 MCP），measurement `65747d0f-d956-44fe-a70a-a01d02dc2a6c`，receipt SHA256 `c20d4e16a8056cb110912b0b57ad4664523b9505bf81884ba7d5dbc9affcfd08`。无效JSON、超长参数、缺失必填和未知参数均同步拒绝，原输入／来源／generation／闲置草稿保持，未启动连接任务。

最终Preview构建／安装PASS，measurement `40ebd6f0-87fa-4b3b-977f-d82c79b9a027`，receipt SHA256 `a75e8ce0a4b58fbb58e61d5294045e6cfaca4f1b8b58423f5ecbbafc628f48cf`。本地合成`Synthetic-context-review.txt`通过系统文件选择器导入，实际显示文本文件＋basename，转入总结草稿保留正文与来源。中文浅色／英文深色AI页截图已检查，Tools英文深色编辑和动作行已检查；源标签准确显示“已编辑”。Tools与AI分别清除仅作用于各自输入，导航往返确认旧草稿保留及最终两处正文／来源皆清空。语言和外观恢复原跟随系统，没有调用AI或修改权限。

原生文本注入有一次多行typeText只出现首行的观察；随后通过该编辑器支持的settable AX值确认完整中英多行保留。未确认第一次观察的输入层原因，不据此声称真实中文IME通过。无真实模型结果时，本轮没有观察冻结旧运行与新输入并列的原生状态，也没有覆盖长来源名称、全部窗口／主题／系统辅助设置及最低系统。

干净源`5652b7379571e19b3c0db17b73c8d047c405c8ad`完整本机PASS：644 Swift／46 Python／691 key，inventory623，原OCR配置双轮PASS；measurement `76aa02ef-3d40-47b6-96e9-f07cfe1f33be`，本机summary `.local/pipeline/20261125T032731875504Z/check-summary.json`。同源[feature CI 45540103875](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45540103875)及[master CI 45540972809](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45540972809)均PASS；云端643 Swift／46 Python／691 key与优化构建通过，系统OCR明确NOT_QUALIFIED。已通过GitHub工具下载并完整读取feature日志artifact 14989605442，88,446字节，SHA256 `387de325abefa797963083a915e2b7ee23dfadb8a190bb15c0ae6ed43105c87d`，本地`.local/desktop/context-5652b73-ci-summary.json`。该源已FF并推master，后续草稿关闭仍需其精确最终源单独资格。
