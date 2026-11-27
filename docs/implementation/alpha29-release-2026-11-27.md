# alpha.29 本机一键发行验收

2026-11-27，源提交 `12dbf2b1699c5197d6909d377dcd751db9423f21`，干净且与远端 master 一致。精确 tag `v0.1.0-alpha.29` 固定该源，公开 GitHub prerelease [alpha.29](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.29) 的 `publishedAt` 为 `2026-11-27T07:42:42Z`，非 draft。旧版 tag／资产未改写。

## 真实链路与资格

| 阶段 | 结果与证据 |
|---|---|
| 本机资格 | PASS：macOS 27.2 arm64／Xcode 27.2，1,082 项声明、1,103 次 Swift 执行、166 项 Python、1,037 个双语键，生产 OCR 两轮。资格摘要 `9b0fc28f6acc2294efa2edf71d8e4fbcbccfbe73316e307cac4dc1fc1bf640bc`。 |
| 同源 CI | PASS：[45956865727](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45956865727)，精确源一致；只执行 core 检查和诊断，不生成重复 Preview 安装包。云端 OCR NOT_QUALIFIED，不替代本机 OCR。 |
| 本机签名公证 | PASS：Release archive、Developer ID team `J56BFQN5PZ`／Hardened Runtime，App 与 DMG 公证、装订和 Gatekeeper；只读挂载 DMG 核验内含 App。App 公证 ID `2fcae140-edf0-467b-8b5b-06cf8e8c9baf`；DMG 公证 ID `1aac5bc8-43f2-4bbe-a186-766cc7b5cd4a`。 |
| GitHub 上传 | PASS：精确 tag 推送，draft 上传四项资产并回下载核验，公开后再次核验；GitHub API 确认四项资产均为 uploaded，isDraft=false，isPrerelease=true。 |
| 独立发行审计 | PASS：[45960343004](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45960343004)，release-assets job success。 |

首次尝试因同源 CI 尚未完成而未发行；待 CI 通过后继续原源版本，没有跳过门禁。本次实际 `make ship` 退出码 0，最终 receipt stage=`published-and-verified`。本地 ship 日志目录 `.local/pipeline/20261127T073929896563Z/`；receipt SHA256 `b51349bafe86f85025fc05b4c68225729f10434f2ae14ec0fb472767bc95e132`。构建和发行全程使用共享存储准入。

## 公开资产核验

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.29-macos-arm64.dmg | 4316116 | `6eb2264e13ac537ac83157031c221e60147899680ee2ea96f0c8111805f93e19` |
| KeyDock-0.1.0-alpha.29-macos-arm64.zip | 3791903 | `de9378a69e8309b657168d44bee01baf4a96164e6acd8c10b1cc22b362ebeb64` |
| release-manifest.json | 5560 | `a9449b022f5c470f1cee7be6af8d9be10bfb47a3ed666bcfaa23e9a133d7aaf2` |
| SHA256SUMS.txt | 298 | `f346493afdb42d2a72134f1ceb48fd6320bc70da6131b68dfed4ce6be56c9f5b` |

本地发行目录为 `build/releases/0.1.0-alpha.29`，不将二进制、钥匙串凭据及本地日志写入源码提交；GitHub Release 是二进制公开托管入口。`hdiutil` 对旧只读挂载参数产生弃用警告，但挂载与资产一致性检查均成功，后续可单独迁移到新版系统接口。

## 交付边界

本次收口 iSpec 45.1／45.2 的发行工程义务。未显式请求安装，`/Applications/KeyDock.app` 实测 build 28，未替换生产 App。该版本的最低目标为 macOS 14，未完成真实最低系统资格；实体热键、实际目标插入、多屏、完整视觉、辅助功能、长期驻留及外部模型验收仍 PARTIAL。后续文档证据提交不改变已签名发行源或 tag。
