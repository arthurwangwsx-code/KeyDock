# 自动用量维护开发收口

此页保留交接当时的分支与版本。后续已完成 alpha.28 发布、公证与 27 → 28 → 27 → 28 正式安装演练。当前源码、原生证据以及未通过项目见[验收总账](retention-shutdown-2026-11-26.md)。

按用户要求在2026-11-26收口当前变更并交接。工作分支为`fix/usage-retention-budget-redaction`，从干净master `eb4b50694b17fef21b9c788d3af36d81dfe6f1ea`建立；当前增量未晋升master、未打新tag或替换正式App。公开及本机正式版本仍为alpha.27，代码源`e6c7b98aa3dfd563f957cdb7f6ef6048386a23fc`；该版本与前述master文档提交的CI已核实通过。

## 已落盘的实现

- Core按候选剥离预算数值，持久确认后才批准ledger删除；保留阈值、任务状态和RunAttempt身份。当前live owner延后，旧recovery来源不永久豁免。
- 显式清除先处理无ledger的已结束预算，再逐候选确认；已终态但仍live的orphan以进程内票据延后，绑定Store身份和receipt birth，不能误绑跨Store或复用的legacy UUID。
- metadata写入、清除和维护通过FIFO gate跨await串行；retention epoch在actor侧同步关闭旧读取资格，普通无逐出的保存不推进该epoch。
- 候选检查inode、大小和mtime／ctime；unlink后目录同步才确认删除。Core、unlink及目录同步失败分别保留账本或未确认状态，报告预算剥离／确认删除／延后／失败。
- report投影直接await主线程，owner释放后重试延后维护；shutdown最终关闭准入并等待mutation屏障。旧start不能在stop之后重新挂定时器。
- 原public Workbench初始化签名保留，通过内部构造依赖接入真实Core；HTTP夹具显式使用空凭据读取器，不访问实际钥匙串。

## 本机验证

基线RED为真实TTL删除后预算磁盘与旧快照仍31token／2轮：measure `7022ff6b-16ae-4a7a-821a-0f1f93558e9b`，receipt摘要`f96c544dc8091229971c36575254995558c1df758ce2917a84e2eadd6954697d`，失败2项。没有外部API或个人数据。

最终定向44项／7套件通过：measure `7f68b553-678b-445c-8390-a5073d9767d1`，receipt摘要`ccf865ac0d8667ac9869f5925832e8b5af5c62590c589cd362bdff8d9b8a17f8`。覆盖TTL／数量／字节逐出、live容量及Host释放重试、Core beforeWrite／afterRename、unlink／目录同步失败、延迟生产报告、旧与维护中票据、替换／原inode改写、orphan票据身份、FIFO及stop／start／close。真实loopback模型请求在清除后排队保存，恰好一个POST，新事实保留；两个时点的磁盘副本重新打开核验预算未知，不等同实际进程SIGKILL验收。

全量本机通过：1094 Swift执行／1073声明、156 Python、1035中英key，生产合成OCR双轮。measure `59e91d83-2df9-4f9b-8849-c34051d66bad`，receipt摘要`1b104c68860500ca87f2c51053267e8f0eebfe6b08148e71c65f27a0c8b144d6`；summary `.local/pipeline/20261126T125935994965Z/check-summary.json`摘要`d67501f24166913de9fd00e4d6fe1c380fe5aee2e323e7dd0c77fc38fc814010`。

全量检查发生在未提交工作区，运行时代码在检查期间冻结；之后只补交付文档与任务记录。这是本机回归，不能作为最终干净提交的发行资格。v1的ignored-entry重盘点计数FAIL、v2的close名称遮蔽编译FAIL及v3夹具启动中途0预算的FAIL均保留；修补后v4通过，未重写失败记录。

## 交接后优先事项

1. 审核当前完整diff和同源CI；对最终干净提交重跑完整本机检查及优化Preview，补真实启动自动维护和中英文预算／部分完成界面证据。
2. 当前延后票据与显式清除意图只在进程内；重点审查owner收口、shutdown和重启边界，证明已确认删除不会复活，并明确部分完成后延后意图的恢复语义。不能据现有测试宣称全部跨重启清理已完成。
3. 补自动维护期间Workflow子记录／父摘要、关闭屏障排队、候选核验IO失败等必要边界；不把手动handler或磁盘副本重开当成完整生产竞态／进程故障证明。
4. 42.4与43.2–43.5保持开放；费用停止阈值、持久步骤、原图附件／增量用量和完整桌面／视觉验收继续按原P0–P4推进。

后续并行调度见[可复制提示词](../handoffs/2026-11-26-parallel-work.md)。技术支持、反馈和隐私请求：arthur.wang.wsx@gmail.com。
