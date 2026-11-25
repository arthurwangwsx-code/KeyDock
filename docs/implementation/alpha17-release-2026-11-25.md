# alpha.17 发行与安装证据

2026-11-25。[公开Release](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.17)于13:13:44Z发布为prerelease，非draft；正式版本`0.1.0-alpha.17 (17)`，精确源码／tag为`3e681f00efa54ed3763effd64047fba3a5797bd5`。经本机检查、只读评审和同源CI后受控fast-forward进入master，无worktree或并发写入。

## 本版资格

工作流／MCP独立移除审阅、禁用引用保护、准确绑定事务、旧确认与旧编辑拒绝、MCP会话撤权及异步退出收口已交付。25项新增和54项定向回归、中文浅色／英文深色原生子集见[实现复查](source-removal-2026-11-25.md)；未扩为完整视觉、真实API或实际系统权限资格。

干净3e681f0完整本机760 Swift／74 Python／789 key、原生产OCR配置双轮PASS；739 inventory／729 core／9 Terminal／1 OCR。检查目录`.local/pipeline/20261125T130304522029Z`，summary SHA-256 `9363daf93f721daa76b81bba5e078084d17d3c54469a00a665a4b2223171ab6f`，qualification SHA-256 `f7aa0a7921042d264f10c075e985eefff300c769d2444f61f48234338b165d64`。

[指定同源CI45619648249](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45619648249)与Release优化Preview构建PASS，job139224065521；云端759 Swift／74 Python／789 key，OCR为NOT_QUALIFIED。日志artifact15024735929，98759字节，SHA-256 `d65fe47ce47303f7afe55b7b42e80ef52e11e109a00abcd46d524a263eb203ab`；回下载核对21文件／10零退出阶段及摘要中所有日志字节和摘要通过，私有审计`.local/desktop/alpha17-ci-3e681f0-summary.json`。

Preview原生观察来自06a271c＋WIP候选，其后仅更新文档及提交，没有修改应用源码。正式App只打开设置“关于”，实际显示`0.1.0-alpha.17 (17)`与约定支持邮箱；没有读取生产配置正文、个人剪贴板或历史作为开发数据。

## 签名、公证与公开资产

Developer ID／Hardened Runtime、App／DMG公证Accepted、装订、Gatekeeper、只读DMG内App与ZIP同源同内容PASS。App submission `86a6f194-1e90-45a8-8f14-d05deadfd846`，DMG submission `f34751ad-971d-4518-b069-7ec1772319f9`；复用已有钥匙串profile，未导出凭据。

| 资产 | 字节 | SHA-256 |
|---|---:|---|
| ZIP | 2803564 | `31403c00faa1a4d3b4f19f4d89949e62c61194fe2f8ec29f162c76a274101877` |
| DMG | 3390170 | `cb15116c4dd8ed4ee605921b2813603789b5e251c65235b7e390da753aee1b84` |
| release-manifest.json | 5071 | `06dc8afee6043117861e95ded9d2f8856ca2ffb00f8663b263514a7c42bcd41d` |
| SHA256SUMS.txt | 298 | `ef1c639680b582d933c2aacf3b8f80241fc874711c9a629a2c4a34759ca0a827` |

既有publish流水线先draft、回下载验哈希／解包／验签和只读DMG核对后公开，不覆盖旧资产。[发行资产审计45621435948](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45621435948)，job139230345654，PASS。公开文件与本地`build/releases/0.1.0-alpha.17`一致。

## 本地替换与回退

安装事务`0d610dd1-a830-476e-8d1d-15cc69d4d62e`，目标`/Applications/KeyDock.app`，state=installed。正式App bundle SHA-256 `929d9dcdcb2ca8dcdc104ff68df0206081f5fe7f1386ccb60c67c7992950f235`，源3e681f0／Release／safeSmoke=false／Developer ID／notarized=true，安装后独立检查与receipt一致。

alpha.16备份`/Applications/.KeyDock.app.keydock-backup-0d610dd1-a830-476e-8d1d-15cc69d4d62e.app`，源20854e3／bundle SHA-256 `6142429915e093afe671cdcf58f188d258da736a57221d27a343be8666469d5a`，独立验签及摘要与receipt一致，rollback_available=true；保留但未实际回退。私有观察摘要`.local/desktop/alpha17-install-observed-receipt.json`。

alpha.16构建／xcarchive／build-result保留于`build/pipeline/release-history/0.1.0-alpha.16-20854e3-before-alpha17`，移动前后摘要一致；原archive不含最终注入的BuildInfo属预期，版本16及Mach-O UUID `048FD4A5-F915-3393-BBB9-19322246254D`与最终App核对。archive SHA-256 `889c179eaaba5df670f5ba7bf84407fc3a7567517edd27728e4cf47361f77823`。

## 回执与完整产品边界

| 阶段 | Measurement | 实测秒 |
|---|---|---:|
| 干净源检查 | `02cc9675-6a0c-4b0a-b2ea-72405165e5f8` | 91.705 |
| Release构建 | `fafc2f2e-80f3-4de3-865a-28a61aaadb52` | 74.922 |
| 公证打包 | `6303386e-25c3-4c4b-9a80-4450685259e9` | 66.721 |
| 发布／回下载 | `ee26c06b-dbf0-482f-99e5-050ad56f8afa` | 32.399 |
| 安装 | `7aa7f7d7-66ef-4f49-85f3-e763fd2043c3` | 9.025 |

所有回执绑定apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`。本次交付的metrics快照和回执逐项摘要／ID／attempt／阶段／时间／退出码核验保留在`.local/desktop/alpha17-metrics-final-v1.json`及`alpha17-receipt-audit-final-v1.json`。原首轮定向失败保留；历史unfinished `a17c06c5-0ab4-4750-b2ca-be7f5e2bf4d2`与两个legacy缺开始记录仍未伪造补齐，因此不声称全局测量审计完整。

31完成本增量工程、原生子集和发行交付；原完整P0–P4目标仍PARTIAL。下一增量为[可选AI费率与调用快照](../technical/ai-rate-snapshots.md)，当前只完成规划。完整RunStore显式恢复、多模态原附件、ACP、首帧trace、真实API／模型质量、目标插入／AX、多屏、IME／VoiceOver、最低系统和8小时含睡眠驻留继续开放。
