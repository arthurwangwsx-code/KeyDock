# 桌面自定义一致性复查

2026-11-26。命名分支`fix/desktop-customization-lifecycle`从master553677c创建，主Agent唯一写入，三位Agent仅只读评审／官方模型复核。alpha.24是本次候选，正式安装及公开版本仍alpha.23，不能用候选版本号表示已分发。

## 实现与失败边界

Review身份probe保存同一次NSRunningApplication快照中的缺失／变化字段固定类别，首次失效锁定，不重查推测或恢复scope。诊断不含实际路径、PID、时间或用户正文。旧targetIdentityChanged记录不能倒推具体字段。

收藏改候选事务，写前／写后失败保留原始字节或原本不存在状态；Launcher显示错误且保留动作菜单。贡献动作菜单和页脚消费当前受信handler的标题，失效绑定显示Unavailable，解析不授权或执行动作。

应用动作迁至配置schema3必填nullable字段，与快捷键／收藏／别名／最近使用共用候选提交。只读旧源保留，未知源允许无关设置写null但停用相关动作；目录失效则停止整份配置写入。编辑／删除身份、集合引用、精确清理、OS注册补偿、API保存和配置导出统一接入。详见[技术合同](../technical/application-action-configuration.md)。旧reader安装／回退须拒绝schema3，包含null态；保留旧App副本不代表可直接回退。

## 已执行的定向检查

`desktop-target-probe-tests`：44项通过；`desktop-favorite-title-tests`：22项通过。对应代码提交c4f6b07，私有日志位于`.local/desktop/`，iSpec测量保留准确receipt。

`application-action-migration-tests-v4`：48项Swift测试通过（Workbench44／MacAdapters4；参数case不另算测试数），含旧配置1／2、无主配置但有旧动作、首次成功迁移、写前／写后失败、未知null、目录替换、旧源写中变化、精确清理、引用阻止删除、A→B→A旧确认／旧编辑、canonical重开忽略坏旧源和关闭launcher热键重载。receipt SHA256 `296509395fd5d17b66befcd07efac3683087c5d41382d634382ee28529b264d5`。

`application-action-reader-tests-v1`：21项Python兼容测试通过，receipt SHA256 `2721bf07f9802e1e9c0d9e4afa4d0b387a8f38cce83c44b9788bbcdb93781470`。新安装／回退用例及最后的补偿目录复核测试将在完整检查中单独取得资格。

初次迁移测试v1／v2因旧测试引用及新增断言语法编译失败；v3一项测试错把favorites归入preferences导出，修正为实际shortcuts分区，产品无需为此改变导出字段。原失败日志和receipt均保留；v4通过不擦除历史失败。

完整检查v1：153 Python通过，Swift发现两处旧fixture仍伪装新版数据为schema1或尝试编码未知schema。修正fixture为真实旧字段集，并保留摘要对未知schema号的过滤检查及当前writer拒绝未知schema的合同；不放宽生产reader／writer来迁就测试。原检查失败保留。

修正后完整检查v2在a9fa255通过，包含本机生产OCR；summary `.local/pipeline/20261126T073826251825Z/check-summary.json`，测量receipt SHA256 `d53622abe5ce14b8ac2906a8dee07db8ec61a96cd46dab2da57105875feacfa0`。后续UI身份修补另需完整检查，不把此旧资格套用于新源。

交互复核发现View.init可在重绘时重算epoch／创建UUID；最终改为SettingsSession持有固定草稿对象和字段，SettingsRoot稳定Host承载sheet。关闭后保留同ID owner到实际dismiss，保存核对对象身份，旧close／dismiss不能释放新owner。`application-action-editor-owner-tests-v2`的23项定向通过，包含导航保留未存文本、A→B→A、关闭动画互斥及旧回调；receipt SHA256 `1af537472201ebc951a8dd002f822a3602c4da5b1c96daf08137cdc70a3eba41`。子Agent静态复核通过，原生弹窗仍待实测。

## 尚待本增量证明

完整检查、优化Preview及双语原生设置／删除／重启、同源CI、签名发行与正式安装分别待执行。原真实插入／实体热键、完整深浅／IME／VoiceOver／多屏、最低系统、长期驻留、20条AI质量样本及P0–P4工程缺口仍开放。
