# MCP互通与HTTP生命周期复查

2026-11-25，feature/mcp-independent-interoperability，自master 4555dab开始，主Agent串行写入与验证；两位Agent只读评审。任务26，正式安装仍为alpha.11。本记录先保存开发证据，干净候选检查／发布与安装另行追加，不能视作完整产品验收。

独立官方Time 2026.11.18、原版SDK 2.3.0，没有修改服务端来迎合宿主。第一次四格握手成功，但工具0接纳／3拒绝，measurement 86d1405b-7524-42e0-b0d0-6d389ae62601为FAIL。原工具目录、拒绝原因和退出事实保留。补齐schema语义后，独立服务四格真实工具、text／structuredContent、无效时区错误和旧目录拒绝通过；最近开发入口measurement f9fe53a6-eff3-421a-b33c-0fcbf8e8869e为PASS，所有owned组退出且无需强制收口。

官方SDK自有夹具以started、finally、completed和取消后同连接snapshot验证真实取消，四格PASS（c1bf8e8f-01ea-4bb1-b271-f5e3f221b3d4）。legacy HTTP接受一次原ID取消并删除会话，现代只关闭流。它是本工程自有夹具，不是独立第三方长任务。时间工具同样不代替resources／prompts、真实AI或全部MCP兼容。

schema／client／stdio／wire／Broker及新增HTTP生命周期定向回归共41项报告测试PASS（1f6336c0-7152-48b5-9e5f-dcc26170ebd5）。验证并发取消＋双断开只一次控制请求、撤权后不重新取钥匙串、已知初始化会话正文中断、未知session记未确认、刷新DELETE gate后不复活、旧revision不影响新连接，以及404／405／500／重定向／控制超时的独立结果。原编译失败（30428fa0，测试Task捕获非Sendable夹具）与夹具误将旧正常路径变慢导致的失败（53be9876）均保留，分别改为捕获不可变URL与精确匹配夹具路径后通过。

工程完整性和进程组12项回归PASS（37247470-078f-4086-87fe-c9f2e1ce6d6d）：wheel／lock／安装字节改变、新启动钩子、pyvenv、其他解释器／cwd、symlink与版本证据漂移拒绝；探针残留子进程、超时忽略TERM、持续观察失败都必须FAIL并收口自有组。信号发送完前不回收组长，防止数字PID复用。观察／信号／等待失败均明确报告，不能以清理成功改判互通成功。观察失败首轮未处理Darwin对仅剩zombie组的信号拒绝而报错（649487e2），修补后保留原失败及诊断。

复核发现准备脚本的依赖版本变量覆盖解释器版本字段；旧环境／回执原样保留，其版本metadata不作为最终资格。已独立命名并加形状负测，重新准备time-20261125-4环境（18054be9-74bc-4dba-a3d8-b06774183e00，PREPARED_NOT_QUALIFIED），后续最终重放只使用该环境。文件均在忽略的.local/interop及.local/desktop中，不含个人正文或凭据，不进入发行包。原测试包许可／notice按[互通合同](../technical/mcp-independent-interoperability.md)保留，不加入App。

全部验证绑定当前apply attempt 9881b6d8-e08e-4176-b6a2-97706ee67811；原始receipt位于change下receipts，成功和失败均不覆盖。版本候选的干净源码、完整本机／CI、签名公证、公开回下载及安装尚待各自通过，不借此关闭24.5或全产品义务。

首次干净候选a7c2921完整本机685 Swift／58 Python／708 key与系统OCR PASS（3bcf883f-08de-4684-9764-2e152a8f83eb），新v4独立Time四格PASS（3c8e760f-837e-4a51-a732-fd48ca7bfe94）。SDK四格的业务取消均PASS，但legacy stdio单格进程观察失败，整组FAIL（492f913c-0438-43b1-bdb1-ce44a3812496）；错误未留具体类型，不能断言根因。进程已回收、无组残留，但该FAIL仍阻止发行。将ps从全局进程表缩为仅查询自有组，保留5秒时限、失败门禁和未回收leader围栏，新增错误类型诊断；后续修补提交必须重做同源资格。

最终修补源d99fee8的新v4环境两组四格、本机685 Swift／58 Python／708 key、同源core／优化构建、独立互通CI、公证／公开回下载及原生About12均通过，已随alpha.12安装。完整回执与边界见[发行证据](alpha12-release-2026-11-25.md)，本文件前文保留各历史时点失败和候选状态。
