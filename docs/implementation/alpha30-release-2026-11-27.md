# alpha.30 应用图标与 AI 快速配置交付

2026-11-27，精确发行源 `315b499d959cb0297a1d35e81216eee926b88c1c`，由功能提交 `b691984` 与实际包图标元数据修复组成。[alpha.30](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.30) 已公开为预发行，publishedAt 为 2026-11-27T08:35:30Z，非 draft，四项资产均 uploaded。

## 实现与验证

- [交互合同](../technical/ai-service-quick-setup.md)：新用户草稿 OpenAI 预设、显式获取账号模型、推荐和账号目录分组搜索、选择默认模型、Keychain 事务保存，高级配置及场景覆盖保留。六项定向合成 Swift 测试覆盖草稿、来源、密钥隔离与保存等边界；未调用本次用户真实 API。
- 图标沿用蓝紫玻璃钥匙坞与星光构思，以可维护的矢量绘制重新生成 16–1024px ICNS，而非逐像素复用聊天中的原图。首次实际构建存在图标资源但 Info.plist 未指向该资源；修复后优化 Preview 和正式 App 的 CFBundleIconFile 均为 AppIcon.icns，实际包内 ICNS 与源文件字节一致。新增构建门禁和两项图标回归。
- 本机精确源全量检查 PASS：1,109 次 Swift 执行、168 项 Python、1,054 个中英文案键、两轮生产 OCR。资格摘要 `db063005bb810369523e4725599a394234907d886addbb1a6558b90f7378d4f7`；同源[功能分支 CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45964662010)、[master Core CI](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45965269894)及[性能检查](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45965269903)均通过。
- 隔离 Preview 构建通过；桌面观察工具未识别新窗口，原生点击和视觉验收未完成。不把示意图、模型 GET 清单或合成测试当作实机点击及真实生成证明。正式本机安装仍为 build 28，未替换。完整产品资格 PARTIAL。

## 真实发行

`make ship` 退出 0，receipt stage 为 published-and-verified，receipt SHA256 `4b5c8f463f52dc423308034121124503931f84d62b8a73bc76e607670a8ececd`。Developer ID、Hardened Runtime、App 和 DMG 公证装订及 Gatekeeper、公开前后回下载和资产一致性检查均通过。App 公证 ID `5c7d0314-42f8-4f2c-9cfd-63d552f62948`，DMG 公证 ID `c544269e-5e29-4a39-a9ea-8db60c854ac6`。[独立公开发行审计](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45966857546)已完成，结论 success。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.30-macos-arm64.dmg | 5760371 | `3e3fe10d7d15edacef80150ef670a50ea5dc014b804b6a0ed8dcf15d71d1ce85` |
| KeyDock-0.1.0-alpha.30-macos-arm64.zip | 5229222 | `77f51735033f7bcaa64a7b58febca73cbf15842232e2bb0e7e22cf65bb039f25` |
| release-manifest.json | 5560 | `64cacec83fec4bbbbd752011526c8739daac51b4b5b06235eccebf4bfe429e8f` |
| SHA256SUMS.txt | 298 | `351e9b2351da720bcc8a2ca7e3873ad42e8d456daadb702e2c4c7f9513256db5` |

旧 tag 与资产不改写；日志保存在本机 .local/pipeline/20261127T082354732358Z/。hdiutil 旧挂载参数弃用警告保留，不影响本次通过。此次证据文档提交不改变发行源或资产。
