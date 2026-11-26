# alpha.23发行与模型设置交付

2026-11-26。[公开alpha.23](https://github.com/arthurwangwsx-code/KeyDock/releases/tag/v0.1.0-alpha.23)固定于干净源`3b0dfe2dbcabea16120b887d461e4f5aa4b5a8bb`、build23，经受控fast-forward晋升master。原alpha.21 tag／资产不变；alpha.22保留本地公证候选及真实刷新失败，未建tag或公开，不覆写其输入。

## 同源资格与分发

`ai-inventory-json-full-check-v1`通过1002 Swift执行、142 Python、994中英UI key及原生产OCR双轮。summary `.local/pipeline/20261126T050434141772Z/check-summary.json`，规范资格摘要`8dc9c8eb030a7b219fac7fe7146bca29647a48719f33daa3775011f122f8be1a`；测量receipt SHA256 `3f5cc8e86261bc15d0f09f59f82d24a683fc8ff3a30c80c97367b53320eecbc0`。

指定[同源CI45759194770](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45759194770)及优化Preview构建通过，云端OCR保持NOT_QUALIFIED。[独立发行审计45760565498](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45760565498)通过。重复master CI另记，不替代已完成的指定资格。

Developer ID team `J56BFQN5PZ`、Hardened Runtime、App／DMG公证Accepted及装订／Gatekeeper、只读挂载DMG中的App一致性通过。冻结候选`.local/pipeline/20261126T051205583680Z/package`；App与DMG公证ID分别`7c24b3b2-afd1-4637-b22a-1ef68cb077e3`、`dd0a580f-abb7-42a5-aacf-2f7a1ccb849b`。发布先draft回下载验签／摘要，再公开prerelease并再次回下载。publish receipt SHA256 `37b08de87fcf485651a9f0c54cf92808466293f1624d6f7f330d58ab575da0cd`。

| 资产 | 字节 | SHA256 |
|---|---:|---|
| KeyDock-0.1.0-alpha.23-macos-arm64.zip | 3632201 | `0bd5bb4648819d15772e69e3b8bc01380b89fafa449476d64fdf698c2c71efd9` |
| KeyDock-0.1.0-alpha.23-macos-arm64.dmg | 4154116 | `4b0c8694f0f2edf9812f298e6c9228e6a9e045ad94fe0ac20ce214409949276a` |

正式App已原子安装，实际About显示alpha.23(23)。receipt `.local/pipeline/20261126T051321055877Z/install-receipt.json`，事务`429db41d-6c67-45e6-b0ea-c790b7dc27a7`；bundle摘要`eda657f8e73cb93b7a58a689d54a0f15b0e662c19878159fffa120990ef40f44`。alpha.22副本保留，回退仍须重新检查当前数据reader；未实际反向交换。

## 正式App真实刷新

`ai-inventory-json-live-native-v1`：同一PID30761，已观察中文／英文各连续3次GET，6次全部返回103模型。中文当地时间13:14:28／33／37，英文13:15:15／18／23，Asia/Kuala_Lumpur。全局Sol low／Automatic→Responses／4096和翻译Luna none／4096未改变；none从alpha.22明确保存与正常重启后跨升级保留。推荐日期与服务清单独立，无自动换模或能力推断。

账本仍23次、3856输入／1737输出token：它等于alpha.20的10次、alpha.21的12次和alpha.22重启翻译的1次；本阶段6次清单请求新增模型调用为0。新模型费用未配置费率，保持未知；旧4.1 mini手工估算不改变。语言恢复system、活动记录保持关闭，未使用个人内容或记录凭据。此为已观察子集PASS，不是全部模型／服务／网络条件可靠性证明。

私有观察根`.local/desktop/OpenAI-Inventory-JSON-Live-4fbf2021-6f74-4d43-b770-cf04c3f9b731`；测量receipt SHA256 `33d1962686fb122030bbeb5be45148a0f60da32721dc127a3b44ff5a6975881d`，sameApplicationInstance=true。alpha.22两次成功后两次失败及旧none判断／加总纠正完整保留，见[原生复查](model-inventory-native-2026-11-26.md)。旧失败没有记录具体错误类别，不倒推唯一原因。

## 交付范围

全局、九场景及定义逐字段覆盖，共用中英模型选择器；模型默认省略、继承与明确none分开，按已知能力约束强度。真实翻译／总结／CLI审阅取消／两种Agent时间工具／Workflow及活动语言的分源证据见[alpha.21记录](alpha21-release-2026-11-26.md)与原生复查。配置schema2和签名reader门禁保留。操作入口见[使用说明](../product/model-settings-guide.md)。

完整P0–P4、20条模型质量样本、在途切语言、全部服务／错误／参数组合、真实插入与实体快捷键、AX／IME／VoiceOver／多屏、最低系统与长期驻留仍开放；不以本增量关闭更广义务。
