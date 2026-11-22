## ADDED Requirements

### Requirement: 应用与窗口切换
系统 SHALL 提供应用启动与窗口搜索/切换，窗口 identity 不得仅为 PID，AX 权限不足时保留可用的应用级路径。

#### Scenario: 同一应用多个窗口
- **WHEN** 用户选择某一窗口且同进程还有其他窗口
- **THEN** 系统按窗口身份解析并激活所选目标；目标失效则明确报告

### Requirement: 结构化 CLI
系统 MUST 区分 executable/argv、显式 shell 和交互终端，提供退出状态、输出上限、超时与取消。

#### Scenario: 参数含 shell 元字符
- **WHEN** 用户在 argv 模式传入含空格或元字符的参数
- **THEN** 参数按单独 argv 传递，不隐式交由 shell 展开

#### Scenario: 取消命令
- **WHEN** 用户取消仍在运行的命令
- **THEN** 系统停止后续派发并按适配器管理进程生命周期，显示取消/已发生副作用，不伪报成功

### Requirement: 剪贴板敏感过滤与清理
系统 MUST 在读取正文前检查敏感类型，支持启停、排除、TTL、容量限制和清除。

#### Scenario: Concealed 文本
- **WHEN** pasteboard 变化且带有 concealed 或 transient 标记
- **THEN** 系统跳过正文读取与历史索引，不将内容写入日志

### Requirement: 窗口布局恢复
P2 系统 SHALL 按窗口保存恢复 frame，并处理屏幕变化和目标最小尺寸。

#### Scenario: 外接屏移除
- **WHEN** 恢复布局时原屏幕已断开
- **THEN** 系统将 frame 合理限制在现有屏幕可见范围，不复用其他窗口记录

### Requirement: 用户触发截图与 OCR
P3 系统 SHALL 在用户选择范围并满足屏幕权限后获取截图，OCR 输出可进入明确选定的 AIAction。

#### Scenario: 无屏幕录制权限
- **WHEN** 用户未授权截图但仍使用窗口标题搜索
- **THEN** 标题搜索的可用性只按其所需权限判断，不被截图权限连带阻止
