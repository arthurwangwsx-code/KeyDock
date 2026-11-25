# alpha.12发行与安装证据

2026-11-25。完整产品仍为PARTIAL；本次完成任务26的独立Time工具互通与HTTP生命周期子集，没有关闭24.5其余义务。

精确发行源`d99fee8078f807ce3803f2829181c69509468cc2`，版本0.1.0-alpha.12／build12。主Agent从master 4555dab创建独立分支、串行修改／验证，两位Agent只读评审。测试和评审后受控fast-forward master，推送同一源的annotated tag再发布。[公开prerelease](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.12)于2026-11-25T06:38:17Z公开；旧tag／资产字节不变。

## 源码与互通资格

| 范围 | 实际结果 |
|---|---|
| 完整本机 | PASS，685 Swift／58 Python／708 key；声明664项，core654／Terminal9／OCR1；原生产accurate／revision3／自动语言／纠错／supportedCPU配置，owned合成PNG两轮识别通过 |
| 独立Time | PASS，官方mcp-server-time 2026.11.18／mcp2.3.0，两协议×两传输；每格接纳3工具、实际时间／转换／相对时间／错误、旧目录拒绝及进程退出 |
| SDK慢任务 | PASS，本工程自有官方SDK夹具，四格真实started→cancel→finally，completed=0，原连接继续调用；legacy HTTP一次原ID取消及一次DELETE，现代两项为零 |
| 同源core CI | PASS，[45560494888](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45560494888)，684 Swift／58 Python／708 key、Release优化Preview；云端系统OCR明确NOT_QUALIFIED |
| 独立互通CI | PASS，[45561750623](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45561750623)，全新依赖环境与两组四格均通过 |
| 发行资产CI | PASS，[45562087011](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45562087011) |

本机check在`.local/pipeline/20261125T062623973999Z/check-summary.json`，文件SHA256 `4a4516649f9ddb6f73a947c55a8216940602946750d8c5eb9b8e862fb3d6ce52`；资格canonical digest `20e65f6b8cf22b5bc523d33321f2b1ecd259f25c5536be5caf47eb0acaf1dbc7`。inventory digest `45ae8514186dbb74172aca61ad563300303ab5ec348282ca766bfd0e1633399e`。OCR owned PNG `06db6e05ce33913ef1ec983f48496c89ff7112b5f2a1ab26dd782f349499e161`，此前OCR失败／长期可靠性仍保留。

Time与SDK最终本机报告在忽略的`.local/interop/time-20261125-4/runs/time-d99fee8`和`sdk-d99fee8`，source为同一干净提交，源码／依赖前后未变。31项依赖lock `f9f9d9045e332f8a6a55281a9567c3bb07ec7c47aa9c95a5b6ea0655a9840d46`；原wheel对应1581安装文件digest `ce74ef30e415eeb803e7aa63429b27b2c81122e5da29c5802b755d6c30e08a04`。解释器3.13.12、完整安装树／pyvenv另有绑定。所有进程组退出，不需异常／强制清理。旧错误metadata环境和SDK观察失败均保留，见[开发复查](mcp-interoperability-2026-11-25.md)。

远端core日志artifact14998476076，92129B，SHA256 `029b68baea2ec09e72d59a1ba96fb359b8954c45958d4dedf87d0e2bda691a4c`，21文件完整读取；summary引用日志字节／hash及10份stage JSON exit0已核对。互通artifact14998955323，213452B，SHA256 `4339d0ac67be3f12d84b4635e66e547759484f2333b3e3d122086c4332956245`，80文件完整读取，两组四格的源、结果、旧目录、finally和组退出已核对。脱敏摘要在`.local/desktop/alpha12-ci-d99fee8-summary.json`及`alpha12-mcp-ci-summary.json`，原始报告不进入发行包。

## 签名、公证与安装

Developer ID team J56BFQN5PZ／hardened runtime；App公证`6ba383e6-1bae-49f3-958b-1f3fd7294666`、DMG公证`3cf8a3db-f110-4f13-ad48-0385416d7d70`均Accepted，装订、Gatekeeper及只读DMG内App比对通过。复用已有钥匙串profile，未导出密钥。先draft回下载核验，再公开并重新核验。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| ZIP | 2556803 | `4e5163de388422322974e69b8b13f5f39526b0ce5b21018fc4222a7c691e89be` |
| DMG | 3120242 | `9918fc46196fcbe0753a1d7d14517737c9438503218553dc3a26a7dd3740fd56` |
| release-manifest.json | 5071 | `27bc64757965a032a28c82bf2721b425ccb94272ecca5228d70103b31bac744d` |
| SHA256SUMS.txt | 298 | `33c6a9ca18d0337af0ac7debb3ef532d191359a679ac6d20cccc4224bc6f2613` |

原子安装事务`b5ed94c5-b522-4be8-a350-e7bd42edc8c7`，`/Applications/KeyDock.app`实际About通过原生菜单观察为**0.1.0-alpha.12 (12)**，公开联系邮箱一致。installed bundle digest `9bd702dfd4f13e4f7315c6130d33f2c2e0248ffe580b6d71d9de5e3c87780b99`。alpha.11直接回退包`/Applications/.KeyDock.app.keydock-backup-b5ed94c5-b522-4be8-a350-e7bd42edc8c7.app`，旧源9f8d6d5b、bundle digest `cabe8f703eff7a258f7c791d80621f8722010b4af6ef8059e9910322563457a9`，rollback_available=true；未实际回退。

旧alpha.11构建App／xcarchive／build-result以原字节移至`build/pipeline/release-history/0.1.0-alpha.11-9f8d6d5b-7909d64d-5368-4ac0-9b85-a4f65a0c0508`；前后hash相同。旧发行资产、安装备份和更早证据保留，未清理其他工程或个人数据。

## 回执与剩余义务

同一apply attempt 9881b6d8-e08e-4176-b6a2-97706ee67811，change下receipts：本机71489791、Time bd6d503f、SDK 0654e0b4、build 4dea9d77、package 797c88df、publish 4930cd9a、install 1ad1d693均exit0。对应耗时86.830／13.647／12.527／70.412／96.965／65.100／11.277秒。证据整理前快照293次当前attempt测量（255零退出／38非零），当前receipt身份／摘要均有效；全局legacy两个无start记录仍未补造，businessAcceptance为not-evaluated。

本次只观察安装About，不将其记为完整视觉通过。真实模型、AX跨应用插入／窗口、多屏、物理快捷键／IME／VoiceOver、长来源／原生在途关闭、驻留性能等仍开放。另确认Snippet旧编辑稿／关联配置删除、脱敏配置导出和UI首帧采样存在工程缺口，将继续开发。不能报告“仅剩用户配置”。技术支持与隐私请求：arthur.wang.wsx@gmail.com。
