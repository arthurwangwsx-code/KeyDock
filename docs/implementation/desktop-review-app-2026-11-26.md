# 独立桌面验收App接线与原生复查

本增量承接任务36.3–36.5；完整P0–P4仍为PARTIAL。正式公开与本机安装仍为alpha.23、源`3b0dfe2`；本轮配对是本地开发工具，不进入安装／package／publish白名单。

## 工程资格

最终代码源`afb97cbe7a73ab42536cf61a6588ce752c5f07a6`：

- PASS：完整本机检查，1012 Swift执行／151 Python／1003中英文key，991 inventory ID（981 core＋9 Terminal＋1 OCR），生产合成OCR双轮通过。`.local/pipeline/20261126T064229838616Z/check-summary.json`，SHA-256 `824a55b1cbf6a0136fa9f48f7695a8da3169c6f3368fcdb6a93feea97a7b5157`；测量`receipts/desktop-review-full-check-v2.json`。
- PASS：[同源CI 45768775028](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45768775028)，包括核心检查与Release优化普通Preview；云端OCR仍不授予生产资格。规划检查45768775078通过。
- PASS：最终Developer ID签名配对，测量`receipts/desktop-review-signed-pair-v5.json`；本地manifest为`build/pipeline/desktop-review/pair/pair.json`。先签名companion，再绑定最终binary／Info摘要并签名Review。Review binary SHA-256为`f875622a0616c9c463b710f8ae59ac23fdec384d659053775fce780fedfb6554`，fixture binary为`b99feb402155d3581d32d1f07f876d577c22981f926d160e2c8992de167a7046`。
- PASS：正式App配置另在前序代码`cf21df7`完成原生Release编译，`receipts/desktop-review-production-compile.json`；它不能代替最终源的正式签名发行。该源的1009 Swift／151 Python／1002 key及同源CI45766690542亦通过。
- PASS：最终45项定向覆盖配置／Scope、跨profile参数拒绝、native editor、取消后丢弃槽位仍等待真实worker、首个失效类别保留。测量`receipts/desktop-review-diagnostic-tests-v2.json`。流水线9项新增回归含真实owned Python TERM/HUP，未调用真实App或系统权限。

## 原生观察与未关闭项

| 项目 | 结论 | 范围 |
|---|---|---|
| 独立设置与原ClipboardPanel | PASS子集 | 实际签名启动；固定合成宿主，设置、面板和菜单入口分离 |
| 查询／有序合并／复制 | PASS子集 | 合成3条记录、筛选、Shift-Return多选、按顺序合并、预览焦点下Command-Return复制已观察；普通键入正常 |
| 输入拒绝 | PASS子集 | Review查询Command-V未改变查询；原生editor的paste／readSelection拒绝与键入／IME组合测试通过。真实拖入与完整IME矩阵仍开放 |
| 双语与外观 | PASS子集 | 中文浅色、完整英文深色设置、窗口标题、F18标准键名及英文面板已观察；完整视觉／对比度／VoiceOver矩阵未关闭 |
| 明确重启 | PASS子集 | 同一PID/birth的companion保留；新Review实例恢复English、Dark、F18及3条历史，新auxiliary session，不重放旧任务 |
| 失效保护 | PASS子集 | `afb97cb`记录`targetIdentityChanged`后，所有Review设置／操作禁用、提示重启、快捷键停用；原因只记录固定类别 |
| 实际插入消费 | 待权限 | Insert仍因缺Accessibility／事件权限而禁用；未发送或宣称目标恰好消费一次 |
| 全局热键／实体键盘 | PARTIAL | 录制及持久化已观察；CUA两次模拟未唤起面板，原因未确定，不能代替物理按键验收 |
| 长期稳定性 | PARTIAL | 有保留的身份失效及工具故障；不能据重启成功关闭 |

最后两组实例均由流水线精确正常退出，最终回执`receipts/desktop-review-final-stop-v2.json`；生产App未退出或替换。原生观察来自当前chat的CUA AX与单窗口截图，没有导出或上传个人屏幕内容。

## 保留的失败与解释边界

1. 首次签名源`5184426`的设置窗口被hosting controller初始尺寸压缩；已设contentMinSize并显式恢复600×720内容尺寸。`42008f5`另观察语言切换后共享行为View／窗口标题残留中文；以局部语言identity及标题回调修复，`35a113f`和最终源复验通过。
2. field editor初次指定空container没有文本网络，查询／IME测试失败；现显式持有网络。还保留初始化参数、CGFloat歧义及测试signal枚举字符串编译／测试失败。初次package raw Info预检破坏5个既有注入测试，已复用统一inspect_app端口，原断言保留并通过。
3. 首轮正常退出15秒未确认；随后CUA Escape后App退出，下一次只收口剩余companion成功。菜单跟踪与失焦均有可能，不能倒推唯一原因；后续无菜单情况下多轮正常退出通过，未强杀。
4. `cf21df7`原生设置期间曾显示会话失效，未分类原因保留。后来同宿主明确重启恢复；这不抵消原FAIL。旧次不能由新日志补写原因。
5. `afb97cb`的CUA批量尝试发生`input_required` MRTR限制，随后约295秒传输故障与kernel重置，完成载入次数未知。期间App日志记录`targetIdentityChanged`；它只表示当次probe缺失或某身份字段不匹配，不能确定哪一项或归因工具。稍后helper查询与原PID／birth／路径相同，仍不据此恢复旧scope。私有记录`.local/desktop/review-target-expiry-afb97cb.json`。明确重启后状态与3条记录恢复已观察。
6. 本轮未读取、重输或使用用户API key；Review凭据／网络／普通执行端口保持拒绝。已有alpha.23真实AI证据独立保留，未以本轮mock或原生拒绝态替代。

所有被替换的本地配对先压缩并还原逐资源校验；manifest、旧helper及retention receipt在`.local/desktop-review/pair-history/`。该保留不是异地备份或产品验收。

## 接线与后续

Review仅接收固定编译身份、safe-smoke、签名BuildInfo与一个root参数，验证后建立Scope再构造Workbench，无真实用户目录fallback。独立Coordinator只组合生产ClipboardPanelSession、HotkeyRecorder、HotkeyCenter、主动作偏好及Host／paste事务，不构造通用Launcher／Workspace或任务恢复入口。OwnedTaskLifetime持有被取消、已移出槽位的任务直到实际返回，封住退出后的新任务。

继续区分：身份失效的具体字段／时序诊断、实际目标恰好消费一次、目标变化／取消／重启、实体热键、正式App身份及完整系统／视觉矩阵。用户需在系统设置正常授予独立Review App的Accessibility；本工具不改TCC。操作方式见[独立桌面验收入口](../technical/desktop-review.md)。
