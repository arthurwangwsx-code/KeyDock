# alpha.11发行与安装证据

2026-11-25。公开tag `v0.1.0-alpha.11`精确源`9f8d6d5b39579c85f1edeec55cace27fb8fcf62a`，公开prerelease于05:11:25Z；已替换`/Applications/KeyDock.app`，实际About为**0.1.0-alpha.11 (11)**。完整产品仍PARTIAL。

本轮接通受信版本化工具目录、三个生产迁移与独立工具开关，详见[实现与原生复查](trusted-contributions-2026-11-25.md)。双只读Agent复核，canonical源码、分支、构建和设备均由主Agent串行操作；未使用worktree或复制checkout。

## 同源资格

| 项目 | 结果与证据 |
|---|---|
| 本机完整检查 | 671 Swift（core661＋Terminal9＋生产OCR1）、46 Python、708中英文key；650声明ID，其中core640／Terminal9／OCR1，参数化执行另计 |
| 清单摘要 | `8744359731b0e6cc0e5d6fe19c40d8c01718d4e92b21fea034f39e763f067617` |
| 原生产OCR | accurate／revision3／自动语言／校正／支持CPU配置双轮PASS；同一合成PNG `06db6e05ce33913ef1ec983f48496c89ff7112b5f2a1ab26dd782f349499e161`；历史失败与长期可靠性PARTIAL继续保留 |
| 完整measurement | `bf04cda0-2a46-4b7f-aae8-20342f8f6554`，85.247s，`.local/pipeline/20261125T050006257945Z/check-summary.json`，文件SHA256 `3180ccc41bc6f3f8f006c285a29044bf672d4f08e6b34642520b54be4144780e` |
| App／manifest资格摘要 | `de9a4aa83cbfb4a22eeb02716711d0ca4bd49f83feb5bf3ba726b8c01b2775d7`，macOS27.2／Xcode27.2／arm64；最低系统和Intel未验收 |
| 同源feature CI | [45550500092](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45550500092) PASS，job138990404645，670 Swift／46 Python／708 key、Release优化Preview；云端系统OCR明确NOT_QUALIFIED |
| CI日志回下载 | artifact14994101272，90,490字节，SHA256 `6786f36880fed55958657aead97596f84d66f5ce22ae279c4bada50731f43a89`；21份文件读取，summary所引日志逐项匹配，10份stage JSON均exitCode=0；`.local/desktop/alpha11-ci-9f8d6d5-summary.json` |
| 本机Release archive／签名 | measurement `75d05c59-1695-4a07-9a06-9ce61fd59e91` PASS，63.472s，Team J56BFQN5PZ、Developer ID、Hardened Runtime；`.local/pipeline/20261125T050156154038Z` |

初始c5a82ee完整检查因旧测试假定单一query provider失败，更新测试为精确provider计划、准确结果及绑定后，新源9f8d6d5获得完整资格；原失败measurement ac25c791及前序新增测试编译／夹具失败不删除。c5a82ee的远端运行被新提交自动取消，不计PASS。

## 公证与公开资产

package measurement `e6584b25-c4ae-415f-a8bf-ac1c54b9f7d9` PASS，75.232s，`.local/pipeline/20261125T050832760070Z`。App submission `dcf2be63-766e-4861-9d92-ebb4285ea0e5`、DMG submission `65155d08-38f8-4f76-b154-e11fe14b8d1b`均Accepted；装订、ticket、Gatekeeper及只读DMG内部App一致性全部通过。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.11-macos-arm64.zip | 2513005 | `683e25a3a6741718be5a29f7a78ce8233abdd1d5fd81c970631a891444692f33` |
| KeyDock-0.1.0-alpha.11-macos-arm64.dmg | 3073062 | `4119a4d9e40e666a1e96d1f612af5343373b22418b2905374c463728314aa439` |
| release-manifest.json | 5071 | `9d66ec1df83e08a88fa7fd5abb3df104b9d983bb5efa46b36fcd663e73e33e36` |
| SHA256SUMS.txt | 298 | `f511fcd12825ac020f408726ee63b72537fbf2994a4d83ef1856b1da26f9e916` |

首次publish因主Agent漏推精确tag在上传前被门禁拒绝，measurement `7a570e24-3d9b-488e-8be8-8c39967c385e`保留；补annotated tag并推送后，不修改资产字节重新发布。成功measurement `f5237982-f362-475b-9950-cff20e52b632`，38.132s，先draft回下载、验签／验哈希，再公开并再次回下载。[独立发行审计45551838751](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45551838751) PASS，job138994572374。旧tag／资产均不覆盖。

## 安装与回退

install measurement `8c642b3e-e004-42d6-8fde-0836a8ac156c` PASS，9.152s；transaction `f1f06b21-fde3-4bc1-9403-bc950d1f7403`。正式目标`/Applications/KeyDock.app`，bundle SHA256 `cabe8f703eff7a258f7c791d80621f8722010b4af6ef8059e9910322563457a9`，源／build／Developer ID／Team／notarized均匹配。实际原生About显示alpha.11 (11)和统一支持邮箱arthur.wang.wsx@gmail.com；独立“内置工具”页三个开关为on。

alpha.10旧App保留在`/Applications/.KeyDock.app.keydock-backup-f1f06b21-fde3-4bc1-9403-bc950d1f7403.app`，源64254e5，bundle SHA256 `0db887b115ff0a0a741848d710534330694dfeeb86499489f31a45c6852d2d7b`；rollback_available=true，本轮未实际回滚。原alpha.10构建App／archive／result已同卷保留到`build/pipeline/release-history/0.1.0-alpha.10-64254e55-87089991-dd45-4265-9ea0-6e04756c9c2a`，移动前后摘要一致；alpha.9及更早历史和公开资产继续保留。

## 完整目标仍开放

正式alpha.11隐私页仍显示需要辅助功能权限，本轮未改TCC、配置真实API或读取个人剪贴板／媒体／终端历史。AX下跨应用插入与窗口控制、多屏／物理热键、实际IME／VoiceOver、完整视觉与驻留性能、原生在途关闭、独立第三方MCP及完整资源交互仍依原合同验收。工具目录实现和原生配置子集PASS不替代全产品日用验收；真实API仍按用户决定稍后配置。

iSpec当前apply继续运行；全局audit保留两项无start的旧measurement，不伪造旧记录，也不把命令receipt审计当业务验收。此次发行的源为9f8d6d5，后续文档提交不改变这个tag或包。
