# 稳定窗口与应用动作

2026-11-24增量；当前处于alpha.6开发分支。alpha.5仍是已安装、已公开版本。实际验证与发行结果见[状态总账](../status.md)，不能把下列实现合同当作真实系统验收结果。

## 产品入口

窗口管理在快捷键设置中提供13项布局，以及当前应用的上一／下一窗口、当前窗口最小化。应用的普通绑定执行启动／激活；「应用动作」独立设置页可另外创建命名动作：启动／激活、前台时隐藏否则显示、隐藏、显示、将所有窗口置前、请求正常退出。同一应用可以有多个独立动作，并分别配置别名、收藏和快捷键。

应用与窗口快捷键直接派发，不先弹出Launcher。由Launcher选择窗口动作时使用原应用身份，收起Launcher后才恢复原应用焦点。普通应用搜索、应用动作、窗口动作仍共用目录、宿主策略与任务历史，不建立第二套授权系统。

## 目标和顺序

`DesktopWindowTarget`只捕获应用PID／launchDate与AX窗口引用，不读取选区正文、输入控件值或窗口标题。窗口成员先读取数量，再有界读取；超过128条、类型异常或读取不完整时明确拒绝，不能把截断误判成窗口关闭。窗口属性枚举有总时间预算；AX单消息继续使用120ms超时。

`WindowCycleRing`保留存活窗口原顺序，新窗口追加。它不会随系统在raise后的列表顺序重排，避免三个窗口中只在两个之间跳转。prepare只生成一次性transition，真实焦点读回目标后才commit；失败、取消、成员变化或作用域更换不能推进游标。原生worker用CFEqual匹配AX对象并分配本地UUID，不将CFHash当作唯一身份。当前应用的快捷窗口切换按8条上限串行排队；每项都重新确认同一应用实例和真实当前窗口。

布局和最小化冻结具体窗口；不能把迟到调用转移到后来激活的应用或窗口。布局保留原frame并写后读回；恢复缓存只在最终取消与关闭围栏均通过后移除。所有AX写入在独立worker执行，主线程只负责排队、系统应用激活和界面状态。

## 应用行为与结果

应用引用首先匹配目录对象修订与物理身份，然后冻结当前实例的PID／非空launchDate。多个相同安装路径的运行实例会被拒绝。隐藏／退出不启动缺失应用；启动／切换行为才允许后台启动。`toggleVisibility`根据调用时的原前台身份解析，不能在Launcher抢到焦点或异步等待后重新解释。

后台启动设置`activates=false`、`promptsUserIfNeeded=false`、`allowsRunningApplicationSubstitution=false`。NSWorkspace没有可撤回的公开请求句柄，故宿主采用独立的3秒单次回调gate。取消或超时后不激活迟到应用、不自动终止它、不重发启动，结果保留未知状态。

显示／隐藏先检查系统返回值，再观察目标状态。正常退出只发一次`terminate()`，等待目标实例实际结束才确认；超过观察期限显示“已请求”，保留应用自己的保存界面。没有强退、kill或自动关闭保存提示。将全部窗口置前使用公开的activateAllWindows选项；只能报告请求接受，不将“应用已激活”当作所有窗口、最小化与Spaces均已逐项确认。

显示中的unhide与activate分别请求，中间重验lease及实例，不因unhide的负返回提前跳过已批准的激活。若最终状态达成可以确认；若只观察到部分变化则保留unknown。两个步骤都不自动重试，固定原生操作枚举仅用于本地最小回执分类，不记录跨进程原始错误或正文。

实际契约依据Apple官方文档：[hide](https://developer.apple.com/documentation/appkit/nsrunningapplication/hide%28%29)、[unhide](https://developer.apple.com/documentation/appkit/nsrunningapplication/unhide%28%29)、[terminate](https://developer.apple.com/documentation/appkit/nsrunningapplication/terminate%28%29)、[activateAllWindows](https://developer.apple.com/documentation/appkit/nsapplication/activationoptions/activateallwindows)、[启动配置](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration/allowsrunningapplicationsubstitution)。外部应用没有NSApplication.unhideWithoutActivation接口，不能声称后台显示绝不激活。

## 单次执行与恢复

`DesktopOperationLease`只能begin一次；取消、定义变更、退出或无关应用激活会撤销后续系统调用。宿主观察器允许原应用、KeyDock及精确目标安装路径的预期激活。隐藏／正常退出提交以后，系统自动激活下一应用属于预期收尾，不误当成新的操作许可，也不引发第二个动作。

宿主声明新增modifyWindow、changeApplicationVisibility和terminateApplication等实际effects。布局／应用启动的声明与工具版本升至2；Agent和Workflow不能借用真实UI授权入口。新的桌面能力没有因此自动进入模型工具白名单。

动作占用既有8个管理任务槽位，系统提交前先写最小intent。回执只存通用「桌面动作」名称、能力ID、指纹和状态，不存窗口引用、正文或应用运行对象。结束状态区分确认、无需变化、请求接受、拒绝、提交前取消和未知。重启将未收口intent显示为中断／未知，不重放任何桌面动作。

## 统一配置与旧文件迁移

alpha.24起，命名应用动作与快捷键、别名、收藏和最近使用共用主配置schema3候选事务，最多100项／1MiB。必填nullable动作字段区分canonical数组与未确认旧源；删除前检查集合引用，并在同一提交中清理准确动作ID的偏好。编辑与确认绑定初始指纹／生命周期，旧草稿不复活已删除动作。

旧`application-actions.json`只在待迁移态通过有界／no-follow reader读取，固定目录／文件身份与原字节，首次成功主配置提交前后核对。旧文件保留，不双写或自动删除；canonical后忽略旧源。主配置目录身份另行保留，目录失效时拒绝整份写入及向新映射补偿。详见[配置一致性合同](application-action-configuration.md)。

旧源发现transaction残留时不读取残留或final正文、不恢复动作或重放，来源保持未确认；其他无关设置可保存null，但旧动作及其孤儿清理停用。旧独立ArchiveStore仍供兼容测试，生产Workbench不再通过它写动作。安装／回退门禁拒绝仅支持schema1／2的旧reader。故障注入测试不等同真实掉电持久性验证。

## 合成原生宿主

`make desktop-fixture`构建独立bundle的KeyDock Desktop Fixture，在用户Applications的全新验收子目录保留构建与收据；不启动、不覆盖生产App。宿主只有三个合成文本窗口及“暂缓正常退出”开关，默认暂缓退出并显示收到的请求次数；不读剪贴板、文件或网络。

通过原生UI打开宿主后，可验证显示／隐藏、切换、正常退出只请求一次和目标文本插入。窗口AX、物理全局热键、多屏、Spaces、IME、辅助功能与最低系统必须分别记录真实证据；未授予TCC或未观察的项目保持待验收。禁止通过事件辅助程序或修改权限数据库绕过这些缺口。
