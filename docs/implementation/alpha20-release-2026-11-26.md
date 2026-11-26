# alpha.20发行与安装证据

2026-11-26。[公开预发行](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.20)固定于干净源`aa0edfc23f01476ebbc3befeef477da684382f0d`、build20。仓库已回查为public，默认分支master；该提交经受控fast-forward晋升。完整产品仍PARTIAL。

## 同源资格

最终`compact-ai-final-check-v1`通过920项Swift执行、137项Python、931条中英key及生产配置合成OCR双轮；summary为`.local/pipeline/20261126T003329032202Z/check-summary.json`。App内规范资格摘要`61a40d77f59e58c764c10f5784fc7d1e959c6f4e1e857cd28da2095571c73478`；测量receipt SHA256 `1b2d8b11b38d5e3b47d4be2afe6333a160c3d79d5192346e894884bfacd81ca3`。

指定[同源core CI45729621200](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45729621200)与优化Preview构建通过，云端系统OCR仍NOT_QUALIFIED。[独立发行资产审计45731164962](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45731164962)通过。重复master CI另行记录，不用其当时的运行中状态代替已完成指定资格。

## 新候选协议的实际发行

候选目录`.local/pipeline/20261126T004437925983Z/package`。App公证ID `e53d2dc6-fe77-41c7-9f70-9439f63d7e7c`，DMG公证ID `8e34aceb-03c7-4ada-abeb-9cd496ea11a0`；持久回执均为accepted，payloadVerified=true，Apple证明的jobID／Accepted／SHA与固定输入一致。

App提交输入为3441708字节、SHA256 `ab8932a0df56a76c66c5698740a22c36d5443f1c80882fd83c799949ceb0c04b`；DMG提交输入为3945758字节、SHA256 `b56df03d9d1fb55606686b28744db6fe18fc5638eb8f6159e86ac5a39cb0af86`。提交输入保留不变，装订和分发使用独立消费副本。Developer ID team `J56BFQN5PZ`／Hardened Runtime、App与DMG装订／票据／Gatekeeper、最终ZIP与实际挂载DMG内部App一致性均通过。

`alpha20-package-v1` receipt SHA256 `258b4b5dfda0efc81690515fd7bdeb43273b1fe8c4367a9fa8447d4b631665ef`。旧hdiutil命令在macOS27.2有弃用提示，本轮成功；未修改或结束历史系统helper。任务34.4的新协议端到端发行因此具备实际证据，不再只依赖alpha.19历史Accepted输入探针。

## 公开资产

先上传draft并回下载验证，再公开prerelease，公开后再次回下载。GitHub回查draft=false、prerelease=true，发布时间`2026-11-26T00:46:45Z`。`alpha20-publish-v1` receipt SHA256 `624b558ea54f9cdbd05ec760fad6fef6741707725fd323d8ec444d2d78a380d7`。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.20-macos-arm64.zip | 3443080 | `4beb3c9c260695c3331242e8990e2e77654779b99ec0545a77b2ce531575b242` |
| KeyDock-0.1.0-alpha.20-macos-arm64.dmg | 3947490 | `3e4d43b28f5b68e820f0fa6316148ab5f90562828d8df8214a18c6d524a488d0` |
| release-manifest.json | 5384 | `e5f42fc5e96bd2d0fc09e4937afdcb6d11d6071104cdf9ec871a4cd807ac0477` |
| SHA256SUMS.txt | 298 | `0656932dda6506b8fb698d55d3bc1a6ed45ca787493c8a6aad55dee1df596907` |

manifest携带App签名、资格、公证及源身份信息；不把JSON本身表述为另有独立数字签名。

## 本机替换与回退副本

正式`/Applications/KeyDock.app`已更新为alpha.20(20)、源aa0edfc、非SafeSmoke。bundle SHA256 `856c84f78ae5641d3f05e7c7ce7a49af08192d826eb72cc6a6c0e7c0802974b8`，与公证候选App逐字段／逐摘要一致。实际中文About页面已观察到`0.1.0-alpha.20 (20)`及统一支持邮箱。

事务`21b2d1a8-f12f-4b35-a61d-98d2d1ffd0f3`，receipt `.local/pipeline/20261126T004813119484Z/install-receipt.json`。旧alpha.19保留于`/Applications/.KeyDock.app.keydock-backup-21b2d1a8-f12f-4b35-a61d-98d2d1ffd0f3.app`，源e488496、bundle摘要`53ef17286197d7dce8b9ae997ef81deaf8d211baeda85699c393a3dd24caafa4`及签名／票据另行核验。此次未对正式App执行反向交换；已有owned签名Preview的reader门禁／安装回退资格见任务35.5，不冒充真实旧版运行。

最初误调用通用`install`且缺`--app`，参数校验exit2，未替换目标；该FAIL回执保留。随后使用发行专用`install-release`成功，receipt SHA256 `1e19bbe47058b21f0eefc26178fe90cdd42413a001dbdff066e0e8a33c9da9c4`。独立安装后验证`alpha20-installed-proof-v1` receipt SHA256 `18b9b3f9abdc6257959965f9098799a2051c997d432de36a69427859badf83ff`。

## 产品与证据边界

本版交付可选内容保留、独立内容库、明确保存／查看／删除与新尝试输入复用，以及原生大结果阅读、compact关闭确认和固定操作层修补。[UI记录](task-material-ui-2026-11-26.md)保留原卡顿、按钮漏绘、未呈现关闭审阅及修补后的分源证据。1MiB部分结果保存精确字节核验、900000字节范围、128KiB材料、中英明暗等均仅是已观察子集。

完整焦点／视觉、真实插入／物理热键、AX／多屏／IME／VoiceOver、最低系统、长期驻留和真实外部AI质量保持开放；API按用户决定稍后配置。完整RunStore、Agent预算、原图附件等[剩余工程](../technical/remaining-engineering-2026-11-26.md)继续推进，不以发行成功关闭P0–P4目标。
