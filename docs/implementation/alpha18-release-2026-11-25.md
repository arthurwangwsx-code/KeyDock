# alpha.18发行与安装证据

2026-11-25。可选AI费率、逐次请求快照、Workflow父子索引和独立本地用量分析已交付；完整P0–P4仍PARTIAL。工程实现及保留的失败见[增量复查](ai-rate-snapshots-2026-11-25.md)。

## 精确源与验证

发行tag为`v0.1.0-alpha.18`，源`6baaee827131a31e342ced8dbc0955c5f2a768ae`，干净提交。功能分支由master `f1f6e53`创建，经测试和只读多Agent评审后受控fast-forward至master；单canonical目录，无worktree或源码副本，AiBox只读参考。

| 检查 | 结果 |
|---|---|
| 本机完整检查 | 804 Swift执行项（783声明项含参数化）、78 Python、847中英key；合成OCR双轮PASS |
| 指定同源CI | [45642260593](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45642260593)，job 139303764966，803 Swift／78 Python／847 key及优化Preview构建PASS；云端OCR仍NOT_QUALIFIED |
| CI原始日志 | artifact 15036182704，101568字节，SHA256 `319671acfcc9d8337b2225716314edbc8983acdfafc6af008692baeadb4e55ff`；回下载核验21文件／10个零退出阶段及全部evidence摘要 |
| 本机资格摘要 | `.local/pipeline/20261125T151100556915Z/check-summary.json`，SHA256 `1ce5778d590be425263c14eb505e488dd3de93197d20ffbc35f3ba9f7c42e60e` |
| 嵌入资格摘要 | `44d6163693327ef5a37bffc44d136d76049129db0c317aefa01f89a1dc989ea0`，App、manifest和ZIP一致 |
| 发布后独立审计 | [45645020268](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45645020268)，release-assets job 139313546204 PASS |

CI 45638887309的canonical路径测试期望错误，以及45639348403的新费率Workflow夹具5秒失败均保留。修补包括测试期望采用resolve后的路径、费率测试使用无人工延时的真实SSE夹具；原逐字节测试和5秒收口断言保留。完整本机首轮旧产品预算断言失败亦保留，详情见增量复查。

## 原生观察子集

中文浅色与英文深色实际观察了费率表单／列表、单次用量／金额、历史恢复和分析区。旧费率2／4（每百万输入／输出token）对12／5生成USD 0.000044；新3／6生成0.000066。重启后两笔保持原值；最终源再主动运行一笔0.000066，分析显示3请求、36输入／15输出、USD 0.000176。服务实际收到3次请求，重启没有重放；没有云端服务或密钥。

7／30／90天、时区与独立行为统计被观察；两条旧版loopback合成记录单独显示30／10 token，没有套用新价。默认Preview目录保留既有合成记录，不能称作空库／全新安装。ForEach金额标题的语言缓存缺陷已修补，在同一页面完成English→中文→English复验，90天选择保持。

最终Preview bundle摘要`6ba65594cffcb34521b60f2a123c7ba4bf18519b091b185d1394cc36e7452291`。原始截图／AX在本轮CUA记录；3条自有合成usage及核验回执在`.local/desktop/alpha18-native-evidence`，receipt SHA256 `8694079524644fc61fded09744717c67e5065d8fc810278ff54011459d7f46fd`。CLI e2e计时仅覆盖元数据核验，不能当作实际交互耗时或完整视觉资格。Preview正常退出，owned loopback服务已停止。

## 公证、公开资产与安装

[公开prerelease](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.18)于2026-11-25 15:25:30 UTC发布，非draft。Developer ID team `J56BFQN5PZ`、Hardened Runtime、App和DMG各自公证／装订及Gatekeeper验证通过；发布流程从draft回下载验证身份、签名及摘要后再公开。

App公证submission：`9afb8280-4e10-4742-b8d8-9075400e48dc`；DMG：`2080187b-817b-4332-b525-c8d069f89869`。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.18-macos-arm64.zip | 2963788 | `8f7b1d8d0d3ba156f105052dcf500365e1c380ba2cdb8f82174955fd94e0b44c` |
| KeyDock-0.1.0-alpha.18-macos-arm64.dmg | 3424105 | `6bf10d4f607cd72b903dddb5087d2f3efa11da3d58c0754ad8e02426963651fe` |
| release-manifest.json | 5071 | `9122f256a79c627eba7bf41cf74575522cff61529aa4c4b905f52decb4e8593f` |
| SHA256SUMS.txt | 298 | `c8bc1d78f94f0c779dd05311433dd17870b839cfff94d31977677429c89a7ca1` |

正式安装为`/Applications/KeyDock.app`，Release、safeSmoke=false、干净6baaee8。实际CUA“关于”显示`0.1.0-alpha.18 (18)`及统一支持邮箱；bundle摘要`6720dc40584d6c1a64202256269c15315e051599e69e31a0cde7a44e137b65c1`。安装事务`e960d248-3369-4a48-afc4-357f1221833e`，receipt在`.local/pipeline/20261125T152546776646Z/install-receipt.json`。

旧alpha.17保存于`/Applications/.KeyDock.app.keydock-backup-e960d248-3369-4a48-afc4-357f1221833e.app`，source `3e681f00efa54ed3763effd64047fba3a5797bd5`，bundle摘要`929d9dcdcb2ca8dcdc104ff68df0206081f5fe7f1386ccb60c67c7992950f235`；可经既有rollback命令审阅后回退，本轮未实际回退。

原始alpha.17 archive、App及build-result在`build/pipeline/release-history/0.1.0-alpha.17-3e681f0-before-alpha18`。移前／移后摘要一致，archive摘要`2c9ad59ff730afdc9e32ec17303590cde2b5b3dd84ae0d50f6ff75c05faec010`，image UUID `C27ED57F-2010-37F7-B802-3030F8C0E1AF`；raw archive不注入发行BuildInfo是既有设计。当前alpha.18与上一版原始包保留，更早被引用证据与回退不自动删除。

## 计时与边界

以下measurement同属apply attempt `9881b6d8-e08e-4176-b6a2-97706ee67811`，receipt位于iSpec change的receipts目录，原始日志在`.local/desktop`：

| 阶段 | measurement | 秒／退出 |
|---|---|---|
| complete-check-v2 | `1dfe471b-2877-4e2b-bafd-a241fc6afb18` | 91.727／0 |
| preview-build-v2 | `ea19262c-ec0d-445d-b665-8eebcb1001e3` | 12.320／0 |
| release-build-v1 | `07a2c6f3-adc7-4e38-be5f-a6dc418eb0e8` | 83.951／0 |
| package-v1 | `5f980cb8-52ee-40a3-9ad5-2d259c8def01` | 80.342／0 |
| publish-v1 | `841af1f0-f874-4548-992a-48fc2f380ba2` | 43.947／0 |
| install-v1 | `7946f2ca-816b-4d8b-b81c-cffda23b2e85` | 13.246／0 |

个人Mac整段开发／检查／构建／证据／安装使用共享12GiB准入租约，CLI嵌套复用且验证租约；KeyDock保持admission-only，没有扩大清理范围。空间治理不代表产品验收。

真实兼容API、账单对账与模型质量继续按用户决定待配置。完整视觉、物理热键／插入、AX／多屏、IME／VoiceOver、最低系统和长期驻留未全量验收；完整RunStore显式恢复、原图多模态附件及ACP仍有独立工程／评估缺口。原任务4.7的无稳定身份delta仍明确拒绝，不能由本次费率交付宣称所有适配完成。整个apply和完整产品均不标完成。
