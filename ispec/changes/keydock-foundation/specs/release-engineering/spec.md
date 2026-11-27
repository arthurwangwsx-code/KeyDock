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

### Requirement: 不可变公证输入与恢复
流水线 MUST 保留creator原件、独立inode的签名提交输入及独立装订资产，以源／版本／team／本机资格／指定CI／准确输入SHA绑定持久候选和公证回执；默认重试只复用同一候选，不自动重复提交未知请求。

#### Scenario: creator仍被系统持有
- **WHEN** 系统镜像helper在创建结束后仍持有creator原件
- **THEN** 通过普通复制和复制前／副本／复制后摘要验证创建独立消费文件，验证／签名该副本，不杀系统helper、不强制detach或删除原件

#### Scenario: 上传中断或丢失ID
- **WHEN** 上传超时、取消、异常退出或ID落盘失败
- **THEN** 保留unknown或已知ID；完整响应中已得到的ID先持久保存，没有ID则停止。显式提供服务ID后，只有Apple日志jobID与提交SHA匹配才可绑定，不凭文件名或时间推断

#### Scenario: Accepted后装订失败
- **WHEN** 同源候选已确认Accepted而最终资产装订失败
- **THEN** 保留失败输出，从原不可变输入重建装订副本并重新验票／Gatekeeper／ZIP与DMG一致性，不再次生成、重签或提交输入

#### Scenario: 候选索引丢失或协议未知
- **WHEN** 持久索引缺失而仍有候选，或回执schema／输入／源发生变化
- **THEN** 默认入口拒绝新提交；未知协议和改变的输入保持拒绝，仅显式路径可在完整验证后重建兼容索引，不能自动认领最新目录

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

### Requirement: 本机一键发布
正式发布 SHALL 由本机干净且与GitHub master一致的源码完成全部Release构建、签名、公证和打包；云端仅执行独立同源core验证及公开资产审计，不再默认构建Preview安装包。

#### Scenario: 发布预检或恢复
- **WHEN** 运行ship预览或再次发布同一版本
- **THEN** 预览只读；源、远端、tag不一致立即拒绝，已有同源冻结候选或完整包不重复构建，CI失败或资格失效不继续上传

#### Scenario: 从本地到GitHub
- **WHEN** 同源core、本机资格、签名公证及包校验均通过
- **THEN** 创建或复用精确tag，上传draft并回下载比较本地manifest和资产，成功才公开并再次复核；安装必须显式请求
