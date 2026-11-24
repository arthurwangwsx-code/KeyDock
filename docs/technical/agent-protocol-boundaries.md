# Agent与外部协议边界

2026-11-24。实现参考AiBox的冻结执行计划与宿主端口拆分；KeyDock源码独立编写，没有迁入AiBox的凭据、历史或私有实现。

## 当前执行路径

AgentDefinition保存指令、模型覆盖、已保存命令与MCP工具allowlist、调用／轮次／时间预算。运行前冻结配置，BoundedAgentRunner只经ScopedToolBroker调用宿主工具；工具参数校验、单次审批、intent、真实执行、result依次发生。只读P1入口仍单独保持只读。

命令使用executable+argv。模型不能改可执行程序、cwd或环境；保存的命令快照作为一个固定工具。所有MCP工具均按可能产生副作用处理，服务端annotations不构成授权。取消后等待真实工具收口才释放运行容量；已派发后断连、回执保存失败等未知结果不自动重试。

暂停停止当前attempt；“新尝试”明确创建新run并重新检查当前定义、目录和权限，可能再次执行已完成步骤。应用重启只恢复元数据与unknown，不恢复模型回路、正文或副作用。

## MCP实现合同

MCPAdapters是独立协议模块，支持用户明确登记的HTTP／stdio来源，以及tools、resources、prompts。用户在设置中启用并显式连接；stdio需要信任提示，子进程具有当前用户权限，产品不声称OS沙箱隔离。

协议版本由用户显式选择：2026-07-28使用每次请求的协议元数据及HTTP方法头；2025-11-25使用initialize与会话握手。两者不自动降级或重放。请求、响应、分页、schema、输出、pending数和deadline均有界。凭据保存在Keychain，绑定来源UUID与endpoint；跨源重定向不转发凭据。

来源修改／禁用／移除使目录generation失效并取消相关运行。旧连接关闭后的发布再次核对取消、来源revision与generation；stdio重新启动前核对launchEpoch。工具暴露取保存allowlist与当前来源目录交集；不能因发现新工具而自动授权。

Resources／prompts由用户明确选择后读入工具页预览，只作为文本数据；不会被提升为system指令，也不会自动发送AI。当前没有图片多模态发送、OAuth浏览器授权、远程任务恢复或任意扩展安装市场。

依据为[MCP 2026-07-28官方规范](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/main/docs/specification/2026-07-28)及[MCP 2025-11-25生命周期](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/basic/lifecycle.mdx)。测试仅使用owned合成进程与loopback服务，不代表所有第三方MCP服务已兼容。

## ACP评估结论

ACP是CLI Agent会话协议，与MCP工具协议分开。已评估官方规范revision `840484ff59b3deb1314d1a74e351cd16ef052b30`：v1 Latest与v2 Preview的prompt终止语义不同。v1以最终stopReason结束，v2返回messageId后还需观察会话终止；不能用同一completed回调假装兼容。

未来adapter须包含双向JSON-RPC、session/update、逐次权限请求、pending取消、bounded buffer与deadline；客户端初始fs读写与terminal能力关闭。取消必须撤销待批权限并观察原prompt是否确认取消，超时则unknown。当前**未实现ACP，不显示已支持**。用户可将CLI Agent配置为普通保存命令；交互模式仍交给用户终端，不能声称PTY或ACP会话管理。

参考[ACP v1概述](https://agentclientprotocol.com/protocol/overview)和[v2迁移说明](https://agentclientprotocol.com/protocol/v2/migration)。不把协议评估或普通Process启动算作真实ACP验收。
