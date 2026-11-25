# alpha.15 发行与安装证据

2026-11-25。完整P0–P4目标仍PARTIAL。本增量完成查询缓存、可重复的性能工程入口、30分钟候选基线及工作区草稿菜单名称修补；原始失败、原生子集和跨源边界见[实现复查](performance-sampling-2026-11-25.md)。

## 精确源码与资格

最终source／tag为`72a7595d2b1ee05a0e1d2df761153d341e1d2d7c`。开发从master `4fa84ab`通过工程helper创建feature/performance-sampling，主Agent独占写入、构建、设备与Git，Agent只读复核。完整本机、Release构建与复核通过后受控fast-forward晋升master；没有worktree、复制checkout或覆盖未提交内容。

最终本机719 Swift／74 Python／744 key全部PASS，生产accurate／revision3／自动语言／纠正／支持CPU配置的合成OCR双轮通过。inventory698（core688／Terminal9／OCR1），摘要`8f25ea7fd97a473d31bc2edf86956de794a991e56f7d10a843fa7c76f8430725`。机器M1 Pro／macOS27.2(26B123)／Xcode27.2(27B52)、arm64；最低macOS14与Intel仍未获运行资格。

完整摘要`.local/pipeline/20261125T104917280324Z/check-summary.json`文件SHA256为`ea55d439ba38c66ed8af09a3668ea25fc001a07a3360ceaa0e227a50fc5831b0`，qualification规范化摘要`d24db6576e6bbf4cc1a50612b10cc1088b5bdc9bfb978f1e36617e4315dc796c`；二者编码范围不同。

[指定同源CI 45598635771](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45598635771)的job139151295824全部步骤PASS，含优化Preview。cloud-core为718 Swift／74 Python／744 key，OCR明确NOT_QUALIFIED。日志artifact15015091200回下载96,447字节，SHA256 `fb33c43a2af2229356830d5680740954c4c83919769b07b9e440d4982feeb2fa`；21个文件、10个阶段JSON实际读取，exitCode均0，源与inventory一致。

## 性能与视觉边界

最终源码本机缓存查询p95为9.937542ms，排序p95为17.693834ms；目录准备14.187917ms另报。原50ms预算、2,000项／10预热／100正式样本未更改，先前51.669292ms失败保留。测量`aa3ad29b-37a5-4f89-805c-7031851963b0`，原始目录`.local/pipeline/20261125T105525644859Z/performance/`；不以较低先导值代替最终测量。

[独立性能CI 45599552942](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45599552942)的job139154508765 PASS，查询p95为15.793292ms，排序p95为15.846416ms；owned原生探针正常采样／错路径／退出负例及CPU单位对照通过。云端为M1 Virtual／macOS27.0.1／Xcode27.2，不能当本机或GUI结果。artifact15014348118共19,616字节，SHA256 `64080781a2248bc051bdc8c68a1d556e5445fac3d204df0f97de833214bcbb60`；14个文件、4阶段JSON实际读取，原始统计、stdout摘要与CPU单位重新校验通过。

干净候选2b3d5b6的ReleasePreview完成1800.014秒／361点三阶段资源基线；随后发现并修补草稿Menu辅助名称。该基线按准确源保留，不升级为最终72a7595的同源驻留资格。最终修补UI文件与原生dirty候选的SHA256一致，英文浅→深→浅、返回中文及草稿选择子集通过。完整视觉、IME／VoiceOver／多屏／Esc、150ms屏幕唤起、8小时含睡眠／唤醒和真实采集能耗继续开放。

## 打包、公开与安装

| 阶段 | 测量 | 结果 |
|---|---|---|
| 最终完整本机 | `9ed82010-00db-41d1-b51c-f174faa49e40` | PASS，84.603秒 |
| Release构建v2 | `8c750720-ce15-4320-b50b-f8833c315d0d` | PASS，72.014秒 |
| 打包 | `cc679bbc-4721-4d0a-8bb3-ea8cb218faff` | PASS，72.054秒 |
| 发布／回下载 | `0df6d207-d0c5-4987-8f30-247fb74fa9df` | PASS，36.850秒 |
| 正式安装 | `581f853f-46cd-40c4-8648-8c60b42e9972` | PASS，8.978秒 |

Developer ID、Hardened Runtime、team J56BFQN5PZ；App公证`6986d03e-ec95-44a1-8367-5490331fef21`、DMG公证`7e4d5b9c-aa16-4743-8678-28be5657f17e`均Accepted，装订、票据、Gatekeeper与只读挂载内外App一致性通过。hdiutil弃用提示和实际构建warning保留，不表述为零警告。

[公开alpha.15](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.15)于11:02:54Z发布，isDraft=false／isPrerelease=true；先draft回下载，再公开并复核。[发行审计45600733292](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45600733292)的job139158652082全部步骤PASS。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.15-macos-arm64.dmg | 3,192,572 | `d6f8687bab770fd5c3c01932cef4b3b4b365b765da6c3fbea6a66a82c29dfd0e` |
| KeyDock-0.1.0-alpha.15-macos-arm64.zip | 2,620,951 | `9bfbec0aabd1ec5be975caf84e7969ae493431fbf9456701dee09418d661d41b` |
| release-manifest.json | 5,071 | `725da1b6a5a0b27cc026d58ceb6d08ea0b08c3b19862bead69f4f54c7356b04e` |
| SHA256SUMS.txt | 298 | `2bfa817d5d80502fc88562375d96f6fe6f2bf656978dbc08cb2a4763d39c089d` |

transaction `162f8eb3-35dd-426e-aaea-9b10ddea90d4`原子替换`/Applications/KeyDock.app`，源72a7595、safeSmoke=false，bundle SHA256 `b082470c49b6e0105de8742daa0e8907ee2a8cbd2f4080a10445d8713e5aeedf`。按准确正式路径打开，实际“关于”显示`0.1.0-alpha.15 (15)`及统一支持邮箱，不以Preview或plist代替。

alpha.14回退包为`/Applications/.KeyDock.app.keydock-backup-162f8eb3-35dd-426e-aaea-9b10ddea90d4.app`，源475e31f、bundle SHA256 `2f88d754a71be8c910d4004e2ab09777e54b285e2465dfb809c29b6870d0bb7b`；rollback_available=true，本轮没有实际回退。旧App／xcarchive／build-result保留于`build/pipeline/release-history/0.1.0-alpha.14-475e31f-deab74e6-2eb8-460f-ad63-53f1b36947d9`，前后摘要相同。

## 保留的工程失败

旧产物预检曾错误地对原始xcarchive内App要求流水线BuildInfo，失败后shell后续构建仍启动。主Agent立即中断该自建构建，原始档案build14及Mach-O UUID与旧App相符，mtime与旧产物一致，已发布／已安装App摘要未变；修正为按档案结构核验后才保留，后续v2构建独立计量。App／archive／构建记录三个前后摘要分别为`2f88d754…`／`89c60ee7…`／`9087f903…`，完整值在`.local/desktop/alpha14-build-preservation-before-alpha15.json`。

中断的v1只有测量开始`a17c06c5-0ab4-4750-b2ca-be7f5e2bf4d2`，工具会话实际exit130，没有完成回执；不补造成功或结束时间。iSpec审计继续保留该unfinished及历史两条legacy-start未验证，不能写成全局测量审计完整或产品验收通过。最终v2及发行阶段的已完成回执另行逐项核对。

[同源master CI 45599552762](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45599552762)的job139154508408全部步骤PASS，含优化Preview；发行manifest继续绑定前述指定CI，不改写已公开资产。当前attempt已完成回执的id／attempt／退出码及文件SHA逐项复核通过，未完成a17c06c5及历史legacy继续保留，最终审计快照在`.local/desktop/alpha15-receipt-audit-final-v2.json`，全局complete=false／businessAcceptance=not-evaluated。

完整定义导出28.4按[下一增量方案](../technical/configuration-export.md)继续实现，原完整产品义务保留。真实API按用户决定稍后配置，不绕过系统权限。支持、反馈与隐私请求：arthur.wang.wsx@gmail.com。
