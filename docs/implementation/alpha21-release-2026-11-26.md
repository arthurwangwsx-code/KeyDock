# alpha.21发行与真实模型验证

2026-11-26。[公开alpha.21](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.21)固定于干净源`5712546d072414772f8eb65846eed8ea4e1d968f`、build21；受控fast-forward晋升master，旧tag和资产保持不变。完整P0–P4仍PARTIAL。

## 构建与分发

最终本机`ai-model-full-check-v4`通过985 Swift执行、142 Python、981中英key和原生产配置合成OCR双轮；资格摘要`1aa717ee5c4d41f583edfeddff15fa91c869da6daaba2ce2330b9ccf47bdb01e`，summary在`.local/pipeline/20261126T035128298578Z/check-summary.json`。指定[core CI45751575658](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45751575658)、重复[master CI45754790133](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45754790133)和[公开发行审计45754842571](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45754842571)均通过；云端系统OCR继续NOT_QUALIFIED。

Developer ID team `J56BFQN5PZ`、Hardened Runtime、App／DMG公证Accepted、装订、Gatekeeper及只读挂载App一致性通过。冻结候选`.local/pipeline/20261126T040351513595Z/package`，App公证ID `0762471f-238e-4c6b-94cb-9540fe3ac572`。先draft回下载验签／摘要，再公开prerelease并再次回下载；`ai-model-publish-v1` exit0，receipt SHA256 `277cd82fd903cd9820085ec7c8cdfd1db97d33e45df15dc23a8aa7aa0033643e`。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.21-macos-arm64.zip | 3596541 | `3f9825b8c88fed4a76f99c41b163b9bf29be5946c1c4be8724477812822c1225` |
| KeyDock-0.1.0-alpha.21-macos-arm64.dmg | 4115940 | `75f2093ca6c73b351b6ac8d92dd0ae9a3b5911130ddd5e6610ea4e5877c32eb7` |

正式App已原子替换，About实际观察到alpha.21(21)。安装事务`83a7053d-eaf4-432c-b87c-69f14b3cb971`，receipt `.local/pipeline/20261126T040618229761Z/install-receipt.json`；bundle摘要`fc6b3d8bfd2c8c38023fcfba4868c956749aada93e7800b41dc41ef088604692`。alpha.20副本保留，未实际反向交换；保存schema2后旧配置reader不能安全覆盖新设置，不能把保留副本宣传为无条件可回退。

## 真实API已观察子集

正式App同一PID93837、合成输入、原Keychain凭据，开发工具未读取或记录凭据。全局Sol／Automatic→Responses／low／4096，翻译场景Luna／继承4096；当时none只观察会话画面，后续重启未保留，旧请求不能据此宣称none；原端点及密钥保留，保存反馈和最终设置已观察。

| 场景 | 实际输入／输出token | 结果 |
|---|---:|---|
| 翻译场景覆盖 | 61／31 | 中文保留周五、15:30及12项 |
| 中文总结 | 91／44 | 两条中文保留12、11通过、1待复查与评审时间 |
| 只读Agent总结 | 225／44 | 无需工具的正常完成 |
| 只读Agent时间工具 | 458／56 | 两次模型请求；真实current_time结果及中文UTC回答 |
| CLI草稿 | 172／112 | 精确touch参数，按对应任务进入审阅并取消，目标文件未创建 |
| 通用Agent时间工具 | 416／50 | 仅开放时间工具，两次模型请求，中文UTC回答 |
| Trim→AI总结 | 73／29 | 两步完成，保留8/8及周五15:30 |
| 中文活动总结 | 419／290 | 仅旧合成1条事件，中文说明部分覆盖及记录关闭 |
| 英文活动总结 | 415／233 | 同一合成事件，英文说明边界 |

另有57／20 token的ASCII输入控制请求：CUA typeText未提交中文，已检查实际输入并用paste重新发送完整中文；该次不作中文质量证明。合计10个run、12次模型请求，2387／909 token；新模型未配置费率，费用保持未知，未虚构账单。原alpha.20俄语FAIL保留；本版中英文活动结果通过，未实际覆盖运行中切语言竞争。

`openai-models-live-native-v1` exit0，receipt SHA256 `70c091077f1a547bec699e3b602a262141a52715bae83f1d068efbde6b97bf19`。私有观察根`.local/desktop/OpenAI-Models-Live-69e4cb02-bca3-4525-a110-2630362c9f3e/`；同一App实例确认，命令标记文件缺失。语言恢复system、记录始终关闭。补充复查纠正原1009加总及none参数判断，原证据附correction且保留原字节；alpha.22明确单独保存none、正常重启及55／26真实翻译证明见[后续原生复查](model-inventory-native-2026-11-26.md)。仅本次合成观察子集PASS；20条质量样本、所有模型／参数／协议、离线限流取消、物理热键／插入、IME／VoiceOver／多屏／完整视觉／长期驻留仍开放。
