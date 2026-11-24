# 应用目录卷观察生命周期复查

2026-11-25。主Agent独占修改／构建／设备，子Agent只读审阅。继续`fix/ui-semantics-and-text-sync`；正式alpha.7、alpha.8 OCR未放行与原P0–P4义务不变。

## 真实失败

源`9cd6d1052876a40c8800e238e9da46100fd00ff7`本机cloud-core的508 Swift／46 Python／615 key通过，但[同源CI 45493283966](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45493283966)的源码／流水线阶段FAIL，优化构建被跳过。远端macOS27.0.1 arm64／Xcode27.2，唯一报告为`ApplicationCatalogTests.watcherPreparationCannotBlockTheMainActorOrLauncherRefresh`中`catalog.start()`小于100ms的断言；该用例整体0.584秒。没有重试旧run或把本机绿测当作远端成功。

源码复查确认`start()`在MainActor同步首次访问NSWorkspace通知中心并注册两类卷事件，`stop()`也同步重新访问中心并清理。日志未记录这些调用的单独耗时，故不能认定这就是本次超时的唯一根因；这些无时间上界的系统准备仍是应移除的同步路径。

## 修复合同

卷观察与目录观察纳入同一后台准备代次。先创建卷监听，再准备目录监听；目录factory失败保留卷失效通道并报告失败，后续扫描与TTL恢复仍可用。扫描继续等待准备完成，覆盖监听建立期间的变化。刷新取消旧准备，在后台清理已发布的旧代次；未完成的旧准备返回后自行清理，新扫描只等待自己的准备代次。

volume lease保存创建时的center和tokens；stop先停用共享signal，再移除tokens，不重新访问NSWorkspace。回调不读通知正文，只将失效信号排到MainActor，并核对running／observing／generation。取消、迟到candidate、停止后排队信号及重启后的旧通知不得发布。

Apple明确允许从任意线程访问[NSWorkspace.shared](https://developer.apple.com/documentation/appkit/nsworkspace/shared)与[notificationCenter](https://developer.apple.com/documentation/appkit/nsworkspace/notificationcenter)；[线程安全摘要](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/ThreadSafetySummary/ThreadSafetySummary.html)将NSNotificationCenter列为线程安全类。目录／卷的token和状态仍各自同步，界面发布只在MainActor；该合同没有把其他AppKit UI API移到后台。

## 验证

| 检查 | 测量 | 结果 |
|---|---|---|
| 定向v1 | `6c160967-8aa6-4865-a013-687dde66188b` | PASS，23项／3 suite，21:52:14Z–21:52:59Z |
| Preview构建安装 | `127b67c4-7329-40e8-9ab6-49054c49a788` | PASS，21:53:33Z–21:53:59Z；正常退出／替换并保留回退回执 |
| 定向v2 | `d86175b2-d74e-4142-a4da-69af08080b3c` | PASS，23项，21:54:54Z–21:55:08Z；修正重启夹具以第二次实际onChange发布确认就绪 |
| 干净源完整cloud-core | `ee52be18-eccb-4aa9-8b54-960068ef523a` | PASS，源`df2a3674d779b621b207daf2c08edca5dadf7cc3`，21:59:57Z–22:01:20Z；513 Swift／46 Python／615 key |
| 同源远端core与优化构建 | [45496727323](https://github.com/arthurwangwsx-code/KeyDock/actions/runs/45496727323) | PASS，job138809085185；源码／流水线检查、Release优化Preview、归档与诊断上传通过；OCR诊断未运行 |

原两条100ms断言完整保留，只增加耗时诊断；v2该用例本机start约39.166微秒、refresh约15.291微秒，仅为本次方法调用样本，不是UI热唤起p95证明。新增五项覆盖阻塞卷准备期间的start／refresh响应、准备中停止后迟到结果、旧通知不能刷新重启实例、目录准备失败仍响应卷失效，以及停止后排队／后续信号拒绝。

合成测试使用私有NotificationCenter与自建临时应用目录，不发布真实系统卷事件或读取通知正文。重启测试等待真实发布而非旧缓存条目，避免过早宣告新监听就绪。

原生Preview实际打开，通用页手动刷新后仍可操作；返回Launcher搜索Activity Monitor得到正确应用结果，随后清空查询。没有启动该应用、修改偏好、操作卷、授权或读写个人剪贴板。它验证了启动／刷新／搜索路径可用，不计100ms真实UI或长期性能通过。

本机摘要`.local/pipeline/20261124T215957810871Z/check-summary.json`绑定上述干净源，清单493个声明ID（core483／Terminal9／OCR1），inventory SHA256为`490639917976052f08d645f06872b0fa88a2064219f5f38c7563292cfd718908`。参数化执行次数与声明ID分别记录。cloud-core与远端CI的系统OCR均为NOT_QUALIFIED，不构成发行资格。

OCR完整本机门禁、最低系统、真实热唤起／耗电及完整产品验收仍未关闭；旧CI失败与日志保留。正式版仍为alpha.7，未晋升master或发布alpha.8。
