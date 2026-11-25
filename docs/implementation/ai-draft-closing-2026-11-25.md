# AI草稿显式关闭

2026-11-25，alpha.10候选。普通隐藏／关闭窗口继续保留共享文档；新“关闭草稿”是单独确认动作，不将CmdW变成丢弃输入。

`AIDraftCloseIntent`冻结最初的文档对象。确认后先增加revision、设置closing门槛并失效提案请求，移除待展示的建议与原选区结果目标，再取消该文档各任务并等待捕获的真实handle.value。调用者取消不会跳过等待；期间编辑、剪贴板输入、动作切换及新运行被拒绝，执行槽保持到实际worker收口。

收口后使用既有会话移除回调释放文档正文、来源、AX目标及Launcher／Workspace的准确引用。历史任务输出和冻结来源标签保留；已打开的命令编辑器是独立草稿，保留用户编辑。关闭不会运行建议、不停止由独立用户动作启动的CLI，也不删除Tools的独立输入槽。原选区替换在开始关闭时即停用，历史结果仍可复制。

首轮40 tests／5 suites PASS，measurement `b3b9744b-ae1c-4650-a604-d2aec48cde49`，receipt SHA256 `531fdf3169d0a5cd7c31a9a8069e818c4fa74e579bb167262ec5a5e846ccb195`。包括不响应取消的owned worker gate、调用者取消仍需drain、真实loopback慢请求／迟到建议、共享引用和独立编辑稿。只读评审随后发现确认身份需要冻结，现改为显式intent，并移除结果目标；最终回归和原生观察继续追加。

这是当前文档与执行生命周期范围，不能替代真实AX、API、IME／VoiceOver或完整视觉验收。

最终确认绑定／revision围栏回归11 tests／2 suites PASS，measurement `7a5ccd11-8308-48dc-b36c-12a938aafd6b`，receipt SHA256 `0a298bebbdbea07d1caa5ab33ef98fe64c7113bd97598c93661f851fddba5936`；之前冻结身份的32项回归PASS，measurement `ad372998-7c08-4625-af77-439355b99611`。原稿在审阅后被编辑会拒绝旧确认；导航切换不会把确认改绑新文档。

保留原生失败观察：最初系统confirmationDialog的AX文案与Esc响应正常，但两次截图均为260×187纯白，原因未确认，不能据此断言用户屏幕必然空白，也不计视觉PASS。改为应用自己的独立Sheet，包含冻结来源／160字符摘要、取消、关闭及变化提示。最终Preview构建／安装PASS，measurement `b5d2e835-00e5-4d91-8c78-6386ed757e70`，receipt SHA256 `cd244cd814db19cd070292f7d19a408782d9e30de430803f96d10eb06c208bcb`。

最终原生中文浅色／英文深色Sheet截图已观察，正文和按钮完整呈现。中文Esc及英文Cancel保留准确输入。原生在A审阅期间按CmdN创建B，再确认关闭A，B仍显示，草稿菜单仅有B；随后明确关闭B，工作区返回空状态且草稿菜单禁用。Preview语言／外观恢复跟随系统，没有改API／凭据／TCC；临时owned SSE进程未被调用且已正常终止。慢请求／等待态／关闭调用者取消由合成gate与loopback验证，未在本轮原生页面配置服务，不将其写成原生在途关闭PASS。
