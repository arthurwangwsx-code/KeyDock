# alpha.8发行与安装证据

2026-11-25，KeyDock `0.1.0-alpha.8 (8)`已[公开prerelease](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.8)并替换安装至`/Applications/KeyDock.app`。**完整产品仍PARTIAL**。本版交付既有界面／编辑／剪贴板／工作流／目录与保存反馈增量，桌面工作区仍仅开放定义管理；组合执行、逐项汇总和profile热键继续依任务20推进。

## 精确源码与检查

发行tag固定在`009532663eeac2f1e62461975060cce5adc29813`。主Agent独占写入／提交／设备，子Agent只读评审；未建worktree、复制checkout或删远端分支。master从`703b9a1`受控fast-forward至该提交后推送，tag不随后续证据文档移动。

| 检查 | 实际结果 |
|---|---|
| 完整本机native-system | 601 Swift／46 Python／660中英key PASS；macOS27.2／M1 Pro arm64／Xcode27.2，最低macOS14未实际验收 |
| 原生产Vision OCR | 同一PNG、accurate／revision3／自动语言／纠正／支持CPU，双轮约0.417s／0.083s，原180s门禁不变 |
| [指定push CI 45521123251](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45521123251) | 同SHA的600 Swift core／Terminal、46 Python、660 key及Release优化Preview／归档／上传PASS；云端OCR NOT_QUALIFIED |
| [master CI 45523011741](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45523011741) | 同SHA的core与优化构建PASS |
| [公开发行审计45523490646](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45523490646) | job138900961567实际下载并校验版本／源／资产摘要PASS |

本机summary SHA256 `fc91aed929afe93848d13fc70d161723cfd31205d1638db8b188145feeea7632`，8份stage日志摘要／字节数均核对。App与manifest共用资格摘要`93f89c07217c31d3e4bbcdfe26beb8062609b49391e556b5b2faa49833252cdd`。清单580个声明ID（core570／Terminal9／OCR1），清单SHA256 `ddba92550532f0d16d878d50bf362746009882dd383b3da8e4621dfb7258426f`；执行数含参数化，不混用。

前序`8c2c600`的完整本机601项与同源CI亦通过；其OCR冷首轮107.875s、第二轮约0.460s。此前多次FAIL、资源状态变化与长首轮全部保留在[复发记录](ocr-recurrence-2026-11-25.md)。这两次不同精确源的规定资格通过，不证明唯一根因或长期稳定性已经解决。

## 本地签名、公证与不可变资产

所有操作使用工程既有`keydock.py`流水线。Developer ID为配置team `J56BFQN5PZ`，Hardened Runtime有效；既有notarytool Keychain profile继续复用，未导出凭据。App公证`e546a84c-7da7-4719-9560-4e4f9a91cee3`和DMG公证`a4bf681d-876a-4c42-81a8-4d7200f8557a`均Accepted，票据装订／验证及Gatekeeper通过。DMG只读、nobrowse挂载，内部App与ZIP整包摘要一致。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.8-macos-arm64.zip | 2,277,732 | `16eeaa947cca7170e0499830f33e86b7d91766c65c3c95abd75ea875ef06c2b9` |
| KeyDock-0.1.0-alpha.8-macos-arm64.dmg | 2,816,970 | `a639f05c64ce0b4237f87d6c5c24c4db1c465a034427563d409e801d455c9bb3` |
| release-manifest.json | 见最终文件 | `385b472cdf54a4b5699cf76bfffe7993124c1884c0acf378a2e6e7aa812691f1` |
| SHA256SUMS.txt | 见最终文件 | `46e35d760e4977c41a6ec92ced8ef4b7c78e47fc01a35d7f6d702e172bb219f2` |

资产保存在`build/releases/0.1.0-alpha.8`。先draft上传四项，实际回下载验签／验hash后公开，再次从公开Release回下载核对；未覆盖既有版本或其他资产。本机旧`36812e0`未公开候选的archive、App与build-result整体移入`build/pipeline/release-history/0.1.0-alpha.8-36812e07dc17a7368b79ff5824825e429e36b9a6-2fbe3bbe-d2b6-4b04-8ffc-ef71476ad561`，核对无open files及目录inode连续性，未删除内容。旧alpha.1–alpha.7发行／备份继续保留。

## 安装与原生观察

安装消费核验后的ZIP／DMG，经准确路径正常退出旧App、同卷原子替换；没有force kill、sudo、TCC或quarantine修改。新bundle SHA256 `3a6c3ca6378735446a50dc625d03fc4e007979c1e9bbe12fdb33d1a80de1782b`；回执为`.local/pipeline/20261125T010532642348Z/install-receipt.json`（SHA256 `79c519d3c0fd91143e3778ea58d2cf9850f51ff2f457a655449c62a8df756664`），状态installed且rollback_available=true。

旧alpha.7源`59d1680be17fb5713cf79834fbceec3df496ed27`及bundle SHA256 `abc2863f699b7914e3c2223d63576f0d9cf6046514ba31a20e0a396fbed54efb`保留在`/Applications/.KeyDock.app.keydock-backup-c3974768-9d5f-4dd7-a5ba-be2c3f1ebfa5.app`。本轮实际操作为安装替换，回退操作入口及条件见[工程流水线](../technical/release-pipeline.md)。配置、Keychain和用户内容不进入发行包或回退App包。

通过准确App路径实际启动，Launcher正常出现；应用菜单→关于打开独立设置窗口，AX与截图均显示`0.1.0-alpha.8 (8)`，公共联系邮箱正确。CUA只完成这一导航，没有操作语言／外观／权限项、配置API、读写个人剪贴板或布局系统窗口。此项只计安装启动与About子集，不计完整视觉／物理热键／AX／多屏／AI质量验收。

## 测量记录

| 测量 | 结果与范围 |
|---|---|
| `7775d020-1da8-4049-a86e-d04bf09d9bc9` | PASS，精确发行源完整本机检查，71.627s，00:50:04Z–00:51:15Z |
| `842fe754-88af-4a79-b564-9b8f6f5cab31` | PASS，Release archive／Developer ID构建，136.429s |
| `7dfd399d-e188-4956-b146-0b8380afbf54` | PASS，App／DMG公证装订、Gatekeeper、包内一致性，77.561s |
| `685c371c-6e54-47b6-beb1-fcbfa68bb2ae` | PASS，实际alpha.7→alpha.8原子安装替换，9.121s |
| `1864bc1f-f002-4c0b-a92e-c30fbb7ac20f` | PASS，draft／回下载／公开／再次回下载，35.038s |

全产品和下一段工作仍按[状态总账](../status.md)、[工作区合同](../technical/desktop-workspaces.md)与任务20推进。技术支持、反馈与隐私请求：arthur.wang.wsx@gmail.com。
