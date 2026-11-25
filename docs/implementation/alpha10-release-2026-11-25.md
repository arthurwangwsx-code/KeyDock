# alpha.10发行与安装证据

2026-11-25。**alpha.10工程发行PASS，完整产品PARTIAL**。源码已公开，常规App已原子替换并实际启动；不把发行资格当作完整视觉、真实AI或跨应用操作验收。

## 精确来源与变化

公开[Release v0.1.0-alpha.10](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.10)，源与tag均为`64254e55dcb21b97527a011ff3b831da75101ef8`，发布时master同源。仓库PUBLIC，默认master，isDraft=false、isPrerelease=true，发布时间2026-11-25 04:01:13 UTC。后续文档提交不改变tag与资产字节。

- [准确输入与提交](ai-input-commit-2026-11-25.md)：UTF8字节编辑失效旧建议、共用marked-text提交门槛、设置操作的对象辅助名称。
- [导入文本来源](imported-text-context-2026-11-25.md)：文件／PDF／OCR／MCP到草稿及三类AI运行的会话来源，联合接纳、全局预算、编辑与完整清除。
- [AI草稿关闭](ai-draft-closing-2026-11-25.md)：独立Sheet冻结文档／revision／摘要，取消并等待真实worker后释放输入；历史结果保留，原选区替换停用。中文浅色／英文深色、Esc／取消和A确认期间新建B后仅关闭A的原生子集通过。

## 检查与构建

| 范围 | 结果与证据 |
|---|---|
| 最终本机native-system | PASS，650 Swift／46 Python／697 key；inventory629，SHA256 `53e05f7352f5c9e73cb9d103d148cfe208f9afa7d69ba6f4131566272029aa66`，core619／Terminal9／OCR1 |
| 系统OCR | 原accurate／revision3／自动语言／校正／支持CPU配置双轮PASS，同一合成PNG `06db6e05ce33913ef1ec983f48496c89ff7112b5f2a1ab26dd782f349499e161`；保留历史失败与长期可靠性PARTIAL |
| 本机measurement | `7b0cdd58-aebd-4103-9ccb-3d6b97a21315`，89.632s，`.local/pipeline/20261125T034912086145Z/check-summary.json`，summary SHA256 `a719cb92351ed2ab4ab6ccf8db233fb47e14d795e6c1fc761989a89991d5f131` |
| 资格摘要 | `8c347e5ea5458eaad7a3bbb1761431cb0fad6de7af3e58e631b49bdd0ce08618`，同源干净提交、macOS 27.2／Xcode 27.2／arm64；最低系统与Intel未由此验收 |
| 同源feature CI | [45542566410](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45542566410) PASS，job138964348742；649 Swift／46 Python／697 key与Release优化Preview构建；云端系统OCR为NOT_QUALIFIED |
| 同源master CI | [45542810454](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45542810454) PASS |
| 日志回下载 | artifact14989793981，88,388字节，SHA256 `886911abe50b5463bc19da34c9482604faaba023b135a14654def79e95851abc`；21份文件读取并逐项核对summary引用，10份stage JSON均exitCode=0；`.local/desktop/alpha10-ci-64254e5-summary.json` |
| 本机Release archive／Developer ID | measurement `3595b3e8-6827-4d64-9a08-b04a62dd26fb` PASS，100.586s，Team J56BFQN5PZ、Hardened Runtime；`.local/pipeline/20261125T035121301240Z` |

## 公证与公开资产

measurement `a2b96898-568a-4cfd-b129-2c3832555011` PASS，83.380s，`.local/pipeline/20261125T035811448526Z`。App submission `6ba8f175-058a-458e-8990-167f0b1c4dcf`、DMG submission `6a3f57c1-a2a7-47bd-a9bf-80b5a45528d6`均Accepted；装订、ticket验证、Gatekeeper及只读DMG内部App一致性均通过，未修改TCC／quarantine／系统安全配置。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.10-macos-arm64.zip | 2421079 | `fafe779486db8a8d343fbad168b8466fbc408981264479a29c13efe5198cd531` |
| KeyDock-0.1.0-alpha.10-macos-arm64.dmg | 2970235 | `e5cd642c4bf9ae39bdb8deb2eee5ba6bd8c921da0b85f2f99730b33e4f4ba12c` |
| release-manifest.json | 5071 | `ef5e79d65aff0ab3c86f99832d6b4e1912d514050b78834775242deac400e4cc` |
| SHA256SUMS.txt | 298 | `7b099fc603c43532d7a35aec4b9b7557a3db1831b8beb99b69f9696b28bc897f` |

publish measurement `971c312a-6e54-4015-aa9c-6747f9319607` PASS，36.887s；先draft回下载、验签／验哈希后公开，再公开回下载，现有资产不覆盖。[独立发行审计45543899933](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45543899933) PASS，job138968743031。本机`build/releases/0.1.0-alpha.10`保留全部资产。

## 安装与可回退证据

install measurement `f6ee7e9f-c531-4125-bc5e-7ec59bd42a94` PASS，11.343s，transaction `071620ca-4b88-49ca-a601-1bc228e10f65`。目标`/Applications/KeyDock.app`，Developer ID／Team／notarized=true及source／build均匹配；已安装bundle SHA256 `0db887b115ff0a0a741848d710534330694dfeeb86499489f31a45c6852d2d7b`。原生实际About显示**0.1.0-alpha.10 (10)**和统一支持邮箱arthur.wang.wsx@gmail.com。

直接回退为alpha.9，源5f52658，bundle SHA256 `0a30f6a30d5de3cd4d7b270223826bd7994574da4d95341943cc92fe0a3b36bf`，位置`/Applications/.KeyDock.app.keydock-backup-071620ca-4b88-49ca-a601-1bc228e10f65.app`。rollback_available=true，本轮未实际执行回滚。alpha.9原构建App／archive／result已同卷保留到`build/pipeline/release-history/0.1.0-alpha.9-5f526588-5a4adf60-ddff-4467-9c00-dd2ae858d018`；其公开资产、旧tag、alpha.8及更早备份没有移动或删除。

## 完整目标仍开放

实际alpha.10隐私页仍显示需要辅助功能授权；本轮没有更改权限、配置真实API、读取个人剪贴板／截图／终端历史。任务25的受信版本化贡献目录和三个真实工具迁移仍待实现；原生在途关闭、第三方MCP互通、AX／多屏／物理热键、真实IME／VoiceOver、长来源／完整视觉、最低系统和长期驻留仍依各自合同验收。独立界面的基础材料和本轮截图子集不代表完整Liquid Glass视觉矩阵PASS。

全局iSpec audit仍保留两个无start的旧measurement，不回填伪造；当前apply继续运行，回执逐项复核与全产品验收分别记录。原始Unicode复现失败、MacAdapters错误依赖的编译失败、系统确认框截图空白及历史OCR失败继续保留。
