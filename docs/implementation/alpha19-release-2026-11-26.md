# alpha.19发行与安装证据

2026-11-26（本地时区）。[公开prerelease](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.19)固定在干净源`e4884968c196a0f6c19ee104eb448e65ba9df8d5`，不是后续流水线修补提交。新增“准备新尝试”、四类生产入口的新授权、准确worker所有权和安装数据兼容门禁。完整产品仍PARTIAL。

## 资格与公开验证

本机最终`attempt-full-check-v3`通过：849 Swift执行工具计数、95 Python、876中英key，生产配置OCR双轮通过。检查摘要`.local/pipeline/20261125T183027990027Z/check-summary.json`，文件SHA256 `a7efd5ea386b00200bb7823e57da231e631539247cc82809f196207e70112729`；App内规范资格摘要`7b72fd7a68779cb299f827ac6d703ee0c1bcf4a69428f7e3ae7506274db56a95`。两者序列化规则不同，不是同一摘要。

指定同源[feature core CI 45675855432](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45675855432)及优化Preview构建通过；云端848 Swift／95 Python／876 key，OCR仍NOT_QUALIFIED。21个日志文件artifact完整回下载并校验，ZIP SHA256 `686a73e805aa7e86132866dd0b482d3404973021b59a301a3460a967344cba50`。master core `45677991847`、文档`45677991890`、独立查询性能`45677991785`均通过；不据此补造本轮p95数值。[发布资产审计45686905843](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45686905843)也通过，job `139461791145`。

Release、干净Preview构建和签名安装资格通过。Developer ID team `J56BFQN5PZ`，Hardened Runtime，App公证`482122b9-d5a0-4437-8edd-acc984b3a72e`；DMG公证`06198153-89c6-4777-87f8-38ad681855ff`。App／DMG票据、Gatekeeper、ZIP和实际挂载DMG内App的一致性通过；draft回下载后再公开，并完成公开状态再下载。后续只读探针又核对公开正文、四个资产摘要及正式安装身份。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.19-macos-arm64.zip | 3171882 | `82ff565ddd91c3d89435ff63c78343ffa4041c128979934bda99ef2d213b3a32` |
| KeyDock-0.1.0-alpha.19-macos-arm64.dmg | 3653428 | `1006bfbe60287b5fcd8389ff585c76866889b4bcf04f7366315c0b07fb2d729c` |
| release-manifest.json | 5268 | `96312e5b89927156b957355b93d72d8b3e67a2d45dd98e696817f0b12a5c5b20` |
| SHA256SUMS.txt | 298 | `67ef32f44a0489ff277d7c298a1c2497a37951cd0a4bd5aac06692c3c5ca36d2` |

## 本机安装与回退

`/Applications/KeyDock.app`已通过工程安装器替换为alpha.19(19)，正式Release、非safeSmoke、源e488496，bundle摘要`53ef17286197d7dce8b9ae997ef81deaf8d211baeda85699c393a3dd24caafa4`。事务`758ee726-cf87-4d66-8991-01840903d952`，receipt `.local/pipeline/20261125T191043177369Z/install-receipt.json`；正式GUI About19未观察，不将二进制核验表述为UI验收。

旧alpha.18保留于`/Applications/.KeyDock.app.keydock-backup-758ee726-cf87-4d66-8991-01840903d952.app`；原始archive／App／build-result保留在`build/pipeline/release-history/0.1.0-alpha.18-6baaee8-before-alpha19`，移前后摘要一致。当前签名App声明Envelope读写[1,2]；安装时正式库仍为v1。一旦写出v2，旧alpha.18 reader不能直接回退；统一脚本会拒绝。合成签名旧reader资格不等于实际alpha.18运行，不能通过手工覆盖绕开数据门禁。

## 打包失败与准确恢复

原DMG提交等待1584秒后精确中断自有notarytool，测量FAIL／1保留；另一次60秒有界提交无ID，远端结果仍unknown，未伪称取消远端请求。只读history认证成功，但没有可确认该输入的ID。原件严格签名通过，hdiutil verify报EAGAIN；创建时遗留的diskimages-helper持有该inode。未杀helper、未强制detach。

普通复制到新inode后，复制前原件＝副本＝复制后原件SHA256 `17f4585c843679bd929dcf27139bf8328b65e7daef448a0774628cc8dc75d9c0`，新文件的image verify通过。同字节显式提交后返回上述DMG ID，Apple日志jobID／Accepted／输入SHA匹配。保留不可变提交输入，从其独立副本装订并走原标准资产／Gatekeeper／App一致性门禁，冻结源未变。原文件占用解释与证据相容，尚不宣称唯一根因。

最终冻结打包回执`alpha19-frozen-package-finalize-v1` SHA256 `e0b9b8bf78c182d7be20c7643caf52093bea5a74f3b6f44607efc47f46758a82`，发布回执`alpha19-publish-v1`为`b2f7e85a8f0c6b7db2d690947c3ef5cff74e520025e723a194ae718f5e43c458`。原失败与未知回执、creator和所有输入保留，临时恢复脚本没有替换历史源码或伪造标准门禁。

后续永久修补见[冻结候选与公证恢复](../technical/release-candidate-recovery.md)。它有独立单测／只读真实Apple查询资格，尚未用新版本完整提交发行，不能反向修改alpha.19的历史流程。

## 产品验收边界

[准备页复查](explicit-attempt-ui-2026-11-26.md)包含合成中文／英文、明暗已观察子集、20步范围与执行、取消、unknown确认和冷启动。其Preview是当时的UI源码，不能冒充最终干净Release的完整视觉资格。物理热键当时不可用，未重配系统热键或绕过TCC。真实API按用户决定待配置；自动插入、AX／多屏、IME／VoiceOver、最低系统、完整视觉与长期驻留仍开放。完整RunStore可选材料／checkpoint、原图多模态及ACP等独立工程义务保留；33.5和原P0–P4未标完成。
