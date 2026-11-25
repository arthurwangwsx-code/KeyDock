# 独立MCP服务互通

2026-11-25，任务26，尚未完成。基线alpha.11／master 4555dab。正式安装和公开资产仍以状态总账为准。

使用官方mcp-server-time 2026.11.18及SDK mcp 2.3.0，依据[PyPI固定版本](https://pypi.org/project/mcp-server-time/2026.11.18/)和[固定源码](https://github.com/modelcontextprotocol/servers/tree/c799c8552b0f27b7a33a7b9233773da144dddcf5/src/time)。无需API key，显式UTC，所有工作目录、venv、wheel与报告在工程忽略的.local/interop中。完整依赖按解析所得具体wheel SHA256锁定，再验证下载并从本地wheelhouse安装；不读取已有venv、凭据或个人文件。

此固定版本的pyproject／包metadata标MIT，但[同revision根LICENSE](https://github.com/modelcontextprotocol/servers/blob/c799c8552b0f27b7a33a7b9233773da144dddcf5/LICENSE)声明Apache-2.0／历史MIT过渡、文档另为CC-BY-4.0。只作为独立测试依赖，保留原包notices，不vendor到App或将全仓标为MIT。

工程验收工具调用真实MCPHTTPClient及生产transport。stdio使用绝对venv Python，-I -B -u -m mcp_server_time --local-timezone=UTC；不使用禁用site-packages的-S。HTTP服务由验收脚本独占启动并绑定127.0.0.1，KeyDock连接其/mcp。每个协议／传输格启动新连接；关闭后校验旧目录失效和进程回收，不能重放旧调用。

四格均须发现三个真实工具，调用get_current_time、convert_time、get_time_ago，按有界时钟容差验证UTC及UTC到东京12:00→21:00；按实际响应核对text／structuredContent一致、无效时区isError。握手通过但目录空、工具被拒绝或调用失败均不能算PASS；先记录实际未修补结果，再修补宿主并重跑，服务端保持原样。

schema兼容须遵守标准语义：annotations不构成执行授权或自动填参，未知约束拒绝；不能为单个服务偷改schema，亦不能把外部readOnlyHint变为只读授权。现有参数／目录／输出预算、Broker逐次审批、source revision和取消收口持续有效。schema变更须验证缺失／开放／关闭additionalProperties、嵌套、默认值、数值／Unicode长度、超限和未知关键字。

本机已保留原始基线：四格握手均成功，但三个工具全部因schema拒绝，整组FAIL。修补后独立Time四格已有开发态PASS；最终干净源码重放、完整本机检查及发行资格另行记录。此服务只验证时间工具，不能关闭真实resources／prompts、独立第三方长任务取消、外部AI质量或完整24.5验收。

## HTTP生命周期

legacy按[2025-11-25取消合同](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/docs/specification/2025-11-25/basic/utilities/cancellation.mdx)对已派发、尚无最终响应的请求发一次原ID取消通知；initialize禁止发取消通知。初始化响应头获得session即登记，即使正文未完成也尝试DELETE。断开等待请求清理后再关闭已知会话；刷新先退休旧会话，显式断开改变代次，跨await的旧刷新不得复活。

清理仅复用原来源、revision、endpoint和原请求短期内存认证快照，不重新读取已经撤权的来源密钥。控制请求有独立时限，禁止重定向、重试或派发工具；202／2xx、404、405、未知分别计数。原请求的取消／超时不被清理错误替换；未获得session的中断初始化记未知，不声称撤回远端效果。现代版依[固定2026-07-28 HTTP合同](https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/2bbace557bbf2cb5d03d6f9b48905415cd7607b0/docs/specification/2026-07-28/basic/transports/streamable-http.mdx)关闭请求流，不发送旧版取消／DELETE。

Tools/Fixtures/mcp_sdk_lifecycle.py是本工程自有夹具，使用原版官方SDK，明确不算独立第三方服务。四格要求任务真实开始、取消后finally完成且业务完成数为零、同一连接继续读取状态，再验证退出和旧目录拒绝。真实loopback回归另覆盖并发断开、已知／未知握手会话、刷新DELETE gate、旧revision、冻结认证、控制超时和拒绝／重定向。

## 可重复工程入口

使用已安装Python 3.10+，每次准备新目录。例：

```sh
python3 scripts/keydock.py prepare-mcp-interop --python /opt/homebrew/bin/python3.13 --output .local/interop/time-example
python3 scripts/keydock.py mcp-interop --environment .local/interop/time-example/environment.json --run-name time-first
python3 scripts/keydock.py mcp-interop --environment .local/interop/time-example/environment.json --run-name sdk-first --scenario sdk-lifecycle
```

Makefile也提供mcp-interop-prepare（MCP_PYTHON／MCP_OUTPUT）和mcp-interop（MCP_ENVIRONMENT／MCP_RUN／MCP_SCENARIO）。准备阶段才访问官方PyPI，运行使用已锁定的本地环境。只准备不等于验收；重复run-name拒绝覆盖旧证据。依赖wheel与完整安装树、解释器和pyvenv配置逐次验证，cwd拒绝symlink。探针拥有独占进程组，超时／崩溃后收口其stdio子进程，异常或强制收口均FAIL，不能以清理成功改报互通成功。

本实现为有界schema子集；未知约束、组合schema和x-mcp-header等尚不支持的扩展拒绝，不代表通用JSON Schema或所有MCP服务兼容。服务声明的readOnlyHint仍不能授予本地权限。真实资源／提示词正文、更多服务与长任务、原生UI完整矩阵及24.5其余义务保持开放。
