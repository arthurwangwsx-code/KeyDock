## ADDED Requirements

### Requirement: 统一入口与命令合同
系统 SHALL 以稳定 namespaced ID、版本和输入/输出合同注册命令，搜索与直接快捷键调用同一执行服务。

#### Scenario: 快捷键调用保存动作
- **WHEN** 用户为已保存命令或 AIAction 绑定可用快捷键并触发
- **THEN** 系统按同一命令合同和已配置范围执行，展示状态，不绕过执行策略

### Requirement: 查询隔离与取消
系统 MUST 增量返回本地结果并丢弃过期 generation 的结果，网络和 AI 不阻塞本地搜索。

#### Scenario: 旧查询延迟返回
- **WHEN** query A 未完成时用户输入 query B，随后 A 返回
- **THEN** UI 仅展示 B 的当前结果，A 的结果不能覆盖选择或触发动作

### Requirement: 唤起目标与输入法
系统 MUST 在唤起前捕获目标上下文，并处理 Esc 焦点恢复与输入法组合输入。

#### Scenario: 中文输入确认
- **WHEN** 用户仍在 IME 组合输入时按 Return
- **THEN** 系统提交组合文本，不运行当前第一条结果

#### Scenario: 退出面板
- **WHEN** 用户按 Esc 收起面板且原窗口仍有效
- **THEN** 焦点回到原窗口；失效时不激活错误复用目标

### Requirement: 执行策略与来源隔离
系统 MUST 对所有工具调用验证 caller、schema、目标、权限和预算，外部文本不能更改授权。

#### Scenario: 网页内容要求放宽权限
- **WHEN** 模型读取到网页/OCR/工具返回中的授权指令
- **THEN** Broker 继续使用既有本地策略，不因该文本授予新权限
