# DesktopReview模型与存储接线复查

2026-11-26，`feature/desktop-review`承接36.2，正式安装仍为alpha.20。此层已接通；独立App配置／面板／签名宿主和真实插入继续依36.3–36.5，不以本轮测试替代。

## 结果与边界

Workbench显式要求scope、准确Data目录与`allowContextCapture=false`。仅从scope提供的四字段canonical JSON加载外观、语言和剪贴板绑定；空／坏／未知／重复字段整次拒绝，nil才创建空权限基线。两个面板偏好使用路径绑定的独立Review域，非法原始值拒绝。普通档案不加载，回执／用量／材料只指向新辅助session，调度／活动使用空persistence。

Review不启动采集、应用索引、恢复或维护任务；即使内存配置被注入AI／CLI／MCP／目录定义，不可变模式仍拒绝其provider、Host／贡献授权、任务admission、已有client、目录访问和恢复旁路。只允许明确历史复制与绑定目标插入，后者仍复用原paste事务并复查scope。

配置提交在OS注册前验证候选，仅通过scope写入。失败可能已替换文件时补偿OS并永久撤销本次scope，不用普通路径快照／删除，也不声称磁盘旧值已恢复。配置身份从初始读取或上次确认写入持续比较，外部变化不会被覆盖；合法原子提交与身份更新在同一锁内完成。

SQLite使用单独持有的DB FD，可变身份忽略正常增长的size／时间，持续校验owner／inode／权限／链接。Node复查改用`fstatat`，避免额外关闭同inode FD释放SQLite POSIX锁。Connection持有资源到SQLite关闭之后；Review启用NOFOLLOW并跳过普通路径mkdir／chmod，检查三个恢复辅助文件，缺主库却有恢复文件时保留并拒绝。读写前后复查，已发现替换永久失效；不是同UID恶意进程沙箱。

## 验证

`desktop-review-model-v5`：Workbench 48、MacAdapters 55、CommandCore 5，共108项工具计数PASS，含15项策略及20项scope声明和参数用例。覆盖合成loopback零POST、CLI／stdio标记不存在、凭据端口零调用、旧档案不恢复、配置污染／失败／撤销、材料旁路、正常DB操作与真实子进程锁竞争。三位Agent仅静态复查，主Agent独占写入与测试。

首轮MainActor函数推断、测试宏throw推断、内联optional初始化断言，以及错误使用CLI输入材料的夹具失败分别保留；修补后没有删除用例。相关回执与日志为`desktop-review-model-v1`至`v5`，位于iSpec receipts和`.local/desktop/`。本轮未通过Review调用真实AX或剪贴板正文。
