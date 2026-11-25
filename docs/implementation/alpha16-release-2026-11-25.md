# alpha.16 发行与安装证据

2026-11-25。[公开Release](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.16)于11:59:30Z发布为prerelease，非draft；版本`0.1.0-alpha.16 (16)`，精确源码／tag为`20854e3edf924ec0f4e64b153ec5caddca9c17e9`。源码分支经过本机检查、只读评审和同源CI后受控fast-forward进入master，没有worktree或并发写入。

## 本版能力及资格

独立设置提供完整配置定义导出：六类范围、显式字段投影、源ID／顺序／UTF8保真、内部引用检查、未选依赖／外部资源／本机字段需求、8MiB／1024定义／4096逐次引用预算。后台捕获／编码、稳定保存身份、取消／失败／关闭／shutdown围栏及中英文已接通；[技术合同](../technical/configuration-export.md)和[实现复查](configuration-export-2026-11-25.md)说明实际字段与限额。

16项新增定向测试及完整本机735 Swift／74 Python／768 key、原配置OCR双轮PASS；714 inventory／704 core／9 Terminal／1 OCR。干净20854e3检查目录`.local/pipeline/20261125T114750630924Z`，summary SHA-256 `4777f69766ec409cf943438a4f7556966fe4d07215cb92c69c4d53f8cd3e4f88`，qualification SHA-256 `b22061e418678be7b1de43eebe4ff06f2116c1d02a25eb65e697daf3d908c806`。

[指定同源CI 45607747123](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45607747123)及Release优化Preview构建PASS，job139182929017。云端734 Swift／74 Python／768 key，OCR为NOT_QUALIFIED，不能混为本机OCR资格。回下载artifact15019401832，96598字节，SHA-256 `c3b8b112cfea6ea59d4d5bfd07f4e7822a8554e816f68058b940835062a4d95d`；21文件／10零退出阶段及摘要中每份日志字节／摘要核对通过。日志审计保留在`.local/desktop/alpha16-ci-20854e3-summary.json`。

原生观察在隔离DebugPreview的8f2855d＋WIP候选进行，之后无应用源码修改：中文浅色全选与英文深色部分选择、取消／重试、Esc、提示／控件排版已观察；两个实际系统保存文件分别12116／5375字节，与各自只读AX预览的SHA-256一致。正式App只验证实际About版本，不读取生产配置正文作为开发数据；不把Preview的观察扩为完整生产／视觉矩阵资格。

## 公证与分发

Developer ID、Hardened Runtime、App／DMG公证Accepted、装订、Gatekeeper及只读DMG内App同源同内容PASS。公证profile复用本机已有别名，未导出凭据；App submission `c3805801-2e5f-41c8-9410-5d7ea4cc42eb`，DMG submission `f4e32792-dfe8-4be8-a188-303e9f39180e`。

| 资产 | 字节 | SHA-256 |
|---|---:|---|
| ZIP | 2733005 | `42b350eb9e67175b642ed8b1aa91e63d20540b7db6d1404f3bcecd0e38d2e9b5` |
| DMG | 3313784 | `d4d0ab44d2b198fc228d06baf49c306303c9f2c102e8b49072e66b2f9a069f39` |
| release-manifest.json | 5071 | `a081e34d37130b9cdf32681885e93b1a1b2138897fa196b7430ca9bce8c3b321` |
| SHA256SUMS.txt | 298 | `933734338bf6dd37125342672a635982437d1f3cd3722a91d7e78009d00f7dcf` |

统一publish先draft、回下载验哈希／验签／解包与只读DMG核对后公开；[发布资产审计45609498412](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45609498412)，job139189042816，PASS。公开资产与本地`build/releases/0.1.0-alpha.16`一致，不覆盖旧版本资产。

## 本地替换与回退

安装事务`3d7c73f5-8a14-418e-ae93-f6e2608dd1c8`，目标`/Applications/KeyDock.app`，状态installed。正式App bundle摘要 `6142429915e093afe671cdcf58f188d258da736a57221d27a343be8666469d5a`，source20854e3／Release／safeSmoke=false／Developer ID／notarized=true；实际“关于”显示`0.1.0-alpha.16 (16)`与约定支持邮箱。

alpha.15备份`/Applications/.KeyDock.app.keydock-backup-3d7c73f5-8a14-418e-ae93-f6e2608dd1c8.app`，源72a7595，bundle摘要 `b082470c49b6e0105de8742daa0e8907ee2a8cbd2f4080a10445d8713e5aeedf`，rollback_available=true；保留而未实际回退。原alpha.15构建／xcarchive／build-result另在`build/pipeline/release-history/0.1.0-alpha.15-72a7595-before-alpha16`，移动前后摘要一致；原archive没有注入BuildInfo属于预期，版本15及Mach-O UUID `6432C6F2-D975-31D2-B073-C1D8C416229C`与最终App核对，不套用最终App资源合同。

## 回执与未完成项

| 阶段 | Measurement | 实测秒 |
|---|---|---:|
| 干净源检查 | `5c16798b-9f32-40d8-bcc6-9559eafc66a4` | 78.172 |
| Release构建 | `0af88a40-cbd4-43e2-9483-acdca0f0f837` | 66.438 |
| 公证打包 | `962bd681-3784-41c3-837a-dd16b72c27b2` | 68.571 |
| 发布／回下载 | `0cd0d3e7-b195-487b-ac90-56ccb531673b` | 44.412 |
| 安装 | `3db3b4eb-94a7-48c7-b38f-419af7e7df14` | 9.152 |

回执在change的receipts，原始日志与二次审计在忽略目录`.local`。两次本轮语法编译失败已保留；前序中断`a17c06c5-0ab4-4750-b2ca-be7f5e2bf4d2`仍unfinished，两个legacy缺开始记录仍未重建，因此不声称全局测量审计完整。iSpec整体apply及原完整产品目标继续进行。

28.4／30完成本增量工程、观察子集及可分发交付。未来import、费率快照、完整RunStore显式恢复、原图多模态附件及ACP adapter仍有独立建设／评估义务；工作流／MCP删除的引用保护优先继续补齐。真实兼容API、模型质量、实际AX／目标插入、IME／VoiceOver、多屏、最低系统、完整视觉、首帧与8小时含睡眠驻留未关闭。alpha.15性能数据保留原候选范围，不升级为20854e3性能资格。
