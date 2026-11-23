## ADDED Requirements

### Requirement: 单一源码与工程流水线
系统 SHALL 让本地与CI复用同一检查／构建入口，正式包绑定完整且干净的源commit、版本/build、架构与精确tag。

#### Scenario: 构建期间源码改变
- **WHEN** 正式构建或公证期间HEAD／工作区发生改变
- **THEN** 流程停止，保留日志与产物，不把新旧来源混为同一可发布版本

#### Scenario: 调试安装
- **WHEN** 开发者运行统一调试命令
- **THEN** 构建并安装独立preview身份，使用隔离数据并停用真实上下文采集／凭据存储

### Requirement: 可信发行资产
正式发行流水线 MUST 验证Developer ID team、Hardened Runtime、Apple公证Accepted、装订与Gatekeeper，全部修改完成后计算最终ZIP／DMG摘要。

#### Scenario: 公证失败
- **WHEN** Apple返回非Accepted或缺少有效结果
- **THEN** 流程停止且不公开发行，不自动降级签名或篡改系统安全策略

#### Scenario: 资产与源码不一致
- **WHEN** 资产内容、版本或源commit与清单／tag不一致
- **THEN** 上传或公开步骤拒绝执行，保留已有不同字节的资产供核查

### Requirement: 安装替换与回退
安装工具 MUST 核验目标身份、签名team与资源摘要，使用同卷原子交换和受身份保护的回退回执；不能覆盖用户配置或强制结束未知进程。

#### Scenario: 目标存在未知进程或目标漂移
- **WHEN** 同bundleID进程来自未批准路径，或退出等待期间目标改变
- **THEN** 安装／回退停止，不退出未知进程或覆盖新目标

#### Scenario: 替换后检查失败
- **WHEN** 原子替换后可确认身份的检查发生失败
- **THEN** 尝试补偿已知交换并保留两份App与回执；无法确认时明确needs-recovery，不静默删除备份

### Requirement: 公开仓库与可验证预发行
系统 SHALL 保留master为长期基线，在已核对账号的KeyDock公开源码仓创建精确tag的预发行，公开前后回下载验证资产与签名。

#### Scenario: 断点重试上传
- **WHEN** draft已有部分资产
- **THEN** 逐一比较现有字节，只补传缺失资产；不同内容不clobber，验证完整后才公开

#### Scenario: 预发行与产品验收
- **WHEN** alpha已通过签名公证与上传
- **THEN** 仍单独记录UI、AX、IME、物理快捷键、最低系统与真实模型的未完成验收，不宣称可日用全部通过
