# 服务模型清单原生复查

2026-11-26。alpha.22固定源`afa41924f2061c0ad30f723538e50fbf87cf547f`已完成本机1000 Swift／142 Python／989 key、生产OCR双轮、[同源CI45756933917](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45756933917)、签名、公证装订与本机安装；首次CI取消测试竞态及修正见[技术合同](../technical/ai-model-inventory.md)。本候选因下述真实刷新失败未晋升master、未创建tag、未公开Release；公开版本仍alpha.21，App／资产不覆写。

冻结候选`.local/pipeline/20261126T045223255165Z/package`；App／DMG公证分别为`c36d64bf-3f79-4f76-af9f-98189c2e33cf`、`79001f7d-4b82-4096-90df-73f16c7d9a5c`，Accepted。安装receipt `.local/pipeline/20261126T045345240363Z/install-receipt.json`，事务`cb0bb01b-9368-4c0b-bc03-bb7cca627121`，bundle摘要`66e92fd5793643c450f9f23a43f81694f3c18e99a57d77b37439eea6a46e7bc0`；alpha.21副本保留，签名配置reader接受当前schema2。

`ai-inventory-live-native-v1`只使用正式App及原Keychain槽位。已观察About22、两次真实GET各返回103模型，原全局Sol及翻译Luna选择未改；官方推荐与返回ID明确分开，动作编辑器显示98条额外服务ID，取消不保存。随后英文界面两次刷新失败，旧103清单及时间仍保留，提示未带错误正文；失败原因当时未暴露，不能直接断言是HTTP状态或队列。AI账本仍22次、3801／1711 token，证明清单未增加模型请求。语言恢复system、活动记录保持关闭。

另发现此前alpha.21“翻译none”仅凭会话设置画面判断不足：alpha.22初启实际为继承low。明确关闭菜单后单独保存，再从动作编辑器及正常重启确认none已持久化；随后真实Luna翻译55／26 token，中文保留周五16:45及7项。无需修改配置解码规则。不能倒推旧alpha.21请求已用none，旧证据保留并附correction。旧12次调用的输出合计由1009纠正为909（各行值未变）；账本22次的1711＝旧802＋909，输入3801＝1414＋2387。

私有观察根`.local/desktop/OpenAI-Inventory-Live-d1801a28-e42b-4c80-8f14-ce9ddd37b680`，receipt SHA256 `1772ec9db9940ac45a102fd52ca420666acb43e020a4e304fdcd21fee6ed6dcb`；测量exit0只说明观察记录成功，产品结果PARTIAL。sameApplicationInstance=false来自明确正常重启，不冒充同一PID。原alpha.21 receipt原字节保留，另加correction-v1。未记录凭据或个人内容。

后续发现可复现的传输缺口：pretty JSON按换行消耗SSE的64槽，可能在未达正文上限前丢弃。alpha.23源码对严格application/json按4096B合并、256槽即1MiB；SSE保持64槽逐行及尾块检查。补充强制延迟消费的512-ID真实loopback和固定错误类别，仍为15秒／1MiB／512ID／4MiB工作预算及cancel→实际drain。不凭源码修补宣布真实故障已解决；新二进制实际刷新和发行另验。
