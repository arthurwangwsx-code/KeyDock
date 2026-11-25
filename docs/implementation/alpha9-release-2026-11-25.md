# alpha.9公开发行与安装（2026-11-25）

[公开预发行alpha.9](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.9)已发布并安装，精确源`5f526588a1b280d98d24f7d7a2aa7018439da5d4`，tag保持该原始字节。完整产品仍PARTIAL；发行通过不代替实际AX、多屏、物理快捷键、真实AI与完整视觉验收。

## 产品增量

桌面工作区已接通设置应用、Launcher与独立profile快捷键：全部已有应用／窗口先检查，再按显式缺失策略后台准备，冻结后逐步聚焦／布局。父只占一个管理任务槽，fresh child intent先于派发，取消与新入口等待真实worker；逐项保留confirmed、notExecuted、unknown及独立receiptUncertain。父有序结果在child裁剪后仍保留，重启不重放，缺失记录不冒充未执行。别名清空与写前／写后故障补偿已修补。设计、真实发现的排版失败及回归见[执行复查](desktop-workspace-execution-2026-11-25.md)。

## 精确源码资格

| 范围 | 结果与证据 |
|---|---|
| 完整本机 | PASS；93520356-30b0-47c0-9fad-07dac0c5e8a7，100.744秒；627 Swift／46 Python／680 key，inventory606，全部8份stage日志哈希与字节已核对 |
| 系统OCR | PASS；原accurate／revision3／自动语言／语言修正／支持CPU及180秒门禁不变；同一自有PNG的两轮分别约0.478秒／0.099秒命中；旧FAIL及长期可靠性义务保留 |
| 同源feature CI | [45533000879](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45533000879) PASS；626 Swift／46 Python／680 key，系统OCR明确NOT_QUALIFIED；优化Preview、归档与上传成功 |
| 同源master CI | [45534301402](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45534301402) PASS；core／优化构建／归档及上传成功 |
| CI证据回下载 | artifact14985773084，87,526字节，SHA256 `6dae6995a2d97736198124b9761fd23e55c8809858cdd96401e8493c40edd240`；source、inventory及7份stage日志已核对 |
| 本机Release | ea155300-dab8-40d4-a605-e74d23ede29c PASS；192.840秒；Developer ID／Hardened Runtime／team J56BFQN5PZ |
| App／DMG | 715f3da0-7496-45e3-8c6e-bc1d760456fd PASS；App提交e6ff789a-4885-4ab7-a0fa-3a3d7266cdf6、DMG提交ca59dd7d-e3d1-46da-ad7a-11d571406674均Accepted，装订／Gatekeeper／只读DMG内App一致性通过 |
| 发布 | 9d6ba24f-3e95-4d53-94cf-839e55a551cb PASS；先draft、四资产回下载验签／验哈希，再公开并再次回下载验证；isDraft=false、isPrerelease=true |
| 发行审计 | [45534536518](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45534536518) PASS；release-assets job138937777720实际下载并校验版本／源码／资产摘要 |

本机资格摘要SHA256为`8a950703e4e5e27852a376c7dcbbb28f4c0339402d0222c6a3b14c5f1d2d0458`，App和manifest绑定同一值。第一次打包742db03d因CI尚未结束被原门禁拒绝；没有向Apple提交，待同源CI完成后才继续。没有放宽门禁或重写旧测量。

## 资产

| 文件 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.9-macos-arm64.dmg | 2915955 | `0441e5d56f227f1073edd575963d81c0af9a6c472687a4446a5ca5e2184ee70a` |
| KeyDock-0.1.0-alpha.9-macos-arm64.zip | 2372624 | `d9f091adb460813447507d307597a0513dbc06887e3317d1dbc0491ca2956127` |
| SHA256SUMS.txt | 296 | `32fb23de4da816d4461276ee367d6ffcdeb22bd23266daf83b01f61805ef6e10` |
| release-manifest.json | 5064 | `9f1a52648994f293866e475ee79e0c5b73352d6f1cdfd95bb6adce5eedc5b40e` |

## 本地安装与原生观察

fb7d79ab-4a0c-47ec-ad69-efeaa74995ac安装PASS，7.089秒；正常退出、同卷原子替换，当前`/Applications/KeyDock.app`为alpha.9 build9，源5f52658。实际启动正常Launcher，独立About显示`0.1.0-alpha.9 (9)`，支持邮箱arthur.wang.wsx@gmail.com正确。未打开个人剪贴板、改API或代授予TCC。

安装回执`.local/pipeline/20261125T023815973261Z/install-receipt.json`，SHA256 `291a01048f110c24cc172f2d39875247cd148f18055beaec7ff83234dc6d2bc7`，transaction `06168459-9774-4eda-bbf4-392cbf7308d8`；当前bundle SHA256 `0a30f6a30d5de3cd4d7b270223826bd7994574da4d95341943cc92fe0a3b36bf`。alpha.8备份位于`/Applications/.KeyDock.app.keydock-backup-06168459-9774-4eda-bbf4-392cbf7308d8.app`，旧源0095326、旧bundle SHA256 `3a6c3ca6378735446a50dc625d03fc4e007979c1e9bbe12fdb33d1a80de1782b`；rollback_available=true。本轮没有实际回退，原alpha.7等历史备份继续保留。

Preview中已观察中文浅色／英文深色、窄窗口卡片／宽窗口表格、设置与profile快捷键定位及隔离拒绝原生操作；原挤压失败修补后复验，语言／外观恢复Follow System。该子集不等于完整视觉、VoiceOver、IME或真实AX布局通过。

## 仍开放的范围

- 20.4真实AX授权／撤销、多个应用／窗口、断屏／重连、Spaces／多屏与物理热键；所有子worker和部分失败仍需实际系统验收。
- 真实剪贴板自动插入与完整安全／焦点矩阵；当前公开包没有以开发数据读取个人历史。
- 按用户决定稍后配置真实兼容API；模型质量、外部Agent／MCP组合、长期驻留／性能、最低系统及Intel尚未完整验收。
- ispec apply与完整产品验收保持开放；当前测量可核对不表示旧legacy-start审计已补齐。旧候选、OCR与别名复现FAIL继续保留。
