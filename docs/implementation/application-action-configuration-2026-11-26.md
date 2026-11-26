# 桌面自定义一致性复查

2026-11-26。命名分支`fix/desktop-customization-lifecycle`从master553677c创建，主Agent唯一写入，三位Agent仅只读评审／官方模型复核。最终代码`b1011af95dbac25f3ff52cdb2fc10d9cb49f93f8`经受控fast-forward晋升master，[alpha.24](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.24)已公开并正式安装，实际About24已观察。旧tag、资产和失败证据保持。

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

## 最终同源资格

完整检查v3绑定干净b1011af：1035 Swift执行、153 Python、1005中英UI key；清单1014项（core1004／Terminal9／OCR1），参数case与声明数分开。生产OCR两轮PASS。summary `.local/pipeline/20261126T074429531028Z/check-summary.json`，文件SHA256 `5154d0faf9f75941dc9feae3deafb45a0bf1b5969bc8516fcb09c094d6901b02`，规范资格摘要 `fde6f5d0719ebc20fb2cf012f38ba4ae800b9320cd97d4215a6667b1910f8bf7`；测量receipt SHA256 `4ff7d2f32460900bbbdc5e68a8b1f6d7af838171f31a44eaf73a97bf70c91ed4`。

[指定同源CI45777559734](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45777559734)、[master重复CI45779018677](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45779018677)、[合成查询性能45779018835](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45779018835)及[独立发行审计45779838922](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45779838922)均PASS。云端OCR仍NOT_QUALIFIED。前序632dd26 CI因新提交被取消，不把取消算作产品测试通过。

## 原生隔离Preview与正式App

同源Release优化Preview使用独立owned UUID夹具，只有两项合成Calculator定义及schema2主配置。英文深色编辑草稿后Esc、删除审阅后Esc均保留主配置与旧动作文件的准确字节；最终确认删除才迁移到schema3，剩余动作可编辑保存，准确目标ID的shortcut／favorite／alias／recent均不存在，旧文件摘要不变。中文浅色的新建／取消、再编辑及实际关闭均观察；正常退出0后显式同夹具重启，动作名称、删除结果、语言与外观保持。计算2+3的页脚及动作菜单显示“复制计算结果”，收藏添加／取消后配置字节恢复原值。未执行应用控制或复制计算结果到系统剪贴板。

私有夹具`.local/desktop/KeyDock-Review-5d485f8d-6b3f-4491-ae62-f70d7cfe943a`，`customization-cancel-check.json`／`customization-saved-check.json`／`customization-restart-check.json`分别记录边界。首次运行PID15770、重启PID17494均正常退出0；重启后配置SHA256 `420594d3eeefffa24e9acf33f322a201b06a3d666590c2b6724197297695bc14`。首次退出后的AX读取序列后观察到额外默认Preview PID17125，已正常退出，不纳入夹具验收，也不据此唯一归因底层重启机制；最终退出只用进程回执确认，未再次读取已退出App界面。普通native-review的复用root回执会更新为最新运行，旧运行结论据当时工具读取及测量日志单独记录，逐次不可覆盖回执继续列为调试改进。

正式`/Applications/KeyDock.app`实际About显示0.1.0-alpha.24(24)，公开支持邮箱正确。AI服务页实际加载保留Sol low／Automatic→Responses／4096和翻译Luna none／4096，安全密钥栏显示已保存；未重新输入密钥或保存／刷新／运行AI。本轮没有新增真实模型联调资格，alpha.21–23的真实请求证据仍分源保留。

## 签名、发布与替换

Developer ID team J56BFQN5PZ、Hardened Runtime、App／DMG公证Accepted、装订／Gatekeeper及只读DMG内App一致性PASS。冻结候选`.local/pipeline/20261126T075812073632Z/package`；公证ID分别`96e1b4fb-d9f3-4e0b-adab-5e5c87df37cb`和`48dffa81-1c0d-46bd-a35b-cfee609f7f5d`。package receipt SHA256 `117755c298197e5d7ef1b94903943228ef5c12e42787a12fd0a9046dbe052541`。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.24-macos-arm64.zip | 3678977 | `e7ef4da3b92bb83b1d0f8560e53d2612c90ee2272a8989934233894cca3c2550` |
| KeyDock-0.1.0-alpha.24-macos-arm64.dmg | 4198935 | `9394acbc9bad7d5fddf30e00f745390e7d65559a3ab1170d9fbb02bef79b2209` |

首次publish因缺精确远端tag被门禁拒绝，无资产公开；补推b1011af的annotated tag后，先draft回下载验签／验摘要，再公开prerelease并再次验证。publish v2 receipt SHA256 `19da18548c478ec7f7551e9986a4e8f7af9dcc042189a9cc8b27e7b0903767b5`，首次FAIL仍保留。

正式安装回执`.local/pipeline/20261126T080252301937Z/install-receipt.json`，事务`91d8072e-b7a3-452e-8546-4e77e3323dd8`，正常退出旧alpha.23后原子替换成功，未强杀或改TCC。旧App副本保留；当前首次安装探测配置仍为2，未来写3后旧reader回退会被拒绝，不声称已实际反向交换。

生产新归档前，历史alpha.20／21冻结App已通过ditto压缩、全树恢复摘要及恢复后验签，再移除对应旧raw App；原发布资产、候选／公证元数据、归档与`.local/release-retention/customization-b1011af/receipt.json`保留，alpha.22失败及alpha.23仍保护。此为本次私有维护helper，不宣称已有公共通用保留CLI；空间治理不是产品验收或独立备份。

原真实插入／实体热键、完整深浅／IME／VoiceOver／多屏、最低系统、长期驻留、20条AI质量样本及P0–P4工程缺口仍开放。新字段诊断未在新签名DesktopReview配对中重演旧失效；launcher稀疏结果仍使用固定高度，内容密度与完整视觉待后续优化，不以本轮设置页子集关闭全部视觉验收。
